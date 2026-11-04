-- | Executor data types (internal-design/09 §9.1; plan shape per design/07 §7.2
--   + internal/08 §8.8 cost wrapper).  The PLANNER is the only producer of
--   'Plan'; the executor pattern-matches on it.  Deviations from the docs'
--   sketches are recorded inline (the §ExecData record field left as "..." in
--   §9.1, the flat-ref/join-key fields the docs name but do not fully specify).
module HaskDB.Executor.Types where

import Data.Map.Strict (Map)
-- deviation: the docs' ExecData uses Data.HashMap.Strict; the dependency
--   stance (design/10, D-06 allows Hackage ONLY for `network`/sockets) keeps
--   us on containers, so the join/aggregate tables are Data.Map.Strict keyed
--   by the canonical value encoding (ByteString is Ord -> same equality).

import Data.ByteString (ByteString)
import Data.Int (Int64)
import Control.Monad (when)
import Data.IORef (IORef, readIORef, modifyIORef')

import HaskDB.Common.Types (Value(..), SqlType(..), RelId, RID(..), PageId)
import HaskDB.Common.Error (SqlError(..), errMemoryLimit, throwSql)
import HaskDB.Catalog.Types (IndexDesc(..), RelationDesc(..))
import HaskDB.Catalog.Cache (CatalogCache)
import HaskDB.Sql.Ast (AggFn(..), CreateTableStmt(..), CreateIndexStmt(..))
import HaskDB.Server.Env (Env(..))
import HaskDB.Txn.Manager (TxnCtx)
import HaskDB.Executor.MemoryBudget (MemBudget, mbLimit, mbUsed)

-- ---------------------------------------------------------------------------
-- Flat references (internal/08 §8.4 "FlatRef = Int")
-- ---------------------------------------------------------------------------
type FlatRef = Int

-- ---------------------------------------------------------------------------
-- Physical predicate language (§internal/09 §9.1)
-- ---------------------------------------------------------------------------
data PPred
  = PPAnd PPred PPred
  | PPOr PPred PPred
  | PPNot PPred
  | PPCmp POperand CmpOp POperand
  | PPIn FlatRef Bool SubqueryId        -- col [NOT] IN (materialised set)
  | PPExistsRef SubqueryId              -- §8.5 "RPExistsRef SubqueryId"
  deriving (Show)

data POperand = POCol FlatRef | POLit Value | POScalar SubqueryId
              | POInList SubqueryId     -- §9.1 lists it; PPIn is its user
  deriving (Show)

data CmpOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe deriving (Eq, Show)

newtype SubqueryId = SubqueryId Int deriving (Show, Eq, Ord)

-- ---------------------------------------------------------------------------
-- Plans (design/07 §7.2 -> internal/09 §9.1) + cost wrapper (§8.8)
-- ---------------------------------------------------------------------------
data Plan = Plan { planNode :: PlanNode, planCost :: Double
                 , planRows :: Int64, planSubqueries :: [(SubqueryId, Plan, SQKind)] }
  deriving (Show)

data PlanNode
  = PSeqScan      RelId
  | PIndexScan    RelId IndexDesc IndexBound
  | PFilter       PPred Plan
  | PProject      [ProjItem] Plan
  | PNestedLoop   Plan Plan (Maybe PPred)
  | PIndexNestedLoop Plan RelId IndexDesc FlatRef
  | PHashJoin     Plan Plan JoinSides
  | PHashAggregate [FlatRef] [AggSpec] Plan
  | PSort         [(Int, Bool)] Plan
  | PMaterialize  Plan
  | PInsert       RelId [Int] [[Value]]   -- deviation: target column ordinals
  | PUpdate       RelId [(Int, PAssignRhs)] Plan
  | PDelete       RelId Plan
  | PCreateTable  CreateTableStmt
  | PCreateIndex  CreateIndexStmt
  deriving (Show)

data ProjItem = PJCol FlatRef | PJLit Value deriving (Show)

data IndexBound = IBEqual Value
                | IBRange (Maybe (Value, Bool)) (Maybe (Value, Bool))  -- (bound, inclusive?)
  deriving (Show)

data JoinSides = JoinSides { jsBuild :: WhichSide, jsBuildKey :: FlatRef
                           , jsProbeKey :: FlatRef, jsResidual :: Maybe PPred }
  deriving (Show)
data WhichSide = BuildLeft | BuildRight deriving (Eq, Show)

data AggSpec = AggSpec { asFn :: AggFn, asArg :: Maybe FlatRef
                       , asOutType :: SqlType } deriving (Show, Eq)

data PAssignRhs = PALit Value | PACol FlatRef deriving (Show, Eq)

-- (ctor names differ from SubqueryResult's to avoid a clash)
data SQKind = KindScalar | KindSet | KindExists deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Operator state (internal/09 §9.1)
-- Deviations: child states and the NestedLoop inner state are IORefs (the
--   docs' `next :: ExecState -> IO ...` implies in-place cursor mutation; a
--   pure record needs explicit refs); DNL/DINL/DAgg/DHash carry the extra
--   fields the docs left unspecified or "..."; DModify modCount is an IORef
--   (§9.5 counts after running the operator to completion).
data ExecState = ExecState { esPlan :: Plan, esNode :: PlanNode
                           , esChild :: [IORef ExecState], esData :: ExecData }
  -- no Show: holds IORef cells.  Deviation: esPlan (the node's own Plan) is
  --   kept in the state so closing and re-opening a NestedLoop inner (§9.5)
  --   needs no plan stack.

data ExecData
  = DNone
  | DScan      ScanCursor
  | DFilter
  | DProject
  | DNL        { nlOuter :: Maybe [Value]
               , nlInner :: Maybe (IORef ExecState)
               , nlDone :: Bool
               , nlMat  :: Bool }          -- inner is PMaterialize: replay, not re-open
  | DINL       { inlOuter :: Maybe [Value], inlHits :: [(RID, [Value])] }
  | DHash      { hjTable :: Maybe (Map ByteString [[Value]])
               , hjMatches :: [[Value]]
               , hjProbeRow :: Maybe [Value]      -- §9.1 "hjProbe :: ..."
               , hjBuildLeft :: Bool }
  | DAgg       { aggRows :: [[Value]], aggIx :: Int }   -- finalized at open
  | DSort      { sortRows :: Maybe [[Value]], sortIx :: Int }
  | DMat       { matRows :: [[Value]], matIx :: Int }
  | DModify    { modCount :: IORef Int64 }
  -- no Show: holds IORef cells

data ScanCursor = ScanCursor
  { scPages :: [PageId], scSlot :: Int
  , scHits :: [(RID, [Value])] }
  -- deviation: the docs' scCurrentPage :: Maybe PinnedPage is replaced by
  --   per-page loading (one page pinned during a load call) and heapFetch
  --   per index hit, so no pinned page ever lives in the cursor value.
  deriving (Show)

data AggAccum
  = AccCount !Int64
  | AccSumInt !Int64
  | AccSumFloat !Double
  | AccAvg !Double !Int64
  | AccMinMax !Value
  deriving (Show, Eq)

-- ---------------------------------------------------------------------------
-- Execution context (internal/09 §9.1/§9.2)
-- ---------------------------------------------------------------------------
data SubqueryResult
  = SQScalar (Maybe Value) | SQSet [Value] | SQExists Bool
  deriving (Show)

-- ecRoots is a deviation: the index roots are carried for the WHOLE statement.
--   A COPY IN calls runInsert once per CopyData chunk, and seeding the roots
--   from the catalog each time made a later chunk descend the pre-split root
--   (the staged root only lands in the catalog at COMMIT), which left the
--   rows inserted after a split unreachable through the index.
-- ecTargets is the SIBLING deviation for the heap side of the same problem:
--   internal/06 §6.3's "the Modify operator keeps a local IORef RelationDesc
--   for its target table" (so a statement that allocates several heap pages
--   chains each one from the previous, per internal/01 §1.8 step 3) — it has
--   to live in the ExecCtx, not in runInsert, because one COPY IN statement
--   calls runInsert once per CopyData chunk and the catalog's rdPages stay
--   frozen until COMMIT.
data ExecCtx = ExecCtx { ecEnv :: Env, ecTxn :: TxnCtx
                       , ecCatalog :: CatalogCache
                       , ecSubq :: Map SubqueryId SubqueryResult
                       , ecMem :: MemBudget
                       , ecRoots :: IORef (Map RelId PageId)
                       , ecTargets :: IORef (Map RelId (IORef RelationDesc)) }
-- deviation: ecCatalog added (btreeSearch / index maintenance / relation
--   descs need the catalog handle inside operators; docs pass only Env).

-- | Charge the per-statement memory budget; over the limit is 54000 (D-08).
chargeMem :: ExecCtx -> Int -> IO ()
chargeMem ec n = do
  let m = ecMem ec
  modifyIORef' (mbUsed m) (+ n)
  used <- readIORef (mbUsed m)
  when (used > mbLimit m)
    (throwSql (stateOf errMemoryLimit) (msgOf errMemoryLimit))
  where
    stateOf (SqlError st _) = st
    msgOf (SqlError _ m') = m'

releaseMem :: ExecCtx -> Int -> IO ()
releaseMem ec n = modifyIORef' (mbUsed (ecMem ec)) (subtract n)











