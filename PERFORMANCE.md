# Performance: measuring, profiling, and testing Clipword

This project is a native macOS app (SwiftUI + SwiftData + AppKit). There is no
Flutter here — "flame graphs" and tracing are done with **Instruments /
os_signpost / the unified log**.

## Quick reference

| What you want | How |
|---|---|
| Build | `xcodebuild -project Clipword.xcodeproj -scheme Clipword -configuration Debug -derivedDataPath .build build` |
| Run tests | `xcodebuild -project Clipword.xcodeproj -scheme Clipword -configuration Debug -derivedDataPath .build test` |
| Regenerate project after adding files | `python3 generate_project.py` |
| Seed 1,500 rows | Right-click menu-bar icon → **Debug → Seed 1,500 items** |
| Clear seeded rows | Right-click → **Debug → Clear seeded items** |
| In-app timings | Right-click → **Debug → Run perf self-test** |
| Headless benchmark | `Clipword --seed=1500 --selftest --debug-quit` |
| Signpost trace | Instruments → **os_signpost** template (or `xctrace record --template 'os_signpost'`) |
| CPU / flame graph | Instruments → **Time Profiler** |
| SwiftUI body cost | Instruments → **SwiftUI** template (view-body intervals) |
| Live log | `log stream --predicate 'subsystem == "com.clipword.app"'` |

The Debug menu only exists in **Debug** builds (`#if DEBUG`). `./run.sh` builds
Debug and launches the app, so `print` output and `os_log` appear on stdout.

## Instrumentation in the code

`Clipword/Utilities/Perf.swift` wraps `OSSignposter` + `Logger`:

- `Perf.measure("name") { … }` — signpost interval. Shows as lanes in the
  **os_signpost** template and inline intervals in Time Profiler.
- `Perf.event("name", "msg")` — Points of Interest markers.
- `PerfTimer` — lap timer used by the DEBUG seed/self-test reports.

Instrumented intervals (subsystem `com.clipword.app`, category `intervals`):

| Signpost | Covers |
|---|---|
| `store.init` | App launch: prune + reload + bookmark/folder fetches |
| `store.reload` | Full history fetch (the >1,000-entry path) |
| `store.applyFilters` | Search/filter pipeline incl. derived rebuild |
| `store.rebuildDerivedData` | Sections, rows, index maps, counts, app options |
| `snapshot.encode` / `snapshot.hash` / `snapshot.classify` | Copy pipeline |
| `store.findDuplicate` | Hash-based dedupe lookup |
| `store.select` | Copy/paste-back action |
| `search.run` | Search engine per keystroke |
| `palette.moveSelection` | Arrow-key navigation (POI event) |

## Where the old cost was (regression checklist)

- `HistoryStore.reload()` — used to materialize every `contentData`/`imageData`
  blob. Now `.externalStorage` + `contentHash`; verify `store.reload` stays
  ~flat in `log`/signposts as the store grows.
- Arrow keys — `MainRootView` used to rebuild day-sections + flattened rows +
  per-row UUID strings per keypress. Now reads `paletteRows` /
  `paletteIndexBySelection` / `paletteTableRowBySelection` caches rebuilt once
  per data change in `rebuildDerivedData`.
- Dedupe — used to byte-compare the new blob against every stored blob. Now a
  64-char `contentHash` string compare.
- Search — `SearchService` now caps searchable text at
  `SearchService.searchableTextLimit` (50K chars) per item.
- Right-click menus — `.contextMenu` on each row was evaluated **eagerly** for
  all ~1,600 rows on every body pass, and `folder(forHistoryItem:)` inside it
  did a SwiftData fetch per row. Sampled during `--nav-test`: `contextMenu`
  construction was ~50% of main-thread time. Now a single `.rightMouseDown`
  monitor (`TableContextMenuInstaller`) pops a lazily-built `NSMenu` at the
  clicked row — same menus as ⌘K. `findBookmark` uses a `contentHash`-keyed
  dictionary rebuilt once per data change; `contextMenu` in samples: 2,283 → 0.
- SwiftData schema changes (`contentHash`, `.externalStorage`) lightweight-
  migrate existing `Storage.sqlite` files — verified on a real store: old rows
  stay inline, new writes go to `_EXTERNAL_DATA`, legacy rows get hashes via a
  chunked background backfill.

## Instruments recipes

Time Profiler (main-thread hangs, the "flame graph"):

```sh
xcodebuild -project Clipword.xcodeproj -scheme Clipword -configuration Release -derivedDataPath .build build
xctrace record --template 'Time Profiler' \
  --launch .build/Build/Products/Release/Clipword.app --time-limit 60s
```

os_signpost (all `Perf.measure` intervals as rows):

```sh
xctrace record --template 'os_signpost' \
  --launch .build/Build/Products/Debug/Clipword.app --time-limit 60s
```

While it records: seed 1,500 items, open the palette, hold an arrow key, type a
search. Then stop and group the signpost table by name.

Unified log without Instruments:

```sh
log stream --predicate 'subsystem == "com.clipword.app"' --level debug
# or after the fact:
log show --last 10m --predicate 'subsystem == "com.clipword.app"' --level info
```

Allocations (blob faulting — `contentData` should NOT show up in steady-state
list rendering):

```sh
xctrace record --template 'Allocations' \
  --launch .build/Build/Products/Debug/Clipword.app --time-limit 60s
```

## Measured baseline (this machine, Debug, live store)

From `--seed=1500 --selftest` on the real store — 1,612 items total
(112 pre-existing + 1,500 seeded):

