-- | HaskDB.Executor.Stmts (design/08 §8.10 + internal-design/09 §9.2/§9.6):
--   the statement preamble (subquery materialisation) and result delivery.
--   Deviations (TODO.md): the row sink callback is an explicit argument of
--   'executeStatement' (the docs mention a callback in the flow text, not in
--   the signature); 'StmtResult' is a sum of the two shapes the docs list —
--   SELECT streams and reports a row count, Modify/DDL report a tag plus an
--   affected count (DDL uses 1: one relation created, the session layer
--   prints the bare 'CREATE TABLE'/'CREATE INDEX' tag); subquery results are
--   accumulated into a fresh 'ecSubq' map per statement, and a sub plan's own
--   'planSubqueries' are run before it (the planner hoists most of them into
--   the root list, §8.6 deviation).
module HaskDB.Executor.Stmts where

import Data.Map.Strict (Map)
import qualified Data.Map.Strict as M
import Data.Int (Int64)
import Data.Text (Text)
import Data.IORef (IORef, newIORef, readIORef)

import HaskDB.Common.Types (Value)
import HaskDB.Common.Error (errScalarSubqRows)
import HaskDB.Server.Env (Env(envConfig))
import HaskDB.Catalog.Cache (CatalogCache)
import HaskDB.Txn.Manager (TxnCtx)
import HaskDB.Executor.MemoryBudget (newMemBudget)
import HaskDB.Executor.Operators
import HaskDB.Executor.Types (ExecCtx(..), esData, Plan(..), planNode, planSubqueries, SubqueryId, SQKind(..), SubqueryResult(..), ExecState, PlanNode(PInsert, PUpdate, PDelete, PCreateTable, PCreateIndex))

-- ---------------------------------------------------------------------------
-- Statement result (internal/09 §9.6)
-- ---------------------------------------------------------------------------
data StmtResult
  = StmtRows  !Int64                          -- SELECT: streamed row count
  | StmtCount Text !Int64                     -- tag + affected rows
  deriving (Show, Eq)

stmtTag :: PlanNode -> Maybe Text
stmtTag n = case n of
  PInsert _ _ _      -> Just "INSERT"
  PUpdate _ _ _      -> Just "UPDATE"
  PDelete _ _        -> Just "DELETE"
  PCreateTable _     -> Just "CREATE TABLE"
  PCreateIndex _     -> Just "CREATE INDEX"
  _                  -> Nothing

-- ---------------------------------------------------------------------------
-- ExecCtx construction (internal/09 §9.2)
-- ---------------------------------------------------------------------------
newExecCtx :: Env -> CatalogCache -> TxnCtx -> IO ExecCtx
newExecCtx env cache ctx = do
  mem <- newMemBudget (envConfig env)
  rts <- newIORef M.empty
  tgs <- newIORef M.empty
  pure ExecCtx { ecEnv = env, ecTxn = ctx, ecCatalog = cache
               , ecSubq = M.empty, ecMem = mem, ecRoots = rts
               , ecTargets = tgs }

-- | Preamble: execute every subquery of the plan (bottom-up) and remember
--   its result.  Scalar subqueries are limited to one row here; zero rows
--   store 'SQScalar Nothing' and the 21000 error is raised at evaluation
--   time (§9.2 recorded choice).
runSubs :: ExecCtx -> Map SubqueryId SubqueryResult
        -> [(SubqueryId, Plan, SQKind)] -> IO (Map SubqueryId SubqueryResult)
runSubs _   acc [] = pure acc
runSubs ec acc ((sid, sub, kind) : rest) = do
  acc0 <- runSubs ec acc (planSubqueries sub)
  let ec' = ec { ecSubq = acc0 }
  h <- openPlan ec' sub
  rows <- drainRows ec' h
  closePlan ec' h
  res <- case kind of
    KindScalar -> case rows of
      []       -> pure (SQScalar Nothing)
      [r]      -> pure (SQScalar (case r of
                                    (v : _) -> Just v
                                    []      -> Nothing))
      _        -> throwSqlOf (errScalarSubqRows
                 ("scalar subquery returned " <> tshow (length rows)
                  <> " rows; expected exactly one"))
    KindSet    -> pure (SQSet [ v | (v : _) <- rows ])
    KindExists -> pure (SQExists (not (null rows)))
  runSubs ec' (M.insert sid res acc0) rest

-- ---------------------------------------------------------------------------
-- executeStatement
-- ---------------------------------------------------------------------------
executeStatement :: ExecCtx -> Plan -> ([Value] -> IO ()) -> IO StmtResult
executeStatement ec plan sink = do
  smap <- runSubs ec (ecSubq ec) (planSubqueries plan)
  let ec' = ec { ecSubq = smap }
  h <- openPlan ec' plan
  case stmtTag (planNode plan) of
    Just tag -> do
      st <- readIORef h
      n <- readModify (esData st)
      closePlan ec' h
      pure (StmtCount tag n)
    Nothing -> do
      n <- streamRows ec' h sink
      closePlan ec' h
      pure (StmtRows n)

-- | Drive a SELECT plan to exhaustion, feeding the wire-layer callback.
streamRows :: ExecCtx -> IORef ExecState -> ([Value] -> IO ()) -> IO Int64
streamRows ec h sink = go (0 :: Int64)
  where
    go n = nextRow ec h >>= \r -> case r of
      Nothing        -> pure n
      Just (_, vals) -> sink vals >> go (n + 1)





