-- Phase-4 milestone test suite (design/10 §10.2; design/04 + design/06):
--   * bootstrap: createDatabase -> page 0 file header + self-describing
--     catalog heaps; reopen via recoverDatabase + loadCatalog sees the
--     bootstrap relations and every committed DDL/row afterwards
--   * CREATE TABLE / CREATE INDEX through real transactions: catalog cache
--     staging lands only at commit; CREATE INDEX bulk-builds the B+-tree
--   * B+-tree split storm (pageSize 512 + padded VARCHAR keys -> leaf
--     capacity ~9): leaf splits, internal splits, root splits with the
--     relroot publication (Bootstrap.updateIndexRoot, WAL-logged heapUpdate)
--   * duplicate keys spanning split boundaries: btreeSearch/btreeRange vs
--     the heap ground truth in BOTH directions (strict descend + chain
--     follow), absent keys -> []
--   * DELETE: exact (key, RID) removal, emptied groups -> [], no merge
--   * aborted DDL: staged cache updates discarded AND WAL undo restores
--     the page-0 counter + removes the ghost catalog rows; the ghost
--     remains absent after a full recovery re-replay too
module Main where

import System.Exit (exitFailure)
import Data.List (nub, sort, sortBy)
import Data.Maybe (isNothing)
import Control.Exception (catch)
import System.Directory (doesDirectoryExist, removeDirectoryRecursive)
import Control.Monad (foldM, replicateM, forM, forM_, when)
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8)

import HaskDB.Common.Types (RID(..), Tuple, Value(VInt, VText), SqlType(TyInt64, TyVarchar),
  compareSql, PageId, RelId)
import HaskDB.Common.Config (Config, defaultConfig, cfgPageSize, cfgBufferFrames)
import HaskDB.Common.Error (SqlError(seState, seMessage), throwSql)
import HaskDB.Server.Env (Env, envBufferPool, envFileMgr, envControl, envWalMgr)
import HaskDB.Server.Control (ControlFile(cfNextTid))
import GHC.Internal.Conc.Sync (readTVarIO)
import HaskDB.Storage.FileManager (fsyncDataFile, closeDataFile)
import HaskDB.Wal.Manager (closeWalManager)
import HaskDB.Wal.Recovery (recoverDatabase)
import HaskDB.Catalog.Types (RelationDesc(..), classTupleToDesc)
import HaskDB.Catalog.Cache (CatalogCache, newCatalogCache, loadCatalog, lookupByName)
import HaskDB.Heap.TupleCodec (ColumnDesc(..))
import HaskDB.Txn.Manager (TxnManager, newTxnManager, withTxnAuto, TxnCtx)
import HaskDB.Txn.LockManager (LockManager, newLockManager)
import HaskDB.Heap.Heap (heapInsert, heapScan)
import HaskDB.Catalog.Bootstrap (createDatabase, createTableDDL, createIndexDDL,
  updateIndexRoot)
import HaskDB.Index.BTree (btreeSearch, btreeRange, btreeInsert, btreeDelete)

-- ---------------------------------------------------------------------------
check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then [] else name : errs

testDir :: String
testDir = "index-test-dir"

cfg :: Config
cfg = (defaultConfig testDir) { cfgPageSize     = 1024
                              , cfgBufferFrames = 64 }

-- padded keys keep index entries ~1/12 of a page: leaf capacity ~10,
-- internal fanout ~11 -> the 152-entry fill drives leaf splits, internal
-- splits and propagated ROOT splits.
padKey :: Int -> Text
padKey k = pack ("key" ++ pad4 k ++ "-" ++ replicate 60 '.' ++ show k ++ "xx")
  where pad4 n = replicate (4 - length (show n)) '0' ++ show n

tableCols :: [ColumnDesc]
tableCols = [ColumnDesc "id" TyVarchar, ColumnDesc "age" TyInt64]

-- 25 keys x6 + head/tail boundary keys = 152 entries -> every split kind
fillKeys :: [Text]
fillKeys = concat [ replicate 6 (padKey k) | k <- [1 .. 25 :: Int] ]
        ++ [padKey 0, padKey 26]

mkTup :: Text -> Int -> Tuple
mkTup nm age = [VText (encodeUtf8 nm), VInt (fromIntegral age)]

keyOf :: Tuple -> Value
keyOf (v : _) = v
keyOf []      = VInt 0

cmpKV :: (Value, RID) -> (Value, RID) -> Ordering
cmpKV (k1, r1) (k2, r2) = case compareSql k1 k2 of
  EQ -> compare r1 r2
  c  -> c

