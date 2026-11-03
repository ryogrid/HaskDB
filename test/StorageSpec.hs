-- Phase-1 milestone test suite (design/10 §10.2):
--   * property-style model test: random insert/delete/update/compact
--     sequences vs an in-memory Map model at the page level
--   * file persistence: reopen and verify the page image survives
--   * buffer pool: CLOCK eviction, dirty flush, WAL-rule stub ordering
--   * free-space map basics
module Main where

import System.Exit (exitSuccess, exitFailure)
import qualified Data.ByteString as BS
import qualified Data.Map as Map
import Data.IORef
import System.Directory (createDirectoryIfMissing, removeDirectoryRecursive)
import System.FilePath ((</>))
import Data.List (sort)

import HaskDB.Common.Types
import HaskDB.Common.Codec
import HaskDB.Storage.FileManager
import HaskDB.Storage.Page
import HaskDB.Storage.BufferPool
import HaskDB.Storage.FreeSpace
import HaskDB.Heap.TupleCodec

check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then errs else name : errs

-- ---------------------------------------------------------------------------
-- Deterministic LCG (hand-rolled generators per D-13)
-- ---------------------------------------------------------------------------
nextRnd :: Int -> Int
nextRnd s = (s * 1103515245 + 12345) `mod` 2147483648

-- Schema INT64 + VARCHAR; tuple sizes small enough for the test page size.
cols :: [ColumnDesc]
cols = [ ColumnDesc "n" TyInt64, ColumnDesc "s" TyVarchar ]

mkTuple :: Int -> Tuple
mkTuple i = [ VInt (fromIntegral i)
            , VText (BS.pack (map (fromIntegral . fromEnum) ("r" ++ show i))) ]

-- ---------------------------------------------------------------------------
-- Test A — random op sequence vs Map model (page level, compaction)
-- ---------------------------------------------------------------------------
modelTest :: IO [String]
modelTest = do
  let pageSize = 128
  ref <- newIORef (BS.replicate pageSize 0)
  let pr = PageRef ref
  initPage pr PKHeap pageSize
  model <- newIORef Map.empty
  let loop seed n
        | n == (0 :: Int) = pure []
        | otherwise = do
            let op = seed `mod` 5
            case op of
              0 -> do  -- insert (or compact when tight)
                let nextT = mkTuple n
                hdr <- readHeader pr
                if tupleSize cols nextT + itemSize <= pageFreeContiguous hdr
                  then do
                    s <- pageInsertTuple pr (fromIntegral n) (encodeTuple cols nextT)
                    modifyIORef model (Map.insert s nextT)
                    loop (nextRnd seed) (n - 1)
                  else do
                    pageCompact pr (fromIntegral n) pageSize
                    loop (nextRnd seed) (n - 1)
              1 -> do  -- delete lowest live slot
                t <- readIORef model
                case Map.lookupMin t of
                  Nothing -> loop (nextRnd seed) (n - 1)
                  Just (s, _) -> do
                    pageDeleteTuple pr (fromIntegral n) s
                    modifyIORef model (Map.delete s)
                    loop (nextRnd seed) (n - 1)
              2 -> do  -- update: shrink image (in place)
                t <- readIORef model
                case Map.lookupMin t of
                  Nothing -> loop (nextRnd seed) (n - 1)
                  Just (s, _) -> do
                    let newT = [VInt 777, VText "z"]
                    pageUpdateTuple pr (fromIntegral n) pageSize s (encodeTuple cols newT)
                    modifyIORef model (Map.insert s newT)
                    loop (nextRnd seed) (n - 1)
              3 -> do  -- update: grow (move-within-page, else compact first)
                t <- readIORef model
                case Map.lookupMin t of
                  Nothing -> loop (nextRnd seed) (n - 1)
                  Just (s, _) -> do
                    let bigT = [VInt 5, VText (BS.replicate 30 107)]
                        bigBytes = encodeTuple cols bigT
                    m <- readSlot pr s
                    case m of
                      Nothing -> loop (nextRnd seed) (n - 1)
                      Just (_, l) -> do
                        fm <- pageFragmentedFree pr pageSize
                        if BS.length bigBytes <= l + fm
                          then do
                            pageUpdateTuple pr (fromIntegral n) pageSize s bigBytes
                            modifyIORef model (Map.insert s bigT)
                            loop (nextRnd seed) (n - 1)
                          else do
                            pageCompact pr (fromIntegral n) pageSize
                            loop (nextRnd seed) (n - 1)
              _ -> loop (nextRnd seed) (n - 1)
  errs <- loop 987654321 60
  checkPage pr pageSize
  live <- liveSlots pr
  pairs <- mapM (\(s, _, _) -> do
    b <- pageReadTuple pr s
    pure (s, decodeTuple cols b)) live
  t <- readIORef model
  let decoded = Map.fromList [ (s, tt) | (s, Right tt) <- pairs ]
      decodeOk = all (\(_, r) -> case r of Right _ -> True; Left _ -> False) pairs
  pure $ check "model: 60 random ops keep page == Map model"
              (decodeOk && decoded == t) errs
        ++ check "model: live slot keys match model keys"
              (sort (map (\(s, _, _) -> s) live) == sort (Map.keys t)) []

