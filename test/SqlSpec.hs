-- Phase-5 milestone test suite (design/10 §10.2; design/05 + internal/07):
--   * lexer: case folding, byte positions, `''` escapes, `--` comments,
--     two-char operators, INT64 literal overflow (22003), whole-input
--     UTF-8 validation (22P02)
--   * parser: one positive test per grammar production of design/05 §5.2,
--     clause optionals, PostgreSQL-compatible type aliases, every §5.x
--     "not supported" construct rejected with the SPECIFIC 0A000 feature
--     error (§7.3 nicety), reserved words as identifiers (42601),
--     VARCHAR length specifier / structural syntax errors
--   * analyzer against a seeded catalog: name resolution (qualified,
--     unqualified, aliases, derived tables), ambiguity 42702, undefined
--     relation 42P01 / column 42703, correlation ban 0A000, grouping
--     rule 42803, cross-type rules 42804, VARCHAR byte limit 22001,
--     subquery column cardinality 21000, ORDER BY resolution 42703,
--     DDL 42P07/42701, int-literal -> FLOAT64 promotion rewritten
module Main where

import Control.Exception (catch)
import qualified Data.ByteString as BS
import Data.Text (Text)
import qualified Data.Text as T
import System.Exit (exitFailure)

import HaskDB.Common.Types (SqlType(..), RelId, RID(..), valueType)
import HaskDB.Common.Error (SqlError(..), seState, seMessage)
import HaskDB.Sql.Lexer (Token(..), Tok(tokPos, tokVal), lexSql)
import HaskDB.Sql.Parser (parseStatement)
import HaskDB.Sql.Ast
import HaskDB.Sql.Analyzer
import HaskDB.Catalog.Cache (CatalogCache, newCatalogCache, ccInsert)
import HaskDB.Catalog.Types (RelationDesc(..), RelKind(RelTable, RelIndex))
import HaskDB.Heap.TupleCodec (ColumnDesc(..))

-- ---------------------------------------------------------------------------
check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then [] else name : errs

showE :: SqlError -> String
showE (SqlError st msg) = T.unpack st ++ ": " ++ T.unpack msg

-- | Run an IO action, catching SqlError as a value.
sqlTry :: IO a -> IO (Either SqlError a)
sqlTry act = catch (Right <$> act) handler
  where
    handler :: SqlError -> IO (Either SqlError a)
    handler e = pure (Left e)

runAnalyze :: CatalogCache -> BS.ByteString -> IO (Either SqlError Analyzed)
runAnalyze cache src = case parseStatement src of
  Left e   -> pure (Left e)
  Right st -> sqlTry (analyze cache st)

-- | Expect an analyze-time SqlError with this SQLSTATE.
wantErr :: String -> String -> CatalogCache -> BS.ByteString -> IO [String]
wantErr label want cache src = do
  r <- runAnalyze cache src
  pure $ case r of
    Left e | T.pack want == seState e -> []
           | otherwise -> [label ++ ": expected " ++ want ++ ", got " ++ showE e]
    Right _ -> [label ++ ": expected " ++ want ++ ", but analyzed cleanly"]

-- | Expect an analyze-time SqlError with this SQLSTATE and message text.
wantErrM :: String -> String -> String -> CatalogCache -> BS.ByteString -> IO [String]
wantErrM label want needle cache src = do
  r <- runAnalyze cache src
  pure $ case r of
    Left e | T.pack want == seState e, T.pack needle `T.isInfixOf` seMessage e -> []
           | otherwise -> [label ++ ": expected " ++ want ++ ", got " ++ showE e]
    Right _ -> [label ++ ": expected " ++ want ++ ", but analyzed cleanly"]

-- | Statement must analyze cleanly; the predicate inspects the result.
okAnal :: String -> CatalogCache -> BS.ByteString -> (Analyzed -> Bool) -> IO [String]
okAnal label cache src p = do
  r <- runAnalyze cache src
  pure $ case r of
    Right a | p a -> []
            | otherwise -> [label ++ ": analyzed but result shape unexpected"]
    Left e -> [label ++ ": analyze failed " ++ showE e]

-- | Statement must parse (analyze skipped); pure.
parseOk :: String -> BS.ByteString -> [String]
parseOk label src = case parseStatement src of
  Right _ -> []
  Left e  -> [label ++ ": parse failed " ++ showE e]

parseErr :: String -> String -> BS.ByteString -> [String]
parseErr label want src = case parseStatement src of
  Right _ -> [label ++ ": expected " ++ want ++ ", parsed cleanly"]
  Left e | T.pack want == seState e -> []
         | otherwise -> [label ++ ": expected " ++ want ++ ", got " ++ showE e]

