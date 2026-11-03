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

- [x] T24. `HaskDB.Catalog.Types/Bootstrap` — page 0 header, hask_class/hask_attribute self-describing bootstrap
- [x] T25. `HaskDB.Catalog.Cache` — staged updates (commit applies, abort discards), version counter
- [x] T26. `HaskDB.Index.BTree` — search/range/insert (split+propagate)/delete (no rebalance)/bulk build, per-index latch
- [x] T27. **Milestone**: index property tests vs heap ground truth (incl. after crash/recovery), catalog restart test

## Phase 5 — SQL front end (design/05, internal/07)

- [x] T28. Lexer (UTF-8 validation, `''` escapes, `--` comments, numeric overflow `22003`)
- [x] T29. Recursive-descent parser per grammar §5.2 (function-per-production; unsupported-keyword blocklist のnicety)
- [x] T30. Analyzer — name resolution, correlation ban (`0A000` のspecific のerror), §5.5 のper-clause のrules, aggregate rules (`42803`), int→float promotion
- [x] T31. **Milestone**: per-production positive tests + every §0.3 "not supported" negative test のasserting のspecific のerror

## Phase 6 — Planner + executor (design/07,08, internal/08,09)

- [x] T32. Planner — conjunct flattening/classification, rule-based scan/index choice, left-deep FROM-order joins, fixed cost model, subquery → materialise-once rewriting
- [x] T33. Volcano operators — SeqScan/IndexScan/Filter/Project/NL/INLJ/HashJoin/HashAggregate/Sort/Materialize + memory budget (D-08)
- [x] T34. DML operators — Insert/Update/Delete のtwo-phase のcollect-then-modify, index maintenance, reltuples staging
- [x] T35. **Milestone**: in-process end-to-end SQL tests (all 3 join algorithms のforced の+ verified via plan dump, GROUP BY/ORDER BY/subqueries/error corpus)

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

## Deviations & implementation notes (phase 4 additions)