| Operation | Time |
|---|---|
| Seed 1,500 rows (deferred rebuild) | ~5.3s (~3.5ms/insert) |
| `reload` (full fetch, 1,612 rows) | 169ms |
| `applyFilters` exact/regex/mixed | 24–66ms |
| `applyFilters` fuzzy | 718ms (Fuse; slowest search path) |
| 1,000 selection→index lookups (arrow keys) | 1.13ms total (~1µs/hop) |
| `addSnapshot` insert @1,612 rows | ~41ms (save + derived rebuild) |
| Delete one row | ~35ms |

## Write path — incremental refresh (per-stage, `--insert-bench=200`)

`addSnapshot` at ~1,800 items, 200 unique copies + 200 duplicate re-copies
through the real write path. Before: every copy paid a full sort + filter +
derived rebuild. After: hash-dict duplicate lookup, targeted sorted insertion,
day-section surgery, and one light rows/index-map pass
(`recordCopyIncremental`).

| Stage | Before p50 | After p50 |
|---|---|---|
| **new-copy total** | **55.2ms** | **11.0ms** |
| dup scan | 6.4ms | 3.2ms (bounded by unhashed legacy rows) |
| save | 1.9ms | 1.7ms |
| refresh (sort+filter+derived) | 46.4ms | 5.7ms incremental |
| **dup-copy total** | **44.9ms** | **9.1ms** |
| dup refresh | 37.4ms | 7.0ms (0ms when the row lands in its own slot) |

Correctness gate: after each phase the benchmark forces a full
`refreshWithoutFetch()` and asserts the incremental state is byte-identical
(paletteRows, displayedItems, day sections) — `verify[new] PASS`,
`verify[dup] PASS`.

XCTest perf deltas from the same change (`xcodebuild test`):

| Test | Before | After |
|---|---|---|
| testPerfBulkInsert (1,500 inserts) | ~208s | ~77s |
| testPerfDuplicateLookup | ~18.4s | ~5.1s |
| testPerfApplyFiltersOn1500 | ~5.9s | ~3.7s |
| testPerfReload | ~0.99s | ~0.69s |
| testPerfSelectionLookups | ~4.8s | ~2.4s |

Reproduce: `.build-release/Build/Products/Debug/Clipword.app/Contents/MacOS/Clipword --insert-bench=200` → `/tmp/insert-bench.log`.

## Before/after (A/B harness, same 1,612 rows both schemas)

Two standalone `swiftc -O` binaries seeded identical datasets (1,612 rows, ~34MB
of mixed blobs: ~1 small text + 5% ~200KB + 0.3% ~1.5MB, images on 10%) — one
with the old inline-blob model, one with `.externalStorage` + `contentHash`:

| Operation | Old | New | Δ |
|---|---|---|---|
| Full fetch 1,612 rows | ~57–62ms | ~50–53ms | ~15% faster |
| Read all blob bytes after fetch | ~2ms (already resident via mmap) | ~11–13ms (lazy external fault, on demand) | blobs off the fetch path |
| SQLite store file | 33MB | 392KB (+33MB `_EXTERNAL_DATA` dir) | metadata-only file |
| Arrow-key press, n=1,612 | ~2.0ms/press | ~0µs (dict lookup) | eliminated |
| Arrow-key press, n=5,000 | ~6.0ms/press | ~0µs | eliminated |
| Regex over a 2MB item | 6.0ms | 0.14ms (50K bound) | ~43× |
| Dedupe compare | blob bytes per row | 64-char hash per row | see note |

Caveats worth knowing:

- **Fetch is only ~15% faster, not an order of magnitude.** SQLite mmaps the
  store, so old inline blobs were already lazy-ish; the dominant fetch cost is
  per-row model materialization (~30µs/row). The real `.externalStorage` wins
  are: blob bytes never enter memory on fetch, the 33MB→392KB main file, and
  scans (old dedupe, migration checks) no longer fault multi-MB payloads.
- The ~2ms/press old-keypress number is a **floor**: it covers sections +
  flattened rows + two `map(\.id)` diffs + the `tableRow` walk + `firstIndex`
  scan, but the old code also ran `availableApps`/`count`/`selectableDateRange`
  and NSWorkspace name lookups on the same body evals — real cost was higher.
- Old dedupe scanned *and faulted* stored blobs to compare bytes; the synthetic
  in-memory scan measures ~0 both ways, so the real-world win is avoided blob
  faults + early-out hashing, not raw compare speed.
- The new-code `reload` of 169ms (live store) vs ~50ms (bare harness fetch) is
  the derived-rebuild + backfill + prune pipeline the old code didn't have —
  it amortizes work the old code used to redo per keypress.

`xcodebuild … test` also runs `SearchAndPerfTests` `measure` blocks; absolute
values vary with machine load (the suites run in parallel runners — treat as
regression signal, not gospel). Record before/after numbers in PR descriptions
when touching `HistoryStore`, `SearchService`, or `MainRootView` navigation.

## Manual verification script

```sh
./run.sh                                    # builds Debug, launches app
# right-click menu icon → Debug → Seed 1,500 items
# → palette opens, arrow keys move one row per press, selection stays visible
# right-click → Debug → Run perf self-test   # timings to stdout + NSAlert
# right-click → Debug → Clear seeded items   # removes only seeded rows

# or fully headless against the real store:
.build/Build/Products/Debug/Clipword.app/Contents/MacOS/Clipword \
    --seed=1500 --selftest --debug-quit
```
