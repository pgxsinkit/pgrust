# wasm-release: what the build profile is worth (2026-09-07)

`[profile.wasm-release]` ships the browser module: `inherits = "release"`, `opt-level = "s"`,
`lto = false`, `codegen-units = 16` — chosen for SIZE, never measured for SPEED. The bench
(`pglite-v-pgrust`) has pgrust's wasm 1.3–9× slower than PGlite on bulk writes, so this asks the
narrow question: how much of that is the profile?

- Toolchain: `nightly-2026-07-17`, `-Zbuild-std=std,panic_unwind`, `-C panic=unwind
  -C target-feature=+exception-handling`, target `wasm32-wasip1-threads`
- Build: `LC_ALL=C PGRUST_WASM_TARGET=wasm32-wasip1-threads PGRUST_WASM_PROFILE=wasm-release
  wasm/wasm-build.sh` (846 crates + the `postgres` link), one at a time on an idle machine
- Machine: Linux 7.0.0-30-generic x86_64, i7-1165G7, 8 threads
- Measurement: `pglite-v-pgrust` `bun run bench --suite speedtest|rtt --no-build --configurations
  pglite-memory,pgrust-threads-memory-broker --baseline pglite-memory`, each variant's
  `postgres.wasm` copied over the bench's asset and the original restored afterwards. The
  `pgrust-threads-memory` column could not be used: the bench's vendored host predates the guest's
  `path_symlink` import and refuses to instantiate any module built after `634375ebe6`; its BROKER
  column gets that import from the repacked store adapter, so that is the column here.

## Build and size

| Variant | opt-level | lto | codegen-units | wall build | .wasm raw | gzip -9 | vs baseline gz |
| --- | --- | --- | --- | --- | --- | --- | --- |
| baseline (shipped) | "s" | false | 16 | 276 s | 46 431 092 | 13 306 733 | — |
| A | 3 | false | 16 | 438 s | 50 323 152 | 14 738 844 | +10.8% |
| B | 3 | "thin" | 1 | 316 s | 46 333 130 | 14 405 242 | +8.3% |
| C | 3 | "fat" | 1 | 812 s | 41 659 871 | 13 411 137 | +0.8% |

