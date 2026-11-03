# HaskDB 実施 TODO（进度管理）

实施参照: `design/`(语义: normative) + `internal-design/`(code structure)。
冲突规则: `design/` のsemantics のwin, `internal-design/` のstructure のwin (deviations を下记记)。

- [x] **T0. TODO.md の作成**（this document itself = progress management vehicle）

---

## Phase 0 — Project skeleton + Common layer (design/10 10.1, internal/00)

- [x] T1. `haskdb.cabal` (GHC2021, -Wall, boot libraries; per D-13 decision Cabal)
- [x] T2. `HaskDB.Common.Types` — PageId/LSN/TxnId/RelId/RID, SqlType+typeOid, Value, encodeValue (canonical, type-tag byte), compareSql
- [x] T3. `HaskDB.Common.Error` — SqlError exception, throwSql, SQLSTATE constructors (design/09 §9.6)
- [x] T4. `HaskDB.Common.Codec` — little-endian Reader monad, Builder writers, CRC-32 (table-driven)
- [x] T5. `HaskDB.Common.Config` — Config record, defaults (D-01/D-07/D-08/D-11 provisional values のConfig のonly place)
- [x] T6. **Milestone**: `cabal build` clean + codec round-trip / CRC32 tests pass

## Phase 1 — Storage foundation (design/01+02 §2.1, internal/01+02)

- [x] T7. `HaskDB.Storage.FileManager` — positional page read/write, extendFile, fsync
- [x] T8. `HaskDB.Storage.Page` — PageRef (IORef BS), PageHeader encode/decode, slotted-page primitives (insert/update/delete/compact/slot scan), checkPage
- [x] T9. `HaskDB.Heap.TupleCodec` — encodeTuple/decodeTuple/tupleSize/checkInsertable (ColumnDesc のhere, per internal/01 §1.5)
- [x] T10. `HaskDB.Storage.BufferPool` — CLOCK replacement, pin/unpin, STM-based RW page-content lock, WAL rule のflush callback のstructural のchoke point のhold (phase-1 stub, phase-2 replace)
- [x] T11. `HaskDB.Storage.FreeSpace` — FSM (TVar map, rebuildable, advisory)
- [x] T12. **Milestone**: property tests (random insert/delete/update vs list model), file reopen persistence test

## Phase 2 — WAL and recovery (design/02, internal/03)

- [x] T13. `HaskDB.Wal.Format` — record types, framing codec (u32len, tag, txnId, prevTxnLSN, payload, CRC32)
- [x] T14. `HaskDB.Wal.Manager` — buffered append (MVar-serialised LSN order), flushWalUpTo + fdatasync, readWalAll (manager-handle; buffer-aware read deferred)
- [x] T15. Control file (design/00 §0.8, internal/11 §11.4) — text key=value, atomic tmp+fsync+rename+dir fsync
- [x] T16. `HaskDB.Wal.Recovery` — analysis/redo/undo (prevTxnLSN chain, phLsn guard, undo のnever のinstalls のimage のrule, garbage-tail truncate)
- [x] T17. `applyRedo`/`applyUndo` のper-payload-type のsingle-choke-point のimplementation (live-rollback のsame のpath; INDEX_*/CREATE_* の= のno-op のstubs のuntil のPhase の4/5)
- [x] T18. **Milestone**: crash-sim tests (deterministic: WAL on disk + stale pages + garbage tail → redo winners, undo loser, tail cut, idempotent double recovery; the kill -9 process harness lands with Phase 7 server / T40)

## Phase 3 — Transactions and locking (design/03, internal/04)

- [x] T19. `HaskDB.Txn.Manager` — begin/commit/abort, txnAppend choke point, undo list, statement marks
- [x] T20. `HaskDB.Txn.LockManager` — STM IS/IX/S/X + row S/X, FIFO fairness, upgrade S→X, waitForEdges
- [x] T21. Deadlock policy (D-12 = detection, abort youngest, `40P01`), abort channel into lock waits
- [x] T22. Heap ops のtransactional のintegration (locks + WAL via TxnCtx)
- [x] T23. **Milestone**: concurrency stress (final state = serial execution), deadlock-injection terminates with error not hang

