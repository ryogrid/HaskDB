# 10. Wire Protocol and Session Internals

Refines `design/09-wire-protocol.md`.

## 10.1 Message codecs (`Server.Wire`)

All protocol integers are **big-endian** (opposite of the disk
formats). The module has its own put/get helpers; nothing is shared
with `Common.Codec` except CRC (unused here).

```haskell
-- Frontend messages (client -> server)
data FrontendMsg
  = FQuery ByteString            -- SQL text (NUL-stripped)
  | FTerminate
  | FUnknown Word8 Int           -- type byte, body length (skipped)

data StartupPacket
  = SPStartup [(Text, Text)]     -- parameters
  | SPSSLRequest
  | SPGSSRequest
  | SPCancelRequest Word32 Word32

-- Backend messages are built directly as Builder/ByteString by
-- functions:
msgAuthenticationOk, msgParameterStatus, msgBackendKeyData,
msgReadyForQuery :: Word8 -> ByteString        -- status byte I/T/E
msgRowDescription :: [(Text, SqlType)] -> ByteString
msgDataRow :: [Value] -> ByteString            -- text format only
msgCommandComplete :: Text -> ByteString
msgEmptyQueryResponse :: ByteString
msgErrorResponse :: SqlError -> ByteString
```

Framing reader: sessions read from the socket into a growing buffer
and parse complete frames (1-byte type + u32 length for regular
messages; u32 length + u32 code for startup packets). Partial frames
wait for more bytes. Length sanity: `< 4` or `> 1 GiB` → close
connection (design/09 §9.7).

`msgDataRow` text encodings (design/09 §9.4):

- `VInt i` → decimal ASCII.
- `VFloat d` → `formatFloat d`: use `show d` (GHC's shortest
  round-trip), then if the result contains none of `.`, `e`, `n`
  (nan/inf cannot occur), append `.0`. (e.g. `show 1.0 = "1.0"` is
  already fine; `show 1e22 = "1.0e22"` fine; the append rule covers
  integral doubles printed as integers by foreign `Show` variants.)
- `VText bytes` → bytes as-is.
- `VBool` → `t` / `f`.

## 10.2 Session state (`Server.Session`)

```haskell
data Session = Session
  { ssEnv     :: Env
  , ssConn    :: Connection           -- socket abstraction (doc 11 sect 11.3)
  , ssBuf     :: IORef ByteString     -- unparsed input
  , ssTxn     :: IORef SessionTxn
  , ssPid     :: Word32
  , ssSecret  :: Word32
  }

data SessionTxn
  = TSIdle                        -- no transaction block
  | TSInBlock TxnCtx              -- explicit BEGIN block, healthy
  | TSFailed                      -- explicit block, failed (25P02 state)
```

The session owns at most one `TxnCtx` at a time. Autocommit
statements create and destroy a `TxnCtx` per statement.

## 10.3 Session main loop

```
runSession env conn:
  startup phase (sect 10.4) -> send ReadyForQuery 'I'
  loop:
    msg <- readFrontendMsg
    case msg of
      FTerminate -> cleanup (rollback if in block); close; return
      FQuery sql -> handleQuery sql; send ReadyForQuery (status byte
                    from ssTxn: Idle->I, InBlock->T, Failed->E)
      FUnknown _ _ -> send ErrorResponse 0A000 "unknown message type";
                      continue (body already skipped by the reader)
  on EOF / socket error: cleanup as FTerminate, silently
  on SqlError escaping handleQuery (should not happen — handleQuery
  catches per-statement): treat as internal error, send ErrorResponse,
  rollback any block, continue in TSFailed/TSIdle as appropriate
```

## 10.4 Startup flow

```
1. Read first packet (length+code framed, no type byte):
   - SSLRequest (80877103) -> send 'N', read next packet
   - GSSENCRequest (80877104) -> send 'N', read next packet
   - CancelRequest (80877102) -> close connection (unsupported, doc 09)
   - StartupMessage (196608) -> parameters map
2. Ignore user/database values; record nothing.
3. Send AuthenticationOk, ParameterStatus set (design/09 9.2),
   BackendKeyData (ssPid, ssSecret), ReadyForQuery 'I'.
```

