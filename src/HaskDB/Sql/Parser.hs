-- | Recursive-descent SQL parser (internal-design/07 §7.3; grammar design/05
--   §5.2 is normative — one function per production, names mirror it).
--   Unsupported-construct blocklist yields SPECIFIC feature errors
--   (§7.3 nicety).  Deviation recorded in TODO.md: parser functions are
--   plain `Either SqlError (a, [Tok])` calls (§7.3's Parser newtype with
--   Functor/Applicative/Monad instances adds nothing for a hand-written
--   descent; combinator NAMES from §7.3 are kept: kw/sym/optional/sepBy1).
module HaskDB.Sql.Parser where

import Data.Text (Text, singleton)
import qualified Data.ByteString as BS
import HaskDB.Common.Error (SqlError, errSyntax, errFeatureNotSupported)
import HaskDB.Sql.Lexer (Token(..), Tok(..), lexSql)
import HaskDB.Sql.Ast
import HaskDB.Common.Types (Value(VInt, VFloat, VText, VBool), SqlType(TyInt64, TyFloat64, TyVarchar, TyBool))

-- | Parse exactly ONE statement; one optional trailing ';', then EOF
--   (the wire layer splits multi-statement strings — design/09 §9.4).
parseStatement :: BS.ByteString -> Either SqlError Statement
parseStatement input = do
  toks <- lexSql input
  (st, rest) <- pStatement toks
  rest' <- case rest of
             (Tok _ (TSymbol ';') : ts) -> Right ts
             ts                        -> Right ts
  case rest' of
    [Tok _ TEOF] -> Right st
    (Tok _ (TIdent k) : _) | k `elem` unsupportedWords -> featureErr k
    _ -> Left (errSyntax "trailing input after statement")

-- ---------------- token helpers ----------------
peekT :: [Tok] -> Token
peekT (t : _) = tokVal t
peekT []      = TEOF

-- kw: keyword production (§7.3)
eatK :: Text -> [Tok] -> Either SqlError [Tok]
eatK k ts
  | isKwT k (peekT ts) = Right (drop1 ts)
  | otherwise = Left (errSyntax ("expected keyword `" <> k <> "`"))

-- sym: symbol production (§7.3)
eatSym :: Char -> [Tok] -> Either SqlError [Tok]
eatSym c ts
  | peekT ts == TSymbol c = Right (drop1 ts)
  | otherwise = Left (errSyntax ("expected `" <> singleton c <> "`"))

isKwT :: Text -> Token -> Bool
isKwT k (TIdent t) = t == k
isKwT _ _          = False

drop1 :: [a] -> [a]
drop1 (_ : ts) = ts
drop1 []       = []

optionalK :: Text -> [Tok] -> Either SqlError [Tok]
optionalK k ts
  | isKwT k (peekT ts) = Right (drop1 ts)
  | otherwise          = Right ts

-- | Reserved words (design/05 §5.11): grammar keywords + session cmds.
--   Using one as an identifier is a syntax error.
reservedWords :: [Text]
reservedWords =
  [ "select","from","where","group","by","order","as","on","insert","into"
  , "values","update","set","delete","create","table","index","asc","desc"
  , "and","or","not","exists","in","is","true","false"
  , "int64","float64","varchar","boolean","bigint","int8","double","precision","bool"
  , "count","sum","avg","min","max","begin","commit","rollback" ]

-- §7.3 nicety: FULL-SQL keywords that are not in this dialect.  Checked at
--   the points where they would legally appear in full SQL (statement
--   start, clause boundaries, operands, FROM items) -> errFeatureNotSupported
--   naming the construct, instead of a generic parse error.
unsupportedWords :: [Text]
unsupportedWords =
  [ "join","left","right","cross","outer","inner","having","limit","offset"
  , "null","is","alter","drop","union","distinct","fetch","returning","case" ]

-- | Blocklisted word at an identifier-head position: reserved words win
--   (§5.11 syntax error via pIdent), only non-reserved words get 0A000.
headUnsupported :: Text -> Bool
headUnsupported n = n `elem` unsupportedWords && n `notElem` reservedWords

