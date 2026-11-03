-- | Core identifiers, SQL types and values.
--   Refines internal-design/00 §0.2 and design/05 §5.3-5.4.
module HaskDB.Common.Types where

import qualified Data.ByteString as BS
import Data.Int
import Data.Word
import Data.Bits (shiftR)
import Data.Binary.Get (runGet, getWord64be, getDoublebe)
import Data.Binary.Put (runPut, putWord64be, putDoublebe)

-- ---------------------------------------------------------------------------
-- Identifiers (internal/00 §0.2)
-- ---------------------------------------------------------------------------
type PageId  = Word32          -- page number in the data file
type LSN     = Word64          -- byte offset of a WAL record in the WAL file
type TxnId   = Word64          -- 0 = invalid / none
type RelId   = Int64           -- catalog relation id
type SlotNum = Int             -- slot index within a page (0-based)

data RID = RID { ridPage :: !PageId, ridSlot :: !SlotNum }
  deriving (Eq, Ord, Show)

-- ---------------------------------------------------------------------------
-- Types and OIDs
-- ---------------------------------------------------------------------------
data SqlType = TyInt64 | TyFloat64 | TyVarchar | TyBool
  deriving (Eq, Show)

-- PostgreSQL wire type OID (design/05 §5.3)
typeOid :: SqlType -> Word32
typeOid TyInt64   = 20     -- int8
typeOid TyFloat64 = 701    -- float8
typeOid TyVarchar = 1043   -- varchar
typeOid TyBool    = 16     -- bool

-- ---------------------------------------------------------------------------
-- Values and tuples
-- ---------------------------------------------------------------------------
data Value
  = VInt   !Int64
  | VFloat !Double
  | VText  !BS.ByteString  -- raw UTF-8 bytes; <= 1024 enforced on write paths
  | VBool  !Bool
  deriving (Eq, Show)

valueType :: Value -> SqlType
valueType (VInt _)   = TyInt64
valueType (VFloat _) = TyFloat64
valueType (VText _)  = TyVarchar
valueType (VBool _)  = TyBool

-- A decoded tuple: one Value per table column, in column order.
type Tuple = [Value]

-- Canonical type tag (internal/05 §5.1: encodeValue starts with a tag byte;
-- same numbering as the catalog atttypid codes, design/06 §6.3).
typeTag :: Value -> Word8
typeTag (VInt _)   = 1
typeTag (VFloat _) = 2
typeTag (VText _)  = 3
typeTag (VBool _)  = 4

-- | IEEE-754 bit pattern of a 'Double'. GHC's 'Double' is IEEE-754 on the
--   supported platform (Ubuntu/x86-64, design/00 §0.2); the round-trip
--   goes through Data.Binary's big-endian bit-pattern codecs.
doubleToWord64 :: Double -> Word64
doubleToWord64 x = runGet getWord64be (runPut (putDoublebe x))

word64ToDouble :: Word64 -> Double
word64ToDouble w = runGet getDoublebe (runPut (putWord64be w))

-- ---------------------------------------------------------------------------
-- Canonical value encoding (internal/00 §0.2)
-- ---------------------------------------------------------------------------
le16 :: Word16 -> BS.ByteString
le16 w = BS.pack [ fromIntegral (shiftR w (8 * i)) | i <- [0 .. 1] ]

le64 :: Word64 -> BS.ByteString
le64 w = BS.pack [ fromIntegral (shiftR w (8 * i)) | i <- [0 .. 7] ]

-- | Canonical byte encoding. Invariant (internal/00 §0.2):
--   @encodeValue a == encodeValue b iff compareSql a b == EQ@.
--   VFloat normalises -0.0 to 0.0 so numeric equality and byte equality
--   agree; NaN cannot occur (design/05 §5.4).
encodeValue :: Value -> BS.ByteString
encodeValue v = case v of
  VInt x   -> BS.cons 1 (le64 (fromIntegral x))
  VFloat x -> BS.cons 2 (le64 (doubleToWord64 (if x == 0 then 0 else x)))
  VText s  -> BS.cons 3 (le16 (fromIntegral (BS.length s)) <> s)
  VBool b  -> BS.cons 4 (BS.singleton (if b then 1 else 0))

-- | SQL comparison semantics (design/05 §5.4).  Callers guarantee equal
--   types; mismatched types fall back to tag order so the function stays
--   pure and total (deviation note: design leaves that case unreachable).
compareSql :: Value -> Value -> Ordering
compareSql a b = case a of
  VInt x   -> case b of
    VInt y   -> compare x y
    _        -> def
  VFloat x -> case b of
    VFloat y -> compare x y
    _        -> def
  VText s  -> case b of
    VText t  -> compare s t        -- byte-wise lexicographic (BS Ord)
    _        -> def
  VBool p  -> case b of
    VBool q  -> compare p q        -- False < True
    _        -> def
  where
    def = compare (typeTag a) (typeTag b)