No variant failed to build. The baseline row's wall time is a `rm -rf
target/wasm32-wasip1-threads/wasm-release` rebuild, the same work the profile switches forced on
A/B/C; the variants' times are as cargo ran them in sequence (each profile edit invalidates every
unit in that directory). The shipped profile is also the QUICKEST to build, by a wide margin over
fat LTO.

Fat LTO makes the SMALLEST module of the four — 10% under the size-tuned baseline, raw and 0.8%
over it gzipped — which is the one result here that was not expected.

## Speedtest, absolute pgrust milliseconds (lower is better)

The pgrust column is what the profile moves. PGlite's column is the control and is quoted for the
one run where it drifted (C's first run landed on a noisy patch — Test 1 105 ms against 52–62 ms
elsewhere — so C was re-run; both are shown).

| Benchmark | baseline | A | B | C (run 1 / run 2) |
| --- | --- | --- | --- | --- |
| 1: 1000 INSERTs | 407.1 | 316.4 | 296.9 | 304.2 / 307.1 |
| 2: 25000 INSERTs in a transaction | 5299.3 | 4600.9 | 4273.3 | 4528.6 / 4236.3 |
| 2.1: 25000 INSERTs in single statement | 254.6 | 225.1 | 197.7 | 227.2 / 212.1 |
| 3: 25000 INSERTs into an indexed table | 5331.6 | 4656.1 | 4467.7 | 4560.3 / 4359.6 |
| 3.1: 25000 INSERTs indexed, single statement | 276.3 | 236.1 | 219.8 | 249.2 |
| 4: 100 SELECTs without an index | 392.5 | 364.9 | 395.6 | 416.6 |
| 5: 100 SELECTs on a string comparison | 709.9 | 704.1 | 712.8 | 820.2 |
| 6: Creating an index | 43.7 | 36.1 | 39.6 | 32.7 |
| 7: 5000 SELECTs with an index | 1144.0 | 938.4 | 898.3 | 904.7 |
| 8: 1000 UPDATEs without an index | 260.2 | 203.9 | 193.4 | 193.2 |
| 9: 25000 UPDATEs with an index | 5253.0 | 4376.6 | 4198.7 | 4491.5 / 4511.6 |
| 10: 25000 text UPDATEs with an index | 7456.0 | 6030.6 | 5767.7 | 5998.8 / 6746.8 |
| 11: INSERTs from a SELECT | 525.2 | 422.9 | 403.5 | 445.1 |
| 12: DELETE without an index | 42.9 | 31.3 | 27.9 | 28.0 |
| 13: DELETE with an index | 87.9 | 58.9 | 50.8 | 50.0 |
| 14: A big INSERT after a big DELETE | 463.6 | 322.0 | 266.2 | 270.3 |
| 15: A big DELETE then many small INSERTs | 1467.5 | 1391.2 | 1119.9 | 1085.0 / 1427.3 |
| 16: DROP TABLE | 15.8 | 14.5 | 12.8 | 18.3 |

Speedup over the baseline (baseline ÷ variant) on the rows that dominate the bulk-write gap:

| Benchmark | A | B | C |
| --- | --- | --- | --- |
| 2: 25000 INSERTs in a transaction | 1.15× | 1.24× | 1.17–1.25× |
| 3: 25000 INSERTs into an indexed table | 1.15× | 1.19× | 1.17–1.22× |
| 9: 25000 UPDATEs with an index | 1.20× | 1.25× | 1.17× |
| 10: 25000 text UPDATEs with an index | 1.24× | 1.29× | 1.10–1.24× |
| 14: A big INSERT after a big DELETE | 1.44× | 1.74× | 1.71× |
| 15: A big DELETE then many small INSERTs | 1.05× | 1.31× | 1.03–1.35× |

## RTT (`--iterations 3`), pgrust median over the 12 tests

| Variant | pgrust median (ms) | PGlite median in the same run (ms) |
| --- | --- | --- |
| baseline | 1.164 | 0.505 |
| A | 0.915 | 0.490 |
| B | 0.957 | 0.417 |
| C | 0.913 | 0.670 |

Three iterations is what the brief asked for and it is not enough to separate these: single rows
move by 2× between runs of the SAME binary (Test 9 insert 10kb: 2.658 ms in A against 1.395 ms in
the baseline and 1.085 ms in C). Read the medians as "all three variants are somewhat quicker than
the baseline", nothing finer.

## Conclusion — nothing committed

`opt-level = 3` is worth a real but modest 15–25% on the big write rows however it is combined, and
`lto = "thin", codegen-units = 1` (B) is the best of the three on almost every row while building
in 316 s. The bar this experiment set for changing the shipped profile was **≥1.5× on the
write-heavy rows and no more than +25% gzipped**, and B does not clear it: the four 25 000-row
rows that carry the bulk-write gap are 1.19–1.29×, and only the two smaller composite rows (14, 15)
reach 1.5–1.75×. So the profile is left exactly as it was.

The result that deserves a follow-up is C's SIZE. `lto = "fat"` produced the smallest module of the
four — smaller than the size-tuned baseline by 4.8 MB raw — while also being 10–25% faster on
writes. It costs 812 s to build (2.9× the baseline). A profile that is both smaller and faster is
worth revisiting when the build time is affordable, e.g. for the released artifact rather than the
iteration one.

What this experiment did NOT find: any evidence that the profile explains the 1.3–9× gap to PGlite.
Even the best variant leaves Test 2 at 4273 ms against PGlite's 579 ms. The gap is in the guest or
the transport, not in codegen flags.

## The same profile on 0.3 (2026-09-16)

Rebuilt unchanged — same profile, same `nightly-2026-07-17`, same target — on the spike line rebased
onto upstream v0.3 (`79ad992ede`, PostgreSQL 18.6):

| Module | .wasm raw | gzip -9 | vs the row above |
| --- | --- | --- | --- |
| baseline on v0.2 (`46cb91c6cd`) | 46 431 092 | 13 306 733 | — |
| baseline on v0.3 (`5eb87502c3`) | **53 414 445** | 15 097 262 | +15.0% raw, +13.5% gz |

sha256 `b54a54a0c33281d147bacc9f756c8f32128c1540aae4f8e0945656748f67683f`. Seven megabytes of engine,
not of profile: nothing in `[profile.wasm-release]` moved, and the duplication result in the bench's
`2026-09-08-wasm-size-map.md` applies to this module exactly as it did to the last one.

One thing the rebase changed underneath the module: `child_thread_stack_size()` now takes the SCALED
guard budget (`max_stack_depth` x `STACK_DEPTH_SCALE` + 8 MiB = 16 MiB at `max_stack_depth=2048`),
which dominates the 4 MiB wasm `UNLIMITED_STACK_RESERVE` floor, so the floor no longer decides what a
child thread reserves — and the browser peak fell anyway, 656.9 MiB to 263.5 MiB on the bench's
one-machine A/B of the two modules.

## A Binaryen pass after the link (2026-09-16)

`lto = false` with `codegen-units = 16` leaves duplicate function bodies in the module, which is
what the bench's `2026-09-08-wasm-size-map.md` §5/§9 measured. `wasm/wasm-build.sh` now runs
`wasm-opt -Oz` over `postgres.wasm` in place, but ONLY under `PGRUST_WASM_PROFILE=wasm-release`
(dev builds are untouched) and only when `PGRUST_WASM_OPT` is not `0`. If Binaryen is missing under
the release profile the build fails loudly rather than shipping an unoptimised module quietly.

The feature list is spelled out in the script and must stay that way. The release profile strips the
module's `target_features` section, so wasm-opt cannot detect what the module uses; and
`--all-features` makes a *smaller* module that V8 then refuses to compile (`unknown import kind
0x7e`). Only `--enable-threads` differs between the two targets.

Both modules at `d87d883e` (Binaryen 132, i7-1165G7, 8 threads):

| Module | raw before | raw after | gzip -9 before | gzip -9 after | pass wall |
| --- | --- | --- | --- | --- | --- |
| `wasm32-wasip1-threads` | 53 414 445 | **39 040 753** (−26.9%) | 15 097 262 | **13 434 230** (−11.0%) | 306 s |
| `wasm32-wasip1` | 53 265 180 | **38 410 184** (−27.9%) | 15 089 981 | **13 519 294** (−10.4%) | 299 s |

sha256 after the pass: threads
`737762791ff9b34a6339ceb0ae2ad323856ebb03c4ea6f73c10fffa8ec87d0a0`, single-session
`6ef8c4459bec38d12db1ff45e9108f9f52d93168c727f71ba9548ba5ad5d7be6`.

Fourteen megabytes off each module for five minutes of wall time on top of a build that already
takes five. The pass is the duplicate-elimination `lto = "fat"` would have done in the compiler, at
a third of fat LTO's build cost, and it does not touch the Cargo profile. What it costs in speed is
the bench's measurement, not this file's: `pglite-v-pgrust` `docs/results/2026-09-16-wasm-opt-pass.md`.

## What the module links is a feature list (2026-09-16)

`[profile.wasm-release]` decides how the code is compiled; this section is about **which code there
is**. Up to here every wasm module carried the whole engine — 47 contribs, logical replication,
parallel query, base backup, four non-btree access methods — because `seams_init` is a flat list of
353 path dependencies and 311 `init_seams()` calls with no way to say "not that one".

The mechanism is Cargo's, and it is the whole of it: a `seams_init` dependency becomes
`optional = true`, a feature turns it on, and the `init_seams()` call gets a `cfg`. Feature off ⇒
the crate is **not in the link graph at all** ⇒ its seams are never installed. 90 dependencies are
gated this way behind **47 `contrib-*` features and 12 group features** (`replication`, `parallel`,
`backup`, `index-gin`, `index-gist`, `index-spgist`, `index-brin`, `tsearch`, `geo`, `jsonpath`,
`pgrcolumnar`, `plpgsql`), over 92 `cfg`-ed lines in `seams_init/src/lib.rs`. `main_main` takes
`seams_init` with `default-features = false` and forwards its own `full` / `browser` features; it is
the only crate in the graph that depends on `seams_init`, so nothing re-enables the defaults through
feature unification. `default = ["full"]` is exactly the dependency set and the init order that
existed before, so the native build and the default wasm build are unchanged.

`wasm/wasm-build.sh` takes **`PGRUST_WASM_FEATURES`** (default `full`) and always links with
`--no-default-features --features "$PGRUST_WASM_FEATURES"`, so that variable is the only thing that
decides the set.

### `browser`: the first profile that leaves something out

Every group feature is still ON — the Tier A groups (`replication`, `parallel`, `backup`) are
declared but untested off, because the postmaster touches them at BOOT and a seam called with
nothing installed panics `seam not installed`; the Tier B groups are reached only through fmgr/pg_am
dispatch and are safe by construction, but neither is switched off in this profile. What `browser`
drops is **contribs**: it keeps `pgvector`, `pgvector_hnsw`, `pg_trgm` and `pgcrypto`, and nothing
else.

### The exclusion proof

A feature that is merely *declared off* proves nothing — the crate can still be in the module
because some other crate in `main_main`'s graph depends on it. So before the link the script asks
cargo what it actually resolved, and prints:

```
wasm-build: profile browser excludes 40 crates: amcheck auto_explain btree_gin btree_gist citext
  contrib_cube contrib_earthdistance contrib_lo contrib_seg dblink file_fdw fuzzystrmatch hstore
  injection_points intarray isn ltree pageinspect passwordcheck pg_buffercache pg_freespacemap
  pg_logicalinspect pg_overexplain pg_prewarm pg_stat_statements pg_surgery pg_visibility
  pg_walinspect pgoutput pgrowlocks pgstattuple postgres_fdw sslinfo tablefunc tcn
  test_custom_types test_decoding test_oat_hooks unaccent uuid_ossp
