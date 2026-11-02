# 07. SQL Front-End Internals (Lexer, Parser, AST, Analyzer)

Refines `design/05-sql-language.md`. The grammar there is normative;
this document defines the code that implements it.

## 7.1 Lexer (`Sql.Lexer`)

```haskell
data Token
  = TIdent  !Text            -- lower-cased identifier or keyword text
  | TInt    !Int64
  | TFloat  !Double
  | TString !ByteString      -- decoded UTF-8 content (escapes resolved)
  | TSymbol !Char            -- ( ) , ; * = < >  (<> and <=, >= are two-char:
                             --  lexer emits TNe, TLe, TGe below)
  | TNe | TLe | TGe
  | TEOF
  deriving (Eq, Show)

data Tok = Tok { tokPos :: !Int, tokVal :: Token }  -- byte offset in input

lexSql :: ByteString -> Either SqlError [Tok]
```

Rules:

- Input must be valid UTF-8 overall, else `22P02`.
- `--` comments are stripped in the lexer (to end of line).
- Keywords are *not* distinguished in the lexer; the parser compares
  `TIdent` text against keyword names (case already folded: the lexer
  lower-cases all identifier text, ASCII only).
- Integer literals overflowing `Int64` → error `22003` at lex time.
- Float literals: parsed with `reads`-equivalent over the token text;
  the texts `NaN`, `Infinity`, `inf` (any case) are not valid numeric
  tokens (they lex as identifiers and fail in the parser) — this is
  how design/05 §5.4's "NaN is not producible" is enforced.
- String literal decoding: `''` → `'`; result must be valid UTF-8.
  The 1024-byte check is *not* done here (only when a value is bound
  to a VARCHAR column or stored); a long literal used in a comparison
  against a column is checked at analysis/execution binding time —
  actually simpler and safer: the analyzer checks every string literal
  that flows into a VARCHAR-typed position; literals in other
  positions are impossible by the type rules.

## 7.2 Raw AST (`Sql.Ast`)

Names are unresolved `Text`; no types are attached yet.

```haskell
data Statement
  = StmtSelect   SelectStmt
  | StmtInsert   InsertStmt
  | StmtUpdate   UpdateStmt
  | StmtDelete   DeleteStmt
  | StmtCreateTable CreateTableStmt
  | StmtCreateIndex CreateIndexStmt
  | StmtBegin | StmtCommit | StmtRollback      -- session commands (doc 10)
  deriving (Show)

data SelectStmt = SelectStmt
  { selList     :: [SelectItem]
  , selFrom     :: [FromItem]
  , selWhere    :: Maybe Pred
  , selGroupBy  :: [ColRef]
  , selOrderBy  :: [OrderItem]
  } deriving (Show)

data SelectItem
  = SelStar
  | SelColumn ColRef (Maybe Text)       -- ref, alias
  | SelLiteral Value (Maybe Text)
  | SelAgg AggCall (Maybe Text)
  deriving (Show)

data AggCall = AggCall { aggFn :: AggFn, aggArg :: AggArg } deriving (Show)
data AggFn = AggCount | AggSum | AggAvg | AggMin | AggMax deriving (Show)
data AggArg = AggStar | AggCol ColRef deriving (Show)

data FromItem
  = FromTable Text (Maybe Text)                       -- name, alias
  | FromSubquery SelectStmt Text                      -- alias is mandatory
  deriving (Show)

data ColRef = ColRef { crQualifier :: Maybe Text, crName :: Text }
  deriving (Eq, Show)

data Pred
  = PAnd Pred Pred | POr Pred Pred | PNot Pred
  | PCmp Operand CmpOp Operand
  | PExists SelectStmt
  | PIn ColRef Bool SelectStmt          -- Bool = negated (NOT IN)
  deriving (Show)

data Operand = OCol ColRef | OLit Value | OScalarSubquery SelectStmt
  deriving (Show)

data CmpOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe deriving (Eq, Show)

data OrderItem = OrderItem
  { oiKey :: OrderKey, oiAsc :: Bool } deriving (Show)
data OrderKey = OKCol ColRef | OKOrdinal Int | OKName Text deriving (Show)

data InsertStmt = InsertStmt
  { insTable :: Text, insCols :: Maybe [Text], insRows :: [[Value]] }
  deriving (Show)   -- literals only (parser enforces)

data UpdateStmt = UpdateStmt
  { updTable :: Text, updAssigns :: [(Text, AssignRhs)], updWhere :: Maybe Pred }
  deriving (Show)
data AssignRhs = AssignLit Value | AssignCol ColRef deriving (Show)

data DeleteStmt = DeleteStmt { delTable :: Text, delWhere :: Maybe Pred }
  deriving (Show)

data CreateTableStmt = CreateTableStmt
  { ctName :: Text, ctCols :: [(Text, SqlType)] } deriving (Show)
data CreateIndexStmt = CreateIndexStmt
  { ciName :: Text, ciTable :: Text, ciCol :: Text } deriving (Show)
```

