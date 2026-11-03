-- | Catalog relation types (internal-design/06 §6.1; design/06 §6.5).
--   Introduced in Phase 3 because the heap operations (internal/01 §1.8)
--   thread a RelationDesc; the catalog heaps, bootstrap, name maps and
--   loading land in Phase 4/6 — deviation recorded in TODO.md.
--   ColumnDesc is defined in Heap.TupleCodec (the import layering note of
--   internal/01 §1.5); consumers import it from there.
module HaskDB.Catalog.Types where

import Data.Text (Text)
import Data.Int
import qualified Data.Map as Map (Map)
import HaskDB.Common.Types
import HaskDB.Heap.TupleCodec (ColumnDesc(..))

data RelKind = RelTable | RelIndex
  deriving (Eq, Show)

-- internal/06 §6.1; rdOwner/rdIdxCol exist for indexes (Phase 5/6)
data RelationDesc = RelationDesc
  { rdId      :: !RelId
  , rdName    :: !Text
  , rdKind    :: !RelKind
  , rdColumns :: ![ColumnDesc]   -- tables only
  , rdPages   :: ![PageId]       -- heap page chain, in order
  , rdRoot    :: !PageId         -- indexes only; 0 for tables
  , rdTuples  :: !Int64
  , rdOwner   :: !RelId          -- indexes: owning table; tables: 0
  , rdIdxCol  :: !Int            -- indexes: 0-based column ordinal; -1 tables
  } deriving (Eq, Show)

-- IndexDesc convenience projection (internal/06 §6.1)
data IndexDesc = IndexDesc
  { ixRelId  :: !RelId, ixName :: !Text, ixTable :: !RelId
  , ixColumn :: !Int, ixKeyType :: !SqlType, ixRoot :: !PageId }
  deriving (Show)

indexDescOf :: RelationDesc -> Maybe IndexDesc
indexDescOf rd
  | rdKind rd == RelIndex =
      Just IndexDesc { ixRelId = rdId rd, ixName = rdName rd
                     , ixTable = rdOwner rd, ixColumn = rdIdxCol rd
                     , ixKeyType = case rdColumns rd of
                         (c : _) -> colType c
                         []      -> TyInt64
                     , ixRoot = rdRoot rd }
  | otherwise = Nothing

sqlTypeToCode :: SqlType -> Int
sqlTypeToCode TyInt64   = 1
sqlTypeToCode TyFloat64 = 2
sqlTypeToCode TyVarchar = 3
sqlTypeToCode TyBool    = 4

codeToSqlType :: Int -> Maybe SqlType
codeToSqlType 1 = Just TyInt64
codeToSqlType 2 = Just TyFloat64
codeToSqlType 3 = Just TyVarchar
codeToSqlType 4 = Just TyBool
codeToSqlType _ = Nothing

-- relation head helpers used by the heap ops (internal/01 §1.8:
-- "relation's page list in order")
relIsTable :: RelationDesc -> Bool
relIsTable rd = rdKind rd == RelTable
