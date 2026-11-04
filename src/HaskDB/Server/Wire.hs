-- | HaskDB.Server.Wire (internal-design/10 §10.1; design/09 §9.1-9.6): the
--   PostgreSQL frontend/backend protocol codecs.  All protocol integers are
--   BIG-endian, the opposite of the on-disk formats, so this module keeps its
--   own put/get helpers and shares nothing with 'HaskDB.Common.Codec'.
--
--   Deviations from the docs (also in TODO.md):
--   * the design docs name the messages but never their protocol LETTERS or
--     field order: those follow the PostgreSQL 18.3 protocol reference (the
--     client binaries in the reference source tree require it — see
--     @notes/wire-protocol-psql-pgbench-memo.md@).  In RowDescription the
--     column name is a NUL-terminated String with no length prefix (18.x);
--   * 'SPStartup' carries the protocol version, which the docs' type omits:
--     the §9.2 handshake is version-dependent, and a client asking for a
--     minor above the baseline answers with 'NegotiateProtocolVersion'
--     (supplementary; keeps a PG-19-beta client from hanging);
--   * the COPY statement and its CopyIn/CopyData/CopyDone/CopyFail messages
--     are an EXTENSION — design/09 §9.3's message table has no COPY at all,
--     but pgbench-style bulk loading needs it;
--   * framing answers a 3-way verdict (need-more / bad / message + leftover
--     tail) so a session can buffer partial messages (§10.1).
{-# LANGUAGE LambdaCase, OverloadedStrings, BangPatterns, TupleSections #-}

module HaskDB.Server.Wire where

import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as L
import Data.Text (Text, pack, unpack)
import Data.Text.Encoding (encodeUtf8, decodeUtf8', decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
import Data.Word (Word8, Word32)
import Data.Int (Int16, Int64)
import Data.Char (chr, ord)

import HaskDB.Common.Types (Value(..), SqlType(..), typeOid)
import HaskDB.Common.Error (SqlError(..))

-- | Render a 'Builder' to strict bytes (the module's own big-endian writer).
buildToBytes :: B.Builder -> BS.ByteString
buildToBytes b = L.toStrict (B.toLazyByteString b)

-- | Message-size sanity cap: PostgreSQL's own cap (design/09 §9.7) — a
--   length field outside 4..1GiB closes the connection.
maxMsgLen :: Int
maxMsgLen = 1024 * 1024 * 1024

-- ---------------------------------------------------------------------------
-- Protocol letters (PostgreSQL 18.3; design/09 §9.3 names messages only)
-- ---------------------------------------------------------------------------
qQuery, qTerminate, qSync, qFlush, qCopyDone, qCopyData, qCopyFail,
      qParse, qBind, qDescribe, qExecute, qClose :: Word8
qQuery     = 0x51   -- 'Q' QSimple (simple query protocol)
qTerminate = 0x58   -- 'X'
qSync      = 0x53   -- 'S'
qFlush     = 0x46   -- 'F'
qCopyDone  = 0x63   -- 'c'
qCopyData  = 0x64   -- 'd'
qCopyFail  = 0x66   -- 'f'
qParse     = 0x50   -- extended protocol: out of the baseline (D-05)
qBind      = 0x42
qDescribe  = 0x44
qExecute   = 0x45
qClose     = 0x43

mAuthenticationOk, mParameterStatus, mBackendKeyData, mReadyForQuery,
  mRowDescription, mDataRow, mCommandComplete, mEmptyQueryResponse,
  mError, mNotice, mCopyOut, mCopyIn, mCopyDoneB, mNegotiate :: Word8
mAuthenticationOk   = 0x52   -- 'R'
mParameterStatus    = 0x53   -- 'S'
mBackendKeyData     = 0x4b   -- 'K'
mReadyForQuery      = 0x5a   -- 'Z'
mRowDescription     = 0x54   -- 'T'
mDataRow            = 0x44   -- 'D'
mCommandComplete    = 0x43   -- 'C'
mEmptyQueryResponse = 0x49   -- 'I' (PostgreSQL 18.3: PqMsg_EmptyQueryResponse)
mError              = 0x45   -- 'E'
mNotice             = 0x4e   -- 'N'
mCopyOut            = 0x48   -- 'H'
mCopyIn             = 0x47   -- 'G'
mCopyDoneB          = 0x63   -- 'c'
mNegotiate          = 0x76   -- 'v'

cStartup, cSSL, cGSS, cCancel :: Word32
cStartup = 196608          -- protocol 3.0
cSSL     = 80877103        -- PG_PROTOCOL(1234,5679)
cGSS     = 80877104        -- PG_PROTOCOL(1234,5680)
cCancel  = 80877102        -- PG_PROTOCOL(1234,5678)

-- | Baseline protocol minors: 3.0 .. 3.2 accepted (psql 18.3 asks 3.2).
protoMinorMax :: Word32
protoMinorMax = 2

statusIdle, statusBlock, statusFailed :: Word8
statusIdle   = 0x49   -- 'I'
statusBlock  = 0x54   -- 'T'
statusFailed = 0x45   -- 'E'

-- ---------------------------------------------------------------------------
-- Big-endian primitives
-- ---------------------------------------------------------------------------
be32 :: Word32 -> BS.ByteString
be32 w = buildToBytes (B.word32BE w)

readBE32 :: BS.ByteString -> Int -> Word32
readBE32 b i =
  (fromIntegral (b `BS.index` i)     * 16777216)
    + (fromIntegral (b `BS.index` (i + 1)) * 65536)
    + (fromIntegral (b `BS.index` (i + 2)) * 256)
    +  fromIntegral (b `BS.index` (i + 3))

-- | The self-inclusive span declared by a frame's length field; callers must
--   supply at least 4 bytes.  'Left' = the length is out of range (§9.7).
declaredSpan :: BS.ByteString -> Either Text Int
declaredSpan b
  | l < 4 || l > maxMsgLen = Left "message length out of range"
  | otherwise              = Right l
  where l = fromIntegral (readBE32 b 0) :: Int

-- ---------------------------------------------------------------------------
-- Backend message construction
-- ---------------------------------------------------------------------------
msg :: Word8 -> BS.ByteString -> BS.ByteString
msg t body = BS.cons t (be32 (fromIntegral (4 + BS.length body)) <> body)

nulstr :: Text -> BS.ByteString
nulstr t = encodeUtf8 t <> BS.singleton 0

-- | SSLRequest / GSSENCRequest answer: one byte 'N', no length field
--   (design/09 §9.2: no TLS in the baseline, D-23).
msgCannotUpgradeTLS :: BS.ByteString
msgCannotUpgradeTLS = BS.singleton 0x4e   -- 'N'

msgAuthenticationOk :: BS.ByteString
msgAuthenticationOk = msg mAuthenticationOk (be32 0)

msgParameterStatus :: Text -> Text -> BS.ByteString
msgParameterStatus k v = msg mParameterStatus (nulstr k <> nulstr v)

-- | The startup ParameterStatus set (design/09 §9.2).
startupParams :: [(Text, Text)]
startupParams =
  [ ("server_version", "16.0 (HaskDB)")
  , ("client_encoding", "UTF8")
  , ("server_encoding", "UTF8")
  , ("DateStyle", "ISO, MDY")
  , ("integer_datetimes", "on")
  , ("standard_conforming_strings", "on") ]

msgBackendKeyData :: Word32 -> Word32 -> BS.ByteString
msgBackendKeyData pid secret = msg mBackendKeyData (be32 pid <> be32 secret)

-- | PostgreSQL's own writer (backend_startup.c) sends the NEWEST protocol it
--   speaks (a full PG_PROTOCOL value, e.g. 196610 = 3.2) and then the count of
--   unrecognised options — not the bare minor, which a modern client reads as
--   "newest is 0.2" and rejects.
msgNegotiateProtocolVersion :: BS.ByteString
msgNegotiateProtocolVersion =
  msg mNegotiate (be32 (cStartup + protoMinorMax) <> be32 0)

msgReadyForQuery :: Word8 -> BS.ByteString
msgReadyForQuery st = msg mReadyForQuery (BS.singleton st)

-- | RowDescription (internal/10 §10.8): name, table OID 0, attnum 0, type OID,
--   type length, typmod -1, format code 0.
typeLen :: SqlType -> Int16
typeLen TyInt64   = 8
typeLen TyFloat64 = 8
typeLen TyVarchar = -1
typeLen TyBool    = 1

msgRowDescription :: [(Text, SqlType)] -> BS.ByteString
msgRowDescription cols =
  msg mRowDescription (buildToBytes (
      B.word16BE (fromIntegral (length cols))
      <> mconcat [ B.byteString (nulstr n) <> B.word32BE 0 <> B.int16BE 0
                 <> B.word32BE (typeOid t) <> B.int16BE (typeLen t)
                 <> B.int32BE (-1) <> B.int16BE 0
                 | (n, t) <- cols ]))

-- | Text-format field encodings (design/09 §9.4 + §10.1's float rule; D-16).
fieldText :: Value -> BS.ByteString
fieldText v = case v of
  VInt x   -> buildToBytes (B.intDec (fromIntegral x))
  VFloat d -> floatText d
  VText s  -> s
  VBool b  -> BS.singleton (if b then 116 else 102)   -- 't' / 'f'

floatText :: Double -> BS.ByteString
floatText d = encodeUtf8 (if hasForm s then s else s <> ".0")
  where s = pack (show d)

hasForm :: Text -> Bool
hasForm s = any (`elem` (".eEn" :: String)) (unpack s)

msgDataRow :: [Value] -> BS.ByteString
msgDataRow row =
  msg mDataRow (buildToBytes (
      B.word16BE (fromIntegral (length fields))
      <> mconcat [ B.word32BE (fromIntegral (BS.length f)) <> B.byteString f
                 | f <- fields ]))
  where fields = map fieldText row

msgCommandComplete :: Text -> BS.ByteString
msgCommandComplete tag = msg mCommandComplete (nulstr tag)

msgEmptyQueryResponse :: BS.ByteString
msgEmptyQueryResponse = msg mEmptyQueryResponse BS.empty

-- | Error/Notice: identified fields, then a zero terminator (design/09 §9.6
--   gives S/V/C/M; F/L/P are omitted in the baseline).
--
--   NB the field LETTER is a bare Byte1, NOT a NUL-terminated string: only the
--   VALUE is a String (PostgreSQL 18.3's own writer, @elog.c@'s
--   @pq_sendbyte + err_sendstring@, and libpq's @pqGetc@/@pqGets@ pair agree
--   on this).  Terminating the letter too makes libpq read every field as the
--   empty string, so psql prints "@:  @" and the SQLSTATE accessor is empty.
errField :: Char -> Text -> BS.ByteString
errField c v = BS.singleton (fromIntegral (ord c)) <> nulstr v

msgErrorResponse :: SqlError -> BS.ByteString
msgErrorResponse e =
  msg mError (errField 'S' "ERROR" <> errField 'V' "ERROR"
              <> errField 'C' (seState e)
              <> errField 'M' (seMessage e)
              <> BS.singleton 0)

-- | NoticeResponse.  The SQLSTATE field is emitted only when there is one
--   (PostgreSQL omits fields it has no value for; an empty C field makes
--   clients report the wrong code).
msgNoticeResponse :: Maybe Text -> Text -> BS.ByteString
msgNoticeResponse code m =
  msg mNotice (errField 'S' "NOTICE" <> errField 'V' "NOTICE"
               <> maybe mempty (errField 'C') code <> errField 'M' m
               <> BS.singleton 0)

-- | The format spec both copy responses carry (COPY is our extension: design/09
--   §9.3's message table has none): overall format 0 (text), `Int16 ncol`, then
--   `Int16[ncol]` format codes, all text (D-16).
copyFormBody :: Int -> BS.ByteString
copyFormBody ncol =
  BS.singleton 0 <> buildToBytes (
      B.word16BE (fromIntegral ncol) <> mconcat (replicate ncol (B.int16BE 0)))

msgCopyInResponse :: Int -> BS.ByteString
msgCopyInResponse ncol = msg mCopyIn (copyFormBody ncol)

msgCopyOutResponse :: Int -> BS.ByteString
msgCopyOutResponse ncol = msg mCopyOut (copyFormBody ncol)

msgCopyDone :: BS.ByteString
msgCopyDone = msg mCopyDoneB BS.empty

-- | CopyData on the backend side (COPY OUT payload chunk; the extension).
msgCopyData :: BS.ByteString -> BS.ByteString
msgCopyData chunk = msg qCopyData chunk

-- ---------------------------------------------------------------------------
-- Frontend framing
-- ---------------------------------------------------------------------------
data FrontendMsg
  = FQuery ByteString          -- SQL text, NUL-stripped
  | FTerminate
  | FCopyData ByteString       -- raw COPY IN bytes
  | FCopyDone
  | FCopyFail Text             -- cause
  | FUnknown Word8 Int         -- type byte, body length (body already skipped)

data StartupPacket
  = SPStartup !Word32 [(Text, Text)]   -- deviation: the version is carried
  | SPSSLRequest
  | SPGSSRequest
  | SPCancelRequest !Word32 !Word32

data Verdict
  = Need                         -- wait for more bytes
  | Bad Text                     -- protocol error: close the connection
  | IsStartup StartupPacket BS.ByteString
  | IsFrontend FrontendMsg BS.ByteString

-- | Startup packet: length + code, no type byte (§10.4).
tryGetStartup :: BS.ByteString -> Verdict
tryGetStartup b
  | BS.length b < 4 = Need
  | otherwise = case declaredSpan b of
      Left m  -> Bad m
      Right l
        | BS.length b < l -> Need
        -- a startup frame is u32 length + u32 code, so a declared span of
        --   4..7 cannot address the code field: reading it at offset 4 would
        --   run past the bytes on hand (internal/00 §0.7 — nothing partial may
        --   touch data read from the network).
        | l < 8 -> Bad "startup packet shorter than its length + code fields"
        | otherwise ->
            let code = readBE32 b 4
                rest = BS.drop l b
                body = BS.take (l - 8) (BS.drop 8 b)
            in case code of
                 c | c == cSSL    -> IsStartup SPSSLRequest rest
                   | c == cGSS    -> IsStartup SPGSSRequest rest
                   | c == cCancel -> IsStartup (SPCancelRequest c (field32 b 8)) rest
                   | c >= cStartup && c <= cStartup + protoMinorMax
                         -> IsStartup (SPStartup c (startupParamsOf body)) rest
                   | c > cStartup + protoMinorMax
                       -- a newer client: the session answers
                       -- NegotiateProtocolVersion and then proceeds
                         -> IsStartup (SPStartup c (startupParamsOf body)) rest
                   | otherwise   -> Bad "unsupported startup code"

-- | Frontend message: type byte + length (§10.1).  Unknown types keep their
--   length so the body is skipped (session answers 0A000, §10.3).
tryGetFrontend :: BS.ByteString -> Verdict
tryGetFrontend b
  | BS.null b = Need
  -- Sync ('S') has neither a body nor a length field (extended protocol,
  --   outside the baseline: D-05), so it cannot be length-framed at all.
  | BS.head b == qSync = IsFrontend (FUnknown qSync 0) (BS.drop 1 b)
  | BS.length b < 5 = Need
  | otherwise =
      let t = BS.head b
      in case declaredSpan (BS.drop 1 b) of
           Left m  -> Bad m
           Right l
             | BS.length b < l + 1 -> Need     -- the type byte is extra
             | otherwise ->
                 let body = BS.take (l - 4) (BS.drop 5 b)
                     rest = BS.drop (l + 1) b
                 in case t of
                      c | c == qTerminate -> IsFrontend FTerminate rest
                      c | c == qQuery     -> IsFrontend (FQuery (stripNul body)) rest
                      c | c == qCopyData  -> IsFrontend (FCopyData body) rest
                      c | c == qCopyDone  -> IsFrontend FCopyDone rest
                      c | c == qCopyFail  -> IsFrontend (FCopyFail (textOf body)) rest
                      c                     -> IsFrontend (FUnknown c (l - 4)) rest

-- | Strip one trailing NUL (the QSimple statement string is NUL-terminated).
stripNul :: BS.ByteString -> BS.ByteString
stripNul s
  | not (BS.null s), BS.last s == 0 = BS.init s
  | otherwise                       = s

-- | Total UTF-8 decoding of bytes off the wire (internal/00 §0.7: no partial
--   functions on data read from the network — @decodeUtf8@ throws, which would
--   kill the session instead of answering an error).  @tryText@ refuses
--   invalid bytes so the caller can report a protocol error; @textOf@ is for
--   bytes we only echo into a message or ignore (a startup parameter, a
--   CopyFail cause), where invalid bytes become U+FFFD (logged deviation).
tryText :: BS.ByteString -> Maybe Text
tryText b = case decodeUtf8' b of Right t -> Just t; Left _ -> Nothing

textOf :: BS.ByteString -> Text
textOf = decodeUtf8With lenientDecode . fst . BS.break (== 0)

-- | Startup parameters: NUL-separated name/value pairs plus a final NUL
--   terminator (design/09 §9.2).  Decoded leniently: they are parsed and
--   ignored (§9.2 says unknown parameters are ignored), so a bad byte must
--   not kill the session (internal/00 §0.7's total-decoder rule).
startupParamsOf :: BS.ByteString -> [(Text, Text)]
startupParamsOf b0 = go b0
  where
    go b = case pair b of
      Nothing            -> []
      Just (k, v, b')    -> (decodeUtf8With lenientDecode k
                            , decodeUtf8With lenientDecode v) : go b'
    pair b = case BS.break (== 0) b of
      (x, r)
        | BS.null x   -> Nothing
        | BS.null r   -> Just (x, BS.empty, BS.empty)
        | otherwise   -> case BS.break (== 0) (BS.drop 1 r) of
            (y, r') | BS.null r' -> Just (x, y, BS.empty)
                    | otherwise  -> Just (x, y, BS.drop 1 r')

-- | A field read defensively (0 when absent).
field32 :: BS.ByteString -> Int -> Word32
field32 b i | BS.length b < i + 4 = 0
            | otherwise           = readBE32 b i

-- ---------------------------------------------------------------------------
-- COPY text format (the extension; PostgreSQL COPY text representation)
-- ---------------------------------------------------------------------------
-- | Split accumulated COPY IN bytes into complete lines (newline stripped)
--   and the unconsumed tail.
splitCopyLines :: BS.ByteString -> ([BS.ByteString], BS.ByteString)
splitCopyLines b
  | BS.length b == 0 = ([], BS.empty)
  | otherwise        = case BS.split 10 b of
      []  -> ([], BS.empty)
      ps  -> (init ps, last ps)

-- | Decode one COPY IN line into a tuple for the given column types.  @\\N@
--   becomes the type's zero value (the dialect has no NULL: logged deviation).
--   An arity mismatch is a bad COPY line, so it carries PostgreSQL's
--   bad-copy-file-format code 22P04 (design/09 §9.6 is silent here; logged).
decodeCopyLine :: [SqlType] -> BS.ByteString -> Either SqlError [Value]
decodeCopyLine cols line
  | length fields /= length cols =
      Left (SqlError "22P04"
            ("COPY row has " <> pack (show (length fields))
            <> " fields; the relation has " <> pack (show (length cols))))
  | otherwise = decodeFields (zip cols fields)
  where fields = BS.split 9 line      -- tab-separated

decodeFields :: [(SqlType, BS.ByteString)] -> Either SqlError [Value]
decodeFields [] = Right []
decodeFields ((t, raw) : rest)
  | raw == BS.pack [92, 78] = (zeroOf t :) <$> decodeFields rest
  | otherwise = case unescape raw of
      Left e         -> Left e
      Right s        -> do
        v <- valueOf t s
        (v :) <$> decodeFields rest

zeroOf :: SqlType -> Value
zeroOf TyInt64   = VInt 0
zeroOf TyFloat64 = VFloat 0.0
zeroOf TyVarchar = VText BS.empty
zeroOf TyBool    = VBool False

-- | One COPY text field → Value.  Errors carry a SQLSTATE: design/09 §9.6
--   prescribes 22P02 for a bad literal, 22001 for an over-long VARCHAR and
--   (via 05 §5.3) the same INT64 range rule the SQL literals use, 22003.
--   05 §5.4 forbids Infinity/NaN, so a non-finite parse is a bad literal.
valueOf :: SqlType -> BS.ByteString -> Either SqlError Value
valueOf TyInt64 s = case intOfText (unpack (decodeUtf8With lenientDecode s)) of
  Just n | n >= toInteger (minBound :: Int64)
              && n <= toInteger (maxBound :: Int64) ->
             Right (VInt (fromInteger n))
         | otherwise -> Left (SqlError "22003"
             ("COPY INT64 field out of range: " <> decodeUtf8With lenientDecode s))
  Nothing -> Left (SqlError "22P02"
             ("COPY field is not an INT64 literal: " <> decodeUtf8With lenientDecode s))
valueOf TyFloat64 s = case doubleOfText (unpack (decodeUtf8With lenientDecode s)) of
  Just d | isNaN d || isInfinite d ->
             Left (SqlError "22P02"
               ("COPY FLOAT64 field is not finite: " <> decodeUtf8With lenientDecode s))
         | otherwise -> Right (VFloat d)
  Nothing -> Left (SqlError "22P02"
             ("COPY field is not a FLOAT64 literal: " <> decodeUtf8With lenientDecode s))
valueOf TyVarchar s
  | BS.length s > 1024 = Left (SqlError "22001"
      "COPY VARCHAR field exceeds the 1024-byte limit")
  | otherwise          = Right (VText s)
valueOf TyBool s = case decodeUtf8With lenientDecode s of
  "t" -> Right (VBool True)
  "f" -> Right (VBool False)
  x   -> Left (SqlError "22P02" ("COPY field is not a BOOLEAN literal: " <> x))

-- | Total decimal parser for COPY INT64 fields.
intOfText :: String -> Maybe Integer
intOfText s = case s of
  ('-' : ds) -> negate <$> digits ds
  ('+' : ds) -> digits ds
  ds         -> digits ds
  where
    digits ds
      | not (null ds), all isDecC ds =
          Just (foldl (\a c -> a * 10 + (toInteger (fromEnum c) - 48)) 0 ds)
      | otherwise = Nothing
    isDecC c = c >= '0' && c <= '9'

-- | Total-ish float parser for COPY FLOAT64 fields (reads with a fixed type).
doubleOfText :: String -> Maybe Double
doubleOfText s = case reads s of
  [(d, rest)] | null rest -> Just d
  _                       -> Nothing

-- | Backslash-unescape a COPY text field (PostgreSQL's text escapes).
unescape :: BS.ByteString -> Either SqlError BS.ByteString
unescape b0 = fmap BS.pack (go (BS.unpack b0))
  where
    go [] = Right []
    go (c : cs)
      | c /= 92   = (c :) <$> go cs
      | otherwise = case cs of
          [] -> Left (SqlError "22P04" "COPY field ends with a backslash")
          (d : ds) -> case lookup d simpleEscapes of
              Just e  -> (e :) <$> go ds
              Nothing
                | d >= 48 && d <= 55 -> case octal (d : ds) of
                    Left e             -> Left e
                    Right (n, rest)    -> (n :) <$> go rest
                | otherwise ->
                    Left (SqlError "22P04"
                      ("unknown COPY escape: " <> pack [chr (fromIntegral d)]))

simpleEscapes :: [(Word8, Word8)]
simpleEscapes = [ (110, 10), (116, 9), (98, 8), (102, 12)
                , (114, 13), (118, 11), (92, 92) ]

-- | Read UP TO THREE octal digits (COPY @\\nnn@ escape) and return the bytes
--   that were NOT consumed: folding over the non-digit tail (as an earlier
--   draft did) corrupted the value and swallowed the tail, so a COPY OUT ->
--   COPY IN round trip of a control byte was wrong.
octal :: [Word8] -> Either SqlError (Word8, [Word8])
octal ds0 = case go ds0 (0 :: Int) 0 of
    Nothing        -> Left (SqlError "22P04" "COPY octal escape has no digits")
    Just (n, rest)
      | n > 255    -> Left (SqlError "22P04" "COPY octal escape out of byte range")
      | otherwise  -> Right (fromIntegral n, rest)
  where
    go :: [Word8] -> Int -> Int -> Maybe (Int, [Word8])
    go [] n k         = if k == 0 then Nothing else Just (n, [])
    go (d : ds) n k
      | d >= 48, d <= 55, k < 3 = go ds (n * 8 + fromIntegral (d - 48)) (k + 1)
      | otherwise                = if k == 0 then Nothing else Just (n, d : ds)

-- | Encode one tuple as a COPY OUT text line (tab-separated; the backslash and
--   control bytes escaped so the stream round-trips).
encodeCopyLine :: [Value] -> BS.ByteString
encodeCopyLine row =
  BS.intercalate (BS.singleton 9) (map (escapeText . fieldText) row)

escapeText :: BS.ByteString -> BS.ByteString
escapeText s = BS.pack (concatMap w8 (BS.unpack s))
  where
    w8 c
      | c == 92   = [92, 92]
      | c == 9    = [92, 116]
      | c == 10   = [92, 110]
      | c == 13   = [92, 114]
      | c == 8    = [92, 98]
      | c == 12   = [92, 102]
      | c == 11   = [92, 118]
      | c < 32    = [92] ++ octalDigits c
      | otherwise = [c]

-- | Three-digit octal of a control byte (COPY OUT escaping).
octalDigits :: Word8 -> [Word8]
octalDigits c = [48 + (c `div` 64) `mod` 8, 48 + (c `div` 8) `mod` 8, 48 + c `mod` 8]
