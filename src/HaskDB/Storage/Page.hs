-- | Slotted-page structure and primitives (heap variant; the index variant
--   reuses these entry helpers from Index.BTree).
--   Refines internal-design/01 §1.1-1.4 and design/01 §1.2/1.3.
module HaskDB.Storage.Page where

import qualified Data.ByteString as BS
import Data.IORef (IORef, readIORef, writeIORef)
import Data.Word
import Data.List (sortOn)
import HaskDB.Common.Types
import HaskDB.Common.Error (throwSql)
import Data.Text (Text)
import HaskDB.Common.Codec (Reader(..), runDecode, getW16le, getW32le, getW64le,
  putW16le, putW32le, putW64le, buildToBytes)
import Data.Bits ((.&.))

-- A page lives in a buffer-pool frame: exactly cfgPageSize bytes, mutable.
-- The PageRef constructor is exported so BufferPool can wrap a frame's
-- IORef into a PageRef view (internal/02 §2.2 PinnedPage).
newtype PageRef = PageRef (IORef BS.ByteString)

data PageKind = PKHeap | PKIndexLeaf | PKIndexInternal | PKCatalog | PKFree
  deriving (Eq, Show)

data PageHeader = PageHeader
  { phLsn     :: !LSN
  , phKind    :: !PageKind
  , phLower   :: !Int    -- end of slot array (start of free space)
  , phUpper   :: !Int    -- start of tuple data (end of free space)
  , phSpecial :: !Int    -- special-area start (PAGE_SIZE when none)
  , phNext    :: !PageId -- heap/leaf chain next (0 = end)
  } deriving (Show)

headerSize :: Int
headerSize = 20          -- design/01 §1.2: 8+2+2+2+2+4

itemSize :: Int
itemSize = 4             -- u16 off, u16 len; len==0 => unused slot

kindCode :: PageKind -> Word16
kindCode PKFree          = 0
kindCode PKHeap          = 1
kindCode PKIndexLeaf     = 2
kindCode PKIndexInternal = 3
kindCode PKCatalog       = 4

codeKind :: Word16 -> Maybe PageKind
codeKind 0 = Just PKFree
codeKind 1 = Just PKHeap
codeKind 2 = Just PKIndexLeaf
codeKind 3 = Just PKIndexInternal
codeKind 4 = Just PKCatalog
codeKind _ = Nothing

-- ---------------------------------------------------------------------------
-- PageRef byte helpers (offset splice on a mutable strict ByteString)
-- ---------------------------------------------------------------------------
pageSlice :: PageRef -> Int -> Int -> IO BS.ByteString
pageSlice (PageRef r) off len = do
  bs <- readIORef r
  pure (BS.take len (BS.drop off bs))

pageSplice :: PageRef -> Int -> Int -> BS.ByteString -> IO ()
pageSplice (PageRef r) off len new = do
  bs <- readIORef r
  writeIORef r (BS.take off bs <> new <> BS.drop (off + len) bs)

pageFrameLen :: PageRef -> IO Int
pageFrameLen (PageRef r) = BS.length <$> readIORef r

-- ---------------------------------------------------------------------------
-- Header encode/decode (design/01 §1.2, little-endian)
-- ---------------------------------------------------------------------------
encodeHeader :: PageHeader -> BS.ByteString
encodeHeader h = buildToBytes $
  putW64le (phLsn h)
    <> putW16le (fromIntegral (kindCode (phKind h)))
    <> putW16le (fromIntegral (phLower h))
    <> putW16le (fromIntegral (phUpper h))
    <> putW16le (fromIntegral (phSpecial h))
    <> putW32le (fromIntegral (phNext h))

decodeHeader :: BS.ByteString -> Either Text PageHeader
decodeHeader bs = runDecode (do
  lsn <- getW64le
  w16 <- getW16le
  lo <- getW16le
  up <- getW16le
  sp <- getW16le
  nx <- getW32le
  k <- case codeKind (w16 .&. 7) of
         Just kk -> pure kk
         Nothing -> decodeFail "page: unknown page kind"
  let h = PageHeader
        { phLsn = lsn
        , phKind = k
        , phLower = fromIntegral lo
        , phUpper = fromIntegral up
        , phSpecial = fromIntegral sp
        , phNext = nx
        }
  if headerSize <= phLower h && phLower h <= phUpper h
       && phUpper h <= max 1 (phSpecial h)
    then pure h
    else decodeFail "page: implausible header fields") bs
  where
    decodeFail :: Text -> Reader a
    decodeFail msg = Reader (\_ _ -> Left msg)