-- | First token when it is a blocklisted keyword (clause-boundary check).
peekUnsupported :: [Tok] -> Maybe Text
peekUnsupported ts = case ts of
  (Tok _ (TIdent k) : _) | k `elem` unsupportedWords -> Just k
  _                                                 -> Nothing

-- | Specific "not supported" error naming the construct (§7.3).
featureErr :: Text -> Either SqlError a
featureErr k = Left (errFeatureNotSupported
  ("the `" <> k <> "` construct is not supported by this dialect"))

-- ident: identifier production; rejects reserved + unsupported words.
pIdent :: [Tok] -> Either SqlError (Text, [Tok])
pIdent ts = case peekT ts of
  TIdent t
    | t `elem` reservedWords -> Left (errSyntax ("reserved word used as identifier: " <> t))
    | otherwise -> Right (t, drop1 ts)
  _ -> Left (errSyntax "expected an identifier")

-- sepBy1 (§7.3 combinator name)
sepBy1 :: ([Tok] -> Either SqlError (a, [Tok])) -> Char -> [Tok]
       -> Either SqlError ([a], [Tok])
sepBy1 itemP sep toks0 = itemP toks0 >>= \(x, ts1) -> loop [x] ts1
  where
    loop acc toks = case toks of
      (Tok _ (TSymbol c) : rest) | c == sep ->
          itemP rest >>= (\(y, ts2) -> loop (y : acc) ts2)
      _ -> Right (reverse acc, toks)

pStatement :: [Tok] -> Either SqlError (Statement, [Tok])
pStatement ts = case peekT ts of
  TIdent "select" -> pSelectStmt ts >>= \(s, r) -> Right (StmtSelect s, r)
  TIdent "insert" -> pInsertStmt ts >>= \(s, r) -> Right (StmtInsert s, r)
  TIdent "update" -> pUpdateStmt ts >>= \(s, r) -> Right (StmtUpdate s, r)
  TIdent "delete" -> pDeleteStmt ts >>= \(s, r) -> Right (StmtDelete s, r)
  TIdent "create" -> case drop1 ts of
    ts2 -> case peekT ts2 of
      TIdent "table" -> pCreateTable ts2 >>= \(s, r) -> Right (StmtCreateTable s, r)
      TIdent "index" -> pCreateIndex ts2 >>= \(s, r) -> Right (StmtCreateIndex s, r)
      _              -> Left (errSyntax "expected TABLE or INDEX after CREATE")
  TIdent "begin"     -> Right (StmtBegin, drop1 ts)
  TIdent "commit"    -> Right (StmtCommit, drop1 ts)
  TIdent "rollback"  -> Right (StmtRollback, drop1 ts)
  TIdent k
    | k `elem` unsupportedWords -> featureErr k
  _ -> Left (errSyntax "expected a statement")

-- ---------------- select_stmt ----------------
pSelectStmt :: [Tok] -> Either SqlError (SelectStmt, [Tok])
pSelectStmt ts = do
  ts1 <- eatK "select" ts
  (items, ts2) <- pSelectList ts1
  ts3 <- eatK "from" ts2
  (fs, ts4) <- pFromList ts3
  (mw, ts5) <- pOptWhere ts4
  (gs, ts6) <- pOptGroupBy ts5
  (os, ts7) <- pOptOrderBy ts6
  Right (SelectStmt items fs mw gs os, ts7)

pSelectList :: [Tok] -> Either SqlError ([SelectItem], [Tok])
pSelectList ts
  | peekT ts == TSymbol '*' = Right ([SelStar], drop1 ts)
  | otherwise = sepBy1 pSelectItem ',' ts

pSelectItem :: [Tok] -> Either SqlError (SelectItem, [Tok])
pSelectItem ts = case peekT ts of
  TIdent "count" -> do
    (a, ts1) <- pAggCall ts
    (al, ts2) <- pOptAlias ts1
    Right (SelAgg a al, ts2)
  TIdent f | f `elem` ["sum","avg","min","max"] -> do
    (a, ts1) <- pAggCall ts
    (al, ts2) <- pOptAlias ts1
    Right (SelAgg a al, ts2)
  TIdent "true"  -> litWithAlias ts (VBool True)
  TIdent "false" -> litWithAlias ts (VBool False)
  TInt n   -> litWithAlias ts (VInt n)
  TFloat n -> litWithAlias ts (VFloat n)
  TString s  -> litWithAlias ts (VText s)
  TIdent n
    | headUnsupported n -> featureErr n
    | otherwise -> do
        (cr, ts1) <- pColRef ts
        (al, ts2) <- pOptAlias ts1
        Right (SelColumn cr al, ts2)
  _ -> Left (errSyntax "expected a select item")
  where
    litWithAlias t v = do
      (al, ts1) <- pOptAlias (drop1 t)
      Right (SelLiteral v al, ts1)