wasm-build: profile browser leaves 3 gated crates linked (another crate in the graph depends on
  them; their seams are still not installed):
    bloom <- amapi bloom_build indexam
    tsm_system_rows <- tablesample
    tsm_system_time <- tablesample
wasm-build: exclusion proof OK (no excluded crate is reachable in the link graph)
```

43 of the 47 contribs are gated off; 40 genuinely leave, and the 3 that do not are reported with the
crate that keeps them (core's index and tablesample machinery names them directly). Counting the
transitive deps that leave with them, the package graph goes 922 → 878. Nothing here was
restructured to make the number bigger: where a gate cannot remove a crate, the feature is still
declared — it still stops `seams_init` installing the seams — and the crate stays.

### Sizes, after `wasm-opt -Oz`

| Module | features | .wasm raw | gzip -9 | vs `full` raw |
| --- | --- | --- | --- | --- |
| `wasm32-wasip1-threads` | full | 39 040 753 | 13 434 230 | — |
| `wasm32-wasip1-threads` | **browser** | **37 209 731** | **12 821 035** | −1 831 022 (−4.7%) |
| `wasm32-wasip1` | full | 38 410 184 | 13 519 294 | — |
| `wasm32-wasip1` | **browser** | **36 584 849** | **12 908 762** | −1 825 335 (−4.8%) |

sha256: threads `439df68ba2892023f6a3216d34956e0c428935a49dbe5c46135785dcf94c0a2d`, single-session
`3fb1ad313c5f49ddbded04d9174cb2e281eefa1da7af4c9da9b03efc466d8b28`.

The `full` threads row is a REBUILD with the gates in place, not the old number carried forward: it
came out at 39 040 753 raw and 13 434 230 gzipped, byte-for-byte the same sizes as the module before
this change. **The gates cost nothing when they are all on.** (The sha differs — adding a
`[features]` table changes the crates' metadata hashes and so their symbol names — but not one byte
of size.)

Forty contribs are worth 1.8 MB of a 37 MB module, which is the honest answer to "how much of the
module is the extensions": about five percent. The interesting number is not this one; it is what a
`browser` profile will be worth once the Tier A groups can actually be switched off.

### The runtime smoke

Two files, run through the threaded wire lane's `--sql` runner, split because the runner records any
`ErrorResponse` as a lane failure:

- `wasm/browser-profile-proof.sql` — `LOAD 'pg_trgm'`, `LOAD 'pgcrypto'`, `LOAD 'vector'` all answer,
  and a GIN index over a jsonb column is built and queried (`index-gin` is on): **PASS**.
- `wasm/browser-profile-refusal.sql` — one statement, `LOAD 'dblink'`:
  `ERROR: could not access file "dblink": No such file or directory` (SQLSTATE 58P01), which is
  PostgreSQL's own missing-module error. The same statement on the `full` module answers `LOAD`.

`LOAD` rather than `CREATE EXTENSION`: the seeded image (`wasm/assets/vfs.img`) has no
`share/extension` directory at all, so `CREATE EXTENSION pg_trgm` fails with `extension "pg_trgm" is
not available` (0A000) on **every** profile, the full one included, and proves nothing. `LOAD 'name'`
goes straight to dfmgr's named-builtin-library lookup — the registration a contrib crate performs
from its `init_seams()`, and precisely the thing a feature gate removes.

## The release build is the fast one now (2026-09-19)

The 2026-09-07 experiment at the top of this file left the profile alone, and said why: the bar it
set was ≥1.5× on the write-heavy rows and B did not clear it. The module has changed three times
since — the 0.3 rebase, the `browser` feature set, the `wasm-opt -Oz` pass — so the bench remeasured
it on the module actually published (`pglite-v-pgrust`
`docs/results/2026-09-18-speed-first-profile.md`), and this time the bar was the owner's: **lowest
browser Speedtest total summed over two interleaved rounds wins; two arms within 3% of each other
are settled by size, smaller wins; and the module may not exceed 46 431 092 raw bytes.**

Three arms, all `wasm32-wasip1-threads` with `PGRUST_WASM_FEATURES=browser`, interleaved A, D, D2,
A, D, D2 against the same `pglite-memory` control, one module swap between runs and nothing else
touched:

| Arm | opt-level / lto / codegen-units | Binaryen | raw | gzip -9 -n | Suite r1 / r2 | sum |
| --- | --- | --- | --- | --- | --- | --- |
| A — as published | `"s"` / `false` / 16 | `-Oz` | 37 210 023 | 12 820 980 | 23 153 / 23 355 | 46 508 |
| D | 3 / `"fat"` / 1 | `-O3` | 40 635 385 | 14 112 911 | 20 159 / 20 315 | 40 475 |
| **D2 — adopted** | 3 / `"fat"` / 1 | `-Oz` | **40 127 758** | **14 039 196** | 20 197 / 20 199 | **40 396** |

(The gzip column is `gzip -9 -n`; the bench note's tables were taken without `-n` and so run 10–11
bytes higher, which is the filename gzip stores in the header.)

**D2 wins.** D and D2 are 0.20% apart on the two-round sum — the same link, so this is the Binaryen
level and nothing else — which is well inside the 3% the rule allows and inside each arm's own
round-to-round spread (0.0–0.9%), so size decides it and `-Oz` is 507 627 bytes smaller than `-O3`.
A, in the same session as the control, is 15.1% slower than D2 over the two rounds, against its own
0.9% round-to-round spread: the profile is a real effect and the Binaryen level still is not. The
adopted module is 6 303 334 bytes under the cap.

Per row, best of two against A: 1.37× on the big transactional write (test 2), 1.29× on indexed
SELECTs (7), 1.26× on indexed UPDATEs (9) and indexed DELETEs (13), 1.24× on unindexed UPDATEs (8),
1.16× on text UPDATEs (10) — and 0.93× on test 1, 1000 autocommit INSERTs, the one row that gets
slower and the same row the 0.3 line had already lost.

So `wasm/wasm-build.sh` now exports `CARGO_PROFILE_WASM_RELEASE_OPT_LEVEL=3`,
`…_LTO=fat`, `…_CODEGEN_UNITS=1` under `PGRUST_WASM_PROFILE=wasm-release`, and takes the Binaryen
level from `PGRUST_WASM_OPT_LEVEL` (default `-Oz`). All four are overridable and the old size-first
build is three variables away (`s`, `false`, `16`); `PGRUST_WASM_OPT=0` still skips the pass
entirely. **`[profile.wasm-release]` in the root `Cargo.toml` is untouched** — that file is
upstream's, and a squash rebase should find nothing of ours in it. The `postgres.wasm linked` line
now prints the effective settings so a build log says which module it is.

Both modules rebuilt from those defaults, nothing in the environment:

| Module | size-first raw | speed-first raw | gzip -9 -n | sha256 |
| --- | --- | --- | --- | --- |
| `wasm32-wasip1-threads` | 37 210 023 | **40 127 758** | 14 039 196 | `765b06fb…` |
| `wasm32-wasip1` | 36 585 135 | **39 343 973** | 14 073 961 | `e6ef0b4d…` |

The threads module came out byte-identical to the arm that was measured, which is the point of
putting the settings in the script: the numbers above are the numbers for what ships.

What it costs, per target, on the i7-1165G7. A profile change invalidates every unit in the target
directory, so the first build after flipping any of these variables recompiles build-std and the
whole graph, not an increment: **8 m 57 s** for `wasm32-wasip1` here, 10 m 28 s for the same work on
the threads target during the bench (the 2026-09-07 fat-LTO run measured 812 s), against roughly two
minutes for the size-first profile. A relink of `main_main` alone into an otherwise warm target
directory is 6 m 01 s, almost all of it the LTO step. Then `wasm-opt -Oz` on top, 221 s for the
threads module and 230 s for the single-session one, taking 12–13% off rather than the 27% it took
off the `codegen-units = 16` link — fat LTO has already removed the duplicate bodies the pass used
to find.

## The browser has to compile what Binaryen builds (2026-09-19)

D2 above wins the Suite but loses row 1 — 1000 autocommit INSERTs, 0.93× — and that row had been
written off as "the one the 0.3 line had already lost". It was not the line. It was our own Binaryen
pass. `pglite-v-pgrust` `docs/findings/0002-pgrust-autocommit-insert-regression.md` has the
measurement: Binaryen inlines every function with exactly one call site, at any size, from `-O2` up
(`-Oz` included), which on this fat-LTO link folds **21.6% of the module's functions** into their
single callers and hands V8 a smaller number of much larger ones. V8's TurboFan then spends **14.5 s
of CPU compiling the module against 6.2 s** without it, and the first workload after boot pays for
it: row 1 runs at ~1200 ms instead of ~515 ms. Nothing later in the Suite pays, because by then the
tiering-up is done.

`--one-caller-inline-max-function-size=0` turns that one heuristic off and leaves the rest of `-Oz`
alone. The same link, the same two-interleaved-round rule, order D2, NEW, D2, NEW against the same
`pglite-memory` control:

| Arm | Binaryen | raw | gzip -9 -n | row 1 (r1 / r2) | Suite r1 / r2 | sum |
| --- | --- | --- | --- | --- | --- | --- |
| D2 — as published | `-Oz` | 40 127 758 | 14 039 196 | 1279 / 1242 | 19 974 / 20 125 | 40 099 |
| **NEW — adopted** | `-Oz --one-caller-inline-max-function-size=0` | **40 004 938** | **13 886 510** | **508 / 512** | 19 061 / 19 012 | **38 072** |

**NEW wins on the rule's own metric, by 5.32%** — outside the 3% band, so size never has to decide
it — and it is the smaller module anyway, by 122 820 raw bytes. The `pglite-memory` control held to
1.4% across the four runs. Row 1 is 2.44× faster and no row regresses beyond the round-to-round
spread. There is no trade here to weigh: this is smaller AND faster, which is what you get when the
thing you removed was work done to make a compiler's job harder.

So `wasm/wasm-build.sh` takes the extra Binaryen flags from `PGRUST_WASM_OPT_EXTRA`, default
`--one-caller-inline-max-function-size=0`, passed after `PGRUST_WASM_OPT_LEVEL`. Both are
overridable and `PGRUST_WASM_OPT_EXTRA=` restores stock `-Oz`. The effective string is in the
`postgres.wasm linked` line and the `wasm-opt` line, so a build log still says which module it is.

Both modules rebuilt from those defaults, nothing in the environment:

| Module | previous raw | this raw | gzip -9 -n | sha256 |
| --- | --- | --- | --- | --- |
| `wasm32-wasip1-threads` | 40 127 758 | **40 004 938** | 13 886 510 | `df17f7e2…` |
| `wasm32-wasip1` | 39 343 973 | **39 160 862** | 13 899 026 | `0d772984…` |

The threads module is byte-identical to the arm that was measured. Both are under the 46 431 092-byte
cap, the threads one by 6 426 154 bytes. The pass costs 163 s per target here (it was 221 s and
230 s with the inlining on), into an already-warm target directory — this flag changes nothing in
cargo's unit graph, so adopting it is a re-uplift and a Binaryen pass, not a rebuild.

## Profile-guided optimisation: the threads module is built from a profile (2026-09-26)

The native diagnosis behind malisper/pgrust#117 (pglite-v-pgrust `tmp/agents/planner/diagnosis.md`)
found that pgrust's extra cost per statement is mostly instructions per cycle, not extra
instructions, and that a profile-guided build (`pgo/pgo-build.sh`, trained on `pgo/train.sql`)
removes all of it natively: rows 7, 9 and 1 of the Speedtest went from about 2× C to 0.70–0.96× C.
Its §12.4 said the native profile cannot be reused here: LLVM matches a profile to functions by
symbol name, and the wasm build's names carry different crate hashes. So the profile has to come
from the wasm build itself, which is what this section is.

### The two legs

`PGRUST_WASM_PGO=generate` builds an instrumented `wasm32-wasip1-threads` module with the release
settings exactly (fat LTO, `opt-level 3`, one codegen unit, `browser` features) and no Binaryen pass;
`PGRUST_WASM_PGO=use:<profdata>` rebuilds with `-Cprofile-use` and runs the usual
`wasm-opt -Oz --one-caller-inline-max-function-size=0`. Both go through `wasm/pgo-rustc-wrapper.sh`
as `RUSTC_WRAPPER`, which gives the flag to our crates and their crates.io dependencies only, never
to the `-Zbuild-std` units. Each leg builds into a target directory of its own
(`target/pgo-wasm-generate/`, `target/pgo-wasm-use-<profile sha>/`) that remembers the flags it was
built with.

What had to be solved, in the order it came up:

1. **The profile runtime is not in the target.** `-Cprofile-generate` links LLVM's compiler-rt
   `lib/profile`, which the stock wasm targets do not ship and which `rust-src` does not carry the
   source of (it has `src/llvm-project/libunwind` only). `profiler_builtins` is added to
   `-Zbuild-std` and compiled from compiler-rt source (`PGRUST_WASM_COMPILER_RT`) with a wasi-sdk
   clang and sysroot (`WASI_SDK_PATH`), as upstream compiler-rt builds it for WASI:
   `-D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID`, the two emulation archives from the wasi-sdk
   sysroot at link time, and `-pthread -matomics -mbulk-memory` so wasm-ld takes it into a
   shared-memory module. compiler-rt 22.1.8's profile runtime already has its wasm/WASI paths
   (`InstrProfilingPlatformLinux.c`, `__wasi__` in `InstrProfilingUtil.c` and
   `InstrProfilingPort.h`); nothing in it was changed.
2. **`core` cannot be instrumented.** With `-Cprofile-generate` in `RUSTFLAGS`, `core` fails with
   `E0463 can't find crate for profiler_builtins` and six thousand cascading errors: rustc makes every
   instrumented crate depend on `profiler_builtins` (`inject_profiler_runtime` in rustc_metadata's
   `creader.rs`, with no exception for `core`) and `profiler_builtins` depends on `core`. The
   wrapper leaves every build-std unit alone (cargo marks them `-Z force-unstable-if-unmarked`),
   which is also what the native recipe does — its std is the prebuilt, uninstrumented one. The
   generic parts of std are monomorphised into our crates and instrumented there.