readHeader :: PageRef -> IO PageHeader
readHeader pr = do
  bs <- pageSlice pr 0 headerSize
  case decodeHeader bs of
    Left e  -> throwSql "XX000" e
    Right h -> pure h

writeHeader :: PageRef -> PageHeader -> IO ()
writeHeader pr h = pageSplice pr 0 headerSize (encodeHeader h)

-- Usable region end (internal/01 §1.1: 0 / PAGE_SIZE means no special area).
specialStart :: PageHeader -> Int -> Int
specialStart h pageSize
  | phSpecial h == 0 || phSpecial h >= pageSize = pageSize
  | otherwise = phSpecial h

initPage :: PageRef -> PageKind -> Int -> IO ()
initPage pr k pageSize = do
  bs <- pageSlice pr 0 pageSize
  if BS.length bs /= pageSize
    then throwSql "XX000" "page size mismatch in frame"
    else writeHeader pr (PageHeader 0 k headerSize pageSize pageSize 0)

pageFreeContiguous :: PageHeader -> Int
pageFreeContiguous h = phUpper h - phLower h

-- ---------------------------------------------------------------------------
-- Slot directory primitives (internal/01 §1.2)
-- ---------------------------------------------------------------------------
slotCount :: PageHeader -> Int
slotCount h = (phLower h - headerSize) `div` itemSize

readSlot :: PageRef -> SlotNum -> IO (Maybe (Int, Int))
readSlot pr n = do
  hdr <- readHeader pr
  if n >= 0 && n < slotCount hdr
    then do
      b <- pageSlice pr (headerSize + n * itemSize) itemSize
      case runDecode (do o <- getW16le; l <- getW16le; pure (o, l)) b of
        Left _        -> pure Nothing
        Right (o, l)
          | l == 0    -> pure Nothing
          | otherwise -> pure (Just (fromIntegral o, fromIntegral l))
    else pure Nothing

writeSlot :: PageRef -> SlotNum -> Int -> Int -> IO ()
writeSlot pr n off len =
  pageSplice pr (headerSize + n * itemSize) itemSize $
    buildToBytes (putW16le (fromIntegral off) <> putW16le (fromIntegral len))

clearSlot :: PageRef -> SlotNum -> IO ()
clearSlot pr n = writeSlot pr n 0 0

findUnusedSlot :: PageRef -> IO (Maybe SlotNum)
findUnusedSlot pr = do
  hdr <- readHeader pr
  ms <- mapM (readSlot pr) [0 .. slotCount hdr - 1]
  pure (go 0 ms)
  where
    go _ []         = Nothing
    go i (m : rest) = case m of
      Nothing -> Just i
      Just _  -> go (i + 1) rest

liveSlots :: PageRef -> IO [(SlotNum, Int, Int)]  -- (slot, off, len)
liveSlots pr = do
  hdr <- readHeader pr
  ms <- mapM (\n -> fmap ((,) n) (readSlot pr n)) [0 .. slotCount hdr - 1]
  pure [ (n, o, l) | (n, Just (o, l)) <- ms ]