-- ---------------------------------------------------------------------------
-- Lexer-facing helpers (pure)
lexErr :: String -> String -> BS.ByteString -> [String]
lexErr label want src = case lexSql src of
  Left e | T.pack want == seState e -> []
  Left e -> [label ++ ": expected " ++ want ++ ", got " ++ showE e]
  Right _ -> [label ++ ": expected " ++ want ++ ", lexed cleanly"]

-- | Exact token sequence (ignoring token positions).
lexSeq :: String -> BS.ByteString -> [Token] -> [String]
lexSeq label src want = case lexSql src of
  Left e -> [label ++ ": lex failed " ++ showE e]
  Right ts
    | map tokVal ts == want -> []
    | otherwise -> [label ++ ": tokens were " ++ show (map tokVal ts)]

-- ---------------------------------------------------------------------------
-- seeded catalog
usersCols, ordersCols :: [ColumnDesc]
usersCols =
  [ ColumnDesc "id" TyInt64, ColumnDesc "name" TyVarchar
  , ColumnDesc "score" TyFloat64, ColumnDesc "active" TyBool ]
ordersCols = [ ColumnDesc "id" TyInt64, ColumnDesc "qty" TyInt64 ]

mkTable :: RelId -> Text -> [ColumnDesc] -> RelationDesc
mkTable rid nm cols =
  RelationDesc { rdId = rid, rdName = nm, rdKind = RelTable
               , rdColumns = cols, rdPages = [1], rdRoot = 0
               , rdTuples = 3, rdOwner = 0, rdIdxCol = -1 }

mkIndex :: RelId -> Text -> RelId -> Int -> RelationDesc
mkIndex rid nm owner colOrd =
  RelationDesc { rdId = rid, rdName = nm, rdKind = RelIndex
               , rdColumns = [], rdPages = [], rdRoot = 7
               , rdTuples = 3, rdOwner = owner, rdIdxCol = colOrd }

seed :: CatalogCache -> IO ()
seed cache = do
  ccInsert cache (mkTable 1 "users" usersCols) (RID 0 1)
  ccInsert cache (mkTable 2 "orders" ordersCols) (RID 0 2)
  ccInsert cache (mkIndex 3 "users_ix" 1 1) (RID 0 0)

-- ---------------------------------------------------------------------------
-- Analyzed-result inspectors (no Eq needed on the resolved types)
selShape :: Analyzed -> Maybe RSelect
selShape (ASelect rs) = Just rs
selShape _            = Nothing

outNames :: Analyzed -> [Text]
outNames a = maybe [] rsOutNames (selShape a)

nItems :: Analyzed -> Int
nItems a = maybe (-1) (length . rsItems) (selShape a)

itemTypesList :: Analyzed -> [SqlType]
itemTypesList a = maybe [] (map itemOutType . rsItems) (selShape a)

colIndices :: Analyzed -> [Int]
colIndices a = case selShape a of
  Nothing -> []
  Just rs -> [ rcCol c | RIColumn c <- rsItems rs ]

groupCount :: Analyzed -> Int
groupCount a = maybe (-1) (length . rsGroupBy) (selShape a)

orderKeys :: Analyzed -> [(Int, Bool)]
orderKeys a = maybe [] rsOrderBy (selShape a)

isAggQuery :: Analyzed -> Bool
isAggQuery a = maybe False rsIsAgg (selShape a)

slotNames :: Analyzed -> [Text]
slotNames a = maybe [] (map fsName . rsFrom) (selShape a)

slotCols :: Analyzed -> [Int]
slotCols a = maybe [] (map (length . fsColumns) . rsFrom) (selShape a)

relIds :: Analyzed -> [Maybe RelId]
relIds a = maybe [] (map fsRelId . rsFrom) (selShape a)

-- | True when the WHERE is a comparison whose RHS literal got the
--   int -> float promotion (§5.3 / §7.4 step 3).
rhsPromotedFloat :: Analyzed -> Bool
rhsPromotedFloat a = case selShape a of
  Just RSelect { rsWhere = Just (RPCmp _ _ (ROLit v)) } -> valueType v == TyFloat64
  _ -> False

-- | The single value row of an AInsert, as value types.
insertRowTypes :: Analyzed -> [[SqlType]]
insertRowTypes a = case a of
  AInsert _ _ rows -> [ map valueType row | row <- rows ]
  _ -> []

assignOrdinals :: Analyzed -> [Int]
assignOrdinals a = case a of
  AUpdate _ asgn _ -> [ i | (i, _) <- asgn ]
  _ -> []