pAggCall :: [Tok] -> Either SqlError (AggCall, [Tok])
pAggCall ts = case peekT ts of
  TIdent f
    | f `elem` ["count","sum","avg","min","max"] -> do
        ts1 <- eatSym '(' (drop1 ts)
        case peekT ts1 of
          TSymbol '*'
            | f == "count" -> do
                ts2 <- eatSym ')' (drop1 ts1)
                Right (AggCall (aggFnOf f) AggStar, ts2)
            | otherwise -> Left (errSyntax "`*` is only legal as COUNT argument")
          _ -> do
            (cr, ts2) <- pColRef ts1
            ts3 <- eatSym ')' ts2
            Right (AggCall (aggFnOf f) (AggCol cr), ts3)
  _ -> Left (errSyntax "expected an aggregate call")
  where
    aggFnOf t | t == "count" = AggCount
              | t == "sum"   = AggSum
              | t == "avg"   = AggAvg
              | t == "min"   = AggMin
              | otherwise    = AggMax

pColRef :: [Tok] -> Either SqlError (ColRef, [Tok])
pColRef ts = do
  (n, ts1) <- pIdent ts
  colRefFrom n ts1

colRefFrom :: Text -> [Tok] -> Either SqlError (ColRef, [Tok])
colRefFrom n ts = case ts of
  (Tok _ (TSymbol '.') : ts2) -> do
    (n2, ts3) <- pIdent ts2
    Right (ColRef (Just n) n2, ts3)
  _ -> Right (ColRef Nothing n, ts)

pOptAlias :: [Tok] -> Either SqlError (Maybe Text, [Tok])
pOptAlias ts = case peekT ts of
  TIdent "as" -> do
    (n, ts1) <- pIdent (drop1 ts)
    Right (Just n, ts1)
  -- bare alias: any identifier that is not a reserved word and not one of
  --   the blocklisted full-SQL keywords (those are caught at the clause
  --   boundary by the caller, so we leave the token unconsumed here)
  TIdent n | aliasOk n -> Right (Just n, drop1 ts)
  _ -> Right (Nothing, ts)
  where aliasOk n = n `notElem` reservedWords && n `notElem` unsupportedWords

-- ---------------- from_list ----------------
pFromList :: [Tok] -> Either SqlError ([FromItem], [Tok])
pFromList = sepBy1 pFromItem ','

pFromItem :: [Tok] -> Either SqlError (FromItem, [Tok])
pFromItem ts = case peekT ts of
  TSymbol '(' -> do   -- derived table: alias MANDATORY (§5.6)
    (sub, ts1) <- pSelectStmt (drop1 ts)
    ts2 <- eatSym ')' ts1
    ts3 <- optionalK "as" ts2
    case peekT ts3 of
      TIdent al
        | al `elem` unsupportedWords -> featureErr al
        | al `notElem` reservedWords -> Right (FromSubquery sub al, drop1 ts3)
      _ -> Left (errSyntax "derived table requires an alias (`as` name)")
  TIdent n
    | headUnsupported n -> featureErr n
    | n `notElem` reservedWords -> do
        (mal, ts1) <- pOptAlias (drop1 ts)
        Right (FromTable n mal, ts1)
  _ -> Left (errSyntax "expected a from item")

-- ---------------- clause optionals ----------------
pOptWhere :: [Tok] -> Either SqlError (Maybe Pred, [Tok])
pOptWhere ts
  | Just k <- peekUnsupported ts = featureErr k
  | isKwT "where" (peekT ts) = do
      (p, ts2) <- pPred (drop1 ts)
      Right (Just p, ts2)
  | otherwise = Right (Nothing, ts)