3. **Fat LTO dropped the runtime and nothing was ever written.** The first instrumented module ran
   the training to a clean `exit(0)` and wrote no profile: the runtime's file-writing half was not
   in it (none of its strings were). LLVM keeps the runtime alive through a hook function in each
   instrumented crate; after fat LTO nothing roots that hook, so wasm-ld extracts the runtime's
   objects and then garbage-collects them, constructor — the `atexit` registration — and all. A
   small crate showed the same with `lto = "fat"` and not without it. `--export=__llvm_profile_runtime`
   on the instrumented link roots it (`--undefined=` does not), and the leg now checks the module
   for the runtime's strings.
4. **The two legs had different symbol names.** The first use build warned "no profile data" for
   62 956 functions: every crate hash differed from the instrumented build's. Cargo derives a
   crate's hash from its whole dependency graph, and `-Zbuild-std=…,profiler_builtins` makes the
   runtime a dependency of every unit. So both legs build with the same `-Zbuild-std` set; the use
   leg compiles the runtime and never links it (it checks that too), and needs the same wasi-sdk and
   compiler-rt source to do so.
5. **Cargo cannot see the wrapper's flags,** so it would call a unit built without them fresh — the
   directories above, and their flags stamp, are for that.

`-Cprofile-generate`, `panic=unwind` with wasm exception handling, and `-Zbuild-std` otherwise
coexisted without a complaint.

