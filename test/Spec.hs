-- Phase-0 milestone test: codec round-trips, CRC-32 known vectors,
-- encodeValue/compareSql consistency (design/10 §10.2 Phase 0 milestone).
module Main where

import System.Exit (exitSuccess, exitFailure)
import Data.Word
import qualified Data.ByteString as BS

import HaskDB.Common.Types
import HaskDB.Common.Codec
import HaskDB.Common.Config

check :: String -> Bool -> [String] -> [String]
check name ok errs = if ok then errs else name : errs

main :: IO ()
main = do
  let errs = codecProps ++ crcProps ++ valueProps ++ configProps
  mapM_ putStrLn errs
  if null errs then exitSuccess else exitFailure

-- ---------------------------------------------------------------------------
-- Little-endian codec round-trips
-- ---------------------------------------------------------------------------
codecProps :: [String]
codecProps = concat
  [ check "w8 roundtrip"
      (runDecode getW8 (buildToBytes (putW8 200)) == Right 200) []
  , check "w16le roundtrip"
      (runDecode getW16le (buildToBytes (putW16le 513)) == Right 513) []
  , check "w32le roundtrip"
      (runDecode getW32le (buildToBytes (putW32le 70000)) == Right 70000) []
  , check "w64le roundtrip"
      (runDecode getW64le (buildToBytes (putW64le maxBound))
         == Right (maxBound :: Word64)) []
  , check "i64le roundtrip"
      (runDecode getI64le (buildToBytes (putI64le (-45)))
         == Right (-45)) []
  , check "little-endian byte order of W32"
      (buildToBytes (putW32le 0x12345678) == BS.pack [0x78, 0x56, 0x34, 0x12]) []
  , check "sequence: w16le then bytes"
      (runDecode (do
         a <- getW16le
         b <- getBytes 3
         pure (a, b))
         (buildToBytes (putW16le 258 <> putBytes (BS.pack [9, 8, 7])))
         == Right (258, BS.pack [9, 8, 7])) []
  , check "out of bounds -> Left"
      (case runDecode getW32le (BS.pack [1, 2, 3]) of Left _ -> True; _ -> False) []
  , check "getRemaining"
      (runDecode (do _ <- getW16le; getRemaining)
         (BS.pack [1, 2, 3, 4])
         == Right (BS.pack [3, 4])) []
  ]

-- ---------------------------------------------------------------------------
-- CRC-32 (IEEE reflected) known-answer vectors
-- ---------------------------------------------------------------------------
crcProps :: [String]
crcProps = concat
  [ check "crc32 empty == 0" (crc32 BS.empty == 0) []
  , check "crc32 \"123456789\" == 0xCBF43926"
      (crc32 (BS.pack (map (fromIntegral . fromEnum) "123456789"))
       == 0xCBF43926) []
  , check "crc32 quick fox == 0x414FA339"
      (crc32 (BS.pack (map (fromIntegral . fromEnum)
                "The quick brown fox jumps over the lazy dog"))
       == 0x414FA339) []
  ]

-- ---------------------------------------------------------------------------
-- encodeValue / compareSql consistency and Double bit patterns
-- ---------------------------------------------------------------------------
sampleValues :: [Value]
sampleValues =
  [ VInt 0, VInt (-1), VInt maxBound, VInt (minBound + 1)
  , VFloat 0, VFloat (-0), VFloat 1.5, VFloat (-2.5)
  , VText "", VText "ab", VText "ba", VText "\226\128\157"
  , VBool False, VBool True
  ]

valueProps :: [String]
valueProps = concat
  [ check "encode/compare consistency (all pairs)"
      (all
        (\(x, y) -> (encodeValue x == encodeValue y)
                    == (compareSql x y == EQ))
        [(x, y) | x <- sampleValues, y <- sampleValues])
      []
  , check "doubleToWord64 1.0 == 0x3FF0000000000000"
      (doubleToWord64 1.0 == 0x3FF0000000000000) []
  , check "word64ToDouble roundtrip (1.5)"
      (word64ToDouble (doubleToWord64 1.5) == (1.5 :: Double)) []
  , check "-0.0 normalised"
      (encodeValue (VFloat (-0)) == encodeValue (VFloat 0)) []
  , check "VText length prefix is LE"
      (BS.isPrefixOf (BS.pack [3, 2, 0]) (encodeValue (VText "ab"))) []
  ]

-- ---------------------------------------------------------------------------
-- Config defaults (D-01 8192, D-07 1024, D-08 256MiB, D-11 300s)
-- ---------------------------------------------------------------------------
configProps :: [String]
configProps = concat
  [ check "page size default 8192" (cfgPageSize c == 8192) []
  , check "frames default 1024" (cfgBufferFrames c == 1024) []
  , check "budget default 256MiB" (cfgStmtMemBudget c == 256 * 1024 * 1024) []
  , check "checkpoint 300s" (cfgCheckpointSecs c == 300) []
  , check "port 54329" (cfgPort c == 54329) []
  ]
  where
    c = defaultConfig "/x"