## 10.5 handleQuery flow (simple query protocol)

```
handleQuery session sqlBytes:
  sqlText := strip trailing NUL; if all whitespace/comments:
               send EmptyQueryResponse; return
  stmts := splitStatements sqlText       -- sect 10.6
  if ssTxn == TSFailed and any stmt is not COMMIT/ROLLBACK:
               send ErrorResponse 25P02; return
  for stmtText in stmts:
     result <- try (executeOne session stmtText)
     case result of
       Left sqlErr -> send ErrorResponse sqlErr
                      mark failure effects (sect 10.7); STOP processing
                      remaining statements; return
       Right ()    -> continue
```

### executeOne flow

```
executeOne session stmtText:
  stmt <- parseStatement (Sql.Parser)          -- SqlError on failure
  case stmt of
    StmtBegin ->
       case ssTxn of
         TSIdle -> ctx <- beginTxn; ssTxn := TSInBlock ctx; tag "BEGIN"
         _      -> NoticeResponse warning "there is already a transaction
                   in progress"; tag "BEGIN"
    StmtCommit ->
       case ssTxn of
         TSIdle   -> tag "COMMIT" (no-op, warning notice per PostgreSQL)
         TSInBlock ctx -> commitTxn ctx; ssTxn := TSIdle; tag "COMMIT"
         TSFailed -> ssTxn := TSIdle; tag "ROLLBACK"
                     (the failed block's ctx was already aborted at
                     failure time — see 10.7; nothing to undo here)
    StmtRollback ->
       case ssTxn of
         TSInBlock ctx -> abortTxn ctx; ssTxn := TSIdle
         TSFailed -> ssTxn := TSIdle
         TSIdle -> no-op
       tag "ROLLBACK"
    other ->
       analyzed <- analyze (catalog cache snapshot) stmt
       plan     <- planStatement cache analyzed
       ensure txn context:
         TSInBlock ctx -> use ctx
         TSIdle -> ctx <- beginTxn (implicit; commit/rollback at end)
       res <- executeStatement ctx plan (row callback = send DataRow,
                with RowDescription sent before the first row for
                SELECT: the callback wrapper handles this via a
                "header sent" flag)
       if implicit: commitTxn ctx   -- WAL fsync happens inside
       send CommandComplete (tag from res)
```

Errors inside `executeStatement` for the implicit case: `abortTxn
ctx` then rethrow to `handleQuery`'s per-statement handler.

## 10.6 Statement splitting

`splitStatements :: Text -> [Text]` splits on `;` at top level,
tracking: single-quoted strings (`''` escape), `--` comments, and
parentheses depth is irrelevant (semicolons cannot appear inside
parentheses in this grammar except inside strings, already handled).
Empty pieces are dropped. The parser then handles each piece
(design/09 §9.4 step 1's implementation).

## 10.7 Failure effects matrix

| Session state | Statement fails → |
|---------------|-------------------|
| TSIdle (implicit txn) | implicit txn aborted; session stays TSIdle; ReadyForQuery 'I' |
| TSInBlock ctx | ctx aborted **immediately** (abortTxn), ssTxn := TSFailed; further statements (except COMMIT/ROLLBACK) get `25P02` without execution; ReadyForQuery 'E' |
| TSFailed | statements rejected with `25P02` until COMMIT/ROLLBACK |

Aborting the block's transaction at failure time (rather than lazily
at ROLLBACK) is a deliberate simplification: it frees locks promptly
and makes `TSFailed` carry no live `TxnCtx`.

## 10.8 RowDescription construction

From the analyzed select's output schema: field name = output name
(analyzer), table OID = 0, column attnum = 0, type OID per
`Common.Types.typeOid`, typlen (8/8/-1/1), typmod -1, format 0.
For non-SELECT statements no RowDescription is sent.

Empty result sets still send RowDescription + CommandComplete
`SELECT 0`.