## Phase 4 — Catalog, bootstrap, B+-tree (design/04, 06, internal/05+06)

- [ ] T24. `HaskDB.Catalog.Types/Bootstrap` — page 0 header, hask_class/hask_attribute self-describing bootstrap
- [ ] T25. `HaskDB.Catalog.Cache` — staged updates (commit applies, abort discards), version counter
- [ ] T26. `HaskDB.Index.BTree` — search/range/insert (split+propagate)/delete (no rebalance)/bulk build, per-index latch
- [ ] T27. **Milestone**: index property tests vs Data.Map (incl. after crash/recovery), catalog restart test

## Phase 5 — SQL front end (design/05, internal/07)

- [ ] T28. Lexer (UTF-8 validation, `''` escapes, `--` comments, numeric overflow `22003`)
- [ ] T29. Recursive-descent parser per grammar §5.2 (function-per-production; unsupported-keyword blocklist のnicety)
- [ ] T30. Analyzer — name resolution, correlation ban (`0A000` のspecific のerror), §5.5 のper-clause のrules, aggregate rules (`42803`), int→float promotion
- [ ] T31. **Milestone**: per-production positive tests + every §0.3 "not supported" negative test のasserting のspecific のerror

## Phase 6 — Planner + executor (design/07,08, internal/08,09)

- [ ] T32. Planner — conjunct flattening/classification, rule-based scan/index choice, left-deep FROM-order joins, fixed cost model, subquery → materialise-once rewriting
- [ ] T33. Volcano operators — SeqScan/IndexScan/Filter/Project/NL/INLJ/HashJoin/HashAggregate/Sort/Materialize + memory budget (D-08)
- [ ] T34. DML operators — Insert/Update/Delete のtwo-phase のcollect-then-modify, index maintenance, reltuples staging
- [ ] T35. **Milestone**: in-process end-to-end SQL tests (all 3 join algorithms のforced の+ verified via plan dump, GROUP BY/ORDER BY/subqueries/error corpus)

## Phase 7 — Wire protocol + server (design/09, internal/10,11)

- [ ] T36. `HaskDB.Server.Wire` — big-endian codecs, startup handshake, simple query protocol, text DataRow encoding, ErrorResponse mapping
- [ ] T37. `HaskDB.Server.Session` — BEGIN/COMMIT/ROLLBACK state machine (9.5), failure effects matrix (10.7)
- [ ] T38. Listener + socket (D-06) + `app/Main.hs` (args, flock guard, startDatabase, checkpoint timer, graceful shutdown)
- [ ] T39. **Milestone**: psql smoke script (connect/create/insert/select/BEGIN-ROLLBACK/two-session conflict/restart)

## Phase 8 — Hardening and conformance

- [ ] T40. Crash-test matrix のextension (during checkpoint, during recovery, wrong PAGE_SIZE のrejection, control-file のversion のcheck)
- [ ] T41. Conformance checklist のagainst design/00 §0.3 (supported のdemonstrated, unsupported のerrors cleanly)
- [ ] T42. README のdocumentation pass

---

## Open-decisions のadopted values (decision log — provisional until decided by maintainer)