### The dump, and training

The runtime writes its `.profraw` from the guest's own `exit(0)` through the guest's WASI calls, to
`$LLVM_PROFILE_FILE`. The postmaster lane does exit cleanly: closing the host-pipes listener is the
fast-shutdown request, Postgres checkpoints and exits, and `main` turns the `ProcExitThread` unwind
into `std::process::exit` — libc's `exit`, which runs the handlers. No host code calls into the
module. The counters are in the one shared memory, so the dump from the postmaster's exit carries
what every backend thread counted: `exec_simple_query`'s entry block reads 51 566 after 51 556
training statements on a backend thread.

Training is `pgo/train.sql` — the native recipe's generic small-statement workload, no Speedtest
text — sent the way psql sends it, every plain statement and every `\gexec` result its own simple
query, through pglite-v-pgrust's node lane (its `createPgrustPglite`: the postmaster, backends as
`node:worker_threads` guest threads, the broker store, `relaxed` durability, node 26.10.0). The
instrumented module ran the 51 556 statements in 24.6 s. Under `--fs broker` every guest path is in
the store, so the file lands there; the lane puts the store on its `file` port and reads
`/pgo/train.profraw` back out with the store library after the engine closes. The harness is the
bench's scratch `tmp/agents/pgo-wasm/train.ts`; the bench note
(`docs/results/2026-09-26-wasm-pgo.md`) says exactly what it does.

