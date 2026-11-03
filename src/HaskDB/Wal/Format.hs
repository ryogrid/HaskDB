-- | WAL record types and on-disk framing (internal-design/03 §3.1-3.2,
--   design/02 §2.3).  Framing:
--     u32le totalLen                       -- length of bytes after this field
--     u8 tag  u64le txnId  u64le prevTxn  -- header
--     payload (per tag)
--     u32le crc32                          -- over totalLen..payload
--   Deviation from the design/02 table: internal-design/03 (structure
--   authority) has no BTREE_SPLIT payload — splits are logged as page
--   images (§3.7 note); recorded in TODO.md.
module HaskDB.Wal.Format where

import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import Data.Text (Text)
import Data.Text.Encoding (encodeUtf8, decodeUtf8Lenient)
import Data.Word
import HaskDB.Common.Types
import HaskDB.Common.Codec
import HaskDB.Heap.TupleCodec (ColumnDesc(..))

-- ---------------------------------------------------------------------------
-- Record type tags (appending new tags: never renumber existing ones)
-- ---------------------------------------------------------------------------
data WalRecType
  = WTInsertTuple | WTDeleteTuple | WTUpdateTuple
  | WTIndexInsert | WTIndexDelete
  | WTPageImage   | WTAllocPage
  | WTCreateTable | WTCreateIndex
  | WTCommit      | WTabort       | WTCheckpoint
  deriving (Eq, Show)

recTag :: WalRecType -> Word8
recTag WTInsertTuple = 1
recTag WTDeleteTuple = 2
recTag WTUpdateTuple = 3
recTag WTIndexInsert = 4
recTag WTIndexDelete = 5
recTag WTPageImage   = 6
recTag WTAllocPage   = 7
recTag WTCreateTable = 8
recTag WTCreateIndex = 9
recTag WTCommit      = 10
recTag WTabort       = 11
recTag WTCheckpoint  = 12

tagRec :: Word8 -> Maybe WalRecType
tagRec t = go t
  where
    go 1  = Just WTInsertTuple
    go 2  = Just WTDeleteTuple
    go 3  = Just WTUpdateTuple
    go 4  = Just WTIndexInsert
    go 5  = Just WTIndexDelete
    go 6  = Just WTPageImage
    go 7  = Just WTAllocPage
    go 8  = Just WTCreateTable
    go 9  = Just WTCreateIndex
    go 10 = Just WTCommit
    go 11 = Just WTabort
    go 12 = Just WTCheckpoint
    go _  = Nothing

data WalRecord = WalRecord
  { wrType    :: !WalRecType
  , wrTxn     :: !TxnId          -- 0 for CHECKPOINT (not txn-owned)
  , wrPrevTxn :: !LSN            -- previous record of the same txn, 0=first
  , wrPayload :: !WalPayload
  } deriving (Eq, Show)

data WalPayload
  = PInsertTuple  PageId SlotNum BS.ByteString
  | PDeleteTuple  PageId SlotNum BS.ByteString
  | PUpdateTuple  PageId SlotNum BS.ByteString BS.ByteString
  | PIndexInsert  RelId Value RID
  | PIndexDelete  RelId Value RID
  | PPageImage    PageId BS.ByteString
  | PAllocPage    PageId RelId
  | PCreateTable  RelId Text [ColumnDesc]
  | PCreateIndex  RelId Text RelId Int PageId
  | PCommit
  | PAbort
  | PCheckpoint   [(TxnId, LSN)]
  deriving (Show, Eq)