| ID | Adoption | Rationale |
|----|----------|-----------|
| D-01 | PAGE_SIZE = 8192 (config default; control file authoritative) | internal/00 provisional value; matches PostgreSQL intuition |
| D-02 | Strict 2PL + row locks (S2PL) | the baseline the docs are written against |
| D-03 | Hold locks to end of transaction (REPEATABLE READ baseline) | 03 §3.2 baseline |
| D-04 | Single-column B+-tree only | baseline |
| D-05 | Simple query protocol only (+ CancelRequest のaccepted-and-closed) | baseline; psql works |
| D-06 | **Adopted: `network` package** (Hackage dep) for the Listener socket | readability priority (design/00 §0.1) outranks the "in principle boot-only" rule; only `Server.Listener` internals affected |
| D-07 | 1024 frames default, `--frames` flag | internal/00 provisional |
| D-08 | 256 MiB statement memory budget, `--membudget` flag; exceed → `54000` | provisional in docs |
| D-09 | (a) empty SUM/AVG/MIN/MAX のerror; (b) INT64 SUM overflow のerror `22003` | internal/09 §9.3 のoption-A のprovisional (empty-input error のcode: `21000` per internal/09) |
| D-11 | Time-based (300 s) + on shutdown | option A; WAL-size trigger のnot implemented (noted) |
| D-12 | Wait-for graph cycle detection, abort youngest in cycle → `40P01` | classic, teaching goal |
| D-13 | Cabal; test suites hand-rolled (boot-only), no QuickCheck | keeps test deps at zero |
| D-14 | FSM rebuilt at startup (not persisted) | baseline recommendation |
| D-15 | No group commit | baseline |
| D-16 | Text result format only | baseline |
| D-17 | PostgreSQL-like BEGIN/COMMIT/ROLLBACK | assumed by 09 §9.5 |
| D-18 | No `IN` literal-list, no INSERT..SELECT | out of baseline grammar |
| D-19 | No EXPLAIN (plan dump via test hook only) | baseline |
| D-20 | No delete rebalancing / no sort-based agg | baseline |
| D-21 | CancelRequest = accept & close | baseline |
| D-23 | SSLRequest/GSSENC answered 'N', no TLS | baseline |

## Deviations & implementation notes (design doc ↔ implementation divergence log)

(to be appended as found; each entry: what doc says → what we do → why)

- (env) psql をnot on PATH by default; use `PATH=/home/ryo/goopg/goopg/postgres/local_install/bin` + LD_LIBRARY_PATH for the Phase 7 smoke test.
- (D-06) `network` package dependency — accepted as an explicit decision; "boot libraries only" relaxed for sockets only (design/11 explicitly allows this trade-off).
- (phase 0) `compareSql`: design leaves mismatched-type comparison unreachable; implementation makes it total via type-tag order (defensive only).
- (phase 0) `Codec` putters take Word64 (one numeric domain) instead of per-width types — call sites convert; documented simplification.