-- ---------------------------------------------------------------------------
-- Test B — persistence: write via buffer pool, close, reopen, verify
-- ---------------------------------------------------------------------------
persistTest :: IO [String]
persistTest = do
  let pageSize = 128
      dir = "/tmp/opencode/hdb-p1-test"
      path = dir </> "data"
  createDirectoryIfMissing True dir
  fm <- openDataFile path pageSize
  _ <- extendFile fm  -- page 0
  bp <- newBufferPool pageSize 4 fm (\_ -> pure ())
  pp <- pinNewPage bp 0 PKHeap
  _ <- pageInsertTuple (ppPage pp) 42 (encodeTuple cols (mkTuple 9))
  unpinPage bp pp True
  frameBytes <- readIORef (frBytes (ppFrame pp))
  flushPage bp 0
  closeDataFile fm
  fm2 <- openDataFile path pageSize
  bs <- readPageBytes fm2 0
  removeDirectoryRecursive dir
  let hdrOk = case decodeHeader (BS.take headerSize bs) of
        Right h -> phLsn h == 42
        Left _  -> False
      tupleOk = case decodeSlotIn bs 0 of
        Just (o, l) -> case decodeTuple cols (BS.take l (BS.drop o bs)) of
                         Right t -> t == mkTuple 9
                         Left _  -> False
        Nothing -> False
  pure $ check "persist: reopened file image identical" (bs == frameBytes) []
        ++ check "persist: page LSN stamped from WAL record (42)" hdrOk []
        ++ check "persist: tuple decodes after reopen" tupleOk []

decodeSlotIn :: BS.ByteString -> Int -> Maybe (Int, Int)
decodeSlotIn bs n =
  let o = headerSize + n * itemSize
  in  if o + itemSize <= BS.length bs
        then case runDecode (do x <- getW16le; y <- getW16le; pure (x, y))
                   (BS.take itemSize (BS.drop o bs)) of
               Right (x, y) | y == 0     -> Nothing
                            | otherwise -> Just (fromIntegral x, fromIntegral y)
               Left _ -> Nothing
        else Nothing

-- ---------------------------------------------------------------------------
-- Test C — eviction: 2 frames, 3 pages dirty; CLOCK must flush dirty
-- victims; WAL-rule stub sees each page LSN before its write.
-- ---------------------------------------------------------------------------
evictTest :: IO [String]
evictTest = do
  let pageSize = 128
      dir = "/tmp/opencode/hdb-p1-evict"
      path = dir </> "data"
  createDirectoryIfMissing True dir
  fm <- openDataFile path pageSize
  _ <- extendFile fm
  _ <- extendFile fm
  _ <- extendFile fm  -- pages 0,1,2
  logRef <- newIORef ([] :: [LSN])
  bp <- newBufferPool pageSize 2 fm (\lsn -> modifyIORef logRef (lsn :))
  mapM_ (\(pid, lsn) -> do
    pp <- pinNewPage bp pid PKHeap
    _ <- pageInsertTuple (ppPage pp) lsn (encodeTuple cols (mkTuple (fromIntegral pid)))
    unpinPage bp pp True)
    (zip [0, 1] [11, 22])
  pp2 <- pinNewPage bp 2 PKHeap   -- forces eviction of one dirty frame
  logsAtPin <- readIORef logRef  -- snapshot: only the EVICTED page's LSN
  _ <- pageInsertTuple (ppPage pp2) 33 (encodeTuple cols (mkTuple 2))
  unpinPage bp pp2 True
  flushAll bp
  logs <- readIORef logRef
  closeDataFile fm
  fm2 <- openDataFile path pageSize
  b0 <- readPageBytes fm2 0
  b1 <- readPageBytes fm2 1
  b2 <- readPageBytes fm2 2
  removeDirectoryRecursive dir
  let lsnOf bs = case decodeHeader (BS.take headerSize bs) of
        Right h -> Just (phLsn h)
        Left _  -> Nothing
  pure $ check "evict: CLOCK eviction flushed frame 0 (LSN 11) during pin"
              (logsAtPin == [11]) []
        ++ check "evict: WAL-rule stub called for flushed page LSNs"
              (all (`elem` logs) [11, 22, 33]) []
        ++ check "evict: page0 image on disk has LSN 11" (lsnOf b0 == Just 11) []
        ++ check "evict: page1 image on disk has LSN 22" (lsnOf b1 == Just 22) []
        ++ check "evict: page2 image on disk has LSN 33" (lsnOf b2 == Just 33) []

-- ---------------------------------------------------------------------------
-- Test D — free-space map basics
-- ---------------------------------------------------------------------------
fsmTest :: IO [String]
fsmTest = do
  fsm <- newFreeSpaceMap
  fsmNoteFree fsm 1 3 100
  fsmNoteFree fsm 1 7 50
  m <- fsmFindPage fsm 1 60
  m2 <- fsmFindPage fsm 1 10
  pure $ check "fsm: findPage 60 -> pid 3" (m == Just 3) []
        ++ check "fsm: findPage 10 -> pid 3 (lowest pid wins)" (m2 == Just 3) []

main :: IO ()
main = do
  esA <- modelTest
  esB <- persistTest
  esC <- evictTest
  esD <- fsmTest
  let errs = esA ++ esB ++ esC ++ esD
  mapM_ putStrLn errs
  if null errs then exitSuccess else exitFailure