ddlCols :: Analyzed -> [(Text, SqlType)]
ddlCols a = case a of
  ACreateTable (CreateTableStmt _ cols) -> cols
  _ -> []

createIndexOf :: Text -> Text -> Text -> Analyzed -> Bool
createIndexOf nm0 tbl0 col0 a = case a of
  ACreateIndex (CreateIndexStmt nm tbl col) ->
      nm == nm0 && tbl == tbl0 && col == col0
  _ -> False

-- | The statement a txn-control marker carried through untouched.
isTxnFor :: Statement -> Analyzed -> Bool
isTxnFor st a = case a of
  ATxnControl st' -> show st' == show st
  _ -> False

-- ---------------------------------------------------------------------------
-- LEXER TESTS
lexerTests :: [String]
lexerTests = (concat . concat)
  [ [ lexSeq "L1 case-fold"
        "select Id FROM Users"
        [TIdent "select", TIdent "id", TIdent "from", TIdent "users", TEOF]
    , check "L1 positions are byte offsets"
        (case lexSql "select Id FROM Users" of
           Right ts -> map tokPos ts == [0,7,10,15,20]
           Left _   -> False) []
    ]
  , [ lexSeq "L2 two-char ops"
        "a <= b >= c <> d"
        [ TIdent "a", TLe, TIdent "b", TGe, TIdent "c", TNe, TIdent "d", TEOF ]
    , lexSeq "L2 single < >"
        "a < b > c"
        [ TIdent "a", TSymbol '<', TIdent "b", TSymbol '>', TIdent "c", TEOF ]
    , lexSeq "L2 symbols"
        "(),*;"
        [ TSymbol '(', TSymbol ')', TSymbol ',', TSymbol '*', TSymbol ';', TEOF ]
    ]
  , [ lexSeq "L3 comment to EOL"
        "select id -- trailing comment\nfrom users"
        [ TIdent "select", TIdent "id", TIdent "from", TIdent "users", TEOF ]
    , lexSeq "L3 comment at EOF, no newline"
        "select id--"
        [ TIdent "select", TIdent "id", TEOF ]
    , lexSeq "L3 comment inside parens"
        "count( -- c\nid )"
        [ TIdent "count", TSymbol '(', TIdent "id", TSymbol ')', TEOF ]
    ]
  , [ lexSeq "L4 string escape ''"
        "select 'it''s'"
        [ TIdent "select", TString "it's", TEOF ]
    , lexSeq "L4 empty string"
        "select ''"
        [ TIdent "select", TString "", TEOF ]
    , lexSeq "L4 utf-8 inside literal is kept as bytes"
        "select '\226\128\156'"
        [ TIdent "select", TString "\226\128\156", TEOF ]
    , lexErr "L4 unterminated string" "42601" "select 'abc from users"
    ]
  , [ lexSeq "L5 int64 boundary ok"
        "select 9223372036854775807 -9223372036854775808"
        [ TIdent "select", TInt 9223372036854775807,
          TInt (-9223372036854775808), TEOF ]
    , lexErr "L5 int64 overflow positive" "22003" "select 9223372036854775808"
    , lexErr "L5 int64 overflow negative" "22003" "select -9223372036854775809"
    , lexSeq "L5 float forms"
        "select 1.5 1e3 -2.5E-3"
        [ TIdent "select", TFloat 1.5, TFloat 1000.0, TFloat (-2.5e-3), TEOF ]
    , parseErr "L5 trailing dot is not a number" "42601" "select 1. from users"
    ]
  , [ lexErr "L6 invalid utf-8 (lone continuation byte)" "22P02"
        (BS.pack [0x73,0x65,0x6c,0x0a,0x80,0x61])
    , lexErr "L6 invalid utf-8 (truncated 3-byte)" "22P02"
        (BS.pack [0xe2,0x80])
    , lexErr "L6 unexpected character" "42601" "select a # b"
    ]
  ]