`llvm-profdata merge` (the `llvm-tools` of `nightly-2026-07-17`, LLVM 22.1.8) turns the 15 530 680-byte
`.profraw` into a 24 434 592-byte indexed profile, sha256 `f9bd4885874a…`, committed zstd-compressed
as **`pgo/wasm32-wasip1-threads.profdata.zst`** (2 137 693 bytes). It is committed rather than left
to a recipe because the build is only reproducible from the exact profile, and a second training run
is not the same profile: the background workers count whatever they happened to do. The use leg
rebuilt from the committed `.zst` into an emptied directory reproduces the measured module byte for
byte (`c499994c…`, below).

### Coverage

The profile has records for 65 983 functions, 9 015 of them executed (13.7%). The use build found a
record for every function it compiled but 21, all in one crate (`spillset`, the executor's spill
files, which has no record in the profile at all), and reported no control-flow hash mismatch. A
second profile trained on the Speedtest's 18 scripts (119 244 statements; comparison only, never
shipped) executes 8 840 functions; `llvm-profdata overlap` puts the two at 56.6% edge overlap.

### Sizes

| Module | raw | gzip -9 -n | sha256 |
| --- | --- | --- | --- |
| instrumented (`generate`, no Binaryen) | 103 347 575 | — | `91374a26…` |
| published before this (`3624f82cf0`) | 39 981 509 | 13 876 753 | `556d0731…` |
| **PGO, `train.sql` profile** | **39 759 752** | **14 017 177** | `c499994c…` |
| PGO, Speedtest profile (comparison) | 39 276 350 | 13 829 934 | `55cb6d6e…` |

