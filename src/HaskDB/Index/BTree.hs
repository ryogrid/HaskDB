-- | B+-tree index pages + operations (internal-design/05 + design/04).
--   Entry formats (internal/05 §5.1): leaf = encodeValue key ++ u32le
--   pageId ++ u16le slot; internal = (encodeValue sep absent for the
--   structural -infinity slot 0, the flag bit of design/04 §4.3) ++ u32le
--   child.  Pages reuse document 01's slotted layout; slot order = key
--   order.
--   Deviations recorded in TODO.md (Phase 4):
--   * structural changes REBUILD the whole page from decoded entries and
--     log PPageUndo(before-image) + PPageImage(after-image): logical entry
--     undo cannot revert a split/root change, and design/04 §4.5 requires
--     before-image restoration; PPageUndo is the record that makes it
--     implementable (Wal.Apply redo/undo of INDEX_* is therefore pure —
--     image-based physiological replay; INDEX_* remain WAL markers).
--   * descend uses the STRICT rule "last separator < key" (docs say
--     separator = min key of child with the usual <= descend rule): with
--     duplicate keys a split may put copies of the separator key in both
--     children, so strict descent + chain-follow while page max <= key is
--     the rule that finds every duplicate in both directions.
--   * leaf splits prefer a key-change boundary (all copies of one key
--     stay right of the separator when possible).
--   * btreeInsert/btreeDelete take the CURRENT ROOT page explicitly and
--     btreeInsert returns the possibly-new root (IndexHandle threading of
--     internal/05 §5.2 made real; docs btreeInsert returns ()): an op
--     later in the same transaction must not descend a stale root after
--     an earlier op's root split. The caller still publishes the new root
--     into the catalog (Bootstrap.updateIndexRoot, WAL-logged).
--   * per-index MVar latch held for the WHOLE insert/delete (design/04 §4.4
--     permits the per-index structural latch; whole-op is the simple
--     reading) AND writers also take the lock-table LX on the index relid
--     for the whole transaction — closes the window where the next
--     transaction could descend a root that a committed root split already
--     invalidated (relroot publication is commit-time in the cache).
--   * design/04 §4.3 pd_special (level) and pd_flags root/leaf markers are
--     NOT implemented: page kind PKIndexLeaf/PKIndexInternal is the only
--     discriminator (recorded deviation).
--   * btreeBulk (CREATE INDEX) logs PAllocPage+PPageImage per page but NO
--     per-entry INDEX_INSERT markers (physiological replay makes them
--     useless WAL bloat).
--   * no page merging on delete (design/04 §4.5: "borrowing is not
--     required; empty leaves may remain"); empty pages stay in the chain.
module HaskDB.Index.BTree where

import qualified Data.ByteString as BS
import Data.List (splitAt, last, tail)
import Data.Maybe (isJust, mapMaybe, isNothing)
import Control.Monad (forM_, replicateM)
import Control.Concurrent.MVar (MVar, withMVar)
import Data.Word
import HaskDB.Common.Types (PageId, RelId, RID(..), Value, SqlType(TyInt64), compareSql, encodeValue)
import HaskDB.Common.Config (cfgPageSize)
import HaskDB.Common.Error (throwSql, throwInternal)
import HaskDB.Catalog.Types (RelationDesc(..))
import HaskDB.Heap.TupleCodec (ColumnDesc(..))
import HaskDB.Catalog.Cache (CatalogCache, lookupById, btreeLatch)
import HaskDB.Server.Env (Env, envBufferPool, envFileMgr, envConfig)
import HaskDB.Storage.Page (PageRef, PageKind(PKIndexLeaf, PKIndexInternal), readHeader,
  PageHeader(phNext, phKind), liveSlots, pageReadTuple, installPageImage,
  buildSlottedImage, pageSlice)
import HaskDB.Storage.BufferPool (withPage, withPageDirty)
import HaskDB.Storage.FileManager (extendFile)
import HaskDB.Txn.Manager (TxnCtx, txnAppend, lockTable)
import HaskDB.Txn.LockManager (LockMode(LX))
import HaskDB.Wal.Format (WalPayload(..), decodeValue)
import HaskDB.Common.Codec (runDecode, getW16le, getW32le, putW16le, putW32le, buildToBytes)

-- ---------------------------------------------------------------------------
-- Entry types (internal/05 §5.1) + canonical order (design/04 §4.2: (key,RID))
-- ---------------------------------------------------------------------------
data LeafEntry = LeafEntry { leKey :: !Value, leRid :: !RID }
  deriving (Show)
data InternalEntry = InternalEntry { ieSep :: !(Maybe Value), ieChild :: !PageId }
  deriving (Show)

compareLeaf :: LeafEntry -> LeafEntry -> Ordering
compareLeaf a b = case compareSql (leKey a) (leKey b) of
  EQ -> compare (leRid a) (leRid b)
  c  -> c

-- | Descend rule (STRICT — deviation note, header): child chosen = last
--   entry whose separator is STRICTLY below the key (-infinity always
--   qualifies).  Chain-follow then covers duplicate keys that a split
--   left on both sides of a boundary.
sepLT :: Value -> Maybe Value -> Bool
sepLT k ms = case ms of
  Nothing -> True          -- -infinity
  Just s  -> compareSql s k == LT

insertLeaf' :: LeafEntry -> [LeafEntry] -> [LeafEntry]
insertLeaf' e = go
  where
    go [] = [e]
    go (x : xs) = case compareLeaf e x of
      c | c == LT -> e : x : xs
        | c == EQ -> x : xs          -- exact duplicate: idempotent
        | otherwise -> x : go xs

deleteLeaf' :: LeafEntry -> [LeafEntry] -> [LeafEntry]
deleteLeaf' e = filter (\x -> compareLeaf x e /= EQ)

findLeaf' :: Value -> RID -> [LeafEntry] -> Bool
findLeaf' k rid es = any (\x -> leRid x == rid && compareSql (leKey x) k == EQ) es

-- | Leaf split point: prefer the key-change candidate nearest the middle
--   so the separator (min key of the right page) does not duplicate keys
--   that can also be found left of the boundary.
pickSplitLeaf :: [LeafEntry] -> ([LeafEntry], [LeafEntry])
pickSplitLeaf xs = splitAt pick xs
  where
    n = length xs
    mid = max 1 (n `div` 2)
    cands = [ i | i <- [1 .. n - 1]
             , compareSql (leKey (xs !! (i - 1))) (leKey (xs !! i)) == LT ]
    pick = case [ i | i <- cands, i <= mid ] of
      is@(_:_) -> last is
      _        -> case cands of
                    (i : _) -> i
                    []      -> mid

insertInternal' :: InternalEntry -> [InternalEntry] -> [InternalEntry]
insertInternal' e es = case es of
  (x : rest) | isNothing (ieSep x) -> x : insertInternal' e rest
  _ -> go es
  where
    go [] = [e]
    go (x : xs) = case (ieSep e, ieSep x) of
      (Just a, Just b) | compareSql a b == GT -> x : go xs
      _ -> e : x : xs

-- ---------------------------------------------------------------------------
-- Entry codecs (encodeValue is self-delimiting: tag byte, fixed payload
--   for scalars, u16 length prefix for text — Common.Types line 86)
-- ---------------------------------------------------------------------------
keyByteLen :: BS.ByteString -> Int
keyByteLen bs
  | BS.length bs < 1 = 0
  | otherwise = case BS.index bs 0 of
      1 -> 9                              -- VInt: tag + i64le
      2 -> 9                              -- VFloat
      3 -> case runDecode getW16le (BS.take 2 (BS.drop 1 bs)) of
             Left _             -> 0
             Right (n :: Word16) -> 3 + fromIntegral n   -- tag + u16 + bytes
      4 -> 2                              -- VBool
      _ -> 0

putRid6 :: RID -> BS.ByteString
putRid6 r = buildToBytes (putW32le (fromIntegral (ridPage r))
                        <> putW16le (fromIntegral (ridSlot r)))

getRid6 :: BS.ByteString -> Maybe RID
getRid6 bs = case runDecode (do
  p <- getW32le; s <- getW16le
  pure RID { ridPage = fromIntegral p, ridSlot = fromIntegral s }) bs of
  Left _  -> Nothing
  Right r -> Just r

putChild4 :: PageId -> BS.ByteString
putChild4 p = buildToBytes (putW32le (fromIntegral p))

getChild4 :: BS.ByteString -> Maybe PageId
getChild4 bs = case runDecode getW32le bs of
  Left _  -> Nothing
  Right w -> Just (fromIntegral (w :: Word32))

encodeLeafEntry :: LeafEntry -> BS.ByteString
encodeLeafEntry e = encodeValue (leKey e) <> putRid6 (leRid e)

decodeLeafEntry :: BS.ByteString -> Maybe LeafEntry
decodeLeafEntry bs
  | n == 0 || n + 6 /= BS.length bs = Nothing
  | otherwise = do
      kv <- case decodeValue (BS.take n bs) of
              Left _  -> Nothing
              Right v -> Just v
      rid <- getRid6 (BS.drop n bs)
      pure LeafEntry { leKey = kv, leRid = rid }
  where n = keyByteLen bs

encodeInternalEntry :: InternalEntry -> BS.ByteString
encodeInternalEntry e = maybe mempty encodeValue (ieSep e) <> putChild4 (ieChild e)

decodeInternalEntry :: Bool -> BS.ByteString -> Maybe InternalEntry
decodeInternalEntry negInf bs
  | negInf = InternalEntry Nothing <$> getChild4 bs
  | n == 0 || n + 4 /= BS.length bs = Nothing
  | otherwise = do
      s <- case decodeValue (BS.take n bs) of
             Left _  -> Nothing
             Right v -> Just v
      c <- getChild4 (BS.drop n bs)
      pure InternalEntry { ieSep = Just s, ieChild = c }
  where n = keyByteLen bs

-- ---------------------------------------------------------------------------
-- Page-level primitives (internal/05 §5.1): decode the whole entry list
--   per operation (pages hold at most a few hundred entries)
-- ---------------------------------------------------------------------------
leafEntries :: SqlType -> PageRef -> IO [LeafEntry]
leafEntries _kt pr = do
  sls <- liveSlots pr
  bs <- mapM (\(s, _, _) -> pageReadTuple pr s) sls
  case mapMaybe decodeLeafEntry bs of
    es | length es == length bs -> pure es
       | otherwise -> throwSql "XX000" "index: corrupt leaf entry"

internalEntries :: SqlType -> PageRef -> IO [InternalEntry]
internalEntries _kt pr = do
  sls <- liveSlots pr
  bs <- mapM (\(s, _, _) -> pageReadTuple pr s) sls
  if null bs then throwSql "XX000" "index: empty internal page"
    else case mapMaybe id
             (zipWith decodeInternalEntry (True : map (const False) (drop 1 bs)) bs) of
      es | length es == length bs -> pure es
         | otherwise -> throwSql "XX000" "index: corrupt internal entry"

-- | Assemble a rebuilt page image; Nothing = entries do not fit (the
--   split decision, design/04 §4.4).
mkLeafImg :: Int -> PageId -> [LeafEntry] -> IO (Maybe BS.ByteString)
mkLeafImg ps nxt es = buildSlottedImage ps PKIndexLeaf nxt 0 (map encodeLeafEntry es)

mkInternalImg :: Int -> [InternalEntry] -> IO (Maybe BS.ByteString)
mkInternalImg ps es = buildSlottedImage ps PKIndexInternal 0 0
  (map encodeInternalEntry es)

-- | Whole current frame content (the PPageUndo before-image payload).
pageBytes :: PageRef -> Int -> IO BS.ByteString
pageBytes pr ps = pageSlice pr 0 ps

-- ---------------------------------------------------------------------------
-- Search (internal/05 §5.3) — one pinned frame per hop (withPage); readers
--   only, so no lock cycle against the writer latch.
-- ---------------------------------------------------------------------------
keyTypeOfRel :: RelationDesc -> SqlType
keyTypeOfRel rd = case rdColumns rd of
  (c : _) -> colType c
  []      -> TyInt64

descendToLeaf :: Env -> SqlType -> PageId -> Value
              -> IO (PageId, [PageId])   -- leaf, ancestors root..parent
descendToLeaf env kt root k = loop root []
  where
    bp = envBufferPool env
    -- pin ONE page at a time: the parent is released before the child is
    --   pinned (internal/05 §5.2 "at most 3 pins"; deep trees must not
    --   hold the whole path, and the leaf + parent rule is honoured by
    --   callers re-pinning the leaf)
    loop p acc = do
      nxt <- withPage bp p $ \pr -> do
        hdr <- readHeader pr
        case phKind hdr of
          PKIndexLeaf -> pure (Nothing :: Maybe PageId)
          PKIndexInternal -> do
            es <- internalEntries kt pr
            pure (Just (ieChild (last (filter (sepLT k . ieSep) es))))
          _ -> throwSql "XX000" "index: unexpected page kind"
      case nxt of
        Nothing -> pure (p, acc)
        Just c  -> loop c (acc ++ [p])

leftmostLeaf :: Env -> SqlType -> PageId -> IO PageId
leftmostLeaf env kt p0 = loop p0
  where
    bp = envBufferPool env
    loop p = do
      nxt <- withPage bp p $ \pr -> do
        hdr <- readHeader pr
        case phKind hdr of
          PKIndexLeaf -> pure (Nothing :: Maybe PageId)
          PKIndexInternal -> do
            es <- internalEntries kt pr
            pure (Just (ieChild (head es)))
          _ -> throwSql "XX000" "index: unexpected page kind"
      case nxt of
        Nothing -> pure p
        Just c  -> loop c

-- | Chain-follow decision: keep walking while the current page cannot
--   rule out more occurrences: empty page, or page max <= key.
chainPast :: Value -> [LeafEntry] -> Bool
chainPast k es = null es || compareSql k (leKey (last es)) /= LT

btreeSearch :: Env -> CatalogCache -> RelId -> Value -> IO [RID]
btreeSearch env cache rid k = do
  mrd <- lookupById cache rid
  case mrd of
    Nothing -> pure []
    Just rd -> do
      let kt = keyTypeOfRel rd
      (leaf, _) <- descendToLeaf env kt (rdRoot rd) k
      collect kt leaf
  where
    collect kt2 p = withPage (envBufferPool env) p $ \pr -> do
      es <- leafEntries kt2 pr
      hdr <- readHeader pr
      let hits = [ leRid e | e <- es, compareSql k (leKey e) == EQ ]
      if chainPast k es && phNext hdr /= 0
        then (hits ++) <$> collect kt2 (phNext hdr)
        else pure hits

-- | Range scan [lo, hi) (design/04 §4.4), following the leaf chain.
btreeRange :: Env -> CatalogCache -> RelId
           -> Maybe Value -> Maybe Value -> IO [(Value, RID)]
btreeRange env cache rid lo hi = do
  mrd <- lookupById cache rid
  case mrd of
    Nothing -> pure []
    Just rd -> do
      let kt = keyTypeOfRel rd
      start <- case lo of
        Just l  -> fst <$> descendToLeaf env kt (rdRoot rd) l
        Nothing -> leftmostLeaf env kt (rdRoot rd)
      walk kt start
  where
    walk kt2 p = withPage (envBufferPool env) p $ \pr -> do
      es <- leafEntries kt2 pr
      hdr <- readHeader pr
      let keep = [ (leKey e, leRid e) | e <- es, inRange lo hi (leKey e) ]
          -- continue while the page's max key is still below hi (empty
          --   pages never rule out later keys); hi=Nothing never stops
          more = null es
              || maybe True (\h -> compareSql (leKey (last es)) h == LT) hi
      if phNext hdr /= 0 && more
        then (keep ++) <$> walk kt2 (phNext hdr)
        else pure keep