-- ---------------------------------------------------------------------------
-- PARSER TESTS (positives assert no error; shape checked where cheap)
parserTests :: [String]
parserTests = (concat . concat)
  [ -- every statement production parses
    [ parseOk "P1 select"    "select id from users"
    , parseOk "P1 insert"    "insert into users (id) values (1)"
    , parseOk "P1 update"    "update users set name = 'z' where id = 1"
    , parseOk "P1 delete"    "delete from users where id = 1"
    , parseOk "P1 create table"
        "create table t9 (a int64, b varchar, c float64, d boolean)"
    , parseOk "P1 create index" "create index ix9 on users (name)"
    , parseOk "P1 begin"     "begin"
    , parseOk "P1 commit"    "commit"
    , parseOk "P1 rollback"  "rollback"
    ]
  , -- select-list item forms (§5.2 select_item)
    [ parseOk "P2 star"          "select * from users"
    , parseOk "P2 col"           "select name from users"
    , parseOk "P2 qualified col" "select u.name from users as u"
    , parseOk "P2 alias as"      "select name as nm from users"
    , parseOk "P2 bare alias"    "select name nm from users"
    , parseOk "P2 literal"       "select 1 from users"
    , parseOk "P2 literal alias" "select 1 one from users"
    , parseOk "P2 string literal" "select 'x' from users"
    , parseOk "P2 bool literal"  "select true from users"
    , parseOk "P2 count star"    "select count(*) from users"
    , parseOk "P2 count col"     "select count(name) from users"
    , parseOk "P2 sum/avg/min/max"
        "select sum(score), avg(score), min(id), max(name) from users"
    , parseOk "P2 agg alias"     "select count(id) as n from users"
    , parseErr "P2 star mid-list is not a select item" "42601"
        "select id, * from users"
    , parseErr "P2 * not legal as aggregate arg (AVG)" "42601"
        "select avg(*) from users"
    , parseErr "P2 unknown function call" "42601"
        "select lower(name) from users"
    ]
  , -- FROM forms
    [ parseOk "P3 table"           "select id from users"
    , parseOk "P3 alias"           "select id from users u"
    , parseOk "P3 multi from (no join keyword)"
        "select id from users, orders"
    , parseOk "P3 derived table with AS"
        "select n from (select name from users) as d"
    , parseOk "P3 derived table bare alias"
        "select n from (select name from users) d"
    , parseErr "P3 derived table needs an alias" "42601"
        "select n from (select name from users)"
    ]
  , -- clause optionals in the grammar's order
    [ parseOk "P4 where"        "select id from users where id = 1"
    , parseOk "P4 group by"     "select name from users group by name"
    , parseOk "P4 order by"     "select id from users order by id desc"
    , parseOk "P4 all clauses in order"
        "select id from users where id = 1 group by id order by id asc"
    , parseErr "P4 clauses in the wrong order" "42601"
        "select id from users order by id where id = 1"
    , parseErr "P4 GROUP BY without BY" "42601"
        "select id from users group id"
    , parseErr "P4 ORDER BY without BY" "42601"
        "select id from users order id"
    , parseOk "P4 trailing semicolon" "select id from users;"
    , parseErr "P4 two statements in one string (wire layer splits)" "42601"
        "select id from users; commit"
    ]
  , -- predicate grammar (§5.2 operator chain + primary_pred)
    [ parseOk "P5 eq"            "select id from users where id = 1"
    , parseOk "P5 ne"            "select id from users where id <> 1"
    , parseOk "P5 lt le gt ge"   "select id from users where id < 1 and id <= 1 and id > 1 and id >= 1"
    , parseOk "P5 and/or/not chain"
        "select id from users where id = 1 or id = 2 and not id = 3"
    , parseOk "P5 parens"        "select id from users where (id = 1 or id = 2) and name = 'a'"
    , parseOk "P5 exists"        "select id from users where exists (select id from orders)"
    , parseOk "P5 in"            "select id from users where id in (select id from orders)"
    , parseOk "P5 not in"        "select id from users where id not in (select id from orders)"
    , parseOk "P5 scalar subquery operand"
        "select id from users where id = (select id from orders)"
    , parseOk "P5 not exists"    "select id from users where not exists (select id from orders)"
    , parseOk "P5 qualified operand" "select id from users where u.id = 1"
    ]
  , -- INSERT / UPDATE / DELETE shapes
    [ parseOk "P6 insert col list"   "insert into users (id, name) values (1, 'x')"
    , parseOk "P6 insert full order"  "insert into users values (1, 'x', 2.5, true)"
    , parseOk "P6 insert multi row"
        "insert into users (id) values (1), (2), (3)"
    , parseErr "P6 VALUES rejects a NULL literal" "0A000"
        "insert into users (id) values (null)"
    , parseOk "P6 UPDATE SET right-hand side is a col_ref (qualified too)"
        "update users set name = users.name"
    , parseOk "P6 insert int8 boundary"
        "insert into users (id) values (9223372036854775807)"
    , parseErr "P6 insert needs VALUES" "42601"
        "insert into users (id)"
    , parseErr "P6 INSERT VALUES SELECT not in grammar" "42601"
        "insert into users select id from orders"
    , parseOk "P6 update multi assign"
        "update users set id = 1, name = 'x' where id = 2"
    , parseOk "P6 update col rhs"     "update users set name = name"
    , parseOk "P6 update no where"    "update users set id = 1"
    , parseOk "P6 delete no where"    "delete from users"
    ]
  , [ parseOk "P7 type aliases"
        "create table t10 (i int64, b bigint, i8 int8, f float64, dp double precision, v varchar, bo bool, bb boolean)"
    , parseErr "P7 VARCHAR length specifier" "42601"
        "create table t11 (v varchar(10))"
    , parseErr "P7 no column list" "42601"
        "create table t12 ()"
    , parseErr "P7 reserved word as table name" "42601"
        "create table table (a int64)"
    , parseErr "P7 reserved word as column name" "42601"
        "create table t13 (order int64)"
    ]]

