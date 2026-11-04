-- | HaskDB.Server.Session (internal-design/10 §10.2-§10.8; design/09 §9.2-9.7):
--   the per-connection state machine that drives the simple query protocol.
--
--   Deviations from the docs (recorded in TODO.md):
--   * 'Connection' is DECLARED HERE, not in 'Server.Listener' (internal/11 §11.3
--     puts it in the Listener module, which would make Listener <-> Session a
--     cycle; the socket implementation still lives entirely in the Listener,
--     and sessions only see this record);
--   * the session record carries the catalog cache and the txn/lock managers
--     beyond §10.2's fields: those managers deliberately do not live in 'Env'
--     (Phase-3 decision), so they travel through the session;
--   * backend messages are accumulated in a 'Builder' and flushed after
--     ReadyForQuery (design/09 §9.7's "flushed per query cycle");
--   * an unknown frontend message answers ErrorResponse *and* ReadyForQuery
--     (§10.3's sketch omits the ReadyForQuery, which a real client needs);
--   * the COPY statement's wire message loop lives in the session (it owns the
--     socket) and feeds 'HaskDB.Executor.Operators.runInsert' chunk by chunk:
--     a pure 'Plan' cannot carry a row stream arriving from the wire (T43,
--     dialect extension; see notes/wire-protocol-psql-pgbench-memo.md).
{-# LANGUAGE LambdaCase, ScopedTypeVariables, OverloadedStrings, BangPatterns,
             BlockArguments, PatternGuards #-}

module HaskDB.Server.Session where

import Control.Exception (SomeException, try, finally)
import Control.Monad (when, unless, forM_)
import Data.IORef
import Data.Text (Text, pack)
import qualified Data.Text as T
import Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString as BS
import Data.ByteString (ByteString)
import qualified Data.ByteString.Builder as B
import qualified Data.ByteString.Lazy as L
import Data.Int (Int64)
import Data.Bits (xor)
import Data.Char (chr)
import Data.Time.Clock (getCurrentTime)
import System.IO (hPutStrLn, stderr)
import Data.Word (Word32, Word8)

import HaskDB.Common.Error (SqlError(..), throwSql)
import HaskDB.Common.Types (SqlType, Value, RelId)
import HaskDB.Server.Env (Env)
import HaskDB.Server.Wire
import HaskDB.Sql.Parser (parseStatement)
import HaskDB.Sql.Ast (Statement(StmtBegin, StmtCommit, StmtRollback, StmtCopy))
import HaskDB.Sql.Analyzer (analyze, Analyzed(ASelect, ACopy), RSelect(rsOutNames, rsItems),
                            itemOutType)
import HaskDB.Planner.Planner (planStatement)
import HaskDB.Executor.Stmts (newExecCtx, executeStatement, StmtResult(StmtRows, StmtCount))
import HaskDB.Executor.Operators (runInsert)
import HaskDB.Executor.Types (ExecCtx, Plan)
import HaskDB.Txn.Manager (TxnManager, TxnCtx, beginTxn, commitTxn, abortTxn, withTxnAuto,
                           toSqlError)
import HaskDB.Txn.LockManager (LockManager)
import HaskDB.Catalog.Cache (CatalogCache, lookupById)
import HaskDB.Catalog.Types (RelationDesc(rdColumns))
import HaskDB.Heap.TupleCodec (ColumnDesc(colType))

-- ---------------------------------------------------------------------------
-- The connection abstraction (internal/11 §11.3; the Listener implements it)
-- ---------------------------------------------------------------------------
data Connection = Connection
  { connRecv  :: Int -> IO ByteString     -- up to N bytes; empty = EOF
  , connSend  :: ByteString -> IO ()
  , connClose :: IO ()
  }

-- ---------------------------------------------------------------------------
-- Session state (internal/10 §10.2)
-- ---------------------------------------------------------------------------
data Session = Session
  { ssEnv     :: Env
  , ssCatalog :: CatalogCache
  , ssTxnMgr  :: TxnManager
  , ssLockMgr :: LockManager
  , ssConn    :: Connection
  , ssBuf     :: IORef ByteString        -- unparsed input (§10.2)
  , ssTxn     :: IORef SessionTxn        -- §10.2
  , ssOut     :: IORef B.Builder         -- §9.7 per-query-cycle buffering
  , ssPid     :: Word32
  , ssSecret  :: Word32
  }

data SessionTxn
  = TSIdle                        -- no transaction block
  | TSInBlock TxnCtx              -- explicit BEGIN block, healthy
  | TSFailed                      -- explicit block, failed (25P02 state)

-- | Frontend read verdict of the message loop.
data FEResult = FEof | FEBad Text | FEStartup | FEMsg FrontendMsg

-- ---------------------------------------------------------------------------
-- Construction and the top-level run
-- ---------------------------------------------------------------------------
-- | 'pid' is the listener's session counter (design/09 §9.2's "internal
--   counter"; kept in the Listener so this module has no global cell).
newSession :: Env -> CatalogCache -> TxnManager -> LockManager -> Connection
           -> Word32 -> IO Session
newSession env cache tm lm conn pid = do
  buf <- newIORef BS.empty
  tx <- newIORef TSIdle
  out <- newIORef mempty
  pure Session { ssEnv = env, ssCatalog = cache, ssTxnMgr = tm, ssLockMgr = lm
               , ssConn = conn, ssBuf = buf, ssTxn = tx, ssOut = out
               , ssPid = pid, ssSecret = mixSecret pid }

-- | BackendKeyData's "secret key, random per session" (design/09 §9.2): the
--   boot-library-only constraint leaves no random source, and cancellation is
--   unsupported (D-21), so a Word32 bit-mix of the pid is used.  Deviation.
mixSecret :: Word32 -> Word32
mixSecret p = (p * 2654435761) `xor` (p + 2246822519)

-- | §10.4 startup handshake, then §10.3's loop.  The cleanup handler runs on
--   EVERY exit path: design/09 §9.2 says a CancelRequest (and, per §9.7, a
--   malformed startup or a dead client) ends the session, so the peer must be
--   closed on the startup-failure paths too, not just after the loop.
runSession :: Env -> CatalogCache -> TxnManager -> LockManager
            -> Connection -> Word32 -> IO ()
runSession env cache tm lm conn pid = do
  s <- newSession env cache tm lm conn pid
  -- startupSession may THROW (its socket layer dies with the real errno), and
  --   the peer must still be closed: the docs' "cleanup on every exit path"
  --   covers the startup path too, so the guard sits outside it.
  startup <- try (startupSession s) :: IO (Either SomeException Bool)
  case startup of
    Left ex -> do
      logServer ("startup failed: " <> pack (show ex))
      cleanupSession s
    Right ok
      | ok -> loopSession s `finally` cleanupSession s
      | otherwise -> cleanupSession s

-- ---------------------------------------------------------------------------
-- Startup phase (internal/10 §10.4)
-- ---------------------------------------------------------------------------
startupSession :: Session -> IO Bool
startupSession s = startupLoop s
  where
    -- 'startupLoop' takes the session as an argument on every round: with a
    -- shared local thunk 'go', the SSL-probe round would re-force a thunk that
    -- is still being evaluated (a black hole).
    startupLoop sx = readStartupPacket sx >>= \case
      Nothing -> pure False
      Just (Left m) -> do
        logServer ("startup protocol error: " <> m)
        pure False
      Just (Right packet) -> case packet of
        -- §9.2/§9.6: the probe's answer is ONE byte that must reach the peer
        --   BEFORE the client sends the StartupMessage — libpq waits for it, so
        --   buffering it until the handshake finished would deadlock the client
        --   (§9.7's output batching is a per-query-cycle property, not a
        --   startup-negotiation one).
        SPSSLRequest -> tellS sx msgCannotUpgradeTLS >> flushOut sx
                        >> startupLoop sx
        SPGSSRequest -> tellS sx msgCannotUpgradeTLS >> flushOut sx
                        >> startupLoop sx
        SPCancelRequest _ _ -> do            -- D-21: accepted, then close
          logServer "CancelRequest connection closed"
          pure False
        SPStartup ver _ -> do                  -- §10.4 step 2: params ignored
          -- a client speaking a newer minor than we implement gets the
          -- NegotiateProtocolVersion notice first (supplementary to the docs)
          when (ver > cStartup + protoMinorMax)
               (tellS sx msgNegotiateProtocolVersion)
          tellS sx msgAuthenticationOk
          forM_ startupParams $ \(k, v) -> tellS sx (msgParameterStatus k v)
          tellS sx (msgBackendKeyData (ssPid sx) (ssSecret sx))
          tellS sx (msgReadyForQuery statusIdle)
          flushOut sx
          pure True

-- ---------------------------------------------------------------------------
-- Message loop (internal/10 §10.3)
-- ---------------------------------------------------------------------------
-- | §10.3's loop: an exception that escaped 'handleQuery' (its per-statement
--   handler should have caught everything, so this is the documented safety
--   net) is REPORTED as an ErrorResponse, the §10.7 failure effects applied,
--   and the session CONTINUES in the same cycle — internal/10 §10.3's
--   "on SqlError escaping handleQuery … continue" arm.
loopSession :: Session -> IO ()
loopSession s = readFrontendMsg s >>= \case
  FEof -> pure ()                             -- client left: clean end
  FEBad m -> logServer ("frontend framing error: " <> m) >> pure ()
  FEStartup -> logServer "startup packet mid-session: closing" >> pure ()
  FEMsg m -> case m of
    FTerminate -> pure ()                     -- §10.3: cleanup, close
    FQuery sql -> handleQueryGuarded s sql >> loopSession s
    FCopyData _ ->
      sendError s (copyProtocolErr "COPY data outside a COPY statement")
        >> finishCycle s >> loopSession s
    FCopyDone ->
      sendError s (copyProtocolErr "COPY done outside a COPY statement")
        >> finishCycle s >> loopSession s
    FCopyFail why ->
      sendError s (copyProtocolErr (describeCause why))
        >> finishCycle s >> loopSession s
    FUnknown t _ ->
      sendError s (unknownMsgErr t) >> finishCycle s >> loopSession s

handleQueryGuarded :: Session -> ByteString -> IO ()
handleQueryGuarded s sql = do
  r <- try (handleQuery s sql) :: IO (Either SomeException ())
  case r of
    Right () -> pure ()
    Left ex -> do
      let se = toSqlError ex
      logServer ("query escaped handleQuery: " <> pack (show ex))
      sendError s se
      applyFailureEffects s
      finishCycle s

-- | §10.5 step 1-2.  The decode is TOTAL (internal/00 §0.7: no partial
--   functions on network bytes; @decodeUtf8@ throws): invalid UTF-8 answers
--   the §9.6 code for an invalid text representation and the session stays
--   alive.
handleQuery :: Session -> ByteString -> IO ()
handleQuery s sql = case tryText sql of
  Nothing -> sendError s (SqlError "22P02" "query is not valid UTF-8")
             >> finishCycle s
  Just t -> do
    let pieces = splitStatements t
    if null pieces
      then tellS s msgEmptyQueryResponse
      else runPieces s (map (parseStatement . encodeUtf8) pieces)
    finishCycle s

runPieces :: Session -> [Either SqlError Statement] -> IO ()
runPieces _ [] = pure ()
runPieces s (p : rest) =
  executeParsed s p >>= \ok -> when ok (runPieces s rest)

-- | §10.5's per-statement handler.  design/09 §9.5's rule is PER STATEMENT
--   ("further statements other than COMMIT/ROLLBACK are rejected with 25P02
--   until the block ends"), so the check lives here and not on the whole
--   query string: in a failed block @commit; select n from t;@ must commit
--   (which ends the block, printing the ROLLBACK tag) and then run the SELECT.
executeParsed :: Session -> Either SqlError Statement -> IO Bool
executeParsed s parsed = case parsed of
  Left e -> sendError s e >> applyFailureEffects s >> pure False
  Right stmt -> do
    tx <- readIORef (ssTxn s)
    if isFailedTxn tx && not (blockEndStmt stmt)
      then sendError s failedBlockErr >> pure False
      else do
        r <- try (runStatement s stmt) :: IO (Either SomeException ())
        case r of
          Right () -> pure True
          Left ex -> do
            let se = toSqlError ex
            sendError s se
            when (seState se == "XX000") $            -- §11.7 logs internal errors
              logServer ("session internal error " <> seState se <> ": " <> seMessage se)
            applyFailureEffects s
            pure False

-- | Statements that end a transaction block (§9.5, §10.5).
blockEndStmt :: Statement -> Bool
blockEndStmt stmt = case stmt of
  StmtCommit   -> True
  StmtRollback -> True
  _            -> False

-- | §10.7's matrix: an implicit block was already aborted by 'withTxnAuto';
--   an explicit block's transaction is aborted AT FAILURE TIME and the state
--   becomes TSFailed (which carries no live TxnCtx).
applyFailureEffects :: Session -> IO ()
applyFailureEffects s = do
  tx <- readIORef (ssTxn s)
  case tx of
    TSInBlock ctx -> do
      abortTxn ctx
      writeIORef (ssTxn s) TSFailed
    _ -> pure ()

-- ---------------------------------------------------------------------------
-- executeOne (internal/10 §10.5)
-- ---------------------------------------------------------------------------
runStatement :: Session -> Statement -> IO ()
runStatement s stmt = do
  tx <- readIORef (ssTxn s)
  case stmt of
    StmtBegin -> case tx of
      TSIdle -> do
        ctx <- beginTxn (ssTxnMgr s) (ssLockMgr s) (ssEnv s)
        writeIORef (ssTxn s) (TSInBlock ctx)
        tellS s (msgCommandComplete "BEGIN")
      _ -> do
        tellS s (msgNoticeResponse (Just "25P01")     -- PostgreSQL's own code
          "there is already a transaction in progress")
        tellS s (msgCommandComplete "BEGIN")
    StmtCommit -> case tx of
      TSIdle -> do
        tellS s (msgNoticeResponse Nothing    -- no SQLSTATE in PostgreSQL
          "commit does nothing outside a transaction block")
        tellS s (msgCommandComplete "COMMIT")
      TSInBlock ctx -> do
        commitTxn ctx
        writeIORef (ssTxn s) TSIdle
        tellS s (msgCommandComplete "COMMIT")
      TSFailed -> do                    -- §9.5: PostgreSQL reports ROLLBACK
        writeIORef (ssTxn s) TSIdle
        tellS s (msgCommandComplete "ROLLBACK")
    StmtRollback -> do
      case tx of
        TSInBlock ctx -> abortTxn ctx
        _ -> pure ()
      writeIORef (ssTxn s) TSIdle
      tellS s (msgCommandComplete "ROLLBACK")
    StmtCopy _ -> copyStatement s stmt
    _ -> regularStatement s stmt

-- | The transaction a statement runs in: the session block's 'TxnCtx', or an
--   implicit block committed/aborted around it (§9.5, §10.5).
inStatementCtx :: Session -> (TxnCtx -> IO ()) -> IO ()
inStatementCtx s act = do
  tx <- readIORef (ssTxn s)
  case tx of
    TSInBlock ctx -> act ctx
    _ -> withTxnAuto (ssTxnMgr s) (ssLockMgr s) (ssEnv s) act

-- ---------------------------------------------------------------------------
-- Regular statements: analyze -> plan -> execute (§10.5 + §10.8)
-- ---------------------------------------------------------------------------
regularStatement :: Session -> Statement -> IO ()
regularStatement s stmt = do
  let cache = ssCatalog s
  a <- analyze cache stmt
  plan <- planStatement cache a
  hdr <- newIORef False
  let cols = outSchema a
      isSel = case a of
                ASelect _ -> True
                _         -> False
  inStatementCtx s \ctx -> do
    ec <- newExecCtx (ssEnv s) cache ctx
    res <- executeStatement ec plan \vals -> do
      sent <- readIORef hdr
      unless sent $ do
        writeIORef hdr True
        tellS s (msgRowDescription cols)
      tellS s (msgDataRow vals)
    sentHdr <- readIORef hdr
    when (isSel && not sentHdr) $              -- §10.8: empty results still header
      tellS s (msgRowDescription cols)
    tellCommand s res
  where
    outSchema an = case an of
      ASelect rs -> zip (rsOutNames rs) (map itemOutType (rsItems rs))
      _          -> []

-- | CommandComplete tags (design/09 §9.4): SELECT n / INSERT 0 n / UPDATE n /
--   DELETE n; DDL tags stay bare (§10.5).
tellCommand :: Session -> StmtResult -> IO ()
tellCommand s res = case res of
  StmtRows n -> tellS s (msgCommandComplete ("SELECT " <> intText n))
  StmtCount tag n
    | tag == "CREATE TABLE" || tag == "CREATE INDEX" -> tellS s (msgCommandComplete tag)
    | tag == "INSERT" -> tellS s (msgCommandComplete ("INSERT 0 " <> intText n))
    | otherwise       -> tellS s (msgCommandComplete (tag <> " " <> intText n))

-- ---------------------------------------------------------------------------
-- COPY (the extension: the wire loop lives in the statement handler)
-- ---------------------------------------------------------------------------
copyStatement :: Session -> Statement -> IO ()
copyStatement s stmt = do
  let cache = ssCatalog s
  a <- analyze cache stmt
  plan <- planStatement cache a
  case a of
    ACopy rid wantIn -> do
      mrd <- lookupById cache rid
      case mrd of
        Nothing -> throwSql "XX000"
          "session: COPY relation is not in the catalog"
        Just rd ->
          let colts = map colType (rdColumns rd)
          in if wantIn
            then inStatementCtx s \ctx -> copyIn s ctx rid colts
            else inStatementCtx s \ctx -> copyOut s ctx colts plan
    _ -> throwSql "XX000" "session: COPY analyze produced a non-COPY shape"

-- | COPY IN: CopyInResponse before consuming input (PostgreSQL's rule; the
--   dialect extension of design/09 §9.3), then the CopyData stream until
--   CopyDone.  Rows go through 'runInsert' exactly as INSERT does (row X locks
--   + WAL PInsertTuple) but in chunks, never materialised whole.
copyIn :: Session -> TxnCtx -> RelId -> [SqlType] -> IO ()
copyIn s ctx rid colts = do
  let ncol = length colts
  tellS s (msgCopyInResponse ncol)
  -- psql/pgbench cannot send CopyData before they have RECEIVED the
  -- CopyInResponse, so this point must be flushed even though §9.7 batches
  -- output until ReadyForQuery (PostgreSQL flushes the same way).
  flushOut s
  ec <- newExecCtx (ssEnv s) (ssCatalog s) ctx
  n <- copyInLoop s ec rid [0 .. ncol - 1] colts BS.empty False 0
  tellS s (msgCommandComplete ("COPY " <> intText n))

copyInLoop :: Session -> ExecCtx -> RelId -> [Int] -> [SqlType]
           -> ByteString -> Bool -> Int64 -> IO Int64
copyInLoop s ec rid ords colts acc pastDot n = do
  fe <- readFrontendMsg s
  case fe of
    FEMsg m -> case m of
      FCopyData bs -> do
        let (ls, rest) = splitCopyLines (acc <> bs)
        if pastDot                       -- data after '\.' is ignored
          then copyInLoop s ec rid ords colts rest True n
          else do
            let (dataLines, afterTerm) = break (== copyTerminator) ls
                sawTerm = not (null afterTerm)
            rows <- mapM (decodeCopyRow colts) dataLines
            c <- if null rows then pure 0 else runInsert ec rid ords rows
            copyInLoop s ec rid ords colts (if sawTerm then BS.empty else rest)
                         (pastDot || sawTerm) (n + c)
      FCopyDone -> pure n
      FCopyFail why -> throwSql "22P04"
        ("COPY IN aborted by client: " <> describeCause why)
      FQuery q -> throwSql "22P04"
        ("COPY IN expected COPY data, got a Query message: " <> textOf q)
      FTerminate -> throwSql "22P04" "COPY IN interrupted by Terminate"
      FUnknown t _ -> throwSql "22P04"
        ("COPY IN expected COPY data, got message " <> pack [chr (fromIntegral t)])
    FEBad m -> throwSql "22P04" ("COPY IN framing error: " <> m)
    FEof -> throwSql "22P04" "COPY IN ended by client disconnect"
    FEStartup -> throwSql "22P04" "COPY IN saw a startup packet"

decodeCopyRow :: [SqlType] -> BS.ByteString -> IO [Value]
decodeCopyRow colts line = case decodeCopyLine colts line of
  Left e  -> throwSql (seState e) (seMessage e)
  Right v -> pure v

copyTerminator :: BS.ByteString
copyTerminator = BS.pack [92, 46]          -- "\."

-- | COPY OUT: CopyOutResponse, rows as COPY text in CopyData chunks, the
--   '\.' line, CopyDone, CommandComplete 'COPY n' (the extension).
copyOut :: Session -> TxnCtx -> [SqlType] -> Plan -> IO ()
copyOut s ctx colts plan = do
  tellS s (msgCopyOutResponse (length colts))
  ec <- newExecCtx (ssEnv s) (ssCatalog s) ctx
  -- §9.7 batches output, but a COPY of a large relation must not hold the
  -- whole wire encoding in memory: flush at a bounded pending size.  The
  -- counter tracks that size — measuring with L.length per row is O(N^2).
  pending <- newIORef (0 :: Int64)
  res <- executeStatement ec plan \vals -> do
    let !line = encodeCopyLine vals <> BS.singleton 10
    tellS s (msgCopyData line)
    modifyIORef' pending (+ fromIntegral (BS.length line + 5))  -- + CopyData header
    over <- readIORef pending
    when (over > outCapBytes) (flushOut s >> writeIORef pending 0)
  tellS s (msgCopyData (BS.pack [92, 46, 10]))
  tellS s msgCopyDone
  tellS s (msgCommandComplete ("COPY " <> intText (rowCountOf res)))

rowCountOf :: StmtResult -> Int64
rowCountOf (StmtRows n)    = n
rowCountOf (StmtCount _ n) = n

-- ---------------------------------------------------------------------------
-- Framing reads (internal/10 §10.1: partial frames wait for more bytes)
-- ---------------------------------------------------------------------------
readFrontendMsg :: Session -> IO FEResult
readFrontendMsg s = readFrontendGo s
  where
    -- the read takes the session as an argument each round, so a partial
    -- frame appends bytes and re-enters FRESHLY (a shared 'go' thunk would be
    -- a black hole: it is still being evaluated when the Need branch re-forces
    -- it)
    readFrontendGo sx = do
      buf <- readIORef (ssBuf sx)
      case tryGetFrontend buf of
        Need -> do
          bs <- connRecv (ssConn sx) 4096
          if BS.null bs then pure FEof
            else modifyIORef' (ssBuf sx) (<> bs) >> readFrontendGo sx
        Bad m -> pure (FEBad m)
        IsStartup _ _ -> pure FEStartup
        IsFrontend m rest -> writeIORef (ssBuf sx) rest >> pure (FEMsg m)

readStartupPacket :: Session -> IO (Maybe (Either Text StartupPacket))
readStartupPacket s = readStartupGo s
  where
    readStartupGo sx = do
      buf <- readIORef (ssBuf sx)
      case tryGetStartup buf of
        Need -> do
          bs <- connRecv (ssConn sx) 4096
          if BS.null bs then pure Nothing
            else modifyIORef' (ssBuf sx) (<> bs) >> readStartupGo sx
        Bad m -> pure (Just (Left m))
        IsFrontend _ _ -> pure (Just (Left "frontend message during startup"))
        IsStartup p rest -> writeIORef (ssBuf sx) rest >> pure (Just (Right p))

-- | Append one backend message to the cycle buffer (§9.7 batching).
tellS :: Session -> ByteString -> IO ()
tellS s bs = modifyIORef' (ssOut s) (<> B.byteString bs)

flushOut :: Session -> IO ()
flushOut s = do
  b <- readIORef (ssOut s)
  writeIORef (ssOut s) mempty
  connSend (ssConn s) (buildBytes b)

-- | §9.7's batching is bounded: streaming paths flush once the pending output
--   passes this cap, so a COPY of a large relation never materialises its
--   whole wire encoding in memory.
outCapBytes :: Int64
outCapBytes = 65536

-- | ReadyForQuery with the session's transaction status byte (§10.3 step 2,
--   design/09 §9.4 step 3): 'I' idle, 'T' in a block, 'E' failed block.
finishCycle :: Session -> IO ()
finishCycle s = do
  tx <- readIORef (ssTxn s)
  tellS s (msgReadyForQuery (txStatus tx))
  flushOut s

txStatus :: SessionTxn -> Word8
txStatus TSIdle        = statusIdle
txStatus (TSInBlock _) = statusBlock
txStatus TSFailed      = statusFailed

-- | 'SessionTxn' holds a 'TxnCtx' (no 'Eq' instance), so state tests are
--   explicit case analyses.
isFailedTxn :: SessionTxn -> Bool
isFailedTxn t = case t of
  TSFailed -> True
  _        -> False

-- | The session's cleanup handler: roll back an in-flight block (§9.7: "a
--   session thread that dies by exception must roll back … a client disconnect
--   likewise rolls back") and then ALWAYS close the peer — so a throwing
--   rollback cannot leave the connection open.
cleanupSession :: Session -> IO ()
cleanupSession s = do
  tx <- readIORef (ssTxn s)
  case tx of
    TSInBlock ctx -> do
      r <- try (abortTxn ctx) :: IO (Either SomeException ())
      case r of
        Left ex -> logServer ("cleanup rollback failed: " <> pack (show ex))
        _ -> pure ()
    _ -> pure ()
  writeIORef (ssTxn s) TSIdle
  -- anything still pending (the SSL probe's reply, an ErrorResponse for a
  --   malformed startup packet) must reach the peer before the socket dies,
  --   or a waiting client hangs out waiting for a reply that never arrives.
  --   The flush may itself die with the real socket errno, so it is guarded:
  --   §9.7's "a session thread that dies … closes the peer" still demands the
  --   close, and a close that fails is what the OS already told us.
  flushed <- try (flushOut s) :: IO (Either SomeException ())
  case flushed of
    Left ex -> logServer ("cleanup flush failed: " <> pack (show ex))
    _ -> pure ()
  connClose (ssConn s)

-- ---------------------------------------------------------------------------
-- splitStatements (internal/10 §10.6)
-- ---------------------------------------------------------------------------
-- | Split on top-level ';' honouring '...' strings ('' escapes) and '--' line
--   comments; empty and comment-only pieces are dropped.  Paren depth is
--   irrelevant (§10.6: semicolons cannot appear outside strings in this
--   grammar).  Semicolons and comment markers inside strings are kept.
splitStatements :: Text -> [Text]
splitStatements src0 =
  filter (not . T.null) (map (T.strip . pack) (splitTop (T.unpack src0)))

splitTop :: String -> [String]
splitTop src = splitGo [] src
  where
    splitGo cur s = case s of
      [] -> [reverse cur]
      (c : cs)
        | c == ';'  -> reverse cur : splitGo [] cs
        | c == '\'' -> strLit (c : cur) cs
        | c == '-', dashStart cs -> splitGo cur (dropToNl cs)
        | otherwise -> splitGo (c : cur) cs

    -- a string literal: '' stays inside the piece, the closing quote does too
    strLit cur s = case s of
      [] -> [reverse cur]
      (c : cs)
        | c == '\'' -> case cs of
            ('\'':cs2) -> strLit (c : c : cur) cs2
            _          -> splitGo (c : cur) cs
        | otherwise -> strLit (c : cur) cs

    dashStart s = case s of
      ('-':_) -> True
      _       -> False

    dropToNl s = case s of
      ('\n':r) -> r
      (_:r)    -> dropToNl r
      []       -> []

-- ---------------------------------------------------------------------------
-- Wire-layer errors (design/09 §9.6 + the COPY extension codes)
-- ---------------------------------------------------------------------------
-- | §9.6/§10.3: an ErrorResponse only.  The cycle's single ReadyForQuery is
--   emitted by the CALLER (@finishCycle@) -- internal/10 §10.3 sends it once
--   per frontend-message cycle, after the handler; emitting it here as well
--   made two arrive, which puts libpq's command queue out of step.
sendError :: Session -> SqlError -> IO ()
sendError s e = tellS s (msgErrorResponse e)

failedBlockErr :: SqlError
failedBlockErr = SqlError "25P02"
  "operation not performed because the transaction has already failed; \
  \only COMMIT and ROLLBACK are allowed until the block ends"

unknownMsgErr :: Word8 -> SqlError
unknownMsgErr t = SqlError "0A000"
  ("message type " <> pack [chr (fromIntegral t)] <>
   " is not supported (only the simple query protocol is)")

-- | COPY protocol violations (COPY data outside a COPY statement, a CopyFail
--   where none is expected, a malformed/short row): PostgreSQL's own code for
--   a bad COPY input is 22P04 (errcodes.txt's ERRCODE_BAD_COPY_FILE_FORMAT).
--   design/09 §9.6 is silent here and its tree has no 20F03 (the memo claimed
--   one; corrected) — so 22P04 is used and logged as a deviation.
copyProtocolErr :: Text -> SqlError
copyProtocolErr why = SqlError "22P04" ("COPY protocol error: " <> why)

describeCause :: Text -> Text
describeCause why = if T.null why then "no cause given" else why

-- ---------------------------------------------------------------------------
-- Small utilities
-- ---------------------------------------------------------------------------
buildBytes :: B.Builder -> ByteString
buildBytes b = L.toStrict (B.toLazyByteString b)

intText :: Int64 -> Text
intText = pack . show

-- | §11.7: server log to stderr as plain timestamped lines.  The timestamp is
--   GHC's ISO rendering of 'getCurrentTime' (deviation: 'System.Time' was
--   dropped from base-4.20, so the `time` boot package supplies it).
logServer :: Text -> IO ()
logServer m = do
  t <- getCurrentTime
  hPutStrLn stderr (T.unpack (pack (show t) <> " haskdb-server: " <> m))
