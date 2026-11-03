-- | Little-endian byte codecs over strict 'ByteString' and CRC-32 (IEEE).
--   Refines internal-design/00 §0.6.  Disk formats are little-endian;
--   the wire protocol has its own big-endian codec (Server.Wire).
module HaskDB.Common.Codec where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as L
import Data.Text (Text)
import Data.Int
import Data.Word

import Data.Array (Array, listArray, (!))
import Data.Bits (xor, shiftR, shiftL, complement, (.&.))

-- ---------------------------------------------------------------------------
-- Reading: small hand-rolled reader (internal/00 §0.6)
--   Reader a ~ ByteString -> offset -> Either Text (a, next-offset)
-- ---------------------------------------------------------------------------
newtype Reader a = Reader { runReader :: BS.ByteString -> Int -> Either Text (a, Int) }

instance Functor Reader where
  fmap f (Reader g) = Reader (\bs off -> case g bs off of
    Right (x, n) -> Right (f x, n)
    Left e       -> Left e)

instance Applicative Reader where
  pure x = Reader (\_ off -> Right (x, off))
  Reader f <*> Reader g = Reader (\bs off -> do
    (x, off1) <- f bs off
    (y, off2) <- g bs off1
    pure (x y, off2))

instance Monad Reader where
  return = pure
  Reader g >>= k = Reader (\bs off -> do
    (x, off1) <- g bs off
    runReader (k x) bs off1)

-- n must be <= 8 (Word64 width); larger widths would silently wrap in
-- shiftL, hence the explicit guard (no bare error: returns Left).
leOf :: Int -> Reader Word64
leOf n = Reader (\bs off ->
  if n > 8
    then Left "codec: leOf width > 8"
  else if off + n <= BS.length bs
    then
      let bytes = [ fromIntegral @Word8 @Word64 (BS.index bs (off + i))
                  | i <- [0 .. n - 1] ]
          val = sum [ b `shiftL` (8 * i) | (i, b) <- zip [0 ..] bytes ]
      in  Right (val, off + n)
    else Left "codec: unexpected end of input")

getBytesAt :: Int -> Reader BS.ByteString
getBytesAt n = Reader (\bs off ->
  if off + n <= BS.length bs
    then Right (BS.take n (BS.drop off bs), off + n)
    else Left "codec: unexpected end of input")

-- Primitives required by internal/00 §0.6:
getW8 :: Reader Word8
getW8 = leOf 1 >>= \w -> pure (fromIntegral @Word64 @Word8 w)

getW16le :: Reader Word16
getW16le = leOf 2 >>= \w -> pure (fromIntegral @Word64 @Word16 w)

getW32le :: Reader Word32
getW32le = leOf 4 >>= \w -> pure (fromIntegral @Word64 @Word32 w)

getW64le :: Reader Word64
getW64le = leOf 8

getI64le :: Reader Int64
getI64le = leOf 8 >>= \w -> pure (fromIntegral @Word64 @Int64 w)

getBytes :: Int -> Reader BS.ByteString
getBytes = getBytesAt

getRemaining :: Reader BS.ByteString
getRemaining = Reader (\bs off -> Right (BS.drop off bs, BS.length bs))

runDecode :: Reader a -> BS.ByteString -> Either Text a
runDecode r bs = case runReader r bs 0 of
  Right (x, _) -> Right x
  Left e       -> Left e

-- ---------------------------------------------------------------------------
-- Writing: Builder helpers (internal/00 §0.6)
-- ---------------------------------------------------------------------------
putW8 :: Word8 -> B.Builder
putW8 = B.word8

-- The codec API keeps one numeric domain (Word64) for the putters; callers
-- convert.  All little-endian.
putW16le, putW32le, putW64le :: Word64 -> B.Builder
putW16le w = B.word16LE (fromIntegral @Word64 @Word16 w)
putW32le w = B.word32LE (fromIntegral @Word64 @Word32 w)
putW64le = B.word64LE

putI64le :: Int64 -> B.Builder
putI64le = B.int64LE

putBytes :: BS.ByteString -> B.Builder
putBytes = B.byteString

buildToBytes :: B.Builder -> BS.ByteString
buildToBytes = L.toStrict . B.toLazyByteString

-- ---------------------------------------------------------------------------
-- CRC-32 (IEEE, reflected, table-driven)
-- ---------------------------------------------------------------------------
crcPoly :: Word32
crcPoly = 0xEDB88320

crcTable :: Array Word8 Word32
crcTable = listArray (0, 255) (map mkEntry [0 .. 255])
  where
    mkEntry k = iterate step k !! 8
    step c = if c .&. 1 == 1 then shiftR c 1 `xor` crcPoly else shiftR c 1

crc32 :: BS.ByteString -> Word32
crc32 bs = complement (BS.foldl' upd 0xFFFFFFFF bs)
  where
    -- standard reflected CRC-32: crc' = (crc >> 8) ^ table[(crc ^ b) & 0xff]
    upd acc byte =
      let idx = fromIntegral @Word32 @Word8 (acc .&. 0xFF) `xor` byte
      in  shiftR acc 8 `xor` (crcTable ! idx)