pOptGroupBy :: [Tok] -> Either SqlError ([ColRef], [Tok])
pOptGroupBy ts
  | Just k <- peekUnsupported ts = featureErr k
  | isKwT "group" (peekT ts) = do
      ts1 <- eatK "by" (drop1 ts)
      sepBy1 pColRef ',' ts1
  | otherwise = Right ([], ts)

pOptOrderBy :: [Tok] -> Either SqlError ([OrderItem], [Tok])
pOptOrderBy ts
  | Just k <- peekUnsupported ts = featureErr k
  | isKwT "order" (peekT ts) = do
      ts1 <- eatK "by" (drop1 ts)
      pOrderList ts1
  | otherwise = Right ([], ts)

pOrderItem :: [Tok] -> Either SqlError (OrderItem, [Tok])
pOrderItem ts = case peekT ts of
  TInt n
    | n >= 0 -> do
        (asc, ts1) <- pOptDir (drop1 ts)
        Right (OrderItem (OKOrdinal (fromIntegral n)) asc, ts1)
    | otherwise -> Left (errSyntax "ORDER BY ordinal is unsigned (§5.2)")
  TIdent n
    | n `notElem` reservedWords -> do
        (cr, ts1) <- pColRef ts
        let key = case crQualifier cr of
                    Nothing -> OKName (crName cr)   -- output name
                    Just _  -> OKCol cr             -- qualified col_ref
        (asc, ts2) <- pOptDir ts1
        Right (OrderItem key asc, ts2)
  _ -> Left (errSyntax "expected an ORDER BY key")

-- | order_list (§5.2).
pOrderList :: [Tok] -> Either SqlError ([OrderItem], [Tok])
pOrderList = sepBy1 pOrderItem ','

pOptDir :: [Tok] -> Either SqlError (Bool, [Tok])
pOptDir ts = case peekT ts of
  TIdent "asc"  -> Right (True, drop1 ts)
  TIdent "desc" -> Right (False, drop1 ts)
  _             -> Right (True, ts)

-- ---------------- predicate (operator chain per §5.2) ----------------
pPred :: [Tok] -> Either SqlError (Pred, [Tok])
pPred = pOrExpr

pOrExpr :: [Tok] -> Either SqlError (Pred, [Tok])
pOrExpr ts = pAndExpr ts >>= \(a, ts1) -> loop a ts1
  where
    loop acc toks
      | isKwT "or" (peekT toks) =
          pAndExpr (drop1 toks) >>= (\(b, ts2) -> loop (POr acc b) ts2)
      | otherwise = Right (acc, toks)

pAndExpr :: [Tok] -> Either SqlError (Pred, [Tok])
pAndExpr ts = pNotExpr ts >>= \(a, ts1) -> loop a ts1
  where
    loop acc toks
      | isKwT "and" (peekT toks) =
          pNotExpr (drop1 toks) >>= (\(b, ts2) -> loop (PAnd acc b) ts2)
      | otherwise = Right (acc, toks)

pNotExpr :: [Tok] -> Either SqlError (Pred, [Tok])
pNotExpr ts
  | isKwT "not" (peekT ts) = do
      (p, ts2) <- pPrimaryPred (drop1 ts)
      Right (PNot p, ts2)
  | otherwise = pPrimaryPred ts

pPrimaryPred :: [Tok] -> Either SqlError (Pred, [Tok])
pPrimaryPred ts = case peekT ts of
  TSymbol '('
    | peekT (drop1 ts) == TIdent "select" -> pCmpChain ts
    | otherwise -> do
        (p, ts1) <- pPred (drop1 ts)
        ts2 <- eatSym ')' ts1
        Right (p, ts2)
  TIdent "exists" -> do
    ts1 <- eatSym '(' (drop1 ts)
    (sub, ts2) <- pSelectStmt ts1
    ts3 <- eatSym ')' ts2
    Right (PExists sub, ts3)
  TIdent n
    | headUnsupported n -> featureErr n
    | n `notElem` reservedWords -> do
        (cr, ts1) <- pColRef ts
        pInTail cr ts1
  _ -> pCmpChain ts

