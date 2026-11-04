-- | Raw SQL AST (internal-design/07 §7.2).  Names unresolved Text; no
--   types attached yet — the analyzer does that.
module HaskDB.Sql.Ast where

import Data.Text (Text)
import HaskDB.Common.Types (Value, SqlType)

data Statement
  = StmtSelect   SelectStmt
  | StmtInsert   InsertStmt
  | StmtUpdate   UpdateStmt
  | StmtDelete   DeleteStmt
  | StmtCreateTable CreateTableStmt
  | StmtCreateIndex CreateIndexStmt
  | StmtCopy        CopyStmt
  | StmtBegin | StmtCommit | StmtRollback
  deriving (Show)

-- | COPY is an EXTENSION of the dialect (design/05 §5.2 has no COPY; the
--   PostgreSQL COPY command is needed for pgbench-style bulk loading —
--   see notes/wire-protocol-psql-pgbench-memo.md §5).  Full column list is
--   the only form: this dialect has no NULL/defaults, so a partial list
--   would be the 0A000 partial-INSERT rule anyway.
data CopyStmt = CopyStmt
  { cpTable     :: Text
  , cpFromStdin :: Bool      -- True = 'from stdin' (load), False = 'to stdout'
  } deriving (Show)

data SelectStmt = SelectStmt
  { selList     :: [SelectItem]
  , selFrom     :: [FromItem]
  , selWhere    :: Maybe Pred
  , selGroupBy  :: [ColRef]
  , selOrderBy  :: [OrderItem]
  } deriving (Show)

data SelectItem
  = SelStar
  | SelColumn ColRef (Maybe Text)
  | SelLiteral Value (Maybe Text)
  | SelAgg AggCall (Maybe Text)
  deriving (Show)

data AggCall = AggCall { aggFn :: AggFn, aggArg :: AggArg } deriving (Show)
data AggFn = AggCount | AggSum | AggAvg | AggMin | AggMax deriving (Eq, Show)
data AggArg = AggStar | AggCol ColRef deriving (Show)

data FromItem
  = FromTable Text (Maybe Text)
  | FromSubquery SelectStmt Text          -- alias mandatory (parser)
  deriving (Show)

data ColRef = ColRef { crQualifier :: Maybe Text, crName :: Text }
  deriving (Eq, Show)

data Pred
  = PAnd Pred Pred | POr Pred Pred | PNot Pred
  | PCmp Operand CmpOp Operand
  | PExists SelectStmt
  | PIn ColRef Bool SelectStmt            -- Bool = negated (NOT IN)
  deriving (Show)

data Operand = OCol ColRef | OLit Value | OScalarSubquery SelectStmt
  deriving (Show)

data CmpOp = OpEq | OpNe | OpLt | OpLe | OpGt | OpGe deriving (Eq, Show)

data OrderItem = OrderItem
  { oiKey :: OrderKey, oiAsc :: Bool } deriving (Show)
data OrderKey = OKCol ColRef | OKOrdinal Int | OKName Text deriving (Show)

data InsertStmt = InsertStmt
  { insTable :: Text, insCols :: Maybe [Text], insRows :: [[Value]] }
  deriving (Show)

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