-- unsupported constructs must give the SPECIFIC feature error (§7.3 nicety)
featureTests :: [String]
featureTests = concat
  [ parseErr "F1 JOIN"                 "0A000" "select id from users join orders"
  , parseErr "F1 cross join"           "0A000" "select id from users cross orders"
  , parseErr "F1 LEFT ... ON"          "0A000" "select id from users left orders"
  , parseErr "F1 HAVING"               "0A000" "select count(id) from users having count(id) > 1"
  , parseErr "F1 LIMIT"                "0A000" "select id from users limit 3"
  , parseErr "F1 LIMIT after WHERE"    "0A000" "select id from users where id = 1 limit 3"
  , parseErr "F1 OFFSET"               "0A000" "select id from users offset 2"
  , parseErr "F1 DISTINCT in select list" "0A000" "select distinct id from users"
  , parseErr "F1 IS NULL"              "0A000" "select id from users where id is null"
  , parseErr "F1 bare NULL operand"    "0A000" "select id from users where id = null"
  , parseErr "F1 ALTER"                "0A000" "alter table users (a int64)"
  , parseErr "F1 DROP"                 "0A000" "drop table users"
  , parseErr "F1 UNION"                "0A000" "select id from users union select id from orders"
  , parseErr "F1 FETCH"                "0A000" "fetch id from users"
  , parseErr "F1 RETURNING on UPDATE"  "0A000" "update users set id = 1 returning id"
  , parseErr "F1 CASE in select list"  "0A000" "select case id from users"
  , parseErr "F1 ON is reserved"       "42601" "select on from users"
  , parseErr "F1 unsupported type name" "0A000" "create table t14 (v timestamp)"
  -- §0.3's "not supported" items the keyword blocklist cannot see: arithmetic
  -- (not in the grammar at all => a syntax error) and the exact DDL shapes.
  -- Added in the Phase-8 conformance pass so every §0.3 row has a test.
  , parseErr "F1 arithmetic in the select list" "42601" "select id + 1 from users"
  , parseErr "F1 arithmetic in WHERE" "42601" "select id from users where id + 1 = 2"
  , parseErr "F1 arithmetic in UPDATE SET" "42601" "update users set id = id + 1"
  , parseErr "F1 arithmetic in INSERT VALUES" "42601" "insert into users values (1 + 2, 3)"
  , parseErr "F1 arithmetic in GROUP BY" "42601" "select count(id) from users group by id + 1"
  , parseErr "F1 DROP INDEX" "0A000" "drop index users_id"
  , parseErr "F1 no CREATE DATABASE" "42601" "create database db1"
  , parseErr "F1 arithmetic in ORDER BY" "42601" "select id from users order by id + 1"
  ]

-- ---------------------------------------------------------------------------
-- | Runs a group of analyzer checks and flattens their error lists.
runGroups :: [[IO [String]]] -> IO [String]
runGroups gs = do
  results <- mapM (\g -> sequence g) gs
  pure (concat (concat results))