The PGO module is 221 757 bytes smaller raw and 140 424 bytes larger gzipped. Build cost per leg on
the i7-1165G7: 12 m 38 s for the instrumented cargo leg, 10 m 46 s for the use leg plus 128 s of
Binaryen; both are full builds of their own directory.

### What it is worth

pglite-v-pgrust `docs/results/2026-09-26-wasm-pgo.md` has the measurement: the interleaved
module-only A/B in headless Chromium 149, persistent context, `pgrust-postmaster-opfs-repacked-relaxed`
against `pglite-opfs-repacked-relaxed`, three rounds per arm. Suite totals 9 683–9 886 ms against
11 470–11 863 ms for the published module — 16% off the median, rounds not overlapping, every row
but DROP TABLE faster — and 0.79–0.89× on the node lane's warm rows 1, 9 and 7. The Warm-up line
(first-use costs, outside every Suite total) is the one thing that gets slower: 766–860 ms against
616–646 ms. The Speedtest-trained profile lands within 2% of the generic one on the Suite, as the
native note found.

So the published threads module is built with
`PGRUST_WASM_PGO=use:pgo/wasm32-wasip1-threads.profdata.zst`. The single-session `postgres.wasm`
(`wasm32-wasip1`) is **not** profile-guided: it is untrained and unchanged, and the generate leg has
not been exercised on that target.