-- ---------------------------------------------------------------------------
-- Tuple-area operations (internal/01 §1.3).  Callers MUST append the WAL
-- record first and pass its LSN; these ops stamp phLsn (design/10 global
-- rule: the WAL-before-mutation order is the only expressible order).
-- ---------------------------------------------------------------------------
pageInsertTuple :: PageRef -> LSN -> BS.ByteString -> IO SlotNum
pageInsertTuple pr lsn bytes = do
  hdr <- readHeader pr
  let need = BS.length bytes
  mslot <- findUnusedSlot pr
  hdrslot <- case mslot of
    Just s  -> pure (hdr, s)
    Nothing
      | pageFreeContiguous hdr >= itemSize + need ->
          let h = hdr { phLower = phLower hdr + itemSize }
          in  writeHeader pr h >> pure (h, slotCount hdr)
      | otherwise -> throwSql "XX000" "insert without fit preflight"
  let (hdr', slot) = hdrslot
      off = phUpper hdr' - need
  pageSplice pr off need bytes
  writeSlot pr slot off need
  writeHeader pr hdr' { phUpper = off, phLsn = lsn }
  pure slot

pageReadTuple :: PageRef -> SlotNum -> IO BS.ByteString
pageReadTuple pr n = do
  m <- readSlot pr n
  case m of
    Nothing       -> throwSql "XX000" "read dead slot"
    Just (o, l)   -> pageSlice pr o l

-- Update in place (newLen <= oldLen) or move-within-page; the old region
-- becomes a free fragment (reclaimed by compaction).  RID/slot unchanged.
pageUpdateTuple :: PageRef -> LSN -> Int -> SlotNum -> BS.ByteString -> IO ()
pageUpdateTuple pr lsn pageSize n newB = do
  m <- readSlot pr n
  case m of
    Nothing -> throwSql "XX000" "update dead slot"
    Just (oldOff, oldLen) -> do
      let newLen = BS.length newB
      if newLen <= oldLen
        then do
          pageSplice pr oldOff newLen newB
          writeSlot pr n oldOff newLen
          hdr <- readHeader pr
          writeHeader pr hdr { phLsn = lsn }
        else do
          hdr <- readHeader pr
          live <- liveSlots pr
          let end = specialStart hdr pageSize
              free = pageFreeContiguous hdr
              holes = end - phUpper hdr - sum [ l | (_, _, l) <- live ]
          if newLen > oldLen + free + holes
            then throwSql "54000" "tuple too large for page (update)"
            else if newLen <= free
              then do
                -- move within the contiguous gap; old region becomes a fragment
                let off = phUpper hdr - newLen
                pageSplice pr off newLen newB
                writeSlot pr n off newLen
                writeHeader pr hdr { phUpper = off, phLsn = lsn }
              else do
                -- internal/01 §1.8 flow 4: compact the OTHER live tuples
                -- (excluding slot n's old region) then place; a naive
                -- phUpper-newLen would clobber the slot directory
                pageCompactReplace pr lsn n newB hdr pageSize

pageDeleteTuple :: PageRef -> LSN -> SlotNum -> IO ()
pageDeleteTuple pr lsn n = do
  clearSlot pr n
  hdr <- readHeader pr
  writeHeader pr hdr { phLsn = lsn }

-- Total bytes recoverable by compaction (internal/01 §1.3).
pageFragmentedFree :: PageRef -> Int -> IO Int
pageFragmentedFree pr pageSize = do
  hdr <- readHeader pr
  live <- liveSlots pr
  let end = specialStart hdr pageSize
      liveBytes = sum [ l | (_, _, l) <- live ]
  pure ((end - phUpper hdr - liveBytes) + pageFreeContiguous hdr)

-- Compaction (internal/01 §1.4): rewrite live tuples contiguously from the
-- special-area end backwards, in slot order; slot numbers (hence RIDs)
-- unchanged.  Caller logs a PAGE_IMAGE *before* installing (scratch-copy
-- pattern, internal/01 §1.4 note).
pageCompact :: PageRef -> LSN -> Int -> IO ()
pageCompact pr lsn pageSize = do
  hdr <- readHeader pr
  let end = specialStart hdr pageSize
  live <- liveSlots pr                    -- ascending slot order
  let lens = [ l | (_, _, l) <- live ]
      offs = scanDown end lens            -- offs !! k = new offset for live !! k
      newUpper = end - sum lens
  images <- mapM (\(s, _, _) -> pageReadTuple pr s) live
  mapM_ (\((_, _, _), off, b) -> pageSplice pr off (BS.length b) b)
        (zip3 live offs images)
  mapM_ (\((s, _, _), off, b) -> writeSlot pr s off (BS.length b))
        (zip3 live offs images)
  writeHeader pr hdr { phUpper = newUpper, phLsn = lsn }

-- Compaction that replaces slot n's image (grow-within-page, internal/01
-- §1.8 flow 4): other live tuples are rewritten contiguously from the
-- usable-region end in slot order; the new image sits at the lowest
-- address.  Slot numbers (hence RIDs) unchanged.  Caller checked fit.
pageCompactReplace :: PageRef -> LSN -> SlotNum -> BS.ByteString
                   -> PageHeader -> Int -> IO ()
pageCompactReplace pr lsn n newB hdr pageSize = do
  let end = specialStart hdr pageSize
  live <- liveSlots pr
  let others = filter (\(s, _, _) -> s /= n) live
      lens = [ l | (_, _, l) <- others ]
      offs = scanDown end lens
  images <- mapM (\(s, _, _) -> pageReadTuple pr s) others
  mapM_ (\((_, _, _), off, b) -> pageSplice pr off (BS.length b) b)
        (zip3 others offs images)
  mapM_ (\((s, _, _), off, b) -> writeSlot pr s off (BS.length b))
        (zip3 others offs images)
  let newUpper = end - sum lens - BS.length newB
  pageSplice pr newUpper (BS.length newB) newB
  writeSlot pr n newUpper (BS.length newB)
  writeHeader pr hdr { phUpper = newUpper, phLsn = lsn }

-- right-biased cumulative offsets: offs!!k is the new start of live!!k
scanDown :: Int -> [Int] -> [Int]
scanDown _ []       = []
scanDown e (x : xs) = let e' = e - x in e' : scanDown e' xs

-- | Force-place a tuple into a slot: no-op when the slot already holds
--   exactly these bytes (idempotence guard, internal/03 §3.4/3.7); grow
--   the slot directory when the slot never existed; compact when
--   contiguous free space is too small.  This is the redo (insert
--   placement) and undo (before-image restore) choke point.
pageSetTuple :: PageRef -> LSN -> SlotNum -> BS.ByteString -> IO ()
pageSetTuple pr lsn n bytes = do
  hdr <- readHeader pr
  sz <- pageFrameLen pr
  let need = BS.length bytes
  ms <- readSlot pr n
  case ms of
    Just (off, len)
      | len == need -> do
          cur <- pageSlice pr off len
          if cur == bytes then pure ()
            else pageUpdateTuple pr lsn sz n bytes
      | otherwise -> pageUpdateTuple pr lsn sz n bytes
    Nothing
      | n >= slotCount hdr -> do
          let h1 = hdr { phLower = headerSize + (n + 1) * itemSize }
          writeHeader pr h1
          placeDead pr h1 sz need
      | otherwise -> placeDead pr hdr sz need
  where
    placeDead pr' h sz' need
      | pageFreeContiguous h >= need = do
          let off = phUpper h - need
          pageSplice pr' off need bytes
          writeSlot pr' n off need
          writeHeader pr' h { phUpper = off, phLsn = lsn }
      | otherwise = do
          freeTotal <- pageFragmentedFree pr' sz'
          if freeTotal >= need
            then pageCompactReplace pr' lsn n bytes h sz'
            else throwSql "XX000"
                   "pageSetTuple: restore/redo image does not fit page"

-- Whole-image replacement (splits/compaction scratch-copy pattern).
-- The image already carries its header; we re-stamp the LSN so the
-- invariant "on-page phLsn == record LSN" always holds.
-- The image must be exactly one page (the "exactly PAGE_SIZE bytes"
-- invariant; review note #6: reject short/long images instead of
-- keeping a stale tail or resizing the frame).
installPageImage :: PageRef -> BS.ByteString -> LSN -> IO ()
installPageImage pr img lsn = do
  total <- pageFrameLen pr
  if BS.length img /= total
    then throwSql "XX000" "installPageImage: image size mismatch"
    else do
      pageSplice pr 0 total img
      hdr <- readHeader pr
      if phLsn hdr /= lsn
        then writeHeader pr hdr { phLsn = lsn }
        else pure ()

-- Header sanity checks (internal/01 §1.1 invariants; design/01 §1.9:
-- failure = XX000, abort the transaction, no repair).
checkPage :: PageRef -> Int -> IO ()
checkPage pr pageSize = do
  hdr <- readHeader pr
  live <- liveSlots pr
  let end = specialStart hdr pageSize
      shapeBad = headerSize > phLower hdr || phLower hdr > phUpper hdr
                   || phUpper hdr > end || end > pageSize
      slotBad = any (\(_, o, l) ->
                   o < phUpper hdr || o + l > end || l <= 0) live
      -- cheap overlap scan (recovery/debug path): live regions must be
      -- pairwise disjoint (internal/01 §1.1 invariant, review note #8)
      ivs = sortOn (\(o, _) -> o) [(o, l) | (_, o, l) <- live]
      overlapBad = or [ o2 < o1 + l1
                      | ((o1, l1), (o2, _)) <- zip ivs (drop 1 ivs) ]
  if shapeBad || slotBad || overlapBad
    then throwSql "XX000" "checkPage: page invariant violated"
    else pure ()
