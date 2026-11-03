-- | In-memory free-space map (internal-design/01 §1.7).  Advisory only:
--   Heap rechecks real headers after pinning (a stale entry costs at most
--   one wasted pin).  Not persisted; rebuilt at startup/recovery (D-14).
module HaskDB.Storage.FreeSpace where

import qualified Data.Map as Map
import Control.Monad.STM (atomically)
import GHC.Internal.Conc.Sync (TVar, newTVarIO, readTVar, readTVarIO, writeTVar)
import HaskDB.Common.Types
import HaskDB.Storage.Page (readHeader, pageFreeContiguous)
import HaskDB.Storage.BufferPool (BufferPool, withPage)
import Data.Maybe (fromMaybe)

data FreeSpaceMap = FreeSpaceMap
  { fsmMap :: TVar (Map.Map RelId (Map.Map PageId Int)) }  -- rel -> page -> free bytes

newFreeSpaceMap :: IO FreeSpaceMap
newFreeSpaceMap = FreeSpaceMap <$> newTVarIO Map.empty

-- Rebuild by walking page headers (startup/recovery; internal/01 §1.7:
-- contiguous free only — fragmented space is discovered on demand).
fsmRebuild :: FreeSpaceMap -> BufferPool -> RelId -> [PageId] -> IO ()
fsmRebuild fsm bp rel pages = do
  free <- mapM (\pid -> withPage bp pid (\p -> do
                 hdr <- readHeader p; pure (pageFreeContiguous hdr))) pages
  atomically $ do
    m0 <- readTVar (fsmMap fsm)
    writeTVar (fsmMap fsm) (Map.insert rel (Map.fromList (zip pages free)) m0)

fsmNoteFree :: FreeSpaceMap -> RelId -> PageId -> Int -> IO ()
fsmNoteFree fsm rel pid bytes =
  -- Map.alter creates the inner Map on first note (Map.adjust would drop it)
  atomically $ do
    m0 <- readTVar (fsmMap fsm)
    writeTVar (fsmMap fsm)
      (Map.alter (\m -> Just (Map.insert pid bytes (fromMaybe Map.empty m))) rel m0)

fsmForget :: FreeSpaceMap -> RelId -> IO ()   -- unused in baseline (no DROP)
fsmForget fsm rel = atomically $ do
  m0 <- readTVar (fsmMap fsm)
  writeTVar (fsmMap fsm) (Map.delete rel m0)

-- First page (lowest PageId) whose recorded free bytes >= needed.
fsmFindPage :: FreeSpaceMap -> RelId -> Int -> IO (Maybe PageId)
fsmFindPage fsm rel need = do
  m <- readTVarIO (fsmMap fsm)
  pure $ case Map.lookup rel m of
    Nothing -> Nothing
    Just pm -> fmap fst (Map.lookupMin (Map.filter (>= need) pm))

fsmFreeOf :: FreeSpaceMap -> RelId -> PageId -> IO (Maybe Int)
fsmFreeOf fsm rel pid = do
  m <- readTVarIO (fsmMap fsm)
  pure $ Map.lookup pid =<< Map.lookup rel m