pInTail :: ColRef -> [Tok] -> Either SqlError (Pred, [Tok])
pInTail cr ts
  | Just k <- peekUnsupported ts = featureErr k
  | otherwise = case peekT ts of
  TIdent "in" -> pInRhs cr False (drop1 ts)
  TIdent "not" -> do
    ts1 <- eatK "in" (drop1 ts)
    pInRhs cr True ts1
  _ -> do
    (op, ts1) <- pCmpOp ts
    (o2, ts2) <- pOperand ts1
    Right (PCmp (OCol cr) op o2, ts2)

-- | `operand comp_op operand` (§5.2 primary_pred); both operand positions
--   accept a scalar subquery (§5.5/§5.6), hence the dispatch above.
pCmpChain :: [Tok] -> Either SqlError (Pred, [Tok])
pCmpChain t = do
  (o1, t1) <- pOperand t
  (op, t2) <- pCmpOp t1
  (o2, t3) <- pOperand t2
  Right (PCmp o1 op o2, t3)

pInRhs :: ColRef -> Bool -> [Tok] -> Either SqlError (Pred, [Tok])
pInRhs cr neg ts = do
  ts1 <- eatSym '(' ts
  (sub, ts2) <- pSelectStmt ts1
  ts3 <- eatSym ')' ts2
  Right (PIn cr neg sub, ts3)

pOperand :: [Tok] -> Either SqlError (Operand, [Tok])
pOperand ts = case peekT ts of
  TSymbol '(' -> do
    (sub, ts1) <- pSelectStmt (drop1 ts)
    ts2 <- eatSym ')' ts1
    Right (OScalarSubquery sub, ts2)
  TIdent "true"  -> Right (OLit (VBool True), drop1 ts)
  TIdent "false" -> Right (OLit (VBool False), drop1 ts)
  TInt n   -> Right (OLit (VInt n), drop1 ts)
  TFloat n -> Right (OLit (VFloat n), drop1 ts)
  TString s  -> Right (OLit (VText s), drop1 ts)
  TIdent n
    | headUnsupported n -> featureErr n
    | n `notElem` reservedWords -> do
        (cr, ts1) <- pColRef ts
        Right (OCol cr, ts1)
  _ -> Left (errSyntax "expected an operand")

pCmpOp :: [Tok] -> Either SqlError (CmpOp, [Tok])
pCmpOp ts = case peekT ts of
  TSymbol '=' -> Right (OpEq, drop1 ts)
  TNe         -> Right (OpNe, drop1 ts)
  TSymbol '<' -> Right (OpLt, drop1 ts)
  TLe         -> Right (OpLe, drop1 ts)
  TSymbol '>' -> Right (OpGt, drop1 ts)
  TGe         -> Right (OpGe, drop1 ts)
  _ -> Left (errSyntax "expected a comparison operator")

-- ---------------- insert_stmt ----------------
pInsertStmt :: [Tok] -> Either SqlError (InsertStmt, [Tok])
pInsertStmt ts = do
  ts1 <- eatK "insert" ts
  ts2 <- eatK "into" ts1
  (nm, ts3) <- pIdent ts2
  (mcols, ts4) <- pOptColList ts3
  ts5 <- eatK "values" ts4
  (rows, ts6) <- sepBy1 pValRow ',' ts5
  Right (InsertStmt nm mcols rows, ts6)

pOptColList :: [Tok] -> Either SqlError (Maybe [Text], [Tok])
pOptColList ts = case peekT ts of
  TSymbol '(' -> do
    (ns, ts1) <- sepBy1 pIdent ',' (drop1 ts)
    ts2 <- eatSym ')' ts1
    Right (Just ns, ts2)
  _ -> Right (Nothing, ts)

pValRow :: [Tok] -> Either SqlError ([Value], [Tok])
pValRow ts = do
  ts1 <- eatSym '(' ts
  (vs, ts2) <- sepBy1 pLit ',' ts1
  ts3 <- eatSym ')' ts2
  Right (vs, ts3)

