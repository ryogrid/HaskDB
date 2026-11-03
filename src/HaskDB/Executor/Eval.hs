-- | HaskDB.Executor.Eval (internal/09 §9.4; design/08 §8.3 two-valued logic).
--   Deviation: evaluation runs in IO so a zero-row scalar subquery can throw
--   its 21000 lazily at first evaluation (§9.2's recorded choice), which a
--   pure signature cannot express.
module HaskDB.Executor.Eval where

import qualified Data.Map.Strict as M

import HaskDB.Common.Types (Value, compareSql)
import HaskDB.Common.Error (SqlError(..), throwSql, errScalarSubqRows, errInternal)
import HaskDB.Executor.Types

-- | Operand evaluation.  'POInList' is never produced by the planner
--   (PPIn is the dedicated node) — it is rejected with an internal error.
evalOperand :: ExecCtx -> POperand -> [Value] -> IO Value
evalOperand ec o row = case o of
  POCol i   -> pure (row !! i)
  POLit v   -> pure v
  POScalar sid -> case M.lookup sid (ecSubq ec) of
    Just (SQScalar (Just v)) -> pure v
    Just (SQScalar Nothing)  -> throwSqlOf (errScalarSubqRows
      "scalar subquery returned no rows")
    _ -> throwSqlOf (errInternal "executor: scalar subquery id not materialised")
  POInList _ -> throwSqlOf (errInternal
    "executor: POInList is never produced by the planner")

evalPred :: ExecCtx -> PPred -> [Value] -> IO Bool
evalPred ec p row = case p of
  PPAnd a b -> do
    x <- evalPred ec a row
    if x then evalPred ec b row else pure False
  PPOr a b -> do
    x <- evalPred ec a row
    if x then pure True else evalPred ec b row
  PPNot a -> not <$> evalPred ec a row
  PPCmp o1 op o2 -> do
    v1 <- evalOperand ec o1 row
    v2 <- evalOperand ec o2 row
    pure (cmpToBool op (compareSql v1 v2))
  PPIn f neg sid -> case M.lookup sid (ecSubq ec) of
    Just (SQSet vals) ->
      let m = any (\x -> compareSql (row !! f) x == EQ) vals
      in pure (if neg then not m else m)
    _ -> throwSqlOf (errInternal "executor: IN subquery id not materialised")
  PPExistsRef sid -> case M.lookup sid (ecSubq ec) of
    Just (SQExists b) -> pure b
    _ -> throwSqlOf (errInternal "executor: EXISTS subquery id not materialised")

cmpToBool :: CmpOp -> Ordering -> Bool
cmpToBool op c = case op of
  OpEq -> c == EQ
  OpNe -> c /= EQ
  OpLt -> c == LT
  OpLe -> c /= GT
  OpGt -> c == GT
  OpGe -> c /= LT

throwSqlOf :: SqlError -> IO a
throwSqlOf (SqlError st msg) = throwSql st msg



