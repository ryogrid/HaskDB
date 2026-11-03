-- Phase-6 milestone suite (design/10 §10.2 T32-T35): in-process end-to-end
-- SQL: parse -> analyze -> plan -> execute, one transaction per statement
-- (design/03 §3.6, internal/04 §4.2 rollback discipline).
--   * SeqScan vs IndexScan with plan dumps: equality (IBEqual) and range
--     (IBRange) probes vs a plain filter (PSeqScan) — the §8.3 rule table
--   * the three join algorithms planned by §8.4 (PIndexNestedLoop for the
--     indexed inner slot, PNestedLoop for a cross predicate, PHashJoin above
--     the §7.5 row-product threshold) AND the same join forced as three
--     hand-built plans, whose outputs must be identical
--   * GROUP BY + COUNT/SUM/AVG/MIN/MAX, the empty-global-group rule (COUNT
--     returns 0, the others throw 21000 per D-09), stable ORDER BY asc/desc
--   * subqueries: derived table in FROM, IN / NOT IN, EXISTS / NOT EXISTS,
--     scalar subquery (ok + the >1-row 21000)
--   * DML two-phase: UPDATE/DELETE counts, reltuples staging, index
--     maintenance proven by a probe in a LATER transaction
--   * error corpus + rollback: 0A000 partial INSERT column list, 4280 arity,
--     22001 VARCHAR, 42P01/42703/42702 name errors, 21000 scalar rows,
--     22003 INT64 overflow, 54000 statement memory budget, 54000 too-large
--     tuple mid-UPDATE (a partially executed UPDATE must leave the heap
--     unchanged after rollback)
module Main where

import Control.Exception (catch)
import Control.Monad (forM_, when)
import Data.List (sort, sortBy, nub)
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8, decodeUtf8)
import Data.ByteString (ByteString)
import Data.IORef
import System.Directory (doesDirectoryExist, removeDirectoryRecursive)
import System.Exit (exitFailure)
import GHC.Internal.Conc.Sync (readTVarIO)

import HaskDB.Common.Config (Config, defaultConfig, cfgPageSize, cfgBufferFrames, cfgStmtMemBudget)
import HaskDB.Common.Error (SqlError(seState, seMessage), throwSql)
import HaskDB.Common.Types (Value(VInt, VFloat, VText, VBool))
import HaskDB.Server.Env (Env, envFileMgr, envWalMgr, envControl)
import HaskDB.Server.Control (ControlFile(cfNextTid))
import HaskDB.Storage.FileManager (closeDataFile)
import HaskDB.Wal.Manager (closeWalManager)
import HaskDB.Catalog.Cache (CatalogCache, newCatalogCache, lookupByName, indexesOf)
import HaskDB.Catalog.Types (RelationDesc(rdId), IndexDesc(ixColumn))
import HaskDB.Catalog.Bootstrap (createDatabase)
import HaskDB.Sql.Parser (parseStatement)
import HaskDB.Sql.Analyzer (analyze)
import HaskDB.Planner.Planner (planStatement)
import HaskDB.Executor.Stmts (newExecCtx, executeStatement, StmtResult(StmtRows, StmtCount))
import HaskDB.Executor.Operators (openPlan, drainRows, closePlan)
import HaskDB.Executor.Types (Plan(..), PlanNode(PSeqScan, PNestedLoop, PHashJoin, PIndexNestedLoop, PProject), PPred(PPCmp), POperand(POCol), CmpOp(OpEq), JoinSides(..), WhichSide(BuildLeft), ProjItem(PJCol))
import HaskDB.Txn.Manager (TxnManager, newTxnManager, withTxnAuto)
import HaskDB.Txn.LockManager (LockManager, newLockManager)

-- ---------------------------------------------------------------------------
-- fixtures
-- ---------------------------------------------------------------------------
testDir :: String
testDir = "exec-test-dir"

cfg :: Config
cfg = (defaultConfig testDir) { cfgPageSize      = 1024
                              , cfgBufferFrames  = 64
                              , cfgStmtMemBudget = 20000 }

