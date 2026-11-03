-- | Tuple codec per schema (internal-design/01 §1.5, design/01 §1.3).
--   ColumnDesc lives here (Catalog.Types re-exports it — import layering:
--   Heap < Catalog).
module HaskDB.Heap.TupleCodec where

import qualified Data.ByteString as BS
import Data.Text (Text)
import Data.Int ()
import Data.Word ()
import HaskDB.Common.Types
import HaskDB.Common.Error (SqlError(..), errTupleTooLarge, errStringTooLong,
  throwSql)
import HaskDB.Common.Codec
import HaskDB.Storage.Page (headerSize, itemSize)

data ColumnDesc = ColumnDesc { colName :: !Text, colType :: !SqlType }
  deriving (Eq, Show)

-- ---------------------------------------------------------------------------
-- Encoding (design/01 §1.3, little-endian)
-- ---------------------------------------------------------------------------
encodeTuple :: [ColumnDesc] -> Tuple -> BS.ByteString
encodeTuple cols tup = buildToBytes $
  putW8 0                            -- flags: bit0 = DELETED-pending (never set by normal writes)
    <> putW8 (fromIntegral (length cols))
    <> putW16le 0                    -- reserved
    <> mconcat (zipWith enc cols tup)
  where
    enc (ColumnDesc _ t) v = case (t, v) of
      (TyInt64, VInt x)     -> putI64le x
      (TyFloat64, VFloat x) -> putW64le (doubleToWord64 x)
      (TyBool, VBool b)     -> putW8 (if b then 1 else 0)
      (TyVarchar, VText s)  -> putW16le (fromIntegral (BS.length s)) <> putBytes s
      _                     -> mempty   -- analyzer guarantees otherwise

-- | Decode, consuming exactly the input (design/01 §1.3: decoding must
--   consume exactly @lp_len@ bytes, or the page is corrupt → XX000).
decodeTuple :: [ColumnDesc] -> BS.ByteString -> Either Text Tuple
decodeTuple cols bs = case runReader decoder bs 0 of
  Left e            -> Left e
  Right (vals, off)
    | off == BS.length bs -> Right vals
    | otherwise           -> Left "tuple decode: leftover bytes (corrupt slot)"
  where
    decoder = do
      flags <- getW8
      natts <- getW8
      resv <- getW16le
      if flags `mod` 2 == 0
        then if fromIntegral natts == length cols && resv == 0
          then mapM decVal cols
          else decodeFail "tuple: header mismatch (corrupt)"
        else mapM decVal cols   -- DELETED-pending tolerated; caller filters
    decVal (ColumnDesc _ t) = case t of
      TyInt64   -> VInt <$> getI64le
      TyFloat64 -> do
        w <- getW64le
        let x = word64ToDouble w
        if isNaN x || isInfinite x
          then decodeFail "tuple decode: non-finite float (corrupt)"
          else pure (VFloat x)
      TyBool -> do
        w <- getW8
        if w == 0 || w == 1 then pure (VBool (w == 1))
          else decodeFail "tuple decode: bad boolean byte (corrupt)"
      TyVarchar -> do
        n <- getW16le
        s <- getBytes (fromIntegral n)
        if n > 1024
          then decodeFail "tuple decode: varchar over limit (corrupt)"
          else pure (VText s)
    decodeFail :: Text -> Reader a
    decodeFail msg = Reader (\_ _ -> Left msg)

-- tupleSize without building the ByteString (internal/01 §1.5).
tupleSize :: [ColumnDesc] -> Tuple -> Int
tupleSize cols tup = 4 + sum (zipWith sz cols tup)
  where
    sz (ColumnDesc _ t) v = case (t, v) of
      (TyInt64, _)         -> 8
      (TyFloat64, _)       -> 8
      (TyBool, _)          -> 1
      (TyVarchar, VText s) -> 2 + BS.length s
      _                    -> 0

-- Largest storable tuple (design/01 §1.3 "Maximum tuple size").
maxTupleBytes :: Int -> Int
maxTupleBytes pageSize = pageSize - headerSize - itemSize - 4

checkInsertable :: Int -> [ColumnDesc] -> Tuple -> Either SqlError ()
checkInsertable pageSize cols tup
  | tupleSize cols tup > maxTupleBytes pageSize = Left errTupleTooLarge
  | any (\v -> case v of VText s -> BS.length s > 1024; _ -> False) tup
      = Left errStringTooLong
  | otherwise = Right ()

checkInsertableIO :: Int -> [ColumnDesc] -> Tuple -> IO ()
checkInsertableIO pageSize cols tup = case checkInsertable pageSize cols tup of
  Left e  -> throwSql (seState e) (seMessage e)
  Right _ -> pure ()