analyzerTests :: CatalogCache -> IO [String]
analyzerTests cache = runGroups
  [ -- resolution: unqualified, qualified, aliases, derived tables
    [ okAnal "A1 unqualified" cache "select id from users"
        (\a -> outNames a == ["id"] && nItems a == 1 && itemTypesList a == [TyInt64])
    , okAnal "A1 several columns" cache "select name, score from users"
        (\a -> outNames a == ["name","score"] && colIndices a == [1,2])
    , okAnal "A1 star expands to all columns" cache "select * from users"
        (\a -> outNames a == ["id","name","score","active"]
            && colIndices a == [0,1,2,3]
            && itemTypesList a == [TyInt64, TyVarchar, TyFloat64, TyBool])
    , okAnal "A1 qualified ref" cache "select u.name from users as u"
        (\a -> outNames a == ["name"] && slotNames a == ["u"])
    , okAnal "A1 alias renames output" cache "select name as nm from users"
        (\a -> outNames a == ["nm"])
    , okAnal "A1 bare alias renames output" cache "select name nm from users"
        (\a -> outNames a == ["nm"])
    , okAnal "A1 literal gets generated name" cache "select 1 from users"
        (\a -> outNames a == ["?column?"] && itemTypesList a == [TyInt64])
    , okAnal "A1 literal alias" cache "select 1 one from users"
        (\a -> outNames a == ["one"])
    , okAnal "A1 derived table" cache
        "select name from (select name from users) as d"
        (\a -> slotNames a == ["d"] && slotCols a == [1] && relIds a == [Nothing]
            && outNames a == ["name"])
    , okAnal "A1 derived table qualified" cache
        "select d.n from (select name as n from users) as d"
        (\a -> outNames a == ["n"])
    , okAnal "A1 multi-FROM unambiguous" cache
        "select qty from users, orders"
        (\a -> slotNames a == ["users","orders"] && outNames a == ["qty"]
            && colIndices a == [1])
    ]
  , -- undefined names / ambiguity (§7.4 step 2 codes)
    [ wantErr "A2 unknown table" "42P01" cache "select id from nosuch"
    , wantErr "A2 unknown column" "42703" cache "select nosuchcol from users"
    , wantErr "A2 unknown qualifier" "42P01" cache "select q.id from users"
    , wantErr "A2 known qualifier, unknown column" "42703"
        cache "select users.nope from users"
    , wantErrM "A2 ambiguity is 42702" "42702" "ambiguous"
        cache "select id from users, orders"
    , wantErr "A2 unknown qualifier on multi-FROM" "42P01"
        cache "select u.id from users, orders"
    ]
  , -- aggregate rules (§5.7 / §7.4 step 4)
    [ okAnal "A3 count star aggregates" cache "select count(*) from users"
        (\a -> isAggQuery a && groupCount a == 0 && itemTypesList a == [TyInt64]
            && outNames a == ["?column?"])
    , okAnal "A3 count col equals count star" cache "select count(name) from users"
        (\a -> isAggQuery a && itemTypesList a == [TyInt64])
    , okAnal "A3 group by" cache "select name, count(id) from users group by name"
        (\a -> isAggQuery a && groupCount a == 1
            && outNames a == ["name","?column?"]
            && itemTypesList a == [TyVarchar, TyInt64])
    , okAnal "A3 avg is always FLOAT64" cache "select avg(id) from users"
        (\a -> itemTypesList a == [TyFloat64] && outNames a == ["?column?"])
    , okAnal "A3 min/max keep the argument type" cache
        "select min(name), max(score) from users"
        (\a -> itemTypesList a == [TyVarchar, TyFloat64]
            && outNames a == ["?column?","?column?"])
    , okAnal "A3 aliased aggregate" cache "select count(id) as n from users"
        (\a -> outNames a == ["n"])
    , wantErrM "A3 non-grouped column in aggregate query" "42803" "GROUP BY"
        cache "select name, count(id) from users"
    , wantErrM "A3 non-grouped column with GROUP BY" "42803" "GROUP BY"
        cache "select name, score from users group by name"
    , okAnal "A3 grouping column is legal" cache
        "select name, count(id) from users group by name"
        (\a -> groupCount a == 1)
    , wantErrM "A3 SUM on VARCHAR" "42804" "unsupported type"
        cache "select sum(name) from users"
    , wantErrM "A3 AVG on VARCHAR" "42804" "unsupported type"
        cache "select avg(active) from users"
    , okAnal "A3 MIN/MAX accept any type" cache "select min(active) from users"
        (\a -> itemTypesList a == [TyBool])
    , wantErr "A3 aggregate call in WHERE is a syntax error" "42601"
        cache "select id from users where count(id) > 1"
    ]
  , -- WHERE type rules + int -> float promotion (§5.3/§5.4)
    [ okAnal "A4 same-type comparison" cache "select id from users where name = 'x'"
        (const True)
    , okAnal "A4 int literal vs float column promotes" cache
        "select score from users where score > 2"
        rhsPromotedFloat
    , okAnal "A4 int literal vs int column stays int" cache
        "select id from users where id > 2"
        (\a -> not (rhsPromotedFloat a))
    , wantErrM "A4 cross-type comparison" "42804" "comparison operand types differ"
        cache "select id from users where id = 'x'"
    , wantErrM "A4 VARCHAR vs INT64" "42804" "comparison operand types differ"
        cache "select name from users where name > 1"
    , wantErrM "A4 BOOLEAN ordering is undefined" "42804" "BOOLEAN"
        cache "select id from users where active < true"
    , okAnal "A4 BOOLEAN equality is defined" cache
        "select id from users where active = false"
        (const True)
    , okAnal "A4 float column vs int literal reversed side" cache
        "select score from users where 2 < score"
        (const True)
    , wantErr "A4 GROUP BY keyword without BY is a syntax error" "42601"
        cache "select id from users where id = 1 group"
    ]
  , -- subqueries (§5.6: one column, uncorrelated)
    [ okAnal "A5 EXISTS any schema" cache
        "select id from users where exists (select 1 from orders)"
        (const True)
    , okAnal "A5 IN one comparable column" cache
        "select id from users where id in (select id from orders)"
        (const True)
    , okAnal "A5 NOT IN" cache
        "select id from users where id not in (select qty from orders)"
        (const True)
    , okAnal "A5 scalar subquery as left operand" cache
        "select id from users where (select score from users) > 2"
        (const True)
    , wantErr "A5 scalar subquery left operand, cross type" "42804"
        cache "select name from users where (select name from users) = 2"
    , wantErrM "A5 IN column vs differently typed subquery column" "42804"
        "IN subquery column type"
        cache "select id from users where id in (select score from users)"
    , okAnal "A5 IN same-typed subquery column" cache
        "select id from users where id in (select id from orders)"
        (const True)
    , wantErr "A5 IN with two output columns" "21000"
        cache "select id from users where id in (select id, qty from orders)"
    , wantErr "A5 scalar subquery with two columns" "21000"
        cache "select id from users where id = (select id, qty from orders)"
    , wantErrM "A5 IN type not comparable" "42804" "IN subquery column type"
        cache "select name from users where name in (select id from orders)"
    , wantErrM "A5 correlated reference is 0A000" "0A000" "correlated subqueries"
        cache "select id from users where exists (select 1 from orders where score = 1)"
    , wantErrM "A5 correlated inside NOT IN" "0A000" "correlated subqueries"
        cache "select id from users where id not in (select id from orders where score = 1)"
    , okAnal "A5 nested subqueries are independent scopes" cache
        "select id from users where exists (select 1 from orders where exists (select 1 from users where id = 1))"
        (const True)
    ]
  , -- ORDER BY resolution (§7.4 step 5)
    [ okAnal "A6 order by output name" cache "select name from users order by name"
        (\a -> orderKeys a == [(0,True)])
    , okAnal "A6 order by ordinal" cache "select name, id from users order by 2 desc"
        (\a -> orderKeys a == [(1,False)])
    , okAnal "A6 order by alias" cache "select name as nm from users order by nm"
        (\a -> orderKeys a == [(0,True)])
    , okAnal "A6 order by qualified col in select list" cache
        "select u.name from users as u order by u.name desc"
        (\a -> orderKeys a == [(0,False)])
    , okAnal "A6 order by grouping column" cache
        "select name, count(id) from users group by name order by name"
        (\a -> orderKeys a == [(0,True)])
    , wantErr "A6 order by name not in output" "42703"
        cache "select id from users order by name"
    , wantErr "A6 ordinal out of range" "42703"
        cache "select id from users order by 5"
    , wantErr "A6 negative ordinal is a syntax error" "42601"
        cache "select id from users order by -1"
    , wantErr "A6 order by a column not in the select list" "42703"
        cache "select id from users order by u.name"
    , wantErr "A6 GROUP BY ordinal is not allowed" "42601"
        cache "select name from users group by 1"
    ]
  , -- INSERT (§7.5)
    [ okAnal "A7 insert col list subset" cache
        "insert into users (id, name) values (1, 'x')"
        (\a -> insertRowTypes a == [[TyInt64, TyVarchar]])
    , okAnal "A7 insert full column order" cache
        "insert into users values (1, 'x', 2.5, true)"
        (\a -> insertRowTypes a == [[TyInt64, TyVarchar, TyFloat64, TyBool]])
    , okAnal "A7 insert int literal into FLOAT64 promotes" cache
        "insert into users (id, score) values (7, 8)"
        (\a -> insertRowTypes a == [[TyInt64, TyFloat64]])
    , okAnal "A7 insert many rows" cache
        "insert into users (id) values (1), (2), (3)"
        (\a -> insertRowTypes a == [[TyInt64],[TyInt64],[TyInt64]])
    , okAnal "A7 insert bytes exactly 1024 are fine" cache
        (sqlLongLit 1024) (const True)
    , wantErrM "A7 VARCHAR over 1024 bytes" "22001" "1024 bytes"
        cache (sqlLongLit 1025)
    , wantErrM "A7 literal type mismatch" "42804" "does not match column type"
        cache "insert into users (id) values ('x')"
    , wantErr "A7 arity mismatch" "4280"
        cache "insert into users (id, name) values (1, 'x'), (2)"
    , wantErr "A7 unknown table" "42P01"
        cache "insert into nosuch (a) values (1)"
    , wantErr "A7 unknown column" "42703"
        cache "insert into users (nope) values (1)"
    , wantErr "A7 float literal into INT64 column" "42804"
        cache "insert into users (id) values (1.5)"
    , wantErr "A7 INSERT VALUES takes literals only" "42601"
        cache "insert into users (id) values (score)"
    ]
  , -- UPDATE / DELETE (§7.5: one-slot scope)
    [ okAnal "A8 update literal" cache "update users set name = 'z' where id = 1"
        (\a -> assignOrdinals a == [1])
    , okAnal "A8 update column rhs same table" cache "update users set name = name"
        (const True)
    , okAnal "A8 update several assignments" cache
        "update users set id = 1, active = false where name = 'a'"
        (\a -> assignOrdinals a == [0,3])
    , wantErr "A8 update unknown column" "42703"
        cache "update users set nope = 1"
    , wantErrM "A8 update type mismatch" "42804" "assignment RHS type"
        cache "update users set id = name"
    , wantErr "A8 update WHERE cross-type" "42804"
        cache "update users set id = 1 where name = 1"
    , okAnal "A8 delete WHERE one-slot scope" cache
        "delete from users where name = 'a' and id = 2"
        (const True)
    , wantErr "A8 delete unknown table" "42P01" cache "delete from nosuch"
    , wantErr "A8 delete WHERE unknown column" "42703"
        cache "delete from users where nope = 1"
    , wantErrM "A8 correlated reference inside DELETE WHERE" "0A000"
        "correlated subqueries"
        cache "delete from users where exists (select 1 from orders where name = 'x')"
    , wantErrM "A8 correlated reference inside UPDATE WHERE" "0A000"
        "correlated subqueries"
        cache "update users set id = 1 where exists (select 1 from orders where name = 'x')"
    , wantErr "A8 UPDATE SET needs an ident" "42601"
        cache "update users set 1 = 2"
    ]
  , -- DDL (§7.5 + §5.10)
    [ okAnal "A9 create table fresh" cache
        "create table t20 (a int64, b varchar) "
        (\a -> ddlCols a == [("a",TyInt64),("b",TyVarchar)])
    , okAnal "A9 type aliases map to the four types" cache
        "create table t21 (i int64, b bigint, i8 int8, f float64, dp double precision, v varchar, bo bool, bb boolean)"
        (\a -> map snd (ddlCols a)
                 == [TyInt64, TyInt64, TyInt64, TyFloat64, TyFloat64
                    , TyVarchar, TyBool, TyBool])
    , wantErr "A9 existing relation name" "42P07"
        cache "create table users (q int64)"
    , wantErrM "A9 duplicate column name" "42701" "duplicate column name"
        cache "create table t22 (a int64, a varchar)"
    , okAnal "A9 create index on existing column" cache
        "create index ix20 on users (name)"
        (createIndexOf "ix20" "users" "name")
    , wantErr "A9 index name shares the relation namespace" "42P07"
        cache "create index users_ix on users (name)"
    , wantErr "A9 create index unknown table" "42P01"
        cache "create index ix21 on nosuch (id)"
    , wantErr "A9 create index unknown column" "42703"
        cache "create index ix22 on orders (score)"
    , okAnal "A9 begin passes through" cache "begin" (isTxnFor StmtBegin)
    , okAnal "A9 commit passes through" cache "commit" (isTxnFor StmtCommit)
    , okAnal "A9 rollback passes through" cache "rollback" (isTxnFor StmtRollback)
    ]
  ]

-- | SQL text with a string literal of exactly n bytes (VARCHAR tests).
sqlLongLit :: Int -> BS.ByteString
sqlLongLit n = BS.concat
  [ "insert into users (name) values ('", BS.pack (replicate n 0x78), "')" ]

main :: IO ()
main = do
  cache <- newCatalogCache
  seed cache
  aErrs <- analyzerTests cache
  let errs = lexerTests ++ parserTests ++ featureTests ++ aErrs
  mapM_ putStrLn errs
  if null errs
    then putStrLn "sql-tests: all checks passed"
    else do
      putStrLn ("sql-tests: " ++ show (length errs) ++ " failure(s)")
      exitFailure