## 7.3 Parser (`Sql.Parser`)

Hand-written recursive descent over `[Tok]` with a small parser type:

```haskell
newtype Parser a = Parser { runParser :: [Tok] -> Either SqlError (a, [Tok]) }
-- Functor/Applicative/Monad instances; combinators:
--   kw "select", sym '(', ident, literal, optional, sepBy1, eof
parseStatement :: ByteString -> Either SqlError Statement
  -- lexes, parses exactly one statement, allows one trailing ';',
  -- requires EOF afterwards (the wire layer splits multi-statement
  -- strings before calling this — design/09 section 9.4)
```

Implementation notes:

- One function per grammar production of design/05 §5.2; function
  names mirror production names (`pSelectStmt`, `pPred`, `pOrExpr`…).
- Operator precedence is encoded by call chain:
  `pPred = pOrExpr`, `pOrExpr = pAndExpr {OR pAndExpr}`,
  `pAndExpr = pNotExpr {AND pNotExpr}`, `pNotExpr = [NOT] pPrimary`.
- Unsupported constructs fail with specific messages, not generic
  parse errors, where cheap to detect: encountering `JOIN`, `HAVING`,
  `LIMIT`, `NULL`, `IS`, `ALTER`, `DROP` as the relevant keyword
  produces `errFeatureNotSupported` naming the construct (the lexer
  does not reserve them; the parser checks at the points where they
  would legally appear in full SQL — statement start, after FROM
  items, after WHERE, etc.). This is a usability nicety, implemented
  as a keyword blocklist check in `expectEndOfClause` helpers.
- Type names in `CREATE TABLE`: `INT64|BIGINT|INT8` → TyInt64,
  `FLOAT64|DOUBLE PRECISION` → TyFloat64, `VARCHAR` (a following `(`
  is a syntax error — no length specifier), `BOOLEAN|BOOL` → TyBool.
- `COUNT(*)` vs `COUNT(col)`: `AggStar` only legal for `COUNT`
  (parser-enforced).
- Literals in `INSERT ... VALUES` rows and `SelLiteral` carry `Value`
  directly (with the integer→float promotion deferred to the
  analyzer, which knows the target type).

## 7.4 Analyzer (`Sql.Analyzer`)

Input: raw `Statement` + `CatalogCache`. Output: **resolved AST**
(types below) or `SqlError`. The planner consumes only resolved ASTs.

```haskell
-- Resolved representation: names become (relid, ordinal) pairs and a
-- per-query "scope" assigns each FROM item a slot index.

data RColRef = RColRef { rcFrom :: !Int      -- FROM slot index
                       , rcCol  :: !Int      -- column ordinal in that slot
                       , rcType :: !SqlType }
  deriving (Eq, Show)

data FromSlot = FromSlot
  { fsRelId   :: Maybe RelId        -- Nothing for derived tables
  , fsName    :: !Text              -- alias (or table name)
  , fsColumns :: [ColumnDesc]       -- output schema of this slot
  , fsSubplan :: Maybe RSelect      -- derived table's resolved query
  }

data RSelect = RSelect
  { rsFrom     :: [FromSlot]
  , rsWhere    :: Maybe RPred
  , rsItems    :: [RSelectItem]     -- output schema + how to compute
  , rsGroupBy  :: [RColRef]
  , rsOrderBy  :: [(Int, Bool)]     -- resolved to output column index + asc
  , rsIsAgg    :: Bool
  }

data RSelectItem
  = RIColumn RColRef
  | RILiteral Value
  | RIAgg AggFn (Maybe RColRef)     -- Nothing = COUNT(*)
  deriving (Show)

data RPred
  = RPAnd RPred RPred | RPOr RPred RPred | RPNot RPred
  | RPCmp ROperand CmpOp ROperand
  | RPExists RSelect
  | RPIn RColRef Bool RSelect
  deriving (Show)

data ROperand = ROCol RColRef | ROLit Value | ROScalar RSelect
  deriving (Show)
```

