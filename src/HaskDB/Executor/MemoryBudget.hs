-- | HaskDB.Executor.MemoryBudget — the per-statement memory budget of
--   internal/09 §9.1/§9.3 and design/08 §8.4 (D-08: one shared budget for
--   sort + hash tables + materialisation; exceeding it is 54000).
--   Deviation: the ExecCtx-based charge/release wrappers stay in
--   Executor.Types (ExecCtx is defined there); this module owns the raw
--   MemBudget value and the charged-unit estimate (tupleByteSize 8/8/1/len+2).
module HaskDB.Executor.MemoryBudget where

import Data.IORef (IORef, newIORef)
import qualified Data.ByteString as BS
import HaskDB.Common.Config (Config(cfgStmtMemBudget))
import HaskDB.Common.Types (Value(..))

data MemBudget = MemBudget { mbLimit :: !Int, mbUsed :: IORef Int }

newMemBudget :: Config -> IO MemBudget
newMemBudget cfg = do
  r <- newIORef 0
  pure MemBudget { mbLimit = cfgStmtMemBudget cfg, mbUsed = r }

-- | Estimated bytes of a materialised row: 8/8/1/len+2 per column
--   (internal/09 §9.1 tupleByteSize).
rowByteSize :: [Value] -> Int
rowByteSize = sum . map valueByteSize
  where
    valueByteSize (VInt _)   = 8
    valueByteSize (VFloat _) = 8
    valueByteSize (VBool _)  = 1
    valueByteSize (VText s)  = BS.length s + 2

totalRowBytes :: [[Value]] -> Int
totalRowBytes = sum . map rowByteSize