personFixture :: [(Text, Int)]
personFixture = [ (pack ("p" ++ show i), 20 + (i * 7) `mod` 40) | i <- [1 .. 60 :: Int] ]

cityFixture :: [(Text, Int)]
cityFixture = [ (pack ("p" ++ show (1 + (k - 1) `mod` 7)), 3 * k) | k <- [1 .. 20 :: Int] ]

joinFixture :: [(Int, Text)]
joinFixture = [ (k, pack ("v" ++ show k)) | k <- [1 .. 101 :: Int] ]

longText :: Int -> Text
longText k = pack (show k ++ "-" ++ replicate 110 'z')

bigFixture :: [Text]
bigFixture = [ longText k | k <- [1 .. 250 :: Int] ]

hugeText :: Text
hugeText = pack (replicate 1000 'q')

overText :: Text
overText = pack (replicate 1100 'w')

txt :: Text -> Value
txt = VText . encodeUtf8

vint :: Int -> Value
vint = VInt . fromIntegral

lit :: Text -> Text
lit t = pack ("'" ++ unpack t ++ "'")

sql :: Text -> ByteString
sql = encodeUtf8

ageOf :: Text -> Int
ageOf nm = case [ a | (n, a) <- personFixture, n == nm ] of
  (a : _) -> a
  []      -> 0

-- ---------------------------------------------------------------------------
-- check plumbing
-- ---------------------------------------------------------------------------
canonV :: Value -> String
canonV (VInt x)   = "i" ++ show x
canonV (VFloat x) = "f" ++ show x
canonV (VBool b)  = "b" ++ show b
canonV (VText s)  = "t" ++ unpack (decodeUtf8 s)

canonRows :: [[Value]] -> [String]
canonRows rows = map (\r -> joinBar (map canonV r)) rows
  where
    joinBar :: [String] -> String
    joinBar = foldr (\x acc -> if null acc then x else x ++ "|" ++ acc) ""

planWords :: String -> [String]
planWords s = words (map (\c -> if c `elem` ("(){}[];," :: String) then ' ' else c) s)

check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then [] else name : errs

chkRows :: String -> SqlRes -> [[Value]] -> [String]
chkRows label res want = case res of
  Left e -> [label ++ ": unexpected error " ++ unpack (seState e)]
  Right (rows, _) -> check label (canonRows rows == canonRows want)
    [label ++ ": rows differ, got " ++ show (canonRows rows)
     ++ " want " ++ show (canonRows want)]

chkSet :: String -> SqlRes -> [[Value]] -> [String]
chkSet label res want = case res of
  Left e -> [label ++ ": unexpected error " ++ unpack (seState e)]
  Right (rows, _) -> check label (sort (canonRows rows) == sort (canonRows want))
    [label ++ ": row set differs, got " ++ show (sort (canonRows rows))
     ++ " want " ++ show (sort (canonRows want))]

chkErr :: String -> String -> SqlRes -> [String]
chkErr label want res = case res of
  Left e  -> check label (unpack (seState e) == want)
                [label ++ ": wrong SQLSTATE, got " ++ unpack (seState e)]
  Right _ -> [label ++ ": expected " ++ want ++ ", statement succeeded"]

chkTag :: String -> SqlRes -> String -> Int -> [String]
chkTag label res tag want = case res of
  Left e -> [label ++ ": unexpected error " ++ unpack (seState e)]
  Right (_, r) -> check label (r == StmtCount (pack tag) (fromIntegral want))
                     [label ++ ": " ++ tag ++ " differs, got " ++ show r]

chkRowCount :: String -> SqlRes -> Int -> [String]
chkRowCount label res want = case res of
  Left e -> [label ++ ": unexpected error " ++ unpack (seState e)]
  Right (_, r) -> check label (r == StmtRows (fromIntegral want))
                     [label ++ ": row count differs, got " ++ show r]