inRange :: Maybe Value -> Maybe Value -> Value -> Bool
inRange lo hi k = (maybe True (\l -> compareSql l k /= GT) lo)
               && (maybe True (\h -> compareSql k h == LT) hi)

-- | Is (key, RID) already in the tree?  Chain-follow like search so an
--   insert is idempotent even when duplicates span a split boundary.
findEntry :: Env -> SqlType -> Value -> RID -> PageId -> IO Bool
findEntry env kt k rid p = withPage (envBufferPool env) p $ \pr -> do
  es <- leafEntries kt pr
  if findLeaf' k rid es
    then pure True
    else do
      hdr <- readHeader pr
      if chainPast k es && phNext hdr /= 0
        then findEntry env kt k rid (phNext hdr)
        else pure False

-- ---------------------------------------------------------------------------
-- Insert (internal/05 §5.4 + design/04 §4.4/4.5): WAL before page change;
--   returns Just newRoot on root split (caller publishes via
--   Bootstrap.updateIndexRoot).
-- ---------------------------------------------------------------------------
allocIndexPage :: Env -> TxnCtx -> RelId -> IO PageId
allocIndexPage env ctx rid = do
  pid <- extendFile (envFileMgr env)
  _ls <- txnAppend ctx (PAllocPage pid rid)
  pure pid