-- | Ground truth helper: heap rows, over the relation's cached page list
--   PLUS every heap page seen in RIDs (heapAllocPage chains new pages
--   dynamically; the in-session catalog rdPages is stale for them — see
--   the deviation note; after recovery the catalog chain walk covers all).
truthFrom :: Env -> TxnCtx -> RelationDesc -> [(Value, RID)] -> IO [(Value, RID)]
truthFrom env ctx rd allr = do
  let pages = nub (rdPages rd ++ [ ridPage r | (_, r) <- allr ])
  rows <- heapScan env ctx rd { rdPages = pages }
  pure (sortBy cmpKV [ (keyOf t, r) | (r, t) <- rows ])

-- ---------------------------------------------------------------------------
-- Ground truth = the heap rows; index answers must match them exactly.
-- ---------------------------------------------------------------------------
wantFor :: Value -> [(Value, RID)] -> [RID]
wantFor k rows = sort [ r | (kk, r) <- rows, compareSql kk k == EQ ]

wantRange :: Maybe Value -> Maybe Value -> [(Value, RID)] -> [(Value, RID)]
wantRange lo hi rows = sortBy cmpKV
  [ p | p@(k, _) <- rows
  , maybe True (\l -> compareSql l k /= GT) lo
  , maybe True (\h -> compareSql k h == LT) hi ]

