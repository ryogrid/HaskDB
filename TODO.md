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

- [ ] T13. `HaskDB.Wal.Format` — record types, framing codec (u32len, tag, txnId, prevTxnLSN, payload, CRC32)
- [ ] T14. `HaskDB.Wal.Manager` — buffered append (MVar-serialised LSN order), flushWalUpTo + fdatasync, readRecordAt (buffer-aware)
- [ ] T15. Control file (design/00 §0.8, internal/11 §11.4) — text key=value, atomic tmp+rename+dir fsync
- [ ] T16. `HaskDB.Wal.Recovery` — analysis/redo/undo (prevTxnLSN chain, pd_lsn guard, undo のnever のinstalls のimage のrule)
- [ ] T17. `applyRedo`/`applyUndo` のper-payload-type のsingle-choke-point のimplementation (live-rollback のsame のpath)
- [ ] T18. **Milestone**: crash tests — kill -9 harness, restart, verify committed prefix survives + uncommitted is undone

## Phase 3 — Transactions and locking (design/03, internal/04)

- [ ] T19. `HaskDB.Txn.Manager` — begin/commit/abort, txnAppend choke point, undo list, statement marks
- [ ] T20. `HaskDB.Txn.LockManager` — STM IS/IX/S/X + row S/X, FIFO fairness, upgrade S→X, waitForEdges
- [ ] T21. Deadlock policy (D-12 = detection, abort youngest, `40P01`), abort channel into lock waits
- [ ] T22. Heap ops のtransactional のintegration (locks + WAL via TxnCtx)
- [ ] T23. **Milestone**: concurrency stress (final state = serial execution), deadlock-injection terminates with error not hang

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
