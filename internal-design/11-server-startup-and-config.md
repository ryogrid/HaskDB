# 11. Server Startup, Listener, and Control File

Refines `design/00-overview.md` §0.5–§0.8 and the startup aspects of
documents 02/03/06.

## 11.1 Main entry (`app/Main.hs`)

```
main:
  args: haskdb-server <dataDir> [--port N] [--create]
  cfg  := defaultConfig dataDir overridden by flags
  env  <- startDatabase cfg        -- sect 11.2/11.3
  install signal handlers (SIGTERM/SIGINT -> graceful shutdown, 11.5)
  runListener env                  -- blocks forever
```

Argument parsing is hand-rolled (no optparse library — boot libraries
only). Unknown flags and missing dataDir print usage to stderr and
exit 1.

## 11.2 Database open/create (`startDatabase`)

```
startDatabase cfg:
  createDirectoryIfMissing dataDir
  take exclusive flock on <dataDir>/haskdb.lock
     (System.Posix.IO / flock via `unix` FFI helper lockFile;
      failure -> die "another HaskDB process is using this directory")
  if control file exists:
     ctl <- readControl cfg                    -- 11.4
     check ctl.pageSize == data file's page 0 pageSize (else die)
     env <- recoverDatabase cfg ctl            -- document 03 section 3.6
  else:
     if data/WAL files exist but no control file -> die "incomplete
        database directory" (do not guess)
     create empty data file, WAL file
     bootstrap catalog (document 06 section 6.2)
     write control file with checkpointLSN = end of bootstrap WAL
     env <- assemble Env from the fresh managers
  start checkpoint timer thread (sect 11.6)
  start deadlock detector thread if enabled (document 04 section 4.3)
  return env
```

`--create` is not required to create a database: absence of the
control file *is* the create signal, but only when the directory is
otherwise empty (guard above), so pointing the server at the wrong
directory cannot silently create a new database over stray files.

## 11.3 Listener and connection abstraction (`Server.Listener`)

```haskell
-- Abstracted so sessions can be tested over pipes, not only sockets.
data Connection = Connection
  { connRecv :: Int -> IO ByteString   -- up to N bytes; empty = EOF
  , connSend :: ByteString -> IO ()
  , connClose :: IO ()
  }

runListener :: Env -> IO ()
  -- socket, bind (cfgPort, all interfaces), listen
  -- loop: accept -> forkIO (runSession env conn) with an exception
  -- handler that guarantees session cleanup; thread ids are not
  -- tracked (sessions are independent); the accept loop itself must
  -- never die from a per-connection exception.
```

Socket implementation lives entirely in this module (the D-06
decision changes only this module's internals). Sessions see only
`Connection`.

Per-session thread failure policy: any exception escaping
`runSession` closes that connection only; the listener and other
sessions are unaffected. A failing session rolls back its transaction
in its cleanup handler (document 10 §10.3).

## 11.4 Control file

Path: `<dataDir>/haskdb.control`. Text format (human-readable on
purpose — operators of a teaching system should be able to inspect
it), one `key=value` per line:

```
format=1
pageSize=8192
checkpointLSN=123456
nextTid=42
```

```haskell
data ControlFile = ControlFile
  { cfPageSize :: Int, cfCheckpointLSN :: LSN, cfNextTid :: TxnId }

readControl  :: FilePath -> IO ControlFile     -- parse errors = die
writeControl :: FilePath -> ControlFile -> IO ()
  -- write haskdb.control.tmp, fsync it, rename over haskdb.control,
  -- fsync the directory
```

The control file is written only by checkpoints (document 03 §3.5)
and initial bootstrap. `pageSize` never changes after creation;
`readControl` validates it against page 0's stored page size at open.

The advisory lock file `haskdb.lock` is separate and never written to
(it exists only to be `flock`ed).

## 11.5 Graceful shutdown

On SIGTERM/SIGINT (or listener loop exit):

1. Stop accepting new connections (close the listening socket).
2. Wait briefly (up to 5 s) for active sessions to finish their
   current statement; then close remaining connections (their cleanup
   rolls back active transactions).
3. `runCheckpoint` (final).
4. Close file handles, release the flock, exit 0.

Crash-equivalence note: shutdown is an optimisation, not a
correctness requirement — killing the process at any point must be
equally safe (recovery handles it). Tests for shutdown therefore only
assert data visibility after restart, not the checkpoint's presence.

## 11.6 Background threads summary

| Thread | Started by | Job |
|--------|-----------|-----|
| listener | main | accept connections (11.3) |
| per-session | listener | one per connection (document 10) |
| checkpoint timer | startDatabase | every `cfgCheckpointSecs`, call `runCheckpoint`, log-and-continue on error (a failed checkpoint must not kill the server; consecutive failures are logged each time) |
| deadlock detector | startDatabase | only if D-12 = detection; document 04 §4.3 |
| WAL writer | — | none: WAL writes are synchronous from appending threads (document 03 §3.3) |

## 11.7 Logging

Server logs go to stderr as plain timestamped lines (startup banner
with port and dataDir, checkpoint completions, session errors that
are `XX000`, shutdown). No logging framework (boot libraries only).
Client-visible behaviour never depends on logs.
