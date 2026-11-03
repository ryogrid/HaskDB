-- | HaskDB.Planner.CostModel — the five fixed constants and the formulas of
--   design/07 §7.5 plus the estimation helpers of internal/08 §8.4.  Deviation
--   (recorded in TODO.md): the docs give no cost formula for Sort/Filter/
--   Project/HashAggregate/Materialize, and index `depth` is not tracked
--   anywhere; these use the documented CPU constant and a 4-way log estimate,
--   which never change any rule (scan/join choice is rule-based).
module HaskDB.Planner.CostModel where

import Data.Int (Int64)

-- ---------------------------------------------------------------------------
-- design/07 §7.5 constants
-- ---------------------------------------------------------------------------
seqPageCost, randomPageCost, cpuTupleCost, cpuOperatorCost :: Double
seqPageCost     = 1.0
randomPageCost  = 4.0
cpuTupleCost    = 0.01
cpuOperatorCost = 0.0025

nljHashThreshold :: Int
nljHashThreshold = 10000          -- rows product; above this prefer Hash Join

-- ---------------------------------------------------------------------------
-- Formulas (design/07 §7.5)
-- ---------------------------------------------------------------------------
costSeqScan :: Int -> Int64 -> Double               -- pages, rows
costSeqScan pg rows = fromIntegral pg * seqPageCost
                    + fromIntegral rows * cpuTupleCost

costIndexScan :: Int -> Int64 -> Double             -- depth, matched rows
costIndexScan depth matched =
  fromIntegral depth * randomPageCost
    + fromIntegral matched * (randomPageCost + cpuTupleCost)

-- estimated matched rows: fixed fractions, NOT statistics (§7.5)
matchedEq :: Int64 -> Int64
matchedEq rows    = max 1 (rows `div` 10)

matchedRange :: Int64 -> Int64
matchedRange rows = max 1 (rows `div` 3)

-- deviation: no depth is tracked anywhere; 4-way descent estimate >= 1
indexDepthEst :: Int64 -> Int
indexDepthEst rows
  | rows <= 0   = 1
  | otherwise   = 1 + (logBase4 rows)
  where
    logBase4 n = length (takeWhile (>= 1) (iterate (`div` (4 :: Int64)) n))

costNLJ :: Double -> Int64 -> Double -> Double      -- cost(T), rows(T), cost-per-probe(R)
costNLJ cT rowsT cProbe = cT + fromIntegral rowsT * cProbe

costHashJoin :: Double -> Double -> Int64 -> Int64 -> Double
costHashJoin cT cR rowsT rowsR =
  cT + cR + fromIntegral (rowsT + rowsR) * cpuOperatorCost

-- ---------------------------------------------------------------------------
-- Annotation-only estimates (internal/08 §8.4 fixed rules)
-- ---------------------------------------------------------------------------
-- | Filter selectivity: fold the §7.5 fixed fractions per conjunct
--   (divisor supplied by the planner via 'predDivisor': equality 10,
--   range/other 3).  Deviation: the docs state the fractions but leave
--   the fold shape to the implementation.
estFilterRows :: Int64 -> [Int64] -> Int64
estFilterRows rows ds = foldl (\acc d -> max 1 (acc `div` d)) rows ds

estJoinRowsEqui :: Int64 -> Int64 -> Int64
estJoinRowsEqui a b = max a b

estJoinRowsCross :: Int64 -> Int64 -> Int64
estJoinRowsCross a b = a * b

estSortRows :: Int64 -> Int64
estSortRows rows = rows

estAggRows :: Int64 -> Int64
estAggRows rows = rows

estProjectRows :: Int64 -> Int64
estProjectRows rows = rows