### Analysis algorithm (SELECT)

```
analyzeSelect cache stmt:
  1. Build FROM scope:
     for each FromItem:
       - table: lookupTable (else 42P01); slot with its columns
       - subquery: recursively analyzeSelect -> its output schema is
         the slot's columns; alias required (parser enforced)
     Duplicate effective names across slots are allowed; unqualified
     column refs must then be unambiguous (step 2 errors otherwise).
  2. Resolve a ColRef:
     - qualified q.c: find slot named q (else 42P01/42703),
       then column c in it (else 42703)
     - unqualified c: search all slots; 0 hits -> 42703;
       >1 hits -> 42702 (ambiguous)
     - CORRELATION BAN: resolution searches ONLY the current query's
       scope. Subqueries are analyzed with a fresh scope; there is no
       parent-scope parameter anywhere in the analyzer — correlated
       references therefore fail as "column not found"... 
```

**Note on error quality**: design/05 §5.6 requires correlated
references to be a *specific* error (`0A000`, "correlated subqueries
are not supported"), not a plain 42703. To distinguish the two,
`analyzeSelect` receives an `outerNames :: [Text]` set
(all column/alias names visible in enclosing queries). Resolution
order: current scope first; if not found but the name exists in
`outerNames` → throw `0A000` correlated-subquery error; else `42703`.
The set is names-only (no types), used purely for error quality.

```
  3. WHERE: resolve refs in RPred operands; check:
     - aggregate calls do not appear (grammar already prevents)
     - comparison operand types match (after int-literal -> float
       promotion: an OLit (VInt) compared with a FLOAT64 column is
       rewritten to VFloat)
     - BOOLEAN operands only with OpEq/OpNe
     - subqueries: scalar -> output schema must have exactly 1 column
       (else 21000-family error at analysis time: use 42601? No —
       cardinality of *columns* is static: throw errFeatureNotSupported
       is wrong; use SqlError "21000" with message about column count.
       Row-count cardinality is a runtime check, document 09.)
     - IN subquery: exactly 1 output column, type comparable to the LHS
     - EXISTS: any schema
  4. GROUP BY refs resolve; select items checked against 5.7 rules:
     - rsIsAgg := groupBy non-empty or any SelAgg present
     - if rsIsAgg: every RIColumn item's ref must be in groupBy set,
       else 42803
     - aggregate argument types: SUM/AVG need INT64/FLOAT64 column
       (else 42804); COUNT(*) only for COUNT; MIN/MAX any type
  5. ORDER BY resolution to output indexes:
     - OKOrdinal n -> n-1 (bounds-checked, else 42P10-family: use 42703)
     - OKName t / OKCol (unqualified) matching an output alias or
       output column name -> its index
     - OKCol qualified or non-output column: allowed only if it is a
       grouping/output column — resolution rule: it must identify an
       output column by (slot, ordinal) identity, else error 42703
       "ORDER BY term does not match an output column"
  6. Output schema: name = alias if given, else column name for
     RIColumn, else "?column?"; type per item.
```

### Analysis of DML/DDL

- INSERT: table exists; column list (or full column order) resolves;
  each row's arity matches; literal types match target columns (with
  int→float promotion); string byte length ≤ 1024 (else `22001`).
- UPDATE: assignments target existing columns; RHS column refs must
  be to the target table itself (its single implicit slot); types
  match; WHERE analyzed with the one-slot scope.
- DELETE: WHERE with one-slot scope.
- CREATE TABLE: name not taken (`42P07` — checked again at execution
  under lock), ≥1 column, no duplicate column names (`42701`).
- CREATE INDEX: name not taken; table and column exist.
- BEGIN/COMMIT/ROLLBACK pass through untouched (session layer).

## 7.5 Analyzer outputs for other statements

```haskell
data Analyzed
  = ASelect RSelect
  | AInsert RelId [Int] [[Value]]        -- table, target col ordinals, rows
  | AUpdate RelId [(Int, RAssign)] (Maybe RPred)
  | ADelete RelId (Maybe RPred)
  | ACreateTable CreateTableStmt
  | ACreateIndex CreateIndexStmt
  | ATxnControl Statement                 -- BEGIN/COMMIT/ROLLBACK marker

analyze :: CatalogCache -> Statement -> IO Analyzed
```

`RPred` for UPDATE/DELETE uses a one-slot scope, so its `RColRef`s
have `rcFrom = 0`; the planner/executor treat DML scopes uniformly
with SELECT scopes.