- (phase 4) のINDEX redo/undo は NOT logical: every index mutation logs PPageUndo(page のbefore-image) + PPageImage(after-image) and Wal.Apply treats INDEX_INSERT/INDEX_DELETE as no-op markers (physiological replay; design/04 §4.5 requires before-image restoration, which entry-level undo cannot express for splits). New WT_PAGE_UNDO tag (=13) in Wal.Format.
- (phase 4) のsplits REBUILD the whole page from decoded entries (buildSlottedImage) instead of surgical slot edits — simpler and consistent with the physiological replay above; recorded in the module header.
- (phase 4) のdescend rule is STRICT (last sep STRICTLY < key) + chain-follow while page-empty or max <= key: design/04 §4.3 says sep = min key of child with <= descend, but duplicate copies of a separator can sit on BOTH sides after a split; strict+chain is the rule that finds every duplicate in both directions. Leaf splits prefer a key-change boundary.
- (phase 4) のbtreeInsert/btreeDelete thread the CURRENT ROOT explicitly and btreeInsert RETURNS the possibly-new root (docs' btreeInsert returns (); internal/05 §5.2's IndexHandle made real) — a later op in the same txn must not descend a stale root after an earlier root split. relroot publication is Bootstrap.updateIndexRoot (WAL-logged heapUpdate of the class row).
- (phase 4) のDDL takes lock-table X (not LIx) on the NEW relid, and CREATE INDEX also takes X on the OWNING TABLE (design/03 §3.2 "DDL takes X; DDL/DML exclude"; index WRITERS likewise take X on the index relid — closes the window where a later txn descends a root that a committed split already invalidated).
- (phase 4) のCREATE INDEX bulk build logs PAllocPage+PPageImage per page but NO per-entry INDEX_INSERT markers (physiological replay makes them pure bloat); an aborted CREATE INDEX leaves orphan index pages (harmless; catalog rows are undone via their heap INSERT_TUPLE records).
- (phase 4) のCREATE TABLE allocates the relation's FIRST heap page at DDL time (relpages_head never 0); heapAllocPage chains further pages via phNext + PPageImage, loadCatalog re-walks the chain. stageAllocPage (cache rdPages growth during INSERT) stays executor-facing (Phase 6), so in-session rdPages lists are head-only until reload.
- (phase 4) のrelindex_column stores ordinal+1 (0 = "not an index") — design/06 §6.3's 0-based ordinal collides with a genuine column-0 index.
- (phase 4) のbootstrap writes page 0 + the two catalog heaps OUTSIDE any transaction (db not open yet), then bootstrapCheckpoint so recovery starts past it; relids 1/2 fixed; DDL relid counter bump = PPageUndo+PPageImage pair on page 0.
- (phase 4) のdesign/04 §4.3 pd_special (level) / pd_flags root-marker fields are NOT implemented — PKIndexLeaf/PKIndexInternal page kinds are the only discriminator.
- (phase 4) のper-index MVar latch (internal/05 §5.2) is created ATOMICALLY inside one modifyMVar of the latch map (the first cut's readMVar+modifyMVar_ race handed two callers distinct latches).
- (phase 4) のloadCatalog rebuilds rdColumns from hask_attribute rows and index key types from a pure column map (the first pass's enriched descs, not the raw class rows — the class row itself carries no column list).

## Learned content (phase 4 additions)

- (phase 4) のa findEntry/duplicate probe must run on the DESCENDED LEAF, never on the root — after any root split the root is an internal page and leaf-entry decoders throw "corrupt leaf entry" on internal payloads.
- (phase 4) のrange/chain walks continue while the page is EMPTY or its max key is still below hi (hi=Nothing never stops); a "stop when max >= hi" formulation that treats empty pages as stoppers silently truncates scans after deletes (BTree.hs walk rule mirrors chainPast).
- (phase 4) のtest ground truth must dedup its page list (nub) once CREATE TABLE pre-allocates its head page — scanning the head twice (catalog list + RID-derived list) double-counts rows.
- (phase 4) のa test that deletes INDEX entries only must compare against heap-minus-deleted: the heap rows stay, so plain heap ground truth breaks after the delete phase; run the crash/recovery check BEFORE the delete phase so replay of the fill is verified.
- (phase 4) のpage 0's counter field decode failure must not default to relid 0 (the no-owner sentinel): decode errors throw XX000 (corrupt-data rule design/01 §1.9).
## Deviations & implementation notes (phase 5 additions)

- (phase 5) UTF-8 のvalidation のis の`Data.Text.Encoding.decodeUtf8'` のof のthe のWHOLE input (22P02) instead のof のinternal/07 §7.1's のhand-rolled のDFA; tokPos counts BYTES.
- (phase 5) のlexer のemits `TSymbol '.'` — internal/07 §7.1's symbol set ( ) , ; * = < > omits it, yet §7.2 の`ColRef { crQualifier }` のand のthe のcorrelation/qualified のresolution のin §7.4 のstep の2 のneed のqualified のnames; のdesign/05 §5.2 のNEVER のgives a の`col_ref` のproduction のat のall (no の`.` のanywhere のin のthe のEBNF). のDoc のconflict のreported のboth のways; のthe のdot のis のrequired のto のbuild のthe のAST.
- (phase 5) lexNum のrewritten: a の'.' のNOT のfollowed のby のa のdigit は NOT のa のnumber (it のlexes のas のthe のTSymbol の'.'); のexponent のsign は taken のONLY のdirectly のafter のe/E; のa のdangling の'e' は NOT のconsumed. のA のfloat のliteral のwhose のtext のdenotes a NON-FINITE のvalue (`1e400`) は rejected のwith の22P02 — design/05 §5.4 のsays "`Infinity` literals のare のlikewise rejected" のbut のnames のno のSQLSTATE; の22P02 = "invalid text representation (bad literal)" のper のdesign/09 §9.6 のtable の(provisional のchoice).
- (phase 5) のparser のis のdirect の`Either SqlError (a, [Tok])` のdescent, NOT のthe のinternal/07 §7.3 の`Parser` のnewtype/monad — same のfunction-per-production のshape, のnames のmirror §5.2 のproductions の(pStatement/pSelectStmt/pFromList/pOrderList/pPred/pOperand...).
- (phase 5) §5.11 のvs §7.3 のnicety のconflict のresolved のas のfollows: `reservedWords` は = §5.11's のset のEXACTLY のplus の`is` (a §5.2 のkeyword のat のline の76, so §5.11 のmakes のit のreserved の→ の42601 のas のan のidentifier); のthe の`unsupportedWords` のblocklist のis のchecked のONLY のwhere the のconstruct のwould のlegally のappear (statement のhead, clause のboundaries のvia のpeekUnsupported, のselect-item/operand/from-item/order-item のheads, のVALUES のliterals, のUPDATE のSET のRHS) → の0A000 のnaming のthe のconstruct. のpIdent のitself のchecks のONLY reserved のwords, のso の`create table limit (…)` のparses の(per §5.11 のthose のare のNOT のkeywords).
- (phase 5) §7.3 のblocklist のwords のare のchecked のat のhead のpositions のvia の`headUnsupported` (= のblocklist のMINUS のreserved), のso のa のreserved のword のnever のloses のthe の42601 のclass.
- (phase 5) の`RSelect` のcarries の`rsOutNames :: [Text]` のand の`resolveItem` のreturns の`[(RSelectItem, Maybe Text)]` — §7.4 のRSelectItem のhas NO alias のslot のyet のits のstep の6 のneeds のoutput のnames (alias の| のcolumn のname の| の`?column?`); のthe のdocs のare のself-inconsistent, のthe のfield のis のunavoidable (ORDER BY のand のderived-table のnaming のconsume it).
- (phase 5) のAnalyzer のscope のdiscipline: の`outer` (ENCLOSING のquery のnames, used ONLY to のupgrade a のresolution のmiss to のthe のspecific の0A000) のis のkept SEPARATE のfrom の`outerSub` (enclosing + のthis のquery's のnames, inherited のby のits のsubqueries). のPassing のthe のmerged のlist into のthe のcurrent-scope のresolution のmade `select q.id のfrom のusers` のreport の0A000 のinstead のof の42P01.
- (phase 5) のUPDATE/DELETE のthread のtheir のone-slot のscope のnames のas のouterSub の(earlier のcut のpassed の`[] []`, のso のcorrelated のreferences のinside のa のDML のWHERE のdegraded のto の42703 — §5.6 の"not a のsilent のinner-scope のmiss").
- (phase 5) のFROM-subqueries (derived のtables) のsee のENCLOSING のnames のONLY: のSQL のdoes のnot のlet のa のderived のtable のreference のits のFROM siblings, のso のthose のnames のnever のenter のthe のcorrelation のset.
- (phase 5) の`resolveCol`: のqualified `q.c` のnow のtests のthe のQUALIFIER のfirst (§7.4 のstep の2 の"find slot named q (else 42P01), then column c in it (else 42703)") — のthe のfirst のcut のreported の42P01 のfor のa のPRESENT のslot のwith のa のmissing のcolumn.
- (phase 5) のIN-subquery のtype のrule のis のnow のSTRICT (`t == rcType のrc`): のdesign/05 の§5.3 のpromotes INTEGER のLITERALS のONLY, のand のinternal/00 の§0.2 の`compareSql` のrequires のequal のtypes — のthe のfirst のcut のlet のan のINT64 のcolumn のcompare のagainst のa のFLOAT64 のsubquery のcolumn (42804 のnow).
- (phase 5) の`pPrimaryPred` のdispatches のon のthe のtoken のafter `'('`: `'(' select_stmt ')'` のis のa のSCALAR のSUBQUERY のoperand (§5.2 のlines の75/79, の§5.5/§5.6) のwhile `'(' predicate ')'` のis のa のparenthesized のpredicate; のwithout のthe のdispatch の`where (select …) > 2` のwas のunparseable (review のMUST-FIX).
- (phase 5) のUPDATE のSET のRHS のuses の`pColRef` (§5.2 の`assign ::= ident '=' ( literal | col_ref )`) — のqualified のcol_refs のare のrepresentable のin のthe のAST のand のwere のdropped.
- (phase 5) の§5.2 の`ordinal` のis のan UNSIGNED のinteger: のa のnegative のORDER BY のkey のis のrejected のat のPARSE のtime の(42601); のout-of-range のpositives のstay の42703 (§7.4 のstep の5).
- (phase 5) のVALUES のliterals のget のthe のblocklist のnicety (`values (null)` の→ の0A000) — §7.3 の"where they のwould のlegally のappear".
- (phase 5) のINSERT のVALUES のarity のmismatch のuses のSQLSTATE の`4280`: のneither のdoc のassigns one のand のdesign/09 §9.6 のhas のno のrow for it; のit のis のPostgreSQL's のown のcode のand のis の4 のchars, のnot のthe の5-char のconvention のshown のin internal/00 §0.4 の(PROVISIONAL — flag のfor のthe のmaintainer).
- (phase 5) のanalyzer のVARCHAR の1024-byte のcheck は applied のat のliteral→column のbinding のONLY (INSERT/UPDATE), のper のdesign/05 §5.3; のinternal/07 §7.1 のasked for の"every のstring のliteral のthat のflows into a VARCHAR-typed のposition" (incl. のcomparisons) — のconflict, のdesign/ のwins のsemantics.
- (phase 5) のCREATE のTABLE の"≥1 のcolumn" のanalyzer のguard の(42600) は defensive/unreachable: のthe のparser のrejects の`()` のfirst のwith の42601; のno のdoc のgives の42600.
- (phase 5) のINSERT のwith a PARTIAL のcolumn のlist のis のaccepted (docs のsilent, のno のdefaults のexist のin the のsystem) — のleaves のthe のremaining のcolumns のundefined; のan のexecutor のconcern for のPhase の6, のNOT のa のchoice のmade のhere.
- (phase 5) のAnalyzer のerror のctors のreuse のHaskDB.Common.Error's のshared のset (42P01/42703/42702/42P07/42701/22001/21000 のvia のerrUndefinedTable/errUndefinedColumn/errAmbiguous/errDupName/errDupColumn/errStringTooLong/errScalarSubqRows) per internal/00 §0.4; のlocal のctors のexist のONLY where のthe のshared のset のhas のno のconstructor (correlation の0A000, のgrouping の42803 のwith のthe のcolumn のname, aggregate/literal のtype のnotes の42804, のORDER-BY の42703 のwith のthe のterm).
- (phase 5) の`analyze :: CatalogCache -> Statement -> IO Analyzed` のthrows のSqlError のin IO (the のdocs' のsignature のis IO) のrather のthan のreturning のEither; のDDL のcases のpass のthe のRAW のstmts のthrough のto の`ACreateTable/ACreateIndex` (the のexecutor のre-checks のunder のthe のtable のX のlock).

## Learned content (phase 5 additions)

- (phase 5) のByteString は NOT のpattern-matchable のas `(a : b : _)` (type の[a0]) — のguard のon の`BS.head`/`BS.index` のinstead.
- (phase 5) のcomment-skip のarithmetic のfootgun: のwhen の`body` のhas のALREADY のdropped のthe のtwo の'-' のbytes, のthe のrest のis の`BS.drop t body`, のNOT の`BS.drop (2+t) body` の(the のfirst のcut のate のtwo のtokens のchars).
- (phase 5) のa の"takeWhile のthen のfragment" のscanner のCANNOT のsee のthe の'.': の`extendFrac` のmust のtest のthe のFOLLOWING のbyte のdirectly, のand のthe のexponent のmust のreturn の`Maybe` のso a のdangling の'e' は not のswallowed.
- (phase 5) の`-` のis のfolded のINTO のthe のnumeric のtoken のby のthe のlexer, のso の`order by -1` のarrives のas の`TInt (-1)` — のunsigned のproductions のmust のbe のenforced のin のthe のPARSER.
- (phase 5) のevery のident のentry point のmust のroute のthrough の`pIdent`/`pColRef`: のmatching の`TIdent n` のDIRECTLY のat のthe のselect-item/operand/order-item/from-item のheads のlets のreserved のwords (`on`, `is`, …) のpass のas のidentifiers (42601 のexpected).
- (phase 5) の`pOptAlias` のbare-alias のmust のreject のreserved のAND のblocklisted のwords, のelse `from のusers のlimit の3` のbinds の`limit` のas のan のalias のand のthe の0A000 のnicety のnever のfires.
- (phase 5) のderived-table のbranch のmust の`eatSym ')'` のBEFORE のlooking のat のthe のalias — のchecking のthe のalias のfirst のmakes のEVERY のlegal のderived のtable のfail の"requires an alias".
- (phase 5) のAnalyzer のtests のmust のuse の`seMessage` のfor のmessage needles のand の`T.pack want == seState e` のfor のcodes (seState のis のText, のliterals のare のString のwithout のOverloadedStrings のat のthe のcomparator).
- (phase 5) の`SelAgg` のalias のmust のbe のKEPT のin の`resolveItem` — のdropping it のerases の`count(id) as n` のfrom のrsOutNames.
- (phase 5) の`AInsert _ _ rows` のand のthe のother のAnalyzed のctors のare の1-arity のwrappers: の`ACreateTable (CreateTableStmt …)` のneeds のparens (the のctor のtakes のONE のarg).
- (phase 5) のGHC のreports のduplicate のtype-signature/redefinition のerrors のacross のan inserted のblock のbefore のa のreal のone — のcheck の`grep -c "^name ::"` のbefore のrebuilding.
- (phase 5) のforcing の-Wall のoutput: のcabal のcaches のclean のbuilds の(`cabal build` のsays の"Up to のdate"), のso のappend の`-- probe` のto のeach のsource のfile, のbuild, のthen の`sed -i '/^-- probe$/d'` — の`-fforce-recomp` のvia の--ghc-options のdoes のNOT のwork のafter のthe のfact のis のcached.
- (phase 5) の`cabal test all` のruns のall の6 のsuites; のsql-tests のneeds のno のscratch のdirectory, のthe のothers のdo (rm -rf のthem のbetween のruns).

## Deviations & implementation notes (phase 6 additions)

- (p6) の`classify` のruns のon のthe のPHYSICAL のpredicate のtype (`PPred`) — のinternal/08 の§8.2 のnames のthe のlogical のtype, のyet の§8.5 のrewrites のEXISTS/IN/scalar のsubqueries のBEFORE のclassification のand のalready のemits のa のseparate のphysical のtype.
- (p6) の`planSlotScan` のtakes のthe のpre-planned `Materialize` のfor のderived-table のslots (planning のa のsubplan のis IO; のplanSlotScan のis のpure) and の§8.3 のrule の5 のFilter-over-derived-scan のaccumulates のinto のthe のTOP-level のresidual のFilter (§8.4's のpseudocode のaccumulates のthe のsame のway).
- (p6) のEXTRA のequijoin のpredicates のconnecting のa のslot のbecome のtop-level residuals: の`PIndexNestedLoop` のhas NO residual のslot (driving のequality のenforced のby のthe のindex のprobe), の`PHashJoin` の`jsResidual` のstays `Nothing` (equality のenforced のby のthe のhash のkey), の`PNestedLoop` のcarries のthe のdriving のequality のre-localized (§8.5 のrewrite のof のa のdriving の`a = b` のinto のthe のnode) — のconjunction, のso のequivalent.
- (p6) のINLJ のBRANCH のdiscards のslot i's のplanned のscan (the のprobe のreplaces のit, の§7.4 のrule の1) — のthe のpredicates がscan のHAD のconsumed のinto のbounds のwould のbe のLOST; のthey のrejoin のthe のtop-level のresidual のFilter のvia のplanSlotScan のreturning のa のTHREE-tuple の(plan, のleftovers, のconsumed). のinternal/08 の§8.4 のpseudocode の`tree := IndexNestedLoop(tree, のtable_i, のindex)` のhas のthe のsame のhole; のdesign/07 の§7.3 の"every のconjunct は はa のscan bound, のa のjoin-node のpredicate のor のa のresidual のfilter" のdemands のthe のfix.
- (p6) の§7.4 のrule の2 のthreshold のand のthe のHashJoin のbuild-side のchoice のuse のthe のCATALOG の`reltuples` のfor のthe のbase のrelation のR (`rows(R)` のin の§7.4/§7.5 のIS のreltuples — の"inputs の… のonly のthese"); の`planRows` のof のan のIndexScanned のslot のis のa のFILTERED のestimate のand のwould のflip のthe のchoice のbelow のthe のthreshold. のThe のaccumulated のtree のT のhas のno のreltuples, のits のestimate のstands.
- (p6) のScan のbounds のaccept のLITERAL のoperands のonly (`asBound` のmatches `POLit`): のdesign/07 の§7.3 のline の55 のalso のallows のan のUNCORRELATED のSUBQUERY のvalue のas のa のscan のbound, のbut の§8.5 のrewrites のthose のoperands のto の`POScalar`/`PPIn` のSubqueryId のrefs — のthe のdocs' の"subquery のoperands のwere のrewritten のto のliterals のin の§8.5" のparenthetical は のUNIMPLEMENTABLE のas のthe のdocs のstand (reported のboth のways). のSuch のa のpredicate のstays のa のresidual のFilter のover のa のSeqScan (correct のrows, のweaker のplan).
- (p6) のJoinSides の`jsBuildKey`/`jsProbeKey` のaddress のEACH のside's のOWN のrows (the のplanner のemits のthe のouter のside's のflat ref — のwhich のis のalso のits のside-local のindex — のand のthe のinner のside's のslot-column のordinal). のThe のdocs のtype のboth のas の`FlatRef` の(joined-row のscope); のthe のemitted のrow のIS のthe のjoined-row のlayout, のso のonly のthe のkey のfields のdiffer — のTODO/decision のD-23 のfamily.
- (p6) のNestedLoop/IndexNestedLoop のemit のthe のCONCATENATION `outer ++ inner` (§8.5 の"emit のpairs") のand のthe のresidual のpredicate のis のevaluated のon のthat のjoined のrow. のEmitting のthe のinner のrow のalone broke のevery のcross-predicate のjoin (the のreview のcaught のthe のout-of-range の`POCol` → のnon-SqlError の→ のXX000).
- (p6) の`Filter` のPASSES のTHROUGH のthe のchild's のsource のRID (a のModify's のchild のIS のthe のWHERE-filter のover のthe のscan, §8.8 のstep の1 のcollects `(RID, のoldTuple)` のpairs); の§9.1 の"RID のonly のfrom のa のbase のscan" のwording のmeans のRID-less のafter のnodes がMATERIALISE のor のJOIN.
- (p6) のIndexScan のmaterialises のthe のwhole のmatch のlist のat OPEN (the のdocs' のpinned のleaf のcursor は はan のoptimisation): の`heapFetch` のtakes のS のon のevery のhit のat のopen のand の`queueNext` のre-books のS のper のreturned のrow (S2PL のre-grant のis のa のno-op の— のNO のlock のDOWNGRADE のoccurs); のthe のeager のopen-time のlocking のchanges のthe のdeadlock/abort のprofile のvs の§8.2's のone-by-one のfetch.
- (p6) の`IBRange` のinclusivity のflags のmap のonto のthe のPhase-4 の`btreeRange` のwindow, のwhich のis `[lo, hi)`: のinclusive のlower のkeeps のthe のboundary, のexclusive のlower のdrops のit, のinclusive のupper のis のre-added のwith のa のpoint のsearch + のdedup の— のand のthe のlower-bound のexclusion のis のapplied のto のthe のre-added のboundary のrows のTOO (else の`age > 5 のand のage <= 5` のreturned のthe のkey=5 のrows — のreview MUST-FIX).
- (p6) のHashAggregate のdrains のits のchild のand のgroups のthe のcollected のrows (the のdocs' のstreaming のaccumulators のare のmemory-equivalent: のthe のinput は はmaterialised のeither のway); のthe のdrained のrows のare のcharged のthen のreleased のat のopen のand のthe のFINALISED のgroup のrows のstay charged のuntil のclose (D-08 のcovers のhash のtables の— のthe のlive のtable のmust のbe のin のthe のbudget).
- (p6) のDML のoperators のrun のat OPEN (§9.5 のcollect-then-modify のphases のare のopen-time のphases) のand のkeep のthe のaffected のcount のin のa の`DModify` のIORef のcell, のwhich のthe のstatement のlayer のreports; のtheir のcollected のlists のare のcharged のthen のreleased.
- (p6) のheap のpages のnewly のallocated のduring INSERT のare のstaged のinto のthe のcatalog のrelpages のlist のby のWALKING のthe のheap のchain のafter のthe のfact (`heapChain` の+ `stageAllocPage` のfor のthe のoff-seed のpages): のthe のheap のlayer のlogs のthe のPAllocPage のWAL のrecord のbut のnever のtouches のthe のcache (Phase-4 のstaleness).
- (p6) のindex のroots のare のtracked のin のa のper-operator の`IORef (Map RelId PageId)` のand のpublished のwith のONE の`updateIndexRoot` のcall のper のindex のwhose のroot のCHANGED (the のPhase-4 のin-session のcache のnever のsees のthe のnew のroots); の`btreeDelete` のreturns のno のroot, のso のshrinking のis のuntracked (no のmerge のper のdesign/04 の§4.5).
- (p6) のLIMITATION, のcomposite のof のthe のPhase-4 のcache-staging のcaveats: のcatalog のstate (relpages/reltuples/index のroots) のlands のat COMMIT, のso のa のSECOND のstatement のinside のone のexplicit BEGIN…COMMIT のblock のsees のa のSTALE のpage のlist / root のafter のan のearlier のstatement のof のthe のsame のtransaction のgrew のthem (the のsuite のdrives のone のtransaction のper のstatement).
- (p6) の`PUpdate` のcarries `(colOrdinal, のPAssignRhs)` のpairs and の`PInsert` のcarries のthe のtarget のcolumn のORDINALS (§9.1 のomits のthem; のVALUES のcolumn のorder のmay のdiffer のfrom のschema のorder) — のresolves のthe のphase-5 のopen のitem ("INSERT のwith のa のPARTIAL のcolumn のlist の… のan のexecutor のconcern のfor のPhase の6"): のrejected のat PLAN のtime のwith の`0A000` の— のthis のdialect のhas のno のNULL のand のno のdefaults, のso のunassigned のcolumns のhave のno のvalue のto のwrite (design/05 のis のsilent; のPostgreSQL のfills のNULLs).
- (p6) のstatement のresult のshape: `StmtRows のn` (SELECT のstreamed のvia のthe のsink callback のper §9.6) vs `StmtCount のtag のn` for のDML/DDL; のDDL のcount は は1 (one のrelation のcreated) and のthe のsession のlayer のprints のthe のbare の`CREATE TABLE`/`CREATE INDEX` のtag — のdesign/09 の§9.6 のtable のshapes のfor のDDL のare のwire-layer のconcern.
- (p6) の`runSubs` のexecutes のsubqueries のBOTTOM-up (a のsub's のown `planSubqueries` のfirst, のthen のthe のsub) and のthreads のthe accumulating のmap のthrough のthe の`ec'` のrecursion (the のfirst のcut のpassed のthe のOUTER の`ec`, のdropping のthe のjust-materialised のsubresults のfrom のlater のsiblings のof のnested のpreambles).
- (p6) のmemory のbudget: ONE のper-statement のcell (D-08) のshared のby のsubqueries; のSort/PMaterialize/HashJoin-build のstay charged のuntil の`closePlan` のreleases; のIndexScan のmatch のlist のuncharged (§9.3 のrecorded のsimplification); のcfg のdefault の256 MiB, のthe のsuite のuses の20000 bytes のto のmake のthe の54000 のpaths のreachable.
- (p6) のDDL のgoes のTHROUGH のthe のexecutor (`PCreateTable`/`PCreateIndex` のnodes のcalling のBootstrap のunder のthe のstatement のtxn), のso のCREATE のTABLE/INDEX のare のrollback-able のlike のany のother のstatement.
- (p6) の`ecCatalog` のwas のadded のto `ExecCtx` (the のdocs のread のthe のcatalog のvia のan のimplicit のenvironment); のthe のexecutor のre-resolves のrelations のat のevery のopen (analyzer のresolved のthe のsame のcache のearlier のin のthe のtxn).
- (p6) のaggregate のempty-input のrule のper D-09 のoption のA: のCOUNT のof のan のempty GLOBAL のgroup は は0, のSUM/AVG/MIN/MAX のover のempty のinput のthrow の`21000` (`errAggEmptyInput`); のINT64 のSUM のoverflow のthrows の`22003` の(D-09 のoption のA, のchecked のvia のInteger のin `intSum`).
- (p6) のORDER BY のstability: の`Data.List.sortBy` のon のthe のmaterialised のlist (§8.7 のstability のclaim); のsort のkeys のare `(output-index, のasc)` のpairs のresolved のby のthe のANALYZER (col_ref / のordinal / のoutput のname のper §5.7 の`order_item`).

## Learned content (phase 6 additions)

- (p6) の`foldr` のargument のorder は は`f → のz → のxs`: のa のswapped の`foldr のf のxs ""` のunifies のthe のELEMENT のtype のwith のthe のaccumulator のtype のand のreports の"Expected: のValue -> Char" のon のthe のconsumer のside. のGive のthe のhelper のan のexplicit のsignature の(plus のkeep のthe のargument のorder のright).
- (p6) のUnder のOverloadedStrings, のa のbare のstring のliteral のinside の`c `elem` "(){}[];,"` のis のAMBIGUOUS (`IsString の(t Char) =>`) のand のbreaks のdefaulting — のannotate の`("…" の:: String)`.
- (p6) の-Wx-partial のrejects の`head` のof のa のfixture のlist: のpattern-bind の`(t1 : t2 : _)` のin のa の`case` (with のan の`error` のfallback, のwhich のis のNOT のflagged).
- (p6) の`ExecState` のholding の`IORef` のcells のCANNOT の`deriving Show` のand の`deriving Eq` の(re-export のomits のthem); のplan-dump のtests の`show` のthe のPLAN (pure) not のthe のstate.
- (p6) のImport のlists のmust のuse のnested のctor のforms (`PlanNode(PInsert, の…)`, の`ColumnDesc(..)`): のbare のctor のnames のin のa のmodule のimport のlist のare のrejected のas "data constructor のof PlanNode"; の`Type{..}` のIS のfine のbut のGHC2021 のlacks のrecord-wildcard のIMPORTS のfor のNESTED のrecords.
- (p6) のthe のdrainPairs のinternal-error のguard ("a のmodify のchild のmust のyield のthe のsource のRID") のpinned のthe のFilter-RID-stripping のbug のto のa のone-line のexplanation — のinternal-error のmessages のwith のtheir のown のwords のpay dividends のover のXX000 のalone.
- (p6) の`toSqlError` のmaps のNON-SqlError のexceptions のto のXX000 のwith のthe のraw の`show` — のa のPrelude の`!!` の"index のtoo のlarge" のfrom のa のwrong のforced-plan のJoinSides のprobe のkey のsurfaced のas のXX000, のwhich のis のwhy のforced-plan のfixtures のmust のspell のout のthe のside-local のkey のconvention のin のtheir のarguments.
- (p6) のjoin-algorithm のplan-choice のtests のneed のDISJOINT のfixtures (one のper のalgorithm) のand のpin のBOTH のthe のresult のset のAND のa のplan-dump のtoken のcheck (`chkPlan` のover の`planWords` のof の`show plan`) — のthe のexecutor のalone のcannot のdistinguish のINLJ のfrom のHashJoin のby のrows.
- (p6) のGROUP BY のsemantics のpitfall のin のtest のEXPECTATIONS: の`select のcname, count(cname) のfrom のperson, city のwhere のname = cname のgroup by cname` のcounts のJOIN のrows のper のcname (= のthe のCITY のper-name のcount のsince のperson のnames のare のunique), のnot のthe のper-relation のcount; のa のbare のcolumn のalongside のan のaggregate のWITHOUT のGROUP BY のis のa のgrouping のviolation の`42803` のat のANALYZE のtime, のso のORDER-BY-over-grouped-source のtests のneed のthe のGROUP BY のspelled のout.
- (p6) のVARCHAR の1024-byte のerror の`22001` のfires のat のthe のanalyzer のliteral→column のbinding; のa のvalue のUNDER のthat のlimit のbut のOVER のthe のpage のcapacity のfails のlater のwith のthe のheap のsame-RID のrule の`54000` の— のtwo のdifferent のfixtures のare のneeded のto のtest のboth.
- (p6) のrollback のvisibility のin のthe のsuite: のa のstatement のthat のmutates のSOME のrows のthen のfails の(54000 のmid-DML) のmust のleave のthe のheap のAND のthe のindex のunchanged の— のprobe のthe のmutated のkey のin のa のLATER のstatement (SELECT のvia のIndexScan) のcatches のa のmissing のundo.
- (p6) のscalar-subquery の>1-row の`21000` のis のraised のin のthe PREAMBLE (before のthe のmain のplan のopens) per §9.2; のa のzero-row のscalar のstores `SQScalar Nothing` のand のthrows のlazily のat のFIRST のevaluation — のa のnever-evaluated のpredicate (empty のinput) のraises のnoTHING, のwhich のmatches のPostgreSQL のhere.
- (p6) のGHC2021 のpattern のguards のneed のdirect の`Just x <- のexpr` (no の`[ x | … ]` のtrick のinside のa のguard); の`listToMaybe` のcomes のfrom `Data.Maybe`; のnumeric のcomprehensions のover の`[0 .. のn]` のneed `[0 :: Int ..]` のto のsilence の-Wtype-defaults.
