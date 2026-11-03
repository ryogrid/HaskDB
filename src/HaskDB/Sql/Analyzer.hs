-- | Analyzer: raw AST + CatalogCache -> RESOLVED AST (internal-design/07
--   §7.4/§7.5; clause rules design/05 §5.5-§5.7).  All resolution in IO
--   with SqlError throws (docs' analyze signature is IO).  Correlation
--   ban: subqueries get a FRESH scope; outerNames (names only) upgrades
--   a miss to the SPECIFIC 0A000 (§7.4 note).  Deviations recorded in
--   TODO.md: RSelect carries rsOutNames (needed for ORDER BY/derived
--   tables; §7.4 RSelectItem has no alias slot), and subquery column-
--   cardinality errors use 21000 per the §7.4 inline decision.
{-# LANGUAGE LambdaCase, TupleSections #-}
module HaskDB.Sql.Analyzer where

import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.ByteString as BS
import Data.Maybe (fromMaybe, isJust)
import Control.Monad (when, forM_, zipWithM)
import HaskDB.Common.Error
    (SqlError(..), throwSql, errUndefinedTable, errUndefinedColumn,
     errAmbiguous, errDupName, errDupColumn, errStringTooLong,
     errScalarSubqRows)
import HaskDB.Catalog.Cache (CatalogCache, lookupByName)
import HaskDB.Catalog.Types (RelKind(RelTable), RelationDesc(rdId, rdName, rdKind, rdColumns))
import HaskDB.Heap.TupleCodec (ColumnDesc(..))
import HaskDB.Common.Types (SqlType(..), Value(VInt, VFloat, VText, VBool), RelId)
import HaskDB.Sql.Ast

-- ---------------- resolved types (§7.4) ----------------
data RColRef = RColRef { rcFrom :: !Int, rcCol :: !Int, rcType :: !SqlType }
  deriving (Eq, Show)

data FromSlot = FromSlot
  { fsRelId   :: Maybe RelId
  , fsName    :: !Text
  , fsColumns :: [ColumnDesc]
  , fsSubplan :: Maybe RSelect
  } deriving (Show)

data RSelect = RSelect
  { rsFrom     :: [FromSlot]
  , rsWhere    :: Maybe RPred
  , rsItems    :: [RSelectItem]
  , rsGroupBy  :: [RColRef]
  , rsOrderBy  :: [(Int, Bool)]
  , rsIsAgg    :: Bool
  , rsOutNames :: [Text]
  } deriving (Show)

data RSelectItem
  = RIColumn RColRef
  | RILiteral Value
  | RIAgg AggFn (Maybe RColRef)
  deriving (Eq, Show)

data RPred
  = RPAnd RPred RPred | RPOr RPred RPred | RPNot RPred
  | RPCmp ROperand CmpOp ROperand
  | RPExists RSelect
  | RPIn RColRef Bool RSelect
  deriving (Show)

data ROperand = ROCol RColRef | ROLit Value | ROScalar RSelect
  deriving (Show)

data RAssign = RAssignLit Value | RAssignCol RColRef deriving (Show)

data Analyzed
  = ASelect RSelect
  | AInsert RelId [Int] [[Value]]
  | AUpdate RelId [(Int, RAssign)] (Maybe RPred)
  | ADelete RelId (Maybe RPred)
  | ACreateTable CreateTableStmt
  | ACreateIndex CreateIndexStmt
  | ATxnControl Statement
  deriving (Show)

-- ---------------- errors ----------------
errCorrelated :: Text -> SqlError
errCorrelated nm =
  SqlError "0A000" ("correlated subqueries are not supported: column `"
     <> nm <> "` refers to an outer query")
-- internal/00 §0.4: reuse the shared SQLSTATE constructors; the analyzer only
--   adds the richer messages the shared set has no constructor for.
errNoRel :: Text -> SqlError
errNoRel = errUndefinedTable
errNoCol :: Text -> SqlError
errNoCol = errUndefinedColumn
errAmbig :: Text -> SqlError
errAmbig = errAmbiguous
errNotGrp :: Text -> SqlError
errNotGrp nm = SqlError "42803"
  ("column `" <> nm <> "` in an aggregate query must be a GROUP BY grouping column")
errBadOrder :: Text -> SqlError
errBadOrder nm = SqlError "42703"
  ("ORDER BY term does not match an output column: " <> nm)
errDupCol :: Text -> SqlError
errDupCol = errDupColumn
errNameTaken :: Text -> SqlError
errNameTaken = errDupName
errSubColCount :: SqlError
errSubColCount = errScalarSubqRows
  "subquery must return exactly one column"
errAggType :: Text -> SqlType -> SqlError
errAggType nm t = SqlError "42804"
  ("column `" <> nm <> "` has unsupported type " <> T.pack (show t)
   <> " for this aggregate")
errLitType :: SqlType -> SqlError
errLitType ty = SqlError "42804"
  ("literal type does not match column type " <> T.pack (show ty))
-- first duplicate in a list (CREATE TABLE column names, 42701)
firstDup :: Eq a => [a] -> Maybe a
firstDup (x : xs) = if x `elem` xs then Just x else firstDup xs
firstDup []       = Nothing

litType :: Value -> SqlType
litType (VInt _)   = TyInt64
litType (VFloat _) = TyFloat64
litType (VText _)  = TyVarchar
litType (VBool _)  = TyBool

itemOutType :: RSelectItem -> SqlType
itemOutType it = case it of
  RIColumn c        -> rcType c
  RILiteral v       -> litType v
  RIAgg f arg       -> aggResultType f arg

aggResultType :: AggFn -> Maybe RColRef -> SqlType
aggResultType AggCount _        = TyInt64
aggResultType AggAvg _          = TyFloat64
aggResultType AggMin (Just c)   = rcType c
aggResultType AggMin Nothing    = TyInt64
aggResultType AggMax (Just c)   = rcType c
aggResultType AggMax Nothing    = TyInt64
aggResultType AggSum (Just c)   = rcType c
aggResultType AggSum Nothing    = TyInt64

-- ---------------- name resolution ----------------
resolveCol :: [Text] -> [FromSlot] -> ColRef -> Either SqlError RColRef
resolveCol outer slots (ColRef mq nm) = case matches of
  [(i, j, col)] -> Right (RColRef i j (colType col))
  [] | nm `elem` outer  -> Left (errCorrelated nm)
     | Just q <- mq
     , not (any (\sl -> fsName sl == q) slots) -> Left (errNoRel q)
     | otherwise       -> Left (errNoCol nm)
  _             -> Left (errAmbig nm)
  where
    matches = [ (i, j, col)
              | (i, sl) <- zip [0 ..] slots
              , maybe True (\q -> fsName sl == q) mq
              , (j, col) <- zip [0 ..] (fsColumns sl)
              , colName col == nm ]

-- | Names visible in a FROM scope: slot names plus their column names
--   (§7.4 step 1/2: these are what an enclosed subquery would see, i.e. the
--   correlation-ban "outerNames" set).
scopeNames :: [FromSlot] -> [Text]
scopeNames sls = [ n | sl <- sls, n <- fsName sl : map colName (fsColumns sl) ]

-- | Coerce a literal into a target column type (§5.3: int->float only;
--   VARCHAR byte-length check per §7.1 last rule).
coerceLit :: SqlType -> Value -> IO Value
coerceLit ty v = case coerceLitE ty v of
  Left e  -> throwSqlOf e
  Right v' -> pure v'

coerceLitE :: SqlType -> Value -> Either SqlError Value
coerceLitE ty v = case v of
  VText s
    | ty == TyVarchar
    , BS.length s > 1024 -> Left errStringTooLong
  VInt n | ty == TyFloat64 -> Right (VFloat (fromIntegral n))
  _ | ty == litType v -> Right v
    | otherwise -> Left (errLitType ty)

throwSqlOf :: SqlError -> IO a
throwSqlOf (SqlError st msg) = throwSql st msg

-- ---------------- FROM slots (IO: catalog lookups) ----------------
buildSlots :: [Text] -> CatalogCache -> [FromItem] -> IO ([FromSlot], [Text])
buildSlots outer cache items = do
  sls <- mapM (slotOf cache outer) items
  pure (sls, outer ++ scopeNames sls)
  where
    slotOf c outerNs it = case it of
      FromTable nm mal -> do
        mrd <- lookupByName c nm
        case mrd of
          Nothing -> throwSqlOf (errNoRel nm)
          Just d
            | rdKind d /= RelTable -> throwSqlOf (errNoRel nm)
            | otherwise -> pure FromSlot
                { fsRelId = Just (rdId d), fsName = fromMaybe nm mal
                , fsColumns = rdColumns d, fsSubplan = Nothing }
      FromSubquery sub al -> do
        (ASelect rs) <- analyzeSelect outerNs c sub
        pure FromSlot { fsRelId = Nothing, fsName = al
                      , fsColumns = [ ColumnDesc n t
                                    | (n, t) <- zip (rsOutNames rs)
                                        (map itemOutType (rsItems rs)) ]
                      , fsSubplan = Just rs }

-- | Resolve one raw select item to one resolved item (SelStar expands to
--   all columns of all slots — the planner/executor treat it as a
--   projection list; internal/08 consumes rsItems uniformly).
resolveItem :: [FromSlot] -> [Text] -> SelectItem
            -> IO [(RSelectItem, Maybe Text)]
resolveItem slots outer it = case it of
  SelStar -> pure [ (RIColumn (RColRef i j (colType col)), Nothing)
                  | (i, sl) <- zip [0 ..] slots
                  , (j, col) <- zip [0 ..] (fsColumns sl) ]
  SelColumn cr al -> (: []) <$> ((,) <$> (RIColumn <$> resColE slots outer cr)
                                     <*> pure al)
  SelLiteral v al -> pure [(RILiteral v, al)]
  SelAgg (AggCall f arg) al -> do
    ma <- case arg of
            AggStar -> pure Nothing
            AggCol cr -> Just <$> resColE slots outer cr
    pure [(RIAgg f ma, al)]

-- Either-style resolvers (IO-throws wrappers)
resColE :: [FromSlot] -> [Text] -> ColRef -> IO RColRef
resColE slots outer cr = case resolveCol outer slots cr of
  Left e  -> throwSqlOf e
  Right r -> pure r

-- | Resolve a predicate tree.  `cache` threaded for subqueries; their
--   scopes are FRESH (correlation ban: outerNames only upgrades the
--   error to 0A000).
-- `outer` = names of ENCLOSING queries (only to upgrade a resolution miss to
--   the specific 0A000); `outerSub` = enclosing + this query's names, inherited
--   by the subqueries, so a correlated reference inside one is reported 0A000.
resolvePred :: CatalogCache -> [FromSlot] -> [Text] -> [Text] -> Pred -> IO RPred
resolvePred cache slots outer outerSub p = case p of
  PAnd a b -> RPAnd <$> resolvePred cache slots outer outerSub a
                    <*> resolvePred cache slots outer outerSub b
  POr a b  -> RPOr <$> resolvePred cache slots outer outerSub a
                   <*> resolvePred cache slots outer outerSub b
  PNot a   -> RPNot <$> resolvePred cache slots outer outerSub a
  PCmp o1 op o2 -> do
    r1 <- resolveOperand cache slots outer outerSub o1
    r2 <- resolveOperand cache slots outer outerSub o2
    (r1', r2') <- cmpOperands r1 op r2
    pure (RPCmp r1' op r2')
  PExists sub -> do
    ASelect rs <- analyzeSelect outerSub cache sub
    pure (RPExists rs)
  PIn cr neg sub -> do
    rc <- resColE slots outer cr
    ASelect rs <- analyzeSelect outerSub cache sub
    case itemOutTypes rs of
      [t] | t == rcType rc -> pure ()
          | otherwise -> throwSqlOf (SqlError "42804"
              "IN subquery column type does not match the left operand")
      _ -> throwSqlOf errSubColCount
    pure (RPIn rc neg rs)

resolveOperand :: CatalogCache -> [FromSlot] -> [Text] -> [Text] -> Operand
               -> IO ROperand
resolveOperand cache slots outer outerSub o = case o of
  OCol cr  -> ROCol <$> resColE slots outer cr
  OLit v   -> pure (ROLit v)
  OScalarSubquery sub -> do
    ASelect rs <- analyzeSelect outerSub cache sub
    case itemOutTypes rs of
      [_] -> pure (ROScalar rs)
      _   -> throwSqlOf errSubColCount

itemOutTypes :: RSelect -> [SqlType]
itemOutTypes rs = map itemOutType (rsItems rs)

-- §7.4 step 3 / §5.3: same-type rule; the ONLY promotion is an INT64
--   LITERAL against a FLOAT64 side, rewritten to VFloat at analysis time.
cmpOperands :: ROperand -> CmpOp -> ROperand -> IO (ROperand, ROperand)
cmpOperands r1 op r2 = case (t1, t2) of
  (TyBool, TyBool)
    | op `notElem` [OpEq, OpNe] ->
        throwSqlOf (SqlError "42804"
          "ordering comparisons are not defined on BOOLEAN")
    | otherwise -> pure (r1, r2)
  (TyFloat64, TyInt64)
    | isIntLit r2 -> pure (r1, promoteInt r2)
    | otherwise   -> mismatch
  (TyInt64, TyFloat64)
    | isIntLit r1 -> pure (promoteInt r1, r2)
    | otherwise   -> mismatch
  (a, b)
    | a == b -> pure (r1, r2)
    | otherwise -> mismatch
  where
    t1 = operandType r1
    t2 = operandType r2
    isIntLit (ROLit (VInt _)) = True
    isIntLit _ = False
    promoteInt (ROLit (VInt n)) = ROLit (VFloat (fromIntegral n))
    promoteInt o = o
    mismatch = throwSqlOf (SqlError "42804"
      ("comparison operand types differ: " <> T.pack (show t1)
       <> " vs " <> T.pack (show t2)))

operandType :: ROperand -> SqlType
operandType (ROCol c) = rcType c
operandType (ROLit v) = litType v
operandType (ROScalar rs) = case itemOutTypes rs of
  (t : _) -> t
  []      -> TyInt64

-- | Resolve the SELECT statement (docs §7.4 algorithm, steps 1-6).
analyzeSelect :: [Text] -> CatalogCache -> SelectStmt -> IO Analyzed
analyzeSelect outer cache sel = do
  (slots, outer2) <- buildSlots outer cache (selFrom sel)
  wp <- case selWhere sel of
          Nothing -> pure Nothing
          Just p  -> Just <$> resolvePred cache slots outer outer2 p
  pairs <- concat <$> mapM (resolveItem slots outer) (selList sel)
  let items = map fst pairs
  gb <- mapM (resColE slots outer) (selGroupBy sel)
  let isAgg = not (null gb) || any isAggIt items
  when isAgg $ forM_ items $ \case
    RIColumn c | c `notElem` gb ->
      throwSqlOf (errNotGrp (outNameOfCol slots c))
    _ -> pure ()
  forM_ items $ \case
    RIAgg f (Just c) -> checkAggArg slots f c
    _ -> pure ()
  let outn = map (named slots) pairs
  obs <- mapM (orderIdx slots outn items) (selOrderBy sel)
  pure (ASelect RSelect { rsFrom = slots, rsWhere = wp, rsItems = items
                        , rsGroupBy = gb, rsOrderBy = obs, rsIsAgg = isAgg
                        , rsOutNames = outn })
  where
    -- §7.4 step 6: alias | column name | ?column?
    named sls (RIColumn (RColRef i j _), Nothing) =
      colName (fsColumns (sls !! i) !! j)
    named _ (_, Just al) = al
    named _ (_, Nothing) = "?column?"

-- ---------------- INSERT (§7.5: table, target ordinals, rows) ----------
analyzeInsert :: CatalogCache -> InsertStmt -> IO Analyzed
analyzeInsert cache (InsertStmt nm mcols rows) = do
  mrd <- lookupByName cache nm
  case mrd of
    Nothing -> throwSqlOf (errNoRel nm)
    Just d
      | rdKind d /= RelTable -> throwSqlOf (errNoRel nm)
      | otherwise -> do
          let cols = rdColumns d
          ords <- case mcols of
                    Nothing -> pure [0 .. length cols - 1]
                    Just ns -> mapM (\n -> case [ j | (j, c) <- zip [0 ..] cols
                                                  , colName c == n ] of
                                        (j : _) -> pure j
                                        []      -> throwSqlOf (errNoCol n)) ns
          let arity = length ords
          when (any (\r -> length r /= arity) rows) $
            throwSqlOf (SqlError "4280" "INSERT value arity does not match column count")
          rows' <- mapM (zipWithM coerceLit [ colType (cols !! j) | j <- ords ]) rows
          pure (AInsert (rdId d) ords rows')

-- ---------------- UPDATE / DELETE: one-slot scope (§7.5) ---------------
analyzeUpdate :: CatalogCache -> UpdateStmt -> IO Analyzed
analyzeUpdate cache (UpdateStmt nm asgn mwp) = do
  mrd <- lookupByName cache nm
  case mrd of
    Nothing -> throwSqlOf (errNoRel nm)
    Just d
      | rdKind d /= RelTable -> throwSqlOf (errNoRel nm)
      | otherwise -> do
          let cols = rdColumns d
              slots = [ FromSlot { fsRelId = Just (rdId d), fsName = rdName d
                                 , fsColumns = cols, fsSubplan = Nothing } ]
          as' <- mapM (assign slots cols) asgn
          wp <- maybe (pure Nothing)
                        (\p -> Just <$> resolvePred cache slots [] (scopeNames slots) p) mwp
          pure (AUpdate (rdId d) as' wp)

analyzeDelete :: CatalogCache -> DeleteStmt -> IO Analyzed
analyzeDelete cache (DeleteStmt nm mwp) = do
  mrd <- lookupByName cache nm
  case mrd of
    Nothing -> throwSqlOf (errNoRel nm)
    Just d
      | rdKind d /= RelTable -> throwSqlOf (errNoRel nm)
      | otherwise -> do
          let slots = [ FromSlot { fsRelId = Just (rdId d), fsName = rdName d
                                 , fsColumns = rdColumns d, fsSubplan = Nothing } ]
          wp <- maybe (pure Nothing)
                        (\p -> Just <$> resolvePred cache slots [] (scopeNames slots) p) mwp
          pure (ADelete (rdId d) wp)

assign :: [FromSlot] -> [ColumnDesc] -> (Text, AssignRhs) -> IO (Int, RAssign)
assign slots cols (nm, rhs) = do
  j <- case [ k | (k, c) <- zip [0 ..] cols, colName c == nm ] of
         (k : _) -> pure k
         []      -> throwSqlOf (errNoCol nm)
  let ty = colType (cols !! j)
  ra <- case rhs of
          AssignLit v -> RAssignLit <$> coerceLit ty v
          AssignCol cr -> do
            rc <- resColE slots [] cr
            if rcType rc /= ty
              then throwSqlOf (SqlError "42804"
                "assignment RHS type does not match target column")
              else pure (RAssignCol rc)
  pure (j, ra)

-- ---------------- DDL (§7.5: re-checks; executor checks again under X) --
analyzeCreateTable :: CatalogCache -> CreateTableStmt -> IO Analyzed
analyzeCreateTable cache (CreateTableStmt nm cols) = do
  taken <- lookupByName cache nm
  when (isJust taken) $ throwSqlOf (errNameTaken nm)
  when (null cols) $ throwSqlOf (SqlError "42600" "CREATE TABLE needs at least one column")
  let names = map fst cols
  case firstDup names of
    Just dn   -> throwSqlOf (errDupCol dn)
    Nothing   -> pure ()
  pure (ACreateTable (CreateTableStmt nm cols))

analyzeCreateIndex :: CatalogCache -> CreateIndexStmt -> IO Analyzed
analyzeCreateIndex cache (CreateIndexStmt nm tbl col) = do
  taken <- lookupByName cache nm
  when (isJust taken) $ throwSqlOf (errNameTaken nm)
  mrd <- lookupByName cache tbl
  case mrd of
    Nothing -> throwSqlOf (errNoRel tbl)
    Just d -> do
      when (rdKind d /= RelTable) $ throwSqlOf (errNoRel tbl)
      case [ c | c <- rdColumns d, colName c == col ] of
        (_ : _) -> pure (ACreateIndex (CreateIndexStmt nm tbl col))
        []      -> throwSqlOf (errNoCol col)

-- ---------------- entry ----------------
analyze :: CatalogCache -> Statement -> IO Analyzed
analyze cache st = case st of
  StmtSelect s      -> analyzeSelect [] cache s
  StmtInsert s      -> analyzeInsert cache s
  StmtUpdate s      -> analyzeUpdate cache s
  StmtDelete s      -> analyzeDelete cache s
  StmtCreateTable s -> analyzeCreateTable cache s
  StmtCreateIndex s -> analyzeCreateIndex cache s
  _                 -> pure (ATxnControl st)

-- ---------------- helpers shared by analyzeSelect ----------------
isAggIt :: RSelectItem -> Bool
isAggIt (RIAgg _ _) = True
isAggIt _ = False

-- §7.4 step 6 name for error messages: the column's declared name.
outNameOfCol :: [FromSlot] -> RColRef -> Text
outNameOfCol sls c = colName (fsColumns (sls !! rcFrom c) !! rcCol c)

-- §5.7: SUM/AVG need a numeric argument.
checkAggArg :: [FromSlot] -> AggFn -> RColRef -> IO ()
checkAggArg sls f c
  | (f == AggSum || f == AggAvg)
  , rcType c `notElem` [TyInt64, TyFloat64]
  = throwSqlOf (errAggType (outNameOfCol sls c) (rcType c))
checkAggArg _ _ _ = pure ()

-- ORDER BY key -> output-column index (design/05 §5.9 + §7.4 step 5): ordinal
--   | output name | qualified col_ref matching an OUTPUT column.
orderIdx :: [FromSlot] -> [Text] -> [RSelectItem] -> OrderItem -> IO (Int, Bool)
orderIdx slots outn its (OrderItem key asc) = case key of
  OKOrdinal n
    | n >= 1 && n <= length outn -> pure (n - 1, asc)
    | otherwise -> throwSqlOf (SqlError "42703"
        ("ORDER BY ordinal out of range: " <> T.pack (show n)))
  OKName nm -> case [ i | (i, o) <- zip [0 ..] outn, o == nm ] of
    (i : _) -> pure (i, asc)
    []      -> throwSqlOf (errBadOrder nm)
  OKCol cr -> case resolveCol [] slots cr of
    Left _   -> throwSqlOf (errBadOrder (crName cr))
    Right rc -> case [ i | (i, it) <- zip [0 ..] its, it == RIColumn rc ] of
      (i : _) -> pure (i, asc)
      []      -> throwSqlOf (errBadOrder (crName cr))