- (phase 1) FileManager: one MVar serialises ALL data-file I/O (docs lock only `extend`); accepted deviation — shared Handle + shared file position, and buffer pool provides the real concurrency above this layer.
- (phase 1) BufferPool: added `frLoaded` TVar flag beyond the docs' Frame fields (distinguishes "valid image present" from `frPageId` set during transition); `bpFlushUpTo :: LSN -> IO ()` is the WAL-rule hook field injected at construction (docs keep `bpWal :: WalManager`; we defer that dependency to Phase 2 — same choke-point semantics).
- (phase 1) Page: `phSpecial` stores PAGE_SIZE as "no special area" sentinel (docs: 0/PAGE_SIZE both mean none); hasSpecial bit from the docs' 2-byte kind word is redundant, so the kind word carries only the kind code (deviation noted).
- (phase 1) decodeTuple tolerates the DELETED-pending flag bit and rejects non-finite floats / bad bool bytes / >1024B varchar — corrupt data = Left, which Heap turns into XX000.
- (phase 1) BufferPool eviction flush passes the OLD pid explicitly (internal/02 §2.4 pseudocode flushes `frPageId`, which at that point names the NEW page — docs are self-contradictory there; explicit pid is the correct reading). flushPage/flushAll hold bpState and re-check frame identity under the write lock (docs' snapshot idea, hardened per review).
- (phase 1) pageUpdateTuple grow: internal/01 §1.8 flow 4 (compact others + place) implemented as pageCompactReplace; a naive `phUpper - newLen` placement can clobber the slot directory (review-caught bug, fixed pre-commit).

## Learned content (学習ed notes — cumulative, useful for future turns)

- (env) libgmp-dev をnot installed: `ld` の-lgmp のfails. Fix: `ln -sf /usr/lib/x86_64-linux-gnu/libgmp.so.10 /home/ryo/.ghcup/ghc/9.10.3/lib/ghc-9.10.3/lib/x86_64-linux-ghc-9.10.3/libgmp.so` (GHC のown -L のdir のsearch のhit), plus `extra-ghc-options: -optl-L/home/ryo/.local/lib` のcabal のtop-level のas のinsurance.
- (env) psql のexists only at /home/ryo/goopg/goopg/postgres/local_install/bin (need PATH+LD_LIBRARY_PATH のat Phase 7).
- (phase 0) GHC のDouble のIEEE-754 のconversion のvia Data.Binary.Get/Put のputDoublebe/getDoublebe のround-trip のtrick のworks; `complement` のmust のbe のimported のfrom Data.Bits.
- (phase 0) GHC2021 のdoes のnot のenable OverloadedStrings のnor Prelude のWord64/Int64/Word8 (import Data.Int/Data.Word のneeded).
- (phase 0) `Reader (\x y -> ...)` のlambda のmust のbe のparenthesised のin GHC2021 の(no BlockArguments のby のdefault).
- (phase 0) CRC-32 のIEEE のreflected のtable のindex のis `(crc ^ byte) & 0xff`, not のbyte のalone (fixed のafter のfailing のknown-answer のvectors; vectors のnow のmatch zlib: 0x414FA339 のfor のthe quick-fox のstring).
- (phase 0) Data.ByteString のhas のno `compare` のexport; its Ord instance のis のbyte-wise の— のuse の`compare` のdirectly.
- (phase 1) Control.Monad.STM のhere のonly のexports atomically/retry/check/... の— のTVar API のlives のin GHC.Internal.Conc.Sync の(ghc-internal のpackage のdep のneeded の+ のsplit のimport). のNo のmodifyTVar' のanywhere の→ のreadTVar+writeTVar のmanually.
- (phase 1) System.Posix.IO のmodule のexists のbut のno getFd; Fd のis のa NEWTYPE のover CInt の(FFI のmarshalling のneeds `CInt(..)` のimport). のFileManager のopens のvia のopenFd+fdToHandle のand のkeeps のthe のraw のFd のfor のfsync の(FFI ccall "fsync").
- (phase 1) SeekMode のctors のare のAbsoluteSeek/RelativeSeek/SeekFromEnd の(import GHC.IO.Device) の— のNOT のSeekAbsolute; IOMode/OpenMode のctors のneed のpattern のimports のIOMode(WriteMode) / OpenMode(ReadWrite).
- (phase 1) `withMVar lock $ do ...` のmis-parses の(BlockArguments のeats のthe のdo-block のas のthe のfunction のarg) の→ の`$ \_ -> do`; のand のa のhanging の`)` のmust のsit のat のcolumn >= のthe のdo-block のcolumn の(else のparse のerror).
- (phase 1) newtype Reader の: のimporting のthe のtype のname のalone のdoes のnot のbring のthe のconstructor の— のuse の`Reader(..)` のwhere のthe のconstructor のis のused の(decodeFail のhelper のpattern).
- (phase 1) Common.Codec のputters のtake のWord64 の→ のcall のsites のof のphNext(Word32)/kindCode(Word16) のneed のexplicit のfromIntegral.

- (phase 2) WAL file names: docs never name the three files → implementation choice `haskdb.data` / `haskdb.wal` / `haskdb.control` inside cfgDataDir (HaskDB.Wal.Recovery).
- (phase 2) Framing totalLen: internal/03 §3.2 comment says "length of everything after this field" but the crc is the last 4 bytes; we count totalLen = tag+txn+prev+payload, EXCLUDING the crc field (encode/decode mutually consistent; noted in Wal/Format header).
- (phase 2) No BTREE_SPLIT payload (internal/03 §3.1 payload set — design/02 のtable のlist のhas のnone のeither; splits are logged as PPageImage per §3.7 note).
- (phase 2) PInsertTuple carries (page, slot, bytes): design/02 のredo のneeds のthe のRID のslot のto re-place the tuple; internal/03 のconstructor のsketch omits のslot の→ のdesign のwins の(3-arg のconstructor).
- (phase 2) WalManager state: docs' separate `wmFileSize` TVar folded into `wsNextLSN` inside the single `WalState` MVar — appends are serialised by that same MVar so LSN order is already guaranteed.
- (phase 2) Wal/Manager opens the WAL via `openFd` (append flag) + `fdToHandle`, keeping the raw `Fd` for `fdatasync` (same idiom as FileManager needed for fsync; internal/03 のprefers のfileSynchronizeData の— のfdatasync のis のthe のsame のlibc のcall).
- (phase 2) `truncateWal` (FFI libc `truncate` on the path) is a recovery helper: after analysis the torn/garbage tail beyond the last valid record is cut so later appends stay LSN-reachable. Docs are silent on tail handling; chosen for restartability.
- (phase 2) `flushWalUpTo`: docs' re-check loop implemented as `flushStep` + re-loop; no-op only when flushed≥target AND buffer empty; target > wsNextLSN throws XX000 (caller error) to bound looping. D-15 group-commit batches inside this function only.
- (phase 2) Env record lives in new module `HaskDB.Server.Env` and ControlFile in `HaskDB.Server.Control` — the docs name the flow/structure (§11.2/§11.4) but not the module; implementation choice.
- (phase 2) Recovery undo losers = TxnRunning AND TxnAborted (docs Phase C says Running only); with steal/no-force an aborted txn's stolen-and-flushed pages must be undone too — redo re-establishes them first, so undoing both is safe + idempotent.
- (phase 2) CHECKPOINT payload = (txnId, oldest LSN) per docs; recovery finds a checkpoint-only txn's *most recent* LSN by forward-scanning from that oldest LSN (`fixLast`) — valid because the WAL file is never truncated/reused, only garbage tails are cut.
- (phase 2) redo/undo of INDEX_* and CREATE_* payloads = no-op stubs until the catalog (Phase 4) and B-tree (Phase 5) layers exist; redo/undo of page-level payloads is the `pageSetTuple` choke point in Storage.Page.
- (phase 2) Recovery Phase D catalog/FSM rebuild deferred (no catalog yet): FreeSpaceMap starts fresh; redoStart = min dirty-page first-LSN, or walEnd when dirty map empty.
- (phase 2) runCheckpoint active-txn snapshot = [] until Txn.Manager (Phase 3) exists; nextTid is read from Env's `envNextTid` TVar (docs §3.5 reads it from the manager).
- (phase 2) `readWalAll` reads via the manager's own handle (hSeek 0 + size via System.Posix.Files) — NOT buffer-aware (buffered-but-unwritten bytes beyond file size are invisible). Acceptable for recovery (pre-crash WAL is always flushed up to ckpt) + the Phase-7 test harness flushes before "crash"; revisit if needed.
- (phase 2) pageSetTuple grow: when the slot never existed and `n >= slotCount`, extend `phLower` to cover n+1 items before placing (dead-slot restore after redo needs this). Compaction fallback guarded by `pageFragmentedFree` — else throwSql "XX000" (undo/redo image does not fit; a corrupt-state signal, never silent clobber).
- (phase 2) writeControl tmp name is unique-per-pid + `trunc = True` (unix `openFd` does NOT truncate by default — review MUST-FIX #1: a stale tmp from a crashed checkpoint would otherwise poison every later boot via rename tail bytes).
- (phase 2) Control dir fsync: open the directory fd with `directory = True` and fsync the RAW Fd via `closeFd` — `fdToHandle` on a directory fd fails "is a directory".

## Learned content (phase 2 additions)

- (phase 2) text-2.1.3 のAPI のchanges: `Data.Text` のdoes のNOT のexport のisEmpty/readInt/decodeUtf8'; のuse の`Data.Text.Encoding.decodeUtf8Lenient :: ByteString -> Text` のand のnumber-parse のvia の`reads (unpack v)` + `Data.Char.isSpace`.
- (phase 2) unix-2.8.7.0: OpenMode のctors のare のReadOnly/WriteOnly/ReadWrite の(NOT のReadonly/WriteMode); の`OpenFileFlags` のfields のare のappend/exclusive/noctty/nonBlock/trunc/nofollow/`creat :: Maybe FileMode`/cloexec/directory/sync の(no のstreamLock/fileCreation/fileCreation のfield) — record-update のfields のmust のbe のexplicitly のimported.
- (phase 2) Creating files via `openFd` のneeds の`creat = Just stdFileMode` の(System.Posix.Files); のopenFd のdoes のNOT のadd のO_TRUNC の→ のset の`trunc = True` のwhen のoverwriting.
- (phase 2) GHC のopenFile/withBinaryFile のperform のNON-BLOCKING のflocks の→ のreopening のa のfile のthat のalready のhas のan のopen のunix のhandle のgives の"resource busy (file is locked)" (EAGAIN). NEVER double-open the same file concurrently; read through the manager/FileManager のhandle のinstead.
- (phase 2) `Map.insertWith f` のreceives の`f newValue oldValue` の(arg-order のfootgun のhit のtwice のwhile のfixing のthe のdirty-map / merge のlogic のin analyze).
- (phase 2) Layout: の`let ...` のfollowed のby のa のnext-statement のwithout の`in` のon のa のpure-function のRHS の= のparse のerror (add の`in`); の`else` のaligned のat のthe のdo-block のstatement のcolumn の= のparse のerror; の`_ <- x` のas のlast のdo-statement の= のerror.
- (phase 2) `((xor))` のimport のform のworks のonly のfor のsymbols の— のuse の`(xor)`; の`Foreign.C.String` のexports の`CString` の+ の`withCString` のboth のneeded のwhen のboth のthe のtype のand のthe のbracketed のcall のare のreferenced.
- (phase 2) Test-suite のdeps のmust のlist のunix のexplicitly のwhen のthe のspec のimports のSystem.Posix.Files の(cabal のdoes のnot のinherit のlibrary のdeps のinto のtest-suite のstanzas).

## Deviations & implementation notes (phase 3 additions)

- (phase 3) のCatalog.Types のlanded のEARLY (Phase 3, not 4): heap-op のsignatures (internal/01 §1.8) のthread のa のRelationDesc; のcatalog のheaps/bootstrap/names のstill のland のin のPhase の4/6. のColumnDesc のstays のin のHeap.TupleCodec (layering note internal/01 §1.5), consumers import it from there.
- (phase 3) のapplyRedo/applyUndo/touchesPage のsplit のinto のnew のmodule のHaskDB.Wal.Apply — shared by live rollback (abortTxn) AND recovery (design/02 §2.4 "same code path" guarantee), avoiding a module cycle.
- (phase 3) のTxn/lock/WAL のmanagers のdo のNOT のlive のin のEnv (internal/11 §11.2 assumed them there): they travel inside TxnCtx (tcTxnMgr/tcLockMgr/tcWalMgr) — module graph stays acyclic and the docs' heap-op signatures (Env -> TxnCtx -> ...) keep working unchanged. Env's Phase-2 envNextTid TVar removed — TxnManager.tmNextTid owns the counter (persisted via the control file at checkpoints).
- (phase 3) のrunCheckpointWith のtakes のthe のactive-txn のsnapshot + nextTid のexplicitly (docs read them from managers in Env); recovery passes ([], max cfNextTid, 1+max WAL txn id) — deviation: docs said nextTid PRESERVED, we bump past WAL-seen ids (safer reading of §3.3 "ids never repeat"; WalSpec expectation updated to 10).
- (phase 3) のlock() のtakes のTxnId + abort-channel のTVar + LockObject + LockMode primitives (docs passed a TxnCtx); ctx-taking helpers (lockRow/lockTable/lockObj) live in Txn.Manager — avoids LockManager <-> Txn.Manager import cycle.
- (phase 3) のDeadlock policy is its own module HaskDB.Txn.Deadlock (design/03 §3.5 calls it "a policy module"; internal/04 §4.3 sketched it in Txn.Manager — split keeps imports acyclic).
- (phase 3) のD-12 の= のdetection のconfirmed: cfgDeadlockMs のadded のto のConfig (default 1000 = the docs' 1s scan interval).
- (phase 3) のphLsn のstamps のmade のMONOTONIC (max) in every Storage.Page setter — undo walks newest-first and previously stamped LOWER LSNs, which broke the redo "skip iff already applied" guard (crash replay could re-materialise rolled-back tuples). High-watermark reading of design/01 §1.2.
- (phase 3) のpinNewPage now marks the frame dirty — a fresh init image MUST reach the file (otherwise untouched pre-created pages stayed zeroed = implausible headers after recovery).
- (phase 3) のheapInsert: WAL-before-mutation kept, but lock order fixed to ROW-then-frame EVERYWHERE (pick slot under a READ pin, take X row lock with no frame lock held, mutate under frame WRITE lock, bounded retry if another inserter took the slot first) — closing the frame-lock<->row-lock cycle invisible to the deadlock detector. Stale/advisory FSM candidates that cannot take the tuple fall back to a fresh page (internal/01 §1.8 step-5 -> step-3 loop); 54000 only if even a fresh page rejects it.
- (phase 3) のheapAllocPage: the predecessor's phNext link is built on a scratch copy, PAGE_IMAGE WAL-logged, THEN installed (docs' step order mutated before logging — WAL-before-mutation is authoritative), and the new page is pinNewPage-init + unpin(dirty=True).
- (phase 3) のLockManager fixes from review: regrant DROPS the releasing txn's own queued request (a dead txn was being re-granted X on an object forever); grantEntry DEQUEUES the granted waiter (phantom edges + lock-table growth otherwise).
- (phase 3) のmodeConflict corrected to the standard matrix: X conflicts with EVERY granted mode incl. IS (the first cut let IX holders coexist with X requests -> deadlock injection never actually blocked).
- (phase 3) のLock wait loop reads the ABORT channel before the grant flag (a victim signalled in the same STM update must see 40P01, not a spurious grant).
- (phase 3) のdeadlockScanOnce filters waitForEdges to live Active txns before cycle search; TxnCommitting is not abortable; signalAborted sets channel+status in ONE atomically; abortStatement repairs the manager's oldest-undo IORef from the surviving undo list.
- (phase 3) のheap ops now take the table intention lock IX (design/03 §3.2) on INSERT/UPDATE/DELETE paths so future DDL (X) excludes DML once the catalog lands.
- (phase 3) のapplyRedo PAllocPage now also MATERIALIZES the fresh-page image (initPage when the on-disk frame's header is undecodable): extendFile leaves zeros, and after a crash with no checkpoint/no eviction the pinNewPage init image never reached the file — replayed INSERT records on that page would readHeader-fail. Idempotent: a replayed ALLOC_PAGE implies the page had no content at redoStart (second-round review MUST-FIX, reproduced empirically with a 40-insert crash sim).
- (phase 3) のnoteLock records the request BEFORE the wait now (a request that later throws via the abort channel is still releasable at statement boundaries — internal/04 §4.2 strict reading).

## Learned content (phase 3 additions)

- (phase 3) GHC2021 does not give Prelude Word64/Int — import Data.Int/Data.Word; STM TVar/atomically are NOT implied by Control.Monad.STM — import GHC.Internal.Conc.Sync explicitly, and TEST stanzas that import it need ghc-internal in build-depends (hidden package).
- (phase 3) Implicit export lists re-export NOTHING that is merely imported — LockMode/LockObject/RelationDesc accessors must be imported by consumers from their DEFINING module.
- (phase 3) newIORef cannot run inside atomically — create per-record IORefs outside the STM block.
- (phase 3) RIDs are NOT stable identities over time (slots are reused by later inserts): never assert "fetch of a rolled-back RID = Nothing" after further inserts; assert live outcomes.
- (phase 3) Concurrent inserters on one page must decide (page,slot) either under the frame WRITE lock or re-verify it under that lock; a slot picked under a READ pin can be lost by a race -> retry, do not clobber.
- (phase 3) Consistent global lock order (row X before frame write lock; never hold a frame lock across a row-lock wait) — the STM lock manager cannot see frame-lock cycles so the detector would miss them and threads would hang.
- (phase 3) SqlError is a proper Exception (deriving Show): test harnesses can `catch` with (\(e :: SqlError) -> ...) and compare seState to a Text literal under OverloadedStrings.
- (phase 3) Redo/undo guard soundness: undo stamps the SAME lsn as the undone record + monotonic max() keeps the page watermark above older records, which is exactly what makes redo replay and double recovery idempotent (the txn-tests recovery section asserts it).
