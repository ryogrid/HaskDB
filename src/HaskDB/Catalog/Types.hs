-- | Catalog relation types (internal-design/06 §6.1; design/06 §6.5).
--   Introduced in Phase 3 because the heap operations (internal/01 §1.8)
--   thread a RelationDesc; the catalog heaps, bootstrap, name maps and
--   loading land in Phase 4/6 — deviation recorded in TODO.md.
--   ColumnDesc is defined in Heap.TupleCodec (the import layering note of
--   internal/01 §1.5); consumers import it from there.
module HaskDB.Catalog.Types where

import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8Lenient)
import qualified Data.ByteString as BS
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

-- ---------------------------------------------------------------------------
-- Fixed bootstrap layout (internal/06 §6.2) — constants live in Types so
-- Cache/Bootstrap can share them without an import cycle.
-- ---------------------------------------------------------------------------
classRelId, attrRelId :: RelId
classRelId = 1
attrRelId = 2

classFirstPage, attrFirstPage :: PageId
classFirstPage = 1
attrFirstPage  = 2

page0PayloadOff, page0NextRelOff :: Int
page0PayloadOff = 20
page0NextRelOff = page0PayloadOff + 20

page0Magic :: BS.ByteString
page0Magic = "HDB1"

-- ---------------------------------------------------------------------------
-- Bootstrap relation schemas (design/06 §6.3, internal/06 §6.2).  These
-- live in Catalog.Types (not Bootstrap) so Cache.loadCatalog can use them
-- without importing Bootstrap (which imports Cache) — module-layout
-- deviation recorded in TODO.md.
-- ---------------------------------------------------------------------------
classCols, attrCols :: [ColumnDesc]
classCols = [ ColumnDesc "relid" TyInt64
            , ColumnDesc "relname" TyVarchar
            , ColumnDesc "relkind" TyVarchar
            , ColumnDesc "relpages_head" TyInt64
            , ColumnDesc "relroot" TyInt64
            , ColumnDesc "reltuples" TyInt64
            , ColumnDesc "relowner_table" TyInt64
            , ColumnDesc "relindex_column" TyInt64 ]
attrCols = [ ColumnDesc "attrelid" TyInt64
           , ColumnDesc "attnum" TyInt64
           , ColumnDesc "attname" TyVarchar
           , ColumnDesc "atttypid" TyInt64 ]

classKindText :: RelKind -> Text
classKindText RelTable = "table"
classKindText RelIndex = "index"

kindOfText :: Text -> Maybe RelKind
kindOfText "table" = Just RelTable
kindOfText "index" = Just RelIndex
kindOfText _       = Nothing

-- Deviation (design/06 §6.3): relindex_column is documented as 0-based
-- ordinal with 0 for tables, which clashes with a genuine column-0
-- index; the catalog stores ordinal+1 (0 = not an index).
classTupleOf :: RelationDesc -> Tuple
classTupleOf rd =
  [ VInt (rdId rd)
  , VText (encodeUtf8 (rdName rd))
  , VText (encodeUtf8 (classKindText (rdKind rd)))
  , VInt (case rdPages rd of (p : _) -> fromIntegral p; [] -> 0)
  , VInt (fromIntegral (rdRoot rd))
  , VInt (rdTuples rd)
  , VInt (rdOwner rd)
  , VInt (if rdIdxCol rd >= 0 then fromIntegral (rdIdxCol rd + 1) else 0) ]

classTupleToDesc :: [Value] -> Maybe RelationDesc
classTupleToDesc vs
  | length vs /= 8 = Nothing
  | otherwise =
      case (i 0, t 1, k, i 3, i 4, i 5, i 6, i 7) of
        (Just rid, Just nm, Just kk, Just hd, Just rt, Just tc, Just ow, Just ic) ->
          Just RelationDesc
            { rdId = rid, rdName = nm, rdKind = kk, rdColumns = []
            , rdPages = [ fromIntegral hd | hd /= 0 ]
            , rdRoot = fromIntegral rt, rdTuples = tc
            , rdOwner = ow
            , rdIdxCol = if ic == 0 then (-1) else fromIntegral ic - 1 }
        _ -> Nothing
  where
    k = case drop 2 vs of
          (VText s : _) | kindOfText (decodeUtf8Lenient s) == Just RelIndex -> Just RelIndex
                        | kindOfText (decodeUtf8Lenient s) == Just RelTable -> Just RelTable
          _ -> Nothing
    i n = case vs !! n of
            VInt x -> Just x
            _      -> Nothing
    t n = case vs !! n of
            VText s -> Just (decodeUtf8Lenient s)
            _       -> Nothing

attrTupleOf :: RelId -> [ColumnDesc] -> [Tuple]
attrTupleOf rid cols =
  [ [ VInt rid
    , VInt n
    , VText (encodeUtf8 (colName c))
    , VInt (fromIntegral (sqlTypeToCode (colType c))) ]
  | (n, c) <- zip [1 .. (fromIntegral (length cols) :: Int64)] cols ]