chkPlan :: String -> Text -> Either SqlError String -> [String] -> [String]
chkPlan label src dump need = case dump of
  Left e  -> [label ++ ": plan failed " ++ unpack (seState e)]
  Right s -> check label (all (`elem` planWords s) need)
                [label ++ " (" ++ unpack src ++ ") dump: " ++ s]

-- ---------------------------------------------------------------------------
-- statement driving
-- ---------------------------------------------------------------------------
type SqlRes = Either SqlError ([[Value]], StmtResult)

runSql :: Env -> TxnManager -> LockManager -> CatalogCache -> Text -> IO SqlRes
runSql env tm lm cache src = do
  ref <- newIORef ([] :: [[Value]])
  let action ctx = do
        ec <- newExecCtx env cache ctx
        case parseStatement (sql src) of
          Left e   -> throwSql (seState e) (seMessage e)
          Right st -> do
            a   <- analyze cache st
            p   <- planStatement cache a
            res <- executeStatement ec p (\v -> modifyIORef' ref (++ [v]))
            pure (Right res)
  r <- withTxnAuto tm lm env action `catch` (\(e :: SqlError) -> pure (Left e))
  rws <- readIORef ref
  pure (fmap (\res -> (rws, res)) r)

fill :: Env -> TxnManager -> LockManager -> CatalogCache -> Text -> IO ()
fill env tm lm cache s = do
  _ <- runSql env tm lm cache s
  pure ()

planText :: CatalogCache -> Text -> IO (Either SqlError String)
planText cache src = case parseStatement (sql src) of
  Left e -> pure (Left e)
  Right st -> do
    r <- (do a <- analyze cache st
             p <- planStatement cache a
             pure (Right (show p)))
         `catch` (\(e :: SqlError) -> pure (Left e))
    pure r

-- ---------------------------------------------------------------------------
-- forced join plans: the same join through each algorithm (§7.5 rule bypass)
-- ---------------------------------------------------------------------------
forcedPlan :: PlanNode -> Plan
forcedPlan node = Plan { planNode = node, planCost = 0.0, planRows = 0
                       , planSubqueries = [] }

runForced :: Env -> TxnManager -> LockManager -> CatalogCache -> Plan
          -> IO (Either SqlError [[Value]])
runForced env tm lm cache p = do
  let action ctx = do
        ec <- newExecCtx env cache ctx
        h <- openPlan ec p
        rows <- drainRows ec h
        closePlan ec h
        pure (Right rows)
  withTxnAuto tm lm env action `catch` (\(e :: SqlError) -> pure (Left e))

rowsOf :: Either SqlError [[Value]] -> [[Value]]
rowsOf (Right xs) = xs
rowsOf (Left _)   = []

wrapRows :: Either SqlError [[Value]] -> SqlRes
wrapRows (Right xs) = Right (xs, StmtRows 0)
wrapRows (Left e)   = Left e

forcedJoin :: Env -> TxnManager -> LockManager -> CatalogCache -> IO [String]
forcedJoin env tm lm cache = do
  mp <- lookupByName cache "person"
  mc <- lookupByName cache "city"
  cixs <- indexesOf cache (maybe (-1) rdId mc)
  case (mp, mc, [ i | i <- cixs, ixColumn i == 0 ]) of
    (Nothing, _, _) -> pure ["forced joins: person missing"]
    (_, Nothing, _) -> pure ["forced joins: city missing"]
    (_, _, [])      -> pure ["forced joins: city index missing"]
    (Just pr, Just cr, cix : _) -> do
      let scanP = forcedPlan (PSeqScan (rdId pr))
          scanC = forcedPlan (PSeqScan (rdId cr))
          eqPred = PPCmp (POCol 0) OpEq (POCol 2)
          project p = forcedPlan (PProject [PJCol 0, PJCol 2] p)
      rN <- runForced env tm lm cache
               (project (forcedPlan (PNestedLoop scanP scanC (Just eqPred))))
      rH <- runForced env tm lm cache
               (project (forcedPlan (PHashJoin scanP scanC
                          JoinSides { jsBuild = BuildLeft, jsBuildKey = 0
                                    , jsProbeKey = 0, jsResidual = Nothing })))
      rI <- runForced env tm lm cache
               (project (forcedPlan (PIndexNestedLoop scanP (rdId cr) cix 0)))
      let want = [ [txt nm, txt cn] | (nm, _) <- personFixture
                                   , (cn, _) <- cityFixture, cn == nm ]
      pure (chkSet "forced NLJ rows" (wrapRows rN) want
          ++ chkSet "forced HashJoin rows" (wrapRows rH) want
          ++ chkSet "forced INLJ rows" (wrapRows rI) want
          ++ check "forced plans agree"
               (sort (canonRows (rowsOf rN)) == sort (canonRows (rowsOf rI))
                && sort (canonRows (rowsOf rH)) == sort (canonRows (rowsOf rI)))
               ["forced join outputs differ"])

-- ---------------------------------------------------------------------------
-- scenario
-- ---------------------------------------------------------------------------
scenario :: Env -> TxnManager -> LockManager -> CatalogCache -> IO [String]
scenario env tm lm cache = do
  -- DDL through the executor
  _ <- runSql env tm lm cache "create table person (name varchar, age int64)"
  _ <- runSql env tm lm cache "create table city (cname varchar, cpop int64)"
  _ <- runSql env tm lm cache "create table j1 (k int64, v varchar)"
  _ <- runSql env tm lm cache "create table j2 (k int64, w varchar)"
  _ <- runSql env tm lm cache "create table ovf (n int64)"
  _ <- runSql env tm lm cache "create table bigt (t varchar)"
  _ <- runSql env tm lm cache "create table j3 (a int64, b int64)"
  _ <- runSql env tm lm cache "create table j4 (m int64, n int64)"
  _ <- runSql env tm lm cache "create table j5 (s int64)"
  -- fill
  forM_ personFixture $ \(nm, ag) ->
    fill env tm lm cache ("insert into person (name, age) values ("
                          <> lit nm <> ", " <> pack (show ag) <> ")")
  forM_ cityFixture $ \(nm, cp) ->
    fill env tm lm cache ("insert into city (cname, cpop) values ("
                          <> lit nm <> ", " <> pack (show cp) <> ")")
  forM_ joinFixture $ \(k, v) -> do
    fill env tm lm cache ("insert into j1 (k, v) values ("
                          <> pack (show k) <> ", " <> lit v <> ")")
    fill env tm lm cache ("insert into j2 (k, w) values ("
                          <> pack (show k) <> ", " <> lit v <> ")")
  fill env tm lm cache "insert into ovf (n) values (9000000000000000000)"
  fill env tm lm cache "insert into ovf (n) values (8000000000000000000)"
  forM_ bigFixture $ \t ->
    fill env tm lm cache ("insert into bigt (t) values (" <> lit t <> ")")
  -- indexes AFTER the fill: the bulk build covers every row
  _ <- runSql env tm lm cache "create index person_age on person (age)"
  _ <- runSql env tm lm cache "create index city_name on city (cname)"
  _ <- runSql env tm lm cache "create index j1_v on j1 (v)"
  inlBndSrc <- return
    "select name, cname from person, city where name = cname and cname >= 'p3'"
  inlBndRes <- runSql env tm lm cache inlBndSrc
  inlBndDump <- planText cache inlBndSrc
  hjThSrc <- return
    "select v, w from j2, j1 where j2.k = j1.k and j1.v = 'v7'"
  hjThRes <- runSql env tm lm cache hjThSrc
  hjThDump <- planText cache hjThSrc

  selAll   <- runSql env tm lm cache "select name, age from person"
  selCity  <- runSql env tm lm cache "select cname, cpop from city"
  selStar  <- runSql env tm lm cache "select * from city"
  selLit   <- runSql env tm lm cache "select 1 from person"
  selAlias <- runSql env tm lm cache "select nm from (select name as nm from person) as q"

  let eqSrc  = "select name from person where age = 27"
      rngSrc = "select name from person where age >= 30 and age <= 40"
      neqSrc = "select name from person where age <> 27"
  eqRes   <- runSql env tm lm cache eqSrc
  rngRes  <- runSql env tm lm cache rngSrc
  neqRes  <- runSql env tm lm cache neqSrc
  eqDump  <- planText cache eqSrc
  rngDump <- planText cache rngSrc
  neqDump <- planText cache neqSrc

  let inlSrc = "select name, cname from person, city where name = cname"
      nljSrc = "select name, cname from person, city where age < cpop"
      hjSrc  = "select v, w from j1, j2 where j1.k = j2.k"
  inlRes  <- runSql env tm lm cache inlSrc
  nljRes  <- runSql env tm lm cache nljSrc
  hjRes   <- runSql env tm lm cache hjSrc
  inlDump <- planText cache inlSrc
  nljDump <- planText cache nljSrc
  hjDump  <- planText cache hjSrc
  forcedErrs <- forcedJoin env tm lm cache

  cntAll   <- runSql env tm lm cache "select count(name) from person"
  sumAll   <- runSql env tm lm cache "select sum(age) from person"
  avgAll   <- runSql env tm lm cache "select avg(age) from person"
  minMax   <- runSql env tm lm cache "select min(age), max(age) from person"
  cntEmpty <- runSql env tm lm cache "select count(name) from person where age > 5000"
  sumEmpty <- runSql env tm lm cache "select sum(age) from person where age > 5000"
  grpRes   <- runSql env tm lm cache
                "select cname, count(cname) from person, city where name = cname group by cname"
  grpSrc   <- runSql env tm lm cache
                "select cname, sum(cpop) from city group by cname order by cname"

  ordAsc  <- runSql env tm lm cache "select name, age from person order by age"
  ordDesc <- runSql env tm lm cache "select name, age from person order by age desc"

  inRes    <- runSql env tm lm cache "select name from person where age in (select cpop from city)"
  notRes   <- runSql env tm lm cache "select name from person where age not in (select cpop from city)"
  exRes    <- runSql env tm lm cache "select cname from city where exists (select 1 from person)"
  noExRes  <- runSql env tm lm cache "select cname from city where not exists (select 1 from person)"
  scRes    <- runSql env tm lm cache "select name from person where age > (select cpop from city where cpop = 6)"
  scBadRes <- runSql env tm lm cache "select name from person where age > (select cpop from city)"
  derSrc   <- return "select nm, ag from (select name as nm, age as ag from person) as q where ag = 27"
  derRes   <- runSql env tm lm cache derSrc
  derDump  <- planText cache derSrc

  updRes   <- runSql env tm lm cache "update person set age = 99 where name = 'p3'"
  delRes   <- runSql env tm lm cache "delete from person where name = 'p7'"
  probeUpd <- runSql env tm lm cache "select name from person where age = 99"
  probeOld <- runSql env tm lm cache
                ("select name from person where age = " <> pack (show (ageOf (pack "p3"))))
  cntAfter <- runSql env tm lm cache "select count(name) from person"

  updHuge  <- runSql env tm lm cache
                (case bigFixture of
                   (t1 : t2 : _) -> "update bigt set t = " <> lit hugeText
                                    <> " where t = " <> lit t1 <> " or t = " <> lit t2
                   _             -> error "fixture invariant")
  afterHuge <- runSql env tm lm cache "select t from bigt"

  pPartial <- runSql env tm lm cache "insert into person (name) values ('zz')"
  pArity   <- runSql env tm lm cache "insert into person (name, age) values ('zz')"
  pLong    <- runSql env tm lm cache
                ("insert into person (name, age) values (" <> lit overText <> ", 5)")
  pNoTbl   <- runSql env tm lm cache "select x from nosuchtable"
  pNoCol   <- runSql env tm lm cache "select nosuchcol from person"
  pAmbig   <- runSql env tm lm cache "select k from j1, j2 where k = 1"
  pOvf     <- runSql env tm lm cache "select sum(n) from ovf"
  pMem     <- runSql env tm lm cache "select t from bigt order by t"
  pGroup   <- runSql env tm lm cache "select name, count(age) from person"
  pOrd     <- runSql env tm lm cache "select name from person order by 7"

  let ages = [ a | (_, a) <- personFixture ]
      total = sum ages
      wantAll = [ [txt nm, vint ag] | (nm, ag) <- personFixture ]
      wantCity = [ [txt nm, vint cp] | (nm, cp) <- cityFixture ]
      wantEq = [ [txt nm] | (nm, ag) <- personFixture, ag == 27 ]
      wantRng = [ [txt nm] | (nm, ag) <- personFixture, ag >= 30, ag <= 40 ]
      wantNeq = [ [txt nm] | (nm, ag) <- personFixture, ag /= 27 ]
      wantInl = [ [txt nm, txt cn] | (nm, _) <- personFixture
                                    , (cn, _) <- cityFixture, cn == nm ]
      wantNlj = [ [txt n2, txt cn] | (n2, ag) <- personFixture
                                    , (cn, cp) <- cityFixture, ag < cp ]
      wantHj = [ [txt v, txt w] | (k, v) <- joinFixture
                                    , (k2, w) <- joinFixture, k == k2 ]
      wantCnt = [[vint (length ages)]]
      wantSum = [[vint total]]
      wantAvg = [[VFloat (fromIntegral total / fromIntegral (length ages))]]
      wantMinMax = [[vint (minimum ages), vint (maximum ages)]]
      wantCntEmpty = [[vint 0]]
      grpKeys = nub [ cn | (cn, _) <- cityFixture ]
      wantGrp = [ [txt cn, vint (length [ x | x <- cityFixture, fst x == cn ])]
                | cn <- grpKeys ]
      wantGrpSrc = [ [txt cn, vint (sum [ cp | (c, cp) <- cityFixture, c == cn ])]
                   | cn <- sort grpKeys ]
      idxs = [0 .. length personFixture - 1 :: Int]
      ascIdx = sortBy (\x y -> case compare (snd (personFixture !! x))
                                      (snd (personFixture !! y)) of
                               EQ -> compare x y
                               c  -> c) idxs
      descIdx = sortBy (\x y -> case compare (snd (personFixture !! y))
                                      (snd (personFixture !! x)) of
                               EQ -> compare x y
                               c  -> c) idxs
      wantAsc = [ [txt (fst (personFixture !! i)), vint (snd (personFixture !! i))]
                | i <- ascIdx ]
      wantDesc = [ [txt (fst (personFixture !! i)), vint (snd (personFixture !! i))]
                 | i <- descIdx ]
      wantIn = [ [txt nm] | (nm, ag) <- personFixture
                             , any (\(_, cp) -> cp == ag) cityFixture ]
      wantNot = [ [txt nm] | (nm, ag) <- personFixture
                             , not (any (\(_, cp) -> cp == ag) cityFixture) ]
      wantAllCity = [ [txt cn] | (cn, _) <- cityFixture ]
      wantSc = [ [txt nm] | (nm, ag) <- personFixture, ag > 6 ]
      wantDer = [ [txt nm, vint ag] | (nm, ag) <- personFixture, ag == 27 ]
      oldP3 = ageOf (pack "p3")
      wantProbeOld = [ [txt nm] | (nm, ag) <- personFixture
                             , ag == oldP3, nm /= pack "p3" ]
      wantAfter = [[vint (length ages - 1)]]

  pure (concat
    [ chkRows "select person" selAll wantAll
    , chkRows "select city" selCity wantCity
    , chkRows "select star city" selStar wantCity
    , chkRowCount "select literal" selLit 60
    , chkSet "derived alias rows" selAlias [[txt nm] | (nm, _) <- personFixture]
    , chkSet "index equality" eqRes wantEq
    , chkSet "index range" rngRes wantRng
    , chkSet "filter no-index" neqRes wantNeq
    , chkPlan "plan equality" eqSrc eqDump ["PIndexScan", "IBEqual"]
    , chkPlan "plan range" rngSrc rngDump ["PIndexScan", "IBRange"]
    , chkPlan "plan plain filter" neqSrc neqDump ["PSeqScan"]
    , chkSet "join INLJ rows" inlRes wantInl
    , chkSet "join NLJ rows" nljRes wantNlj
    , chkSet "join HashJoin rows" hjRes wantHj
    , chkPlan "plan INLJ" inlSrc inlDump ["PIndexNestedLoop"]
    , chkPlan "plan NLJ" nljSrc nljDump ["PNestedLoop"]
    , chkPlan "plan HashJoin" hjSrc hjDump ["PHashJoin"]
    , chkSet "inlj keeps inner scan bounds" inlBndRes
        [ [txt cn, txt cn] | (cn, _) <- cityFixture, cn >= pack "p3" ]
    , chkPlan "plan inlj bound residual" inlBndSrc inlBndDump
        ["PIndexNestedLoop"]
    , chkSet "hashjoin catalog-rows threshold" hjThRes
        [[txt (pack "v7"), txt (pack "v7")]]
    , chkPlan "plan hashjoin chosen by reltuples" hjThSrc hjThDump
        ["PHashJoin"]
    , chkRows "agg count" cntAll wantCnt
    , chkRows "agg sum" sumAll wantSum
    , chkRows "agg avg" avgAll wantAvg
    , chkRows "agg min/max" minMax wantMinMax
    , chkRows "agg count empty" cntEmpty wantCntEmpty
    , chkErr "agg sum empty is 21000" "21000" sumEmpty
    , chkSet "group by counts" grpRes wantGrp
    , chkRows "group src order" grpSrc wantGrpSrc
    , chkRows "order by asc stable" ordAsc wantAsc
    , chkRows "order by desc stable" ordDesc wantDesc
    , chkSet "subquery IN" inRes wantIn
    , chkSet "subquery NOT IN" notRes wantNot
    , chkSet "subquery EXISTS" exRes wantAllCity
    , chkRowCount "subquery NOT EXISTS" noExRes 0
    , chkSet "scalar subquery" scRes wantSc
    , chkErr "scalar subquery >1 row" "21000" scBadRes
    , chkSet "derived table" derRes wantDer
    , chkPlan "plan derived materialises" derSrc derDump ["PMaterialize"]
    , chkTag "update count" updRes "UPDATE" 1
    , chkTag "delete count" delRes "DELETE" 1
    , chkSet "index probe after update" probeUpd [[txt (pack "p3")]]
    , chkSet "old key probe after update" probeOld wantProbeOld
    , chkRows "count after dml" cntAfter wantAfter
    , chkErr "update tuple too large" "54000" updHuge
    , chkRows "heap unchanged after rollback" afterHuge
        [ [txt t] | t <- bigFixture ]
    , chkErr "insert partial column list" "0A000" pPartial
    , chkErr "insert arity" "4280" pArity
    , chkErr "varchar too long" "22001" pLong
    , chkErr "undefined table" "42P01" pNoTbl
    , chkErr "undefined column" "42703" pNoCol
    , chkErr "ambiguous column" "42702" pAmbig
    , chkErr "int64 overflow in sum" "22003" pOvf
    , chkErr "memory budget sort" "54000" pMem
    , chkErr "grouping violation" "42803" pGroup
    , chkErr "order by ordinal range" "42703" pOrd
    ] ++ forcedErrs)

main :: IO ()
main = do
  exists <- doesDirectoryExist testDir
  when exists (removeDirectoryRecursive testDir)
  cache <- newCatalogCache
  env <- createDatabase cfg cache
  ctl <- readTVarIO (envControl env)
  tm <- newTxnManager (cfNextTid ctl)
  lm <- newLockManager
  errs <- scenario env tm lm cache
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  mapM_ putStrLn errs
  if null errs
    then putStrLn "exec-tests: all checks passed"
    else exitFailure

