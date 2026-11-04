-- Phase-7 milestone (design/09 §9.2-9.7 + internal-design/10 §10.2-§10.8):
--   sessions driven over a SCRIPTED in-memory 'Connection' — internal/11
--   §11.3 asks for exactly this ("abstracted so sessions can be tested over
--   pipes, not only sockets").  Checks:
--   * startup handshake, incl. the SSL probe answered with the bare 'N' byte
--     (design/09 §9.2 / D-23: no TLS) then params + BackendKeyData + 'I'
--   * SELECT: RowDescription once (even for an empty result), DataRows, the
--     CommandComplete tag, exactly one ReadyForQuery per query cycle
--   * a multi-statement Query message: ONE ReadyForQuery for the whole cycle
--   * an explicit BEGIN block: ReadyForQuery 'T' inside, 'I' after COMMIT
--   * a FAILED block: the 25P02 gate, the ROLLBACK tag on COMMIT, and that an
--     insert that succeeded EARLIER in the block is rolled back (internal/10
--     §10.7 aborts the block at FAILURE time)
--   * COPY IN: CopyInResponse BEFORE reading input, CopyData chunks split
--     mid-line and mid-message, CopyDone, CommandComplete, rows landed
--   * COPY OUT: CopyOutResponse + CopyData text incl. the '\.' terminator
--   * COPY IN aborted by CopyFail: 22P04 (PostgreSQL's bad-COPY-input
--     code; the tree has no 20F03) and NO partial rows committed
--   * an unknown frontend message: 0A000 then ReadyForQuery (§10.3)
--   * an empty/comment-only query: EmptyQueryResponse
--   * Terminate inside a block: cleanup closes the connection, rolls back
--   * a startup packet carrying psql's real parameters (they are ignored)
--   * COPY IN over an INDEXED relation split across CopyData messages, then a
--     probe through the index (rows after a split must be reachable)
--   * COPY round trip of a control byte through the @\NNN@ octal escape
--   * a failed block: @commit; select …;@ in ONE Query — COMMIT ends the block
--     and the SELECT after it runs (design/09 §9.5's rule is per statement)
--   * COPY inside an explicit BEGIN…COMMIT block (rows land at COMMIT)
{-# LANGUAGE LambdaCase, ScopedTypeVariables, OverloadedStrings, BangPatterns,
             BlockArguments, TupleSections, PatternGuards #-}

module Main (main) where

import Control.Exception (SomeException, try, catch)
import Control.Monad (when, void)
import Data.IORef
import Data.Text (Text, pack)
import Data.Text.Encoding (encodeUtf8)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as L
import Data.Word (Word8, Word32)
import Data.Int (Int64)
import System.Directory (doesDirectoryExist, removeDirectoryRecursive)
import System.Exit (exitFailure)
import GHC.Internal.Conc.Sync (readTVarIO)

import HaskDB.Common.Config (defaultConfig, cfgStmtMemBudget)
import HaskDB.Common.Error (SqlError(seState, seMessage), throwSql)
import HaskDB.Common.Types (Value(VInt, VText), SqlType(TyInt64, TyVarchar))
import HaskDB.Server.Env (Env, envFileMgr, envWalMgr, envControl)
import HaskDB.Server.Control (ControlFile(cfNextTid))
import HaskDB.Server.Wire
import HaskDB.Server.Session (runSession, mixSecret, Connection(..))
import HaskDB.Storage.FileManager (closeDataFile)
import HaskDB.Wal.Manager (closeWalManager)
import HaskDB.Catalog.Cache (CatalogCache, newCatalogCache, lookupByName, indexesOf)
import HaskDB.Catalog.Types (RelationDesc(rdTuples, rdId))
import HaskDB.Catalog.Bootstrap (createDatabase)
import HaskDB.Sql.Parser (parseStatement)
import HaskDB.Sql.Analyzer (analyze)
import HaskDB.Planner.Planner (planStatement)
import HaskDB.Executor.Stmts (newExecCtx, executeStatement)
import HaskDB.Txn.Manager (TxnManager, newTxnManager, withTxnAuto)
import HaskDB.Txn.LockManager (LockManager, newLockManager)

-- ---------------------------------------------------------------------------
-- The scripted connection
-- ---------------------------------------------------------------------------
data Mock = Mock { miChunks :: IORef [ByteString]
                 , moOut   :: IORef B.Builder
                 , mclosed :: IORef Bool }

newMock :: [ByteString] -> IO Mock
newMock chunks = do
  q <- newIORef chunks
  o <- newIORef mempty
  c <- newIORef False
  pure Mock { miChunks = q, moOut = o, mclosed = c }

mockConnection :: Mock -> Connection
mockConnection m = Connection
  { connRecv = \n -> do
      q <- readIORef (miChunks m)
      case q of
        [] -> pure BS.empty                     -- EOF ends the session
        (chunk : cs)
          | BS.length chunk <= n -> writeIORef (miChunks m) cs >> pure chunk
          | otherwise -> writeIORef (miChunks m) (BS.drop n chunk : cs)
                          >> pure (BS.take n chunk)
  , connSend = \bs -> modifyIORef' (moOut m) (<> B.byteString bs)
  , connClose = writeIORef (mclosed m) True
  }

-- | Run one scripted session; the collected output is the backend stream.
--   A session thread that dies is reported as a failed run (a check failure),
--   never as an exception out of the suite.
runScripted :: Env -> CatalogCache -> TxnManager -> LockManager
            -> [ByteString] -> Word32 -> IO (ByteString, Bool, Bool)
runScripted env cache tm lm chunks pid = do
  m <- newMock chunks
  r <- try (runSession env cache tm lm (mockConnection m) pid)
         :: IO (Either SomeException ())
  ob <- readIORef (moOut m)
  closed <- readIORef (mclosed m)
  pure (L.toStrict (B.toLazyByteString ob), closed,
        case r of Left _ -> False; Right _ -> True)

-- ---------------------------------------------------------------------------
-- Decoding the collected backend stream
-- ---------------------------------------------------------------------------
decodeBackend :: ByteString -> [(Word8, ByteString)]
decodeBackend b = case BS.uncons b of
  Nothing -> []
  Just (t, rest)
    | t == tlsByte && not (validFrame rest) -> (t, BS.empty) : decodeBackend rest
    | otherwise ->
        let l = fromIntegral (readBE32 rest 0) :: Int
            body = BS.take (l - 4) (BS.drop 4 rest)   -- length covers itself, not the type byte
        in (t, body) : decodeBackend (BS.drop l rest)

tlsByte :: Word8
tlsByte = BS.head msgCannotUpgradeTLS

validFrame :: ByteString -> Bool
validFrame b
  | BS.length b < 4 = False
  | otherwise = let l = fromIntegral (readBE32 b 0) :: Int
                in l >= 4 && l <= maxMsgLen

letters :: [(Word8, ByteString)] -> [Word8]
letters = map fst

-- | The handshake letter pattern for a session with pid 'pid'.
handshakeLetters :: [Word8]
handshakeLetters = [mAuthenticationOk]
                ++ replicate (length startupParams) mParameterStatus
                ++ [mBackendKeyData, mReadyForQuery]

-- | Expected letters of a whole session (handshake + the rest).
expectLetters :: [(Word8, ByteString)] -> [Word8] -> Bool
expectLetters got rest = letters got == handshakeLetters ++ rest

hasMsg :: [(Word8, ByteString)] -> ByteString -> Bool
hasMsg got m = pairOf m `elem` got

-- | How many messages are exactly this one (all three INSERT fixtures share
--   the "INSERT 0 1" tag, so counting is what distinguishes the skip).
countMsg :: [(Word8, ByteString)] -> ByteString -> Int
countMsg got m = length (filter (== pairOf m) got)

-- | The (letter, body) pair of a whole backend message as built by Wire's
--   builders: type byte, then Int32 length (which covers itself, not the type
--   byte), then the body.
pairOf :: ByteString -> (Word8, ByteString)
pairOf m = (BS.head m, BS.drop 5 m)

rfqStatus :: [(Word8, ByteString)] -> [Word8]
rfqStatus = map BS.head . payloadsOf mReadyForQuery

payloadsOf :: Word8 -> [(Word8, ByteString)] -> [ByteString]
payloadsOf t ms = [b | (t', b) <- ms, t' == t]

lastRfq :: [(Word8, ByteString)] -> Word8
lastRfq ms = case rfqStatus ms of
  [] -> 0
  ss -> goLast ss
  where
    goLast [] = 0
    goLast (x : []) = x
    goLast (_ : xs) = goLast xs

countRfq :: [(Word8, ByteString)] -> Int
countRfq ms = length (rfqStatus ms)

hasInfixOf :: Word8 -> ByteString -> [(Word8, ByteString)] -> Bool
hasInfixOf t needle ms = any (\(t', b') -> t' == t && BS.isInfixOf needle b') ms

errCodeIn :: Text -> [(Word8, ByteString)] -> Bool
errCodeIn code ms = any (\(t, b) -> t == mError &&
                             BS.isInfixOf (encodeUtf8 code) b) ms

-- ---------------------------------------------------------------------------
-- Client-side encoding
-- ---------------------------------------------------------------------------
startupPacket :: ByteString
startupPacket = be32 8 <> be32 cStartup

-- | design/09 §9.2's real startup body: each parameter is one NUL-terminated
--   @name=value@ string (PostgreSQL sends @PROTOCOL=3@ @RESTART=yes@ @DIR=@
--   this way) and the list ends with an extra NUL terminator.
startupPacketParams :: ByteString
startupPacketParams =
  be32 (fromIntegral (8 + BS.length body)) <> be32 cStartup <> body
  where body = "user=psql" <> BS.singleton 0
                    <> "database=haskdb" <> BS.singleton 0
                    <> BS.singleton 0

sslProbe :: ByteString
sslProbe = be32 8 <> be32 cSSL

feQuery :: Text -> ByteString
feQuery sql = msg qQuery (encodeUtf8 sql <> BS.singleton 0)

feTerminate :: ByteString
feTerminate = msg qTerminate BS.empty

feCopyData :: ByteString -> ByteString
feCopyData bs = msg qCopyData bs

feCopyDone :: ByteString
feCopyDone = msg qCopyDone BS.empty

feCopyFail :: Text -> ByteString
feCopyFail why = msg qCopyFail (encodeUtf8 why)

feUnknownPrepare :: ByteString
feUnknownPrepare = msg qParse (BS.replicate 8 0)

-- ---------------------------------------------------------------------------
-- In-process fixtures (the pipeline, outside the wire layer)
-- ---------------------------------------------------------------------------
sqlBytes :: Text -> ByteString
sqlBytes = encodeUtf8

setupSql :: Env -> TxnManager -> LockManager -> CatalogCache -> Text -> IO Bool
setupSql env tm lm cache src = do
  let action ctx = do
        ec <- newExecCtx env cache ctx
        case parseStatement (sqlBytes src) of
          Left e -> throwSql (seState e) (seMessage e)
          Right st -> do
            a <- analyze cache st
            p <- planStatement cache a
            void (executeStatement ec p (\_ -> pure ()))
        pure True
  r <- withTxnAuto tm lm env action `catch` \(_e :: SqlError) -> pure False
  pure r

tuplesOf :: CatalogCache -> Text -> IO Int64
tuplesOf cache nm = do
  mrd <- lookupByName cache nm
  case mrd of
    Nothing -> pure (-1)
    Just rd -> pure (rdTuples rd)

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------
acctCols :: [(Text, SqlType)]
acctCols = [("n", TyInt64), ("b", TyInt64)]

createAcct, createEmpty, insertOne, insertTwo, insertThree, selectAll,
  selectEmpty, countAll :: Text
createAcct = "create table acct (n int64, b int64)"
createEmpty = "create table emptyt (x int64)"
insertOne  = "insert into acct (n, b) values (1, 10)"
insertTwo  = "insert into acct (n, b) values (2, 20)"
insertThree = "insert into acct (n, b) values (3, 30)"
selectAll   = "select n, b from acct"
selectEmpty = "select x from emptyt"
countAll   = "select count(n) from acct"

copyInSql, copyOutSql :: Text
copyInSql  = "copy acct from stdin"
copyOutSql = "copy acct to stdout"

-- the indexed + varchar fixtures (see scenarios 12/13)
createIdxTable, createIdx, copyIxSql, selectIxProbe :: Text
createIdxTable = "create table ixt (k int64, v int64)"
createIdx      = "create index ixk on ixt (k)"
copyIxSql      = "copy ixt from stdin"
selectIxProbe  = "select v from ixt where k = 7"

createVtTable, copyVtSql, copyVtOutSql, selectVt :: Text
createVtTable = "create table vt (a int64, s varchar)"
copyVtSql     = "copy vt from stdin"
copyVtOutSql  = "copy vt to stdout"
selectVt      = "select a, s from vt"

-- one row: a = 1, s = bytes 01 41 written as the octal escape \001 then 'A'
vtOctalRow :: ByteString
vtOctalRow = BS.pack ([49, 9, 92, 48, 48, 49, 65] ++ [10])

copyTerm :: ByteString
copyTerm = BS.pack [92, 46, 10]             -- "\.\n"

-- ---------------------------------------------------------------------------
-- Scenarios
-- ---------------------------------------------------------------------------
scenario :: Env -> CatalogCache -> TxnManager -> LockManager -> IO [Check]
scenario env cache tm lm = do
  -- 1: the SSL probe and the startup packet in ONE read; SELECT afterwards.
  (out1, _, ok1) <- runScripted env cache tm lm
    [sslProbe <> startupPacket, feQuery selectAll, feTerminate] 11
  let m1 = decodeBackend (BS.drop (BS.length msgCannotUpgradeTLS) out1)
  r1a <- pure (chk "tls probe answered with the bare 'N' byte"
                 (msgCannotUpgradeTLS `BS.isPrefixOf` out1 && ok1))
  r1b <- pure (chk "handshake letters R S..K Z"
                 (take (length handshakeLetters) (letters m1) ==
                      handshakeLetters))
  r1c <- pure (chk "BackendKeyData carries the pid and its secret"
                 (hasMsg m1 (msgBackendKeyData 11 (mixSecret 11))))
  r1d <- pure (chk "select over one row: T D C Z after the handshake"
                 (expectLetters m1 [mRowDescription, mDataRow,
                                     mCommandComplete, mReadyForQuery]))
  r1e <- pure (chk "select: RowDescription + DataRow bytes are exact"
                 (hasMsg m1 (msgRowDescription acctCols) &&
                  hasMsg m1 (msgDataRow [VInt 1, VInt 10])))

  -- 2: an empty result still gets a RowDescription (a second, empty table)
  (out2, _, ok2) <- runScripted env cache tm lm
    [startupPacket, feQuery selectEmpty, feTerminate] 12
  let m2 = decodeBackend out2
  n2 <- tuplesOf cache "emptyt"
  r2a <- pure (chk "empty result still sends RowDescription"
                 (ok2 && n2 == 0 && hasMsg m2 (msgRowDescription [("x", TyInt64)])))
  r2b <- pure (chk "empty result: T C Z (no DataRow)"
                 (expectLetters m2 [mRowDescription, mCommandComplete,
                                     mReadyForQuery]))

  -- 3: multi-statement Query + COPY IN with chunks split mid-line/message
  okSetup <- setupSql env tm lm cache insertOne
  n3pre <- tuplesOf cache "acct"
  (out3, _, _) <- runScripted env cache tm lm
    [ startupPacket
    , feQuery (countAll <> "; " <> copyInSql)
    , feCopyData "3\t3"
    , feCopyData "0\n4\t4"
    , feCopyData "0\n5\t5"
    , feCopyData "0\n6\t60\n"
    , feCopyData copyTerm
    , feCopyDone
    , feTerminate ] 13
  let m3 = decodeBackend out3
  n3post <- tuplesOf cache "acct"
  r3a <- pure (chk "fixture insert landed (n3pre = 2)"
                 (okSetup && n3pre == 2))
  r3b <- pure (chk "COPY IN: letters T D C G C Z (no CopyDone on copy-in)"
                 (expectLetters m3 [mRowDescription, mDataRow,
                     mCommandComplete, mCopyIn, mCommandComplete,
                     mReadyForQuery]))
  r3c <- pure (chk "COPY IN: CopyInResponse before any input read"
                 (m3 /= [] && pairOf (msgCopyInResponse 2) `elem` m3))
  r3d <- pure (chk "COPY IN: CopyDone then COPY tag with the row count"
                 (hasMsg m3 (msgCommandComplete ("COPY " <> pack (show (4 :: Int))))))
  r3e <- pure (chk "COPY IN: the four rows landed through runInsert"
                 (n3post - n3pre == 4))
  r3f <- pure (chk "COPY IN: one ReadyForQuery for the whole cycle"
                 (countRfq m3 == 2))

  -- 4: COPY OUT
  (out4, _, _) <- runScripted env cache tm lm
    [startupPacket, feQuery copyOutSql, feTerminate] 14
  let m4 = decodeBackend out4
  n4 <- tuplesOf cache "acct"
  r4a <- pure (chk "COPY OUT: CopyOutResponse right after the handshake"
                 (letterAt (length handshakeLetters) m4 == Just mCopyOut &&
                  expectSuffix m4 [qCopyData, mCopyDoneB, mCommandComplete,
                    mReadyForQuery]))
  r4b <- pure (chk "COPY OUT: the terminator line is in a CopyData"
                 (hasInfixOf qCopyData copyTerm m4))
  r4c <- pure (chk "COPY OUT: COPY tag counts the whole relation"
                 (hasMsg m4 (msgCommandComplete ("COPY " <> pack (show n4)))))

  -- 5: COPY IN aborted by CopyFail
  n5pre <- tuplesOf cache "acct"
  (out5, _, _) <- runScripted env cache tm lm
    [ startupPacket, feQuery copyInSql, feCopyData "99\t99\n"
    , feCopyFail "client gave up", feTerminate ] 15
  let m5 = decodeBackend out5
  n5post <- tuplesOf cache "acct"
  r5a <- pure (chk "COPY FAIL: the error is 22P04 (bad COPY input)" (errCodeIn "22P04" m5))
  r5b <- pure (chk "COPY FAIL: no partial rows committed" (n5post == n5pre))

  -- 6: explicit BEGIN block
  n6pre <- tuplesOf cache "acct"
  (out6, _, _) <- runScripted env cache tm lm
    [ startupPacket, feQuery "begin", feQuery insertTwo
    , feQuery countAll, feQuery "commit", feTerminate ] 16
  let m6 = decodeBackend out6
  n6post <- tuplesOf cache "acct"
  r6a <- pure (chk "block: BEGIN tag, ReadyForQuery 'T' inside"
                 (hasMsg m6 (msgCommandComplete "BEGIN") &&
                  any (== statusBlock) (rfqStatus m6)))
  r6b <- pure (chk "block: the insert is visible inside the block"
                 (hasMsg m6 (msgDataRow [VInt (n6pre + 1)])))
  r6c <- pure (chk "block: COMMIT tag then ReadyForQuery 'I'"
                 (hasMsg m6 (msgCommandComplete "COMMIT") &&
                  lastRfq m6 == statusIdle))
  r6d <- pure (chk "block: the insert committed" (n6post == n6pre + 1))

  -- 7: failed block (one Query message: begin, good insert, bad insert,
  --    another insert).  The bad one aborts the WHOLE block.
  n7pre <- tuplesOf cache "acct"
  (out7, _, _) <- runScripted env cache tm lm
    [ startupPacket
    , feQuery ("begin; " <> insertOne <> "; insert into nomissing (n) values (1); "
               <> insertTwo)
    , feQuery insertThree
    , feQuery "commit"
    , feTerminate ] 17
  let m7 = decodeBackend out7
  n7post <- tuplesOf cache "acct"
  r7a <- pure (chk "failed block: the failure itself is reported"
                 (countErr m7 >= 1))
  r7b <- pure (chk "failed block: statements after the failure are skipped"
                 (countMsg m7 (msgCommandComplete "INSERT 0 1") == 1))
  r7c <- pure (chk "failed block: ReadyForQuery 'E' after the failure"
                 (any (== statusFailed) (rfqStatus m7)))
  r7d <- pure (chk "failed block: the next query answers 25P02"
                 (errCodeIn "25P02" m7))
  r7e <- pure (chk "failed block: COMMIT prints the ROLLBACK tag"
                 (hasMsg m7 (msgCommandComplete "ROLLBACK") &&
                  lastRfq m7 == statusIdle))
  r7f <- pure (chk "failed block: the earlier insert is rolled back"
                 (n7post == n7pre))

  -- 8: unknown frontend message and an empty query
  (out8, _, _) <- runScripted env cache tm lm
    [ startupPacket, feUnknownPrepare
    , feQuery "  ; -- only a comment"
    , feTerminate ] 18
  let m8 = decodeBackend out8
  r8a <- pure (chk "unknown message: 0A000 then ReadyForQuery 'I'"
                 (errCodeIn "0A000" m8 && lastRfq m8 == statusIdle &&
                  countRfq m8 == 3))
  r8b <- pure (chk "empty query: EmptyQueryResponse 'i'"
                 (mEmptyQueryResponse `elem` letters m8))

  -- 9: Terminate inside an open block
  n9pre <- tuplesOf cache "acct"
  (_, cl9, ok9) <- runScripted env cache tm lm
    [ startupPacket, feQuery "begin", feQuery insertTwo, feTerminate ] 19
  n9post <- tuplesOf cache "acct"
  r9a <- pure (chk "terminate: cleanup closed the connection" (cl9 && ok9))
  r9b <- pure (chk "terminate: the open block is rolled back" (n9post == n9pre))

  -- 10: scenario 2's script delivered in tiny chunks (partial frames)
  script10 <- pure (smallChunks [startupPacket, feQuery selectEmpty, feTerminate])
  (out10, _, ok10) <- runScripted env cache tm lm script10 20
  let m10 = decodeBackend out10
  r10a <- pure (chk "partial frames: the same message stream"
                 (ok10 && letters m10 == letters m2))

  -- 11: a startup packet that carries real client parameters
  --     (design/09 §9.2: NUL-separated pairs + a final NUL terminator).  They
  --     are parsed and ignored, so the handshake must be IDENTICAL.
  (out11, _, ok11) <- runScripted env cache tm lm
    [startupPacketParams, feQuery selectEmpty, feTerminate] 21
  let m11 = decodeBackend out11
  r11a <- pure (chk "startup params: parsed and ignored, handshake unchanged"
                 (ok11 && expectLetters m11
                    [mRowDescription, mCommandComplete, mReadyForQuery]))
  r11b <- pure (chk "startup params: the extra packet did not desync the stream"
                 (letters m11 == letters m2))

  -- 12: COPY IN over an INDEXED relation, with the row stream split across
  --     CopyData messages.  A later chunk used to re-seed the index roots
  --     from the catalog (whose staged root only lands at COMMIT), so rows
  --     inserted after a split were unreachable through the index; the
  --     Executor keeps the root cell for the whole statement now (ecRoots).
  idxRegistered <- do
    mrd <- lookupByName cache "ixt"
    case mrd of
      Nothing -> pure False
      Just rd -> do
        ixs <- indexesOf cache (rdId rd)
        pure (not (null ixs))
  n12pre <- tuplesOf cache "ixt"
  (out12, _, ok12) <- runScripted env cache tm lm
    [ startupPacket, feQuery copyIxSql
    , feCopyData "1\t1"
    , feCopyData "0\n2\t2"
    , feCopyData "0\n3\t3"
    , feCopyData "0\n4\t4"
    , feCopyData "0\n5\t5"
    , feCopyData "0\n6\t6"
    , feCopyData "0\n7\t7"
    , feCopyData "0\n8\t8"
    , feCopyData "0\n"
    , feCopyData copyTerm
    , feCopyDone
    , feQuery selectIxProbe
    , feTerminate ] 22
  let m12 = decodeBackend out12
  n12post <- tuplesOf cache "ixt"
  r12a <- pure (chk "indexed COPY IN: the fixture relation is indexed and empty"
                 (idxRegistered && n12pre == 0))
  r12b <- pure (chk "indexed COPY IN: eight rows landed"
                 (ok12 && n12post - n12pre == 8))
  r12c <- pure (chk "indexed COPY IN: a row after a chunk split is reachable (index)"
                 (hasMsg m12 (msgDataRow [VInt 70])))
  r12d <- pure (chk "indexed COPY IN: the index probe ran as one row"
                 (countMsg m12 (msgCommandComplete "SELECT 1") == 1))

  -- 13: COPY round trip of a control byte through the @\NNN@ octal escape
  --     (COPY IN decodes it, COPY OUT must re-escape it)
  (out13, _, ok13) <- runScripted env cache tm lm
    [ startupPacket, feQuery copyVtSql
    , feCopyData vtOctalRow
    , feCopyData copyTerm
    , feCopyDone
    , feQuery selectVt
    , feQuery copyVtOutSql
    , feTerminate ] 23
  let m13 = decodeBackend out13
  r13a <- pure (chk "COPY octal: the \\001A field decoded to bytes 01 41"
                 (hasMsg m13 (msgDataRow [VInt 1, VText (BS.pack [1, 65])])))
  r13b <- pure (chk "COPY octal: COPY OUT re-escaped it as \\001A"
                 (hasInfixOf qCopyData (BS.pack [92, 48, 48, 49, 65, 10]) m13))

  -- 14: design/09 §9.5's rule is PER STATEMENT, so inside ONE Query message
  --     @commit; select count(n) from acct;@ in a failed block must COMMIT
  --     (ending the block, printing ROLLBACK) and THEN run the SELECT.
  n14pre <- tuplesOf cache "acct"
  (out14, _, ok14) <- runScripted env cache tm lm
    [ startupPacket
    , feQuery ("begin; " <> insertOne <> "; insert into nomissing (n) values (1)")
    , feQuery ("commit; " <> countAll)
    , feTerminate ] 24
  let m14 = decodeBackend out14
  n14post <- tuplesOf cache "acct"
  r14a <- pure (chk "failed block: the failure is reported and the block failed"
                 (countErr m14 == 1 && any (== statusFailed) (rfqStatus m14)))
  r14b <- pure (chk "failed block: commit ends it with the ROLLBACK tag"
                 (hasMsg m14 (msgCommandComplete "ROLLBACK")))
  r14c <- pure (chk "failed block: the SELECT after the commit DID run"
                 (hasMsg m14 (msgDataRow [VInt n14pre])))
  r14d <- pure (chk "failed block: nothing was committed by the failed block"
                 (ok14 && n14post == n14pre))

  -- 15: COPY inside an explicit BEGIN…COMMIT block (pgbench drives its table
  --     reads this way); the rows land only at COMMIT, and ReadyForQuery is
  --     'T' through the block.
  n15pre <- tuplesOf cache "acct"
  (out15, _, ok15) <- runScripted env cache tm lm
    [ startupPacket, feQuery "begin"
    , feQuery copyInSql
    , feCopyData "77\t77\n"
    , feCopyData copyTerm
    , feCopyDone
    , feQuery countAll
    , feQuery "commit"
    , feTerminate ] 25
  let m15 = decodeBackend out15
  n15post <- tuplesOf cache "acct"
  r15a <- pure (chk "COPY in a block: the row landed only at COMMIT"
                 (n15post == n15pre + 1))
  r15b <- pure (chk "COPY in a block: the count inside the block saw the row"
                 (hasMsg m15 (msgDataRow [VInt (n15pre + 1)])))
  r15c <- pure (chk "COPY in a block: CopyInResponse then COPY 1 then COMMIT"
                 (hasMsg m15 (msgCopyInResponse 2) &&
                  hasMsg m15 (msgCommandComplete "COPY 1") &&
                  hasMsg m15 (msgCommandComplete "COMMIT")))
  r15d <- pure (chk "COPY in a block: ReadyForQuery 'T' inside, 'I' after"
                 (any (== statusBlock) (rfqStatus m15) && lastRfq m15 == statusIdle))

  pure [ r1a, r1b, r1c, r1d, r1e, r2a, r2b, r3a, r3b, r3c, r3d, r3e, r3f
       , r4a, r4b, r4c, r5a, r5b, r6a, r6b, r6c, r6d, r7a, r7b, r7c, r7d
       , r7e, r7f, r8a, r8b, r9a, r9b, r10a
       , r11a, r11b, r12a, r12b, r12c, r12d, r13a, r13b
       , r14a, r14b, r14c, r14d, r15a, r15b, r15c, r15d ]

-- | The letter at an absolute offset (Nothing past the end; no partial head).
letterAt :: Int -> [(Word8, ByteString)] -> Maybe Word8
letterAt k ms = go k (letters ms)
  where
    go i (x : xs)
      | i <= 0 = Just x
      | otherwise = go (i - 1) xs
    go _ [] = Nothing

-- | Does the letter sequence end with the expected tail?
expectSuffix :: [(Word8, ByteString)] -> [Word8] -> Bool
expectSuffix ms tailExp = endWith tailExp (letters ms)
  where
    endWith [] _ = True
    endWith _ [] = False
    endWith t xs = take (length t) (drop (length xs - length t) xs) == t

countErr :: [(Word8, ByteString)] -> Int
countErr ms = length (filter ((== mError) . fst) ms)

-- | Chops the script into 7-byte pieces so partial frames are exercised.
smallChunks :: [ByteString] -> [ByteString]
smallChunks cs = concatMap (chunksOf 7) cs

chunksOf :: Int -> ByteString -> [ByteString]
chunksOf n b
  | BS.length b <= n = [b]
  | otherwise = BS.take n b : chunksOf n (BS.drop n b)

chk :: String -> Bool -> Check
chk name ok = Check name ok

data Check = Check String Bool

instance Show Check where
  showsPrec _ (Check name ok) = shows name . showString (if ok then " ok" else " FAIL")

checkName :: Check -> String
checkName (Check n _) = n

checkOk :: Check -> Bool
checkOk (Check _ ok) = ok

main :: IO ()
main = do
  let dir = "session-test-dir"
  exists <- doesDirectoryExist dir
  when exists (removeDirectoryRecursive dir)
  let cfg = (defaultConfig dir) { cfgStmtMemBudget = 200000 }
  cache <- newCatalogCache
  env <- createDatabase cfg cache
  ctl <- readTVarIO (envControl env)
  tm <- newTxnManager (cfNextTid ctl)
  lm <- newLockManager
  okAcct <- setupSql env tm lm cache createAcct
  okEmpty <- setupSql env tm lm cache createEmpty
  okSeed <- setupSql env tm lm cache insertOne
  okIxT <- setupSql env tm lm cache createIdxTable
  okIx <- setupSql env tm lm cache createIdx
  okVt <- setupSql env tm lm cache createVtTable
  if not (okAcct && okEmpty && okSeed && okIxT && okIx && okVt)
    then putStrLn "setup fixture failed" >> pure ()
    else pure ()
  cs0 <- scenario env cache tm lm
  cs <- pure (chk "DDL+INSERT fixtures ran"
                 (okAcct && okEmpty && okSeed && okIxT && okIx && okVt) : cs0)
  closeDataFile (envFileMgr env)
  closeWalManager (envWalMgr env)
  removeDirectoryRecursive dir
  let bad = [ c | c <- cs, not (checkOk c) ]
  mapM_ (putStrLn . pad . checkName) (filter checkOk cs)
  mapM_ (\c -> putStrLn (pad (checkName c) ++ "  <<< FAILED")) bad
  if null bad
    then putStrLn "session-tests: all checks passed"
    else exitFailure
  where
    pad n = n ++ replicate (max (0 :: Int) (66 - length n)) ' '