### The recipe

compiler-rt source from the LLVM the pinned nightly was built with — rust-lang/llvm-project
`52ed14fcd56afc30f9cccd8ca8ce237c2eef7e04` for `nightly-2026-07-17` (`rustc 3d50c25bc`, LLVM
22.1.8; the submodule commit of `src/llvm-project` at that rustc commit) — as a sparse checkout:

```sh
git init compiler-rt-src && cd compiler-rt-src
git remote add origin https://github.com/rust-lang/llvm-project.git
git sparse-checkout set --no-cone /compiler-rt/lib/profile /compiler-rt/include
git fetch --depth 1 --filter=blob:none origin 52ed14fcd56afc30f9cccd8ca8ce237c2eef7e04
git checkout FETCH_HEAD            # PGRUST_WASM_COMPILER_RT=$PWD/compiler-rt
```

wasi-sdk 34 (clang 23.1.0-wasi-sdk, with the `wasm32-wasip1-threads` sysroot) as `WASI_SDK_PATH`,
and `zstd`. The published threads module:

```sh
LC_ALL=C PGRUST_WASM_TARGET=wasm32-wasip1-threads PGRUST_WASM_PROFILE=wasm-release \
  PGRUST_WASM_FEATURES=browser PGRUST_WASM_PGO=use:pgo/wasm32-wasip1-threads.profdata.zst \
  WASI_SDK_PATH=… PGRUST_WASM_COMPILER_RT=… wasm/wasm-build.sh
```

A new profile, after the source has moved far enough that the use leg's "no profile data" count
grows: the same with `PGRUST_WASM_PGO=generate`, `pgo/train.sql` through a postmaster lane with
`LLVM_PROFILE_FILE` in the guest environment, the `.profraw` read out of the store after a clean
shutdown, then `llvm-profdata merge` from the nightly's `llvm-tools`
(`rustup component add llvm-tools --toolchain nightly-2026-07-17`).