pLit :: [Tok] -> Either SqlError (Value, [Tok])
pLit ts = case peekT ts of
  TIdent "true"  -> Right (VBool True, drop1 ts)
  TIdent "false" -> Right (VBool False, drop1 ts)
  TInt n   -> Right (VInt n, drop1 ts)
  TFloat n -> Right (VFloat n, drop1 ts)
  TString s  -> Right (VText s, drop1 ts)
  TIdent n | headUnsupported n -> featureErr n
  _ -> Left (errSyntax "expected a literal")

-- ---------------- update_stmt ----------------
pUpdateStmt :: [Tok] -> Either SqlError (UpdateStmt, [Tok])
pUpdateStmt ts = do
  ts1 <- eatK "update" ts
  (nm, ts2) <- pIdent ts1
  ts3 <- eatK "set" ts2
  (asgn, ts4) <- sepBy1 pAssign ',' ts3
  (mw, ts5) <- pOptWhere ts4
  Right (UpdateStmt nm asgn mw, ts5)

pAssign :: [Tok] -> Either SqlError ((Text, AssignRhs), [Tok])
pAssign ts = do
  (n, ts1) <- pIdent ts
  ts2 <- eatSym '=' ts1
  case peekT ts2 of
    TIdent n2
      | headUnsupported n2 -> featureErr n2
      | n2 `notElem` reservedWords -> do
          (cr, ts3) <- pColRef ts2
          Right ((n, AssignCol cr), ts3)
    _ -> do
      (v, ts3) <- pLit ts2
      Right ((n, AssignLit v), ts3)

-- ---------------- delete_stmt ----------------
pDeleteStmt :: [Tok] -> Either SqlError (DeleteStmt, [Tok])
pDeleteStmt ts = do
  ts1 <- eatK "delete" ts
  ts2 <- eatK "from" ts1
  (nm, ts3) <- pIdent ts2
  (mw, ts4) <- pOptWhere ts3
  Right (DeleteStmt nm mw, ts4)

-- ---------------- DDL ----------------
pCreateTable :: [Tok] -> Either SqlError (CreateTableStmt, [Tok])
pCreateTable ts = do
  ts1 <- eatK "table" ts
  (nm, ts2) <- pIdent ts1
  ts3 <- eatSym '(' ts2
  (cols, ts4) <- sepBy1 pColDef ',' ts3
  ts5 <- eatSym ')' ts4
  Right (CreateTableStmt nm cols, ts5)

pColDef :: [Tok] -> Either SqlError ((Text, SqlType), [Tok])
pColDef ts = do
  (n, ts1) <- pIdent ts
  (ty, ts2) <- pTypeName ts1
  Right ((n, ty), ts2)

pTypeName :: [Tok] -> Either SqlError (SqlType, [Tok])
pTypeName ts = case peekT ts of
  TIdent "int64"   -> Right (TyInt64, drop1 ts)
  TIdent "bigint"  -> Right (TyInt64, drop1 ts)
  TIdent "int8"    -> Right (TyInt64, drop1 ts)
  TIdent "float64" -> Right (TyFloat64, drop1 ts)
  TIdent "double"  -> do
    ts1 <- eatK "precision" (drop1 ts)
    Right (TyFloat64, ts1)
  TIdent "varchar" ->
    case peekT (drop1 ts) of
      TSymbol '(' -> Left (errSyntax "VARCHAR takes no length specifier")
      _           -> Right (TyVarchar, drop1 ts)
  TIdent "boolean" -> Right (TyBool, drop1 ts)
  TIdent "bool"    -> Right (TyBool, drop1 ts)
  TIdent k
    | k `elem` ["timestamp","date","text","char","integer"] ->
        Left (errFeatureNotSupported
              ("type `" <> k <> "` is not in the supported type system"))
  _ -> Left (errSyntax "expected a type name")

pCreateIndex :: [Tok] -> Either SqlError (CreateIndexStmt, [Tok])
pCreateIndex ts = do
  ts1 <- eatK "index" ts
  (nm, ts2) <- pIdent ts1
  ts3 <- eatK "on" ts2
  (tbl, ts4) <- pIdent ts3
  ts5 <- eatSym '(' ts4
  (col, ts6) <- pIdent ts5
  ts7 <- eatSym ')' ts6
  Right (CreateIndexStmt nm tbl col, ts7)