-- ---------------------------------------------------------------------------
-- test 1: DDL, fill (split storm + root publication), then check in a
--   LATER transaction (staged cache visible).  Returns error list + the
--   person heap pages for the follow-up tests.
-- ---------------------------------------------------------------------------
ddlAndFill :: Env -> TxnManager -> LockManager -> CatalogCache -> IO [String]
ddlAndFill env tm lm cache = do
  e1 <- (withTxnAuto tm lm env (\ctx -> do
        rd <- createTableDDL env cache ctx "person" tableCols
        _ix <- createIndexDDL env cache ctx "person_idx" rd 0
        pure (Right ()))
        `catch` (\(er :: SqlError) -> pure (Left (unpack (seMessage er)))))
  case e1 of
    Left msg -> pure ["ddl: txn failed: " ++ msg]
    Right _ -> do
      mrd <- lookupByName cache "person"
      mir <- lookupByName cache "person_idx"
      case (mrd, mir) of
        (Nothing, _) -> pure ["ddl: person table missing from cache"]
        (_, Nothing) -> pure ["ddl: index missing from cache"]
        (Just rd0, Just ixRd) -> do
          let ixId = rdId ixRd
              root0 = rdRoot ixRd
          -- txn 2: rows + one index entry each; root splits thread the new
          --   root locally AND publish relroot (WAL-logged heapUpdate of
          --   the class row via updateIndexRoot)
          e2 <- (withTxnAuto tm lm env (\ctx -> do
                _rt <- foldM (\rt (_i, nm) -> do
                      rid <- heapInsert env ctx rd0 (mkTup nm (100 + _i))
                      rt' <- btreeInsert env cache ctx ixId rt (VText (encodeUtf8 nm)) rid
                      if rt' /= rt
                        then updateIndexRoot env cache ctx ixId rt' >> pure rt'
                        else pure rt')
                      root0 (zip [1 :: Int ..] fillKeys)
                pure (Right ()))
                `catch` (\(er :: SqlError) -> pure (Left (unpack (seMessage er)))))
          case e2 of
            Left msg -> pure ["fill: txn failed: " ++ msg]
            Right _ -> do
              -- txn 3: checks.  Ground truth = heap rows over the pages the
              --   heap layer actually used: the catalog page list PLUS every
              --   heap page seen in index RIDs (heapAllocPage chains new
              --   pages at storage level; the in-session cache list stays
              --   at the DDL page until recovery re-walks the chain).
              e3 <- withTxnAuto tm lm env (\ctx -> do
                    allr <- btreeRange env cache ixId Nothing Nothing
                    truth <- truthFrom env ctx rd0 allr
                    kres <- forM fillKeys $ \nm -> do
                      got <- btreeSearch env cache ixId (VText (encodeUtf8 nm))
                      let want = wantFor (VText (encodeUtf8 nm)) truth
                      pure (if want == sort got then [] else
                            ["dbg key " ++ unpack nm ++ " want=" ++ show want ++ " got=" ++ show (sort got)
                             ++ " truthmatch=" ++ show (length [ kk | (kk, _) <- truth, compareSql kk (VText (encodeUtf8 nm)) == EQ ])])
                    let kbad = concat kres
                    mres <- btreeRange env cache ixId
                            (Just (VText (encodeUtf8 (padKey 3))))
                            (Just (VText (encodeUtf8 (padKey 6))))
                    empty1 <- btreeSearch env cache ixId
                            (VText (encodeUtf8 (padKey 99)))
                    pure (check "fill: per-key search == heap ground truth"
                                (null kbad) kbad
                     ++ check "fill: range [key0003,key0006) matches ground truth"
                                (mres == wantRange
                                    (Just (VText (encodeUtf8 (padKey 3))))
                                    (Just (VText (encodeUtf8 (padKey 6)))) truth) []
                     ++ check "fill: full index scan == ground truth"
                                (sortBy cmpKV allr == truth)
                                ["dbg allrN=" ++ show (length allr) ++ " truthN=" ++ show (length truth)
                                 ++ " pages=" ++ show (rdPages rd0 ++ nub [ ridPage r | (_, r) <- allr ])]
                     ++ check "fill: absent key -> []" (null empty1) []
                     ++ check "fill: truth has 6 rows per key"
                                (length [ (k, r) | (k, r) <- truth
                                            , compareSql k (VText (encodeUtf8 (padKey 24))) == EQ ] == 6)
                                ["truth24=" ++ show [ (ridPage r, ridSlot r) | (k, r) <- truth
                                                  , compareSql k (VText (encodeUtf8 (padKey 24))) == EQ ]
                                 ++ " p41=" ++ show [ (ridPage r, ridSlot r) | (_, r) <- truth, ridPage r == 41 ]]
                     ++ check "fill: absent key -> []" (null empty1) []))
                    `catch` (\(er :: SqlError) ->
                      pure ["fill: check txn failed: " ++ unpack (seMessage er)])
              pure e3

-- ---------------------------------------------------------------------------
-- test 2: deletes: all three copies of every key disappear; key0 and
--   key13 survive; emptied groups -> [] (empty leaves stay in chain).
-- ---------------------------------------------------------------------------
deleteCheck :: Env -> TxnManager -> LockManager -> CatalogCache -> IO [String]
deleteCheck env tm lm cache = do
  mrd <- lookupByName cache "person"
  mir <- lookupByName cache "person_idx"
  case (mrd, mir) of
    (Just rd0, Just ixRd) -> do
      e1 <- withTxnAuto tm lm env (\ctx -> do
            allr <- btreeRange env cache (rdId ixRd) Nothing Nothing
            truth <- truthFrom env ctx rd0 allr
            let root = rdRoot ixRd
            forM_ [1 .. 25 :: Int] $ \k ->
              forM_ [r | (kk, r) <- truth
                     , compareSql kk (VText (encodeUtf8 (padKey k))) == EQ] $ \r ->
                btreeDelete env cache ctx (rdId ixRd) root
                  (VText (encodeUtf8 (padKey k))) r
            pure [])
        `catch` (\(er :: SqlError) -> pure ["delete: txn failed: " ++ unpack (seMessage er)])
      e2 <- withTxnAuto tm lm env (\ctx -> do
            allr <- btreeRange env cache (rdId ixRd) Nothing Nothing
            truth <- truthFrom env ctx rd0 allr
            let k0 = VText (encodeUtf8 (padKey 0))
                k13 = VText (encodeUtf8 (padKey 13))
                k5 = VText (encodeUtf8 (padKey 5))
            s0 <- btreeSearch env cache (rdId ixRd) k0
            s13 <- btreeSearch env cache (rdId ixRd) k13
            s5 <- btreeSearch env cache (rdId ixRd) k5
            pure (check "delete: key0 survivors == heap" (s0 == wantFor k0 truth)
                    ["dbg k0 want=" ++ show (wantFor k0 truth) ++ " got=" ++ show (sort s0)]
                ++ check "delete: key13 survivors == heap" (s13 == wantFor k13 truth)
                    ["dbg k13 want=" ++ show (wantFor k13 truth) ++ " got=" ++ show (sort s13)]
                ++ check "delete: emptied group -> []" (null s5)
                    ["dbg k5 leftovers=" ++ show (sort s5)]
                ++ check "delete: key13 group fully deleted -> []" (null s13)
                    ["dbg k13 leftovers=" ++ show (sort s13)]
                ++ check "delete: full index scan == heap minus deleted"
                     (sortBy cmpKV allr == sortBy cmpKV
                        [ p | p@(k, _) <- truth
                        , not (any (\kk -> compareSql kk k == EQ)
                             [ VText (encodeUtf8 (padKey i)) | i <- [1 .. 25 :: Int] ]) ])
                     ["dbg allrN=" ++ show (length allr) ++ " truthN=" ++ show (length truth) ++ " expectedN=2"]))
        `catch` (\(er :: SqlError) -> pure ["delete: check txn failed: " ++ unpack (seMessage er)])
      pure (e1 ++ e2)
    _ -> pure ["delete: relations missing from cache"]

-- ---------------------------------------------------------------------------
-- test 3: aborted DDL: cache staging dropped + WAL undo of page 0 counter
--   and catalog rows; then recovery re-replay must also leave it absent.
-- ---------------------------------------------------------------------------
abortedDDL :: Env -> TxnManager -> LockManager -> CatalogCache -> IO [String]
abortedDDL env tm lm cache = do
  _e1 <- (withTxnAuto tm lm env (\ctx -> do
        rd <- createTableDDL env cache ctx "ghost" tableCols
        _ <- createIndexDDL env cache ctx "ghost_idx" rd 0
        throwSql "TEST" "injected failure after DDL")
        `catch` (\(er :: SqlError) -> pure (seMessage er)))
  g <- lookupByName cache "ghost"
  gi <- lookupByName cache "ghost_idx"
  rowNames <- withTxnAuto tm lm env (\ctx -> do
        mcls <- lookupByName cache "hask_class"
        case mcls of
          Nothing -> pure []
          Just cls -> do
            rows <- heapScan env ctx cls
            pure [ rdName d | (_, t) <- rows
                 , Just d <- [classTupleToDesc t] ])
      `catch` (\(_ :: SqlError) -> pure [])
  pure (check "abort: ghost table not in cache" (isNothing g) []
      ++ check "abort: ghost index not in cache" (isNothing gi) []
      ++ check "abort: no ghost rows in hask_class"
            (not (any (\nm -> nm == "ghost" || nm == "ghost_idx") rowNames)) [])

-- ---------------------------------------------------------------------------
-- test 4: reopen (recoverDatabase + loadCatalog): the full committed state
--   (catalog rows, heap chains, index pages, published relroot) replays.
-- ---------------------------------------------------------------------------
recoveryCheck :: Env -> IO ([String], CatalogCache)
recoveryCheck env = do
  cache2 <- newCatalogCache
  loadCatalog env cache2
  ctl2 <- readTVarIO (envControl env)
  tm2 <- newTxnManager (cfNextTid ctl2)
  lm2 <- newLockManager
  e1 <- withTxnAuto tm2 lm2 env (\ctx -> do
        mrd <- lookupByName cache2 "person"
        mir <- lookupByName cache2 "person_idx"
        case (mrd, mir) of
          (Just rd, Just ixRd) -> do
            allr <- btreeRange env cache2 (rdId ixRd) Nothing Nothing
            truth <- truthFrom env ctx rd allr
            kres <- forM fillKeys $ \nm -> do
              got <- btreeSearch env cache2 (rdId ixRd) (VText (encodeUtf8 nm))
              let want = wantFor (VText (encodeUtf8 nm)) truth
              pure (if want == sort got then [] else
                    ["dbg " ++ unpack nm ++ " want=" ++ show want ++ " got=" ++ show (sort got)])
            pure (check "recovery: per-key searches match heap" (null (concat kres)) (concat kres)
                ++ check "recovery: full index scan matches heap"
                     (sortBy cmpKV allr == truth)
                     ["rec allrN=" ++ show (length allr) ++ " truthN=" ++ show (length truth)])
          _ -> pure ["recovery: relations missing after reload"])
    `catch` (\(er :: SqlError) ->
      pure ["recovery: check txn failed: " ++ unpack (seMessage er)])
  g <- lookupByName cache2 "ghost"
  gi <- lookupByName cache2 "ghost_idx"
  pure ((e1 ++ check "recovery: ghost table absent" (isNothing g) []
            ++ check "recovery: ghost index absent" (isNothing gi) []), cache2)

-- ---------------------------------------------------------------------------
main :: IO ()
main = do
  d <- doesDirectoryExist testDir
  when d (removeDirectoryRecursive testDir)
  cache <- newCatalogCache
  env <- createDatabase cfg cache
  ctl0 <- readTVarIO (envControl env)
  tm <- newTxnManager (cfNextTid ctl0)
  lm <- newLockManager
  e1 <- ddlAndFill env tm lm cache
  e3 <- abortedDDL env tm lm cache
  fsyncDataFile (envFileMgr env)
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  env2 <- recoverDatabase cfg
  (e4r, cache2) <- recoveryCheck env2
  ctl2 <- readTVarIO (envControl env2)
  tm2 <- newTxnManager (cfNextTid ctl2)
  lm2 <- newLockManager
  e4 <- deleteCheck env2 tm2 lm2 cache2
  closeDataFile (envFileMgr env2)
  closeWalManager (envWalMgr env2)
  let errs = e1 ++ e3 ++ e4r ++ e4
  mapM_ putStrLn errs
  if null errs
    then putStrLn "index-tests: all checks passed"
    else do
      putStrLn ("index-tests: " ++ show (length errs) ++ " failure(s)")
      exitFailure