-- | Payload -> record tag (kept together so tags and payloads never
--   drift apart; Txn.Manager's txnAppend uses this).
walRecType :: WalPayload -> WalRecType
walRecType p = case p of
  PInsertTuple{} -> WTInsertTuple
  PDeleteTuple{} -> WTDeleteTuple
  PUpdateTuple{} -> WTUpdateTuple
  PIndexInsert{} -> WTIndexInsert
  PIndexDelete{} -> WTIndexDelete
  PPageImage{}   -> WTPageImage
  PAllocPage{}   -> WTAllocPage
  PCreateTable{} -> WTCreateTable
  PCreateIndex{} -> WTCreateIndex
  PCommit        -> WTCommit
  PAbort         -> WTabort
  PCheckpoint{}  -> WTCheckpoint

-- | Construct a transaction record chained at `prev` (internal/04
--   §4.1: the caller fills wrPrevTxn BEFORE appending; txnAppend is
--   the only place that computes it).
walRecord :: TxnId -> LSN -> WalPayload -> WalRecord
walRecord tid prev p = WalRecord
  { wrType = walRecType p, wrTxn = tid, wrPrevTxn = prev, wrPayload = p }

-- ---------------------------------------------------------------------------
-- Value codec (canonical, tag-prefixed — internal/03 §3.2: index keys are
-- self-describing in the WAL; same numbering as Common.encodeValue)
-- ---------------------------------------------------------------------------
putValue :: Value -> B.Builder
putValue v = putBytes (encodeValue v)

decodeValue :: BS.ByteString -> Either Text Value
decodeValue bs = case runReader valReader bs 0 of
  Left e -> Left e
  Right (v, off)
    | off == BS.length bs -> Right v
    | otherwise           -> Left "wal: leftover bytes in value"

valReader :: Reader Value
valReader = do
  tag <- getW8
  case tag of
    1 -> VInt <$> getI64le
    2 -> VFloat <$> getF64le
    3 -> do
      n <- getW16le
      VText <$> getBytes (fromIntegral n)
    4 -> do
      w <- getW8
      if w == 0 then pure (VBool False)
        else if w == 1 then pure (VBool True)
        else Reader (\_ _ -> Left "wal: bad bool byte")
    _ -> Reader (\_ _ -> Left "wal: unknown value tag")

getF64le :: Reader Double
getF64le = do
  w <- getW64le
  let x = word64ToDouble w
  if isNaN x || isInfinite x
    then Reader (\_ _ -> Left "wal: non-finite float")
    else pure x

-- ---------------------------------------------------------------------------
-- Builders + encodeRecord
-- ---------------------------------------------------------------------------
putPage :: PageId -> B.Builder
putPage = putW32le . fromIntegral

putSlot :: SlotNum -> B.Builder
putSlot n = putW32le (fromIntegral n)

putTextU16 :: Text -> B.Builder
putTextU16 t = putW16le (fromIntegral (BS.length (encodeUtf8 t)))
            <> putBytes (encodeUtf8 t)

decodeTextU16 :: Reader Text
decodeTextU16 = do
  n <- getW16le
  bs <- getBytes (fromIntegral n)
  pure (decodeUtf8Lenient bs)

putColDesc :: ColumnDesc -> B.Builder
putColDesc (ColumnDesc name ty) =
  putTextU16 name <> B.word8 (colTypeTag ty)

colTypeTag :: SqlType -> Word8
colTypeTag TyInt64   = 1
colTypeTag TyFloat64 = 2
colTypeTag TyVarchar = 3
colTypeTag TyBool    = 4

decodeColDesc :: Reader ColumnDesc
decodeColDesc = do
  name <- decodeTextU16
  t <- getW8
  ty <- case typeTagOf t of
          Just ty' -> pure ty'
          Nothing  -> Reader (\_ _ -> Left "wal: unknown type tag")
  pure (ColumnDesc name ty)
  where
    typeTagOf 1 = Just TyInt64
    typeTagOf 2 = Just TyFloat64
    typeTagOf 3 = Just TyVarchar
    typeTagOf 4 = Just TyBool
    typeTagOf _ = Nothing

putRelId :: RelId -> B.Builder
putRelId = putI64le

decodeRelId :: Reader RelId
decodeRelId = getI64le

-- u32-prefixed byte blob
putBlob :: BS.ByteString -> B.Builder
putBlob b = putW32le (fromIntegral (BS.length b)) <> putBytes b

decodeBlob :: Reader BS.ByteString
decodeBlob = do
  n <- getW32le
  if fromIntegral n > maxBlobLen
    then Reader (\_ _ -> Left "wal: implausible blob length")
    else getBytes (fromIntegral n)
  where
    maxBlobLen :: Word32
    maxBlobLen = 1000000   -- PAGE_SIZE*4 upper sanity bound (8192 default)

putRid :: RID -> B.Builder
putRid r = putPage (ridPage r) <> putSlot (ridSlot r)

decodeRid :: Reader RID
decodeRid = do
  p <- getW32le
  s <- getW32le
  pure RID { ridPage = fromIntegral p, ridSlot = fromIntegral s }

payloadBuilder :: WalPayload -> B.Builder
payloadBuilder p = case p of
  PInsertTuple pg sl tb  -> putPage pg <> putSlot sl <> putBlob tb
  PDeleteTuple pg sl bf -> putPage pg <> putSlot sl <> putBlob bf
  PUpdateTuple pg sl bf af
    -> putPage pg <> putSlot sl <> putBlob bf <> putBlob af
  PIndexInsert ix kv rid'
    -> putRelId ix <> putBlob (encodeValue kv) <> putRid rid'
  PIndexDelete ix kv rid'
    -> putRelId ix <> putBlob (encodeValue kv) <> putRid rid'
  PPageImage pg img    -> putPage pg <> putBlob img
  PAllocPage pg rel    -> putPage pg <> putRelId rel
  PCreateTable rel nm cols ->
    putRelId rel <> putTextU16 nm <> putCount (length cols) <> mconcat (map putColDesc cols)
  PCreateIndex rel nm tbl col root ->
    putRelId rel <> putTextU16 nm <> putRelId tbl
      <> putI64le (fromIntegral col) <> putPage root
  PCommit   -> mempty
  PAbort    -> mempty
  PCheckpoint act ->
    putCount (length act) <> mconcat
      [ putW64le t <> putW64le l | (t, l) <- act ]

putCount :: Int -> B.Builder
putCount k = putW16le (fromIntegral k)

-- ---------------------------------------------------------------------------
-- encodeRecord / decodeRecord (internal/03 §3.2)
-- ---------------------------------------------------------------------------
encodeRecord :: WalRecord -> BS.ByteString
encodeRecord rec = buildToBytes (lenField <> body <> crc)
  where
    body = B.word8 (recTag (wrType rec))
        <> putW64le (wrTxn rec)
        <> putW64le (wrPrevTxn rec)
        <> payloadBuilder (wrPayload rec)
    bodyBytes = buildToBytes body
    lenField = putW32le (fromIntegral (BS.length bodyBytes))
    crc = putW32le (fromIntegral (crc32 (buildToBytes (lenField <> body))))

-- decode at an offset; Left = end-of-valid-WAL (design/02 §2.6)
decodeRecord :: BS.ByteString -> Int -> Either Text (WalRecord, Int)
decodeRecord bs off
  | off + 4 > BS.length bs = Left "wal: no room for length field"
  | otherwise = do
      let lenB = BS.take 4 (BS.drop off bs)
      case runDecode getW32le lenB of
        Left e         -> Left e
        Right totalLen -> decodeBody totalLen
  where
    bodyStart = off + 4
    decodeBody totalLen
      | totalLen < 17 = Left "wal: implausible record length"
      | bodyEnd > BS.length bs = Left "wal: record truncated"
      | otherwise = do
          let crcStored = runDecode getW32le (BS.take 4 (BS.drop bodyEnd bs))
          case crcStored of
            Left e -> Left e
            Right cs
              | cs /= crcCalc -> Left "wal: crc mismatch"
              | otherwise ->
                  case parseBody (BS.take (fromIntegral totalLen)
                                   (BS.drop bodyStart bs)) of
                    Left e          -> Left e
                    Right rec       -> Right (rec, recEnd)
      where
        bodyEnd = bodyStart + fromIntegral totalLen
        recEnd  = bodyEnd + 4
        crcCalc = crc32 (BS.take (bodyEnd - off) (BS.drop off bs))

parseBody :: BS.ByteString -> Either Text WalRecord
parseBody body = case runReader bodyReader body 0 of
  Left e -> Left e
  Right (rec, off)
    | off == BS.length body -> Right rec
    | otherwise -> Left "wal: trailing unparsed bytes in record body"

bodyReader :: Reader WalRecord
bodyReader = do
  tagW <- getW8
  ty <- case tagRec tagW of
          Just t  -> pure t
          Nothing -> Reader (\_ _ -> Left "wal: unknown record tag")
  txn <- getW64le
  prev <- getW64le
  pl <- payloadReaderFor ty
  pure WalRecord { wrType = ty, wrTxn = txn, wrPrevTxn = prev, wrPayload = pl }

payloadReaderFor :: WalRecType -> Reader WalPayload
payloadReaderFor ty = case ty of
  WTInsertTuple -> do
    pg <- getW32le; sl <- getW32le; tb <- decodeBlob
    pure (PInsertTuple (fromIntegral pg) (fromIntegral sl) tb)
  WTDeleteTuple -> do
    pg <- getW32le; sl <- getW32le; bf <- decodeBlob
    pure (PDeleteTuple (fromIntegral pg) (fromIntegral sl) bf)
  WTUpdateTuple -> do
    pg <- getW32le; sl <- getW32le; bf <- decodeBlob; af <- decodeBlob
    pure (PUpdateTuple (fromIntegral pg) (fromIntegral sl) bf af)
  WTIndexInsert -> do
    ix <- decodeRelId; kb <- decodeBlob; rid' <- decodeRid
    kv <- case decodeValue kb of
            Left e  -> Reader (\_ _ -> Left e)
            Right v -> pure v
    pure (PIndexInsert ix kv rid')
  WTIndexDelete -> do
    ix <- decodeRelId; kb <- decodeBlob; rid' <- decodeRid
    kv <- case decodeValue kb of
            Left e  -> Reader (\_ _ -> Left e)
            Right v -> pure v
    pure (PIndexDelete ix kv rid')
  WTPageImage -> do
    pg <- getW32le; img <- decodeBlob
    pure (PPageImage (fromIntegral pg) img)
  WTAllocPage -> do
    pg <- getW32le; rel <- decodeRelId
    pure (PAllocPage (fromIntegral pg) rel)
  WTCreateTable -> do
    rel <- decodeRelId; nm <- decodeTextU16
    n <- getW16le
    cols <- mapM (const decodeColDesc) [1 .. (fromIntegral n :: Int)]
    pure (PCreateTable rel nm cols)
  WTCreateIndex -> do
    rel <- decodeRelId; nm <- decodeTextU16
    tbl <- decodeRelId; col <- getI64le; root <- getW32le
    pure (PCreateIndex rel nm tbl (fromIntegral col) (fromIntegral root))
  WTCommit      -> pure PCommit
  WTabort       -> pure PAbort
  WTCheckpoint  -> do
    n <- getW16le
    pairs <- mapM (const (do t <- getW64le; l <- getW64le; pure (t, l)))
                  [1 .. (fromIntegral n :: Int)]
    pure (PCheckpoint pairs)