publishPage :: Env -> TxnCtx -> PageId -> BS.ByteString -> IO ()
publishPage env ctx pg img = do
  li <- txnAppend ctx (PPageImage pg img)
  withPageDirty (envBufferPool env) pg $ \pr -> installPageImage pr img li

-- | Log before-image + after-image and swap the page in one step
--   (durability rule: every record appended before any mutation).
logAndInstall :: Env -> TxnCtx -> PageId -> BS.ByteString -> BS.ByteString -> IO ()
logAndInstall env ctx p curImg newImg = do
  _u <- txnAppend ctx (PPageUndo p curImg)
  li <- txnAppend ctx (PPageImage p newImg)
  withPageDirty (envBufferPool env) p $ \pr -> installPageImage pr newImg li

-- | Insert (key, rid) into the tree rooted at the GIVEN root page (the
--   caller threads the root like internal/05 §5.2's IndexHandle —
--   deviation: btreeInsert/Delete take the root explicitly and RETURN
--   the possibly-new root, so a mid-transaction op never descends a
--   stale root after an earlier op's root split).
btreeInsert :: Env -> CatalogCache -> TxnCtx -> RelId -> PageId -> Value -> RID
            -> IO PageId
btreeInsert env cache ctx relId root k rid = do
  lockTable ctx relId LX
  latch <- btreeLatch cache relId
  withMVar latch $ \_ -> do
    mrd <- lookupById cache relId
    case mrd of
      Nothing -> throwSql "XX000" "index: relation missing from cache"
      Just rd -> do
        let kt = keyTypeOfRel rd
            ps = cfgPageSize (envConfig env)
        -- descend BEFORE the duplicate probe: after a root split the root
        --   is internal, and findEntry (chain-follow) only makes sense on
        --   the leaf that the descent lands on.
        (leaf, anc) <- descendToLeaf env kt root k
        dup <- findEntry env kt k rid leaf
        if dup
          then pure root
          else do
            es <- withPage (envBufferPool env) leaf $ \pr -> leafEntries kt pr
            let newEs = insertLeaf' e es
            hdr <- withPage (envBufferPool env) leaf $ \pr -> readHeader pr
            fit <- mkLeafImg ps (phNext hdr) newEs
            case fit of
              Just img -> do
                curImg <- withPage (envBufferPool env) leaf $ \pr -> pageBytes pr ps
                _m <- txnAppend ctx (PIndexInsert relId k rid)
                logAndInstall env ctx leaf curImg img
                pure root
              Nothing -> do
                mr <- splitLeaf ctx relId kt ps hdr leaf anc newEs
                pure (maybe root id mr)
  where
    e = LeafEntry { leKey = k, leRid = rid }
    splitLeaf ctx relId kt ps hdr leaf anc newEs = do
      let (lft, rgt) = pickSplitLeaf newEs
      newLeaf <- allocIndexPage env ctx relId
      mImgL <- mkLeafImg ps newLeaf lft
      mImgR <- mkLeafImg ps (phNext hdr) rgt
      case (mImgL, mImgR) of
        (Just imgL, Just imgR) -> do
          curImg <- withPage (envBufferPool env) leaf $ \pr -> pageBytes pr ps
          _m <- txnAppend ctx (PIndexInsert relId k rid)
          _u <- txnAppend ctx (PPageUndo leaf curImg)
          l1 <- txnAppend ctx (PPageImage leaf imgL)
          l2 <- txnAppend ctx (PPageImage newLeaf imgR)
          withPageDirty (envBufferPool env) leaf $ \pr -> installPageImage pr imgL l1
          withPageDirty (envBufferPool env) newLeaf $ \pr -> installPageImage pr imgR l2
          propagateSep env ctx relId kt ps (leKey (head rgt)) newLeaf leaf anc
        _ -> throwSql "XX000" "index: split half does not fit a page"

-- | Insert a separator for a split child into parent/super-root.  Returns
--   Just when the ROOT split (new root page); caller updates relroot.
propagateSep :: Env -> TxnCtx -> RelId -> SqlType -> Int
            -> Value -> PageId -> PageId -> [PageId] -> IO (Maybe PageId)
-- args: sep, newChild, oldChild (the page that split), ancestors above oldChild
propagateSep env ctx relId kt ps sep newChild oldChild anc
  | null anc = do      -- the split page was the root: create a new root
      nr <- allocIndexPage env ctx relId
      mimg <- mkInternalImg ps
        [ InternalEntry { ieSep = Nothing, ieChild = oldChild }
        , InternalEntry { ieSep = Just sep, ieChild = newChild } ]
      case mimg of
        Just img -> do
          _ <- publishPage env ctx nr img
          pure (Just nr)
        Nothing -> throwSql "XX000" "index: new root does not fit"
  | otherwise = do
      let parent = last anc
      pes <- withPage (envBufferPool env) parent $ \pr -> internalEntries kt pr
      let newPEs = insertInternal' (InternalEntry (Just sep) newChild) pes
      mfit <- mkInternalImg ps newPEs
      curImg <- withPage (envBufferPool env) parent $ \pr -> pageBytes pr ps
      case mfit of
        Just img -> do
          _u <- txnAppend ctx (PPageUndo parent curImg)
          li <- txnAppend ctx (PPageImage parent img)
          withPageDirty (envBufferPool env) parent $ \pr -> installPageImage pr img li
          pure Nothing
        Nothing -> do
          let (pleft, pright0) = splitAt (max 1 (length newPEs `div` 2)) newPEs
              pright = InternalEntry { ieSep = Nothing
                                     , ieChild = ieChild (head pright0) }
                     : tail pright0
          np <- allocIndexPage env ctx relId
          mImgL <- mkInternalImg ps pleft
          mImgN <- mkInternalImg ps pright
          case (mImgL, mImgN) of
            (Just imgL, Just imgR) -> do
              _u <- txnAppend ctx (PPageUndo parent curImg)
              l1 <- txnAppend ctx (PPageImage parent imgL)
              l2 <- txnAppend ctx (PPageImage np imgR)
              withPageDirty (envBufferPool env) parent $ \pr -> installPageImage pr imgL l1
              withPageDirty (envBufferPool env) np $ \pr -> installPageImage pr imgR l2
              let sepUp = case ieSep (head pright0) of
                            Just s  -> s
                            Nothing -> sep
              propagateSep env ctx relId kt ps sepUp np parent (init anc)
            _ -> throwSql "XX000" "index: internal split half does not fit"

-- ---------------------------------------------------------------------------
-- Delete (design/04 §4.5): remove the exact (key, RID) entry; no merge
--   (empty leaves/pages may remain — the chain stays walkable).  A missing
--   entry is an index out-of-sync internal error.
-- ---------------------------------------------------------------------------
data DelStep = DelCont PageId | DelNotFound | DelMutate BS.ByteString BS.ByteString

btreeDelete :: Env -> CatalogCache -> TxnCtx -> RelId -> PageId -> Value -> RID -> IO ()
btreeDelete env cache ctx relId root k rid = do
  lockTable ctx relId LX
  latch <- btreeLatch cache relId
  withMVar latch $ \_ -> do
    mrd <- lookupById cache relId
    case mrd of
      Nothing -> throwSql "XX000" "index: relation missing from cache"
      Just rd -> do
        (leaf, _) <- descendToLeaf env (keyTypeOfRel rd) root k
        delLoop env ctx (keyTypeOfRel rd)
                (cfgPageSize (envConfig env)) relId k rid leaf

delLoop :: Env -> TxnCtx -> SqlType -> Int -> RelId -> Value -> RID -> PageId -> IO ()
delLoop env ctx kt ps relId k rid p = do
  step <- withPage (envBufferPool env) p $ \pr -> do
    es <- leafEntries kt pr
    case [ x | x <- es, compareLeaf x target == EQ ] of
      (x : _) -> do
        let rem = deleteLeaf' x es
        hdr <- readHeader pr
        mimg <- mkLeafImg ps (phNext hdr) rem
        case mimg of
          Just img -> DelMutate <$> pageBytes pr ps <*> pure img
          Nothing -> throwSql "XX000" "index: leaf rebuild does not fit"
      [] -> do
        hdr <- readHeader pr
        if chainPast k es && phNext hdr /= 0
          then pure (DelCont (phNext hdr))
          else pure DelNotFound
  case step of
    DelCont q -> delLoop env ctx kt ps relId k rid q
    DelNotFound -> throwInternal "index: delete entry not found (index out of sync)"
    DelMutate cur img -> do
      _m <- txnAppend ctx (PIndexDelete relId k rid)
      logAndInstall env ctx p cur img
  where target = LeafEntry { leKey = k, leRid = rid }

-- ---------------------------------------------------------------------------
-- Bulk build (CREATE INDEX, design/06 §6.4): bottom-up packing; logs
--   PAllocPage + PPageImage per page and one INDEX_INSERT marker per entry.
--   Returns the root page id.  Input MUST be sorted by (key, RID).
-- ---------------------------------------------------------------------------
data SubTree = SubTree { stMin :: !Value, stPage :: !PageId }
  deriving (Show)

packLeaves :: Int -> [LeafEntry] -> IO [[LeafEntry]]
packLeaves ps es
  | null es = pure []
  | otherwise = do
      n <- go 1
      let (g, rest) = splitAt n es
      (g :) <$> packLeaves ps rest
  where
    go acc
      | acc >= length es = pure acc
      | otherwise = do
          ok <- fmap isJust (mkLeafImg ps 0 (take (acc + 1) es))
          if ok then go (acc + 1) else pure acc

packInternals :: Int -> [SubTree] -> IO [[SubTree]]
packInternals ps subs
  | null subs = pure []
  | otherwise = do
      n <- go 1
      let (g, rest) = splitAt n subs
      (g :) <$> packInternals ps rest
  where
    go acc
      | acc >= length subs = pure acc
      | otherwise = do
          ok <- fmap isJust (mkInternalImg ps (internalFor (take (acc + 1) subs)))
          if ok then go (acc + 1) else pure acc

internalFor :: [SubTree] -> [InternalEntry]
internalFor subs = case subs of
  (s : rest) -> InternalEntry { ieSep = Nothing, ieChild = stPage s }
             : [ InternalEntry { ieSep = Just (stMin t), ieChild = stPage t } | t <- rest ]
  []         -> []

btreeBuild :: Env -> TxnCtx -> RelId -> SqlType -> [(Value, RID)] -> IO PageId
btreeBuild env ctx relId _kt rows = do
  let ps = cfgPageSize (envConfig env)
  -- deviation (design/04 §4.5 PAGE_IMAGE per page is enough for the
  --   physiological replay we do; per-entry INDEX_INSERT markers for a
  --   bulk build are pure WAL bloat, so we log none)
  if null rows
    then do
      pg <- allocIndexPage env ctx relId
      mimg <- mkLeafImg ps 0 []
      case mimg of
        Just img -> publishPage env ctx pg img
        Nothing -> throwSql "XX000" "index: empty root page impossible"
      pure pg
    else do
      groups <- packLeaves ps [ LeafEntry { leKey = k, leRid = r } | (k, r) <- rows ]
      subs <- buildLeafLevel env ctx relId ps groups
      goLevels env ctx relId ps subs

goLevels :: Env -> TxnCtx -> RelId -> Int -> [SubTree] -> IO PageId
goLevels env ctx relId ps subs
  | length subs == 1 = pure (stPage (head subs))
  | otherwise = do
      groups <- packInternals ps subs
      subs' <- buildInternalLevel env ctx relId ps groups
      goLevels env ctx relId ps subs'

buildLeafLevel :: Env -> TxnCtx -> RelId -> Int -> [[LeafEntry]] -> IO [SubTree]
buildLeafLevel env ctx relId ps groups = do
  pgs <- replicateM (length groups) (allocIndexPage env ctx relId)
  let nexts = drop 1 pgs ++ [0]
  forM_ (zipWith3 (\pg g nx -> (pg, g, nx)) pgs groups nexts) $ \(pg, g, nx) -> do
    mimg <- mkLeafImg ps nx g
    case mimg of
      Just img -> publishPage env ctx pg img
      Nothing -> throwSql "XX000" "index: packed leaf does not fit (packing bug)"
  pure [ SubTree { stMin = leKey (head g), stPage = pg }
       | (pg, g) <- zip pgs groups ]

buildInternalLevel :: Env -> TxnCtx -> RelId -> Int -> [[SubTree]] -> IO [SubTree]
buildInternalLevel env ctx relId ps groups = do
  pgs <- replicateM (length groups) (allocIndexPage env ctx relId)
  forM_ (zip pgs groups) $ \(pg, g) -> do
    mimg <- mkInternalImg ps (internalFor g)
    case mimg of
      Just img -> publishPage env ctx pg img
      Nothing -> throwSql "XX000" "index: packed internal page does not fit (packing bug)"
  pure [ SubTree { stMin = stMin (head g), stPage = pg }
       | (pg, g) <- zip pgs groups ]
