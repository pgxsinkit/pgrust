#!/usr/bin/env bash
# P5 WS-TOOLCHAIN blocking gate (wasm/p5-toolchain): the enumerated workspace
# subset compiles to wasm32-wasip1 WITH UNWINDS ENABLED (panic=unwind lowered
# through Wasm exception handling), and the catch_unwind smoke actually
# catches under wasmtime's exceptions proposal.
#
# Exclusion ledger: wasm/wasm-crate-ledger.md (ratchet-only — it may
# only shrink). Every workspace member is either BUILT here or LISTED there;
# a member that is neither fails this gate loudly (no silent drops: the
# include set is computed as members-minus-ledger, so an unledgered breakage
# breaks the build).
#
# Toolchain pin lives ONLY here (the repo's rust-toolchain.toml and native
# profiles are untouched): nightly-2026-07-17 is the first validated nightly
# whose wasm-EH linkage resolves the `__cpp_exception` tag — the 2026-04-26
# nightly compiles but FAILS TO LINK panic=unwind wasm (undefined
# __cpp_exception from every throwing object incl. libstd/libunwind).
#
# Usage:
#   wasm/wasm-build.sh              # full gate: crate subset + smoke build
#   PGRUST_WASM_RUN_SMOKE=1 wasm/wasm-build.sh   # also RUN smoke (needs wasmtime >= 46 w/ exceptions)
#
# Profile-guided release modules (off by default; the PGRUST_WASM_PGO block below and
# wasm/BUILD-PROFILES.md, "Profile-guided optimisation"):
#   PGRUST_WASM_PROFILE=wasm-release PGRUST_WASM_PGO=generate \
#     WASI_SDK_PATH=<wasi-sdk> PGRUST_WASM_COMPILER_RT=<compiler-rt source> wasm/wasm-build.sh
#                                   # instrumented, into target/pgo-wasm-generate/, no Binaryen
#   PGRUST_WASM_PROFILE=wasm-release PGRUST_WASM_PGO=use:<file.profdata[.zst]> \
#     WASI_SDK_PATH=<wasi-sdk> PGRUST_WASM_COMPILER_RT=<compiler-rt source> wasm/wasm-build.sh
#                                   # optimised with that profile, into target/pgo-wasm-use-<sha>/
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

TOOLCHAIN="${PGRUST_WASM_TOOLCHAIN:-nightly-2026-07-17}"
# PGRUST_WASM_TARGET selects the wasm target. Default wasm32-wasip1 (the
# gate's target; unchanged). wasm32-wasip1-threads is the SPIKE arm
# (spike/wasip1-threads): wasi-libc pthreads over a SHARED imported memory,
# so the guest's `wasi` `thread-spawn` import is the host's job and every
# instance must be handed the same WebAssembly.Memory.
TARGET="${PGRUST_WASM_TARGET:-wasm32-wasip1}"
LEDGER="$ROOT/wasm/wasm-crate-ledger.md"

# PGRUST_WASM_FEATURES selects WHICH SUBSYSTEMS THE BINARY LINKS. The names are
# main_main's features, which forward to seams_init's (crates/_support/seams_init
# Cargo.toml has the full list and the reasoning). `full` is the default and is
# the build that existed before the gates: every contrib, every subsystem group.
# `browser` is the web-demo profile -- every subsystem group still on, but only
# the four contribs the demo uses. The link leg below always passes
# --no-default-features, so this variable is the ONLY thing that decides the set.
FEATURES="${PGRUST_WASM_FEATURES:-full}"

# re2 is a build.rs probe; force the stub engine deterministically on wasm.
export PGRUST_FORCE_NO_RE2=1

# The MAIN shadow stack (-zstack-size), which is a different thing per target.
#
# wasm32-wasip1: the guest's session runs ON the main stack (`--single`,
# `--stdio-wire`), so it needs the whole budget the boot harness pins with
# max_stack_depth=60000kB (matching the native e2e). Dev-profile frames are
# huge and the 1MiB link default turns legitimate executor recursion into
# "stack depth limit exceeded". 64MiB.
#
# wasm32-wasip1-threads: nothing that runs SQL is on the main stack. A wire
# session gets its own 64MiB thread (tcop/postgres/src/stdio_wire.rs) and every
# postmaster child gets child_thread_stack_size(); the main thread only boots
# the process and then runs the postmaster loop. On this target the stack is
# not address space either — it is bytes of the ONE shared linear memory, sat
# on for the life of the instance — so 16MiB, which the postmaster lane, both
# tablespace proofs and the browser Speedtest/Concurrency Suites all run under.
if [ "$TARGET" = "wasm32-wasip1-threads" ]; then
    DEFAULT_STACK_SIZE=16777216
else
    DEFAULT_STACK_SIZE=67108864
fi
STACK_SIZE="${PGRUST_WASM_STACK_SIZE:-$DEFAULT_STACK_SIZE}"

# panic=unwind + Wasm EH codegen for every unit, including build-std units.
# Any PGRUST_WASM_RUSTFLAGS override MUST carry all three flags.
export RUSTFLAGS="${PGRUST_WASM_RUSTFLAGS:--C panic=unwind -C target-feature=+exception-handling -C link-arg=-zstack-size=${STACK_SIZE}}"

# wasm32-wasip1-threads pins --import-memory --shared-memory in its target
# spec, so the MODULE's declared memory limits must match the limits of the
# WebAssembly.Memory the JS host creates and passes in as an import. Pin them
# here rather than leaving wasm-ld's derived initial size to drift: 256MiB
# initial (static data plus the main shadow stack above must fit under it, and
# a smaller claim than 256MiB has been measured as a boot that either traps on
# an out-of-bounds access or takes the renderer down while it grows) and the
# 4GiB wasm32 ceiling as the maximum. Both are 64KiB multiples.
if [ "$TARGET" = "wasm32-wasip1-threads" ]; then
    RUSTFLAGS="$RUSTFLAGS -C link-arg=--initial-memory=${PGRUST_WASM_INITIAL_MEMORY:-268435456} -C link-arg=--max-memory=${PGRUST_WASM_MAX_MEMORY:-4294967296}"
    export RUSTFLAGS
fi

if ! rustup toolchain list | grep -q "^${TOOLCHAIN}"; then
    echo "wasm-build: installing pinned toolchain ${TOOLCHAIN}" >&2
    rustup toolchain install "${TOOLCHAIN}" >/dev/null
fi
rustup component add --toolchain "${TOOLCHAIN}" rust-src >/dev/null 2>&1 || true
# build-std rebuilds std, but the SELF-CONTAINED sysroot objects (crt1,
# wasi-libc, libunwind) ship in the target's rust-std component — linking
# fails without it.
rustup target add --toolchain "${TOOLCHAIN}" "${TARGET}" >/dev/null 2>&1 || true

[ -f "$LEDGER" ] || { echo "wasm-build: FAIL — ledger missing: $LEDGER" >&2; exit 1; }

# Excluded crate names: first column of the ledger's `| crate | ... |` rows.
EXCLUDED=$(awk -F'|' '/^\|/ {gsub(/[[:space:]]/,"",$2); if ($2 != "" && $2 != "crate" && $2 !~ /^-+$/) print $2}' "$LEDGER" | sort -u)

MEMBERS=$(cargo metadata --no-deps --format-version 1 \
    | python3 -c 'import json,sys
for p in json.load(sys.stdin)["packages"]: print(p["name"])' | sort -u)

# Ledger staleness: every excluded name must still be a workspace member.
STALE=$(comm -23 <(echo "$EXCLUDED") <(echo "$MEMBERS") || true)
if [ -n "$STALE" ]; then
    echo "wasm-build: FAIL — ledger lists non-members (stale rows):" >&2
    echo "$STALE" >&2
    exit 1
fi

INCLUDE=$(comm -23 <(echo "$MEMBERS") <(echo "$EXCLUDED"))
N_MEMBERS=$(echo "$MEMBERS" | wc -l | tr -d ' ')
N_EXCLUDED=$(echo "$EXCLUDED" | wc -l | tr -d ' ')
N_INCLUDE=$(echo "$INCLUDE" | wc -l | tr -d ' ')
echo "wasm-build: ${N_INCLUDE}/${N_MEMBERS} workspace crates in the wasm set (${N_EXCLUDED} ledgered out; ratchet-only)"

PKG_ARGS=""
for p in $INCLUDE; do PKG_ARGS="$PKG_ARGS -p $p"; done

# shellcheck disable=SC2086
cargo +"${TOOLCHAIN}" check --target "$TARGET" -Zbuild-std=std,panic_unwind $PKG_ARGS

echo "wasm-build: crate-subset compile OK (panic=unwind, +exception-handling)"

# Codegen + LINK leg (the F1 remedy): the postgres binary must actually link
# for wasip1 — cargo check proves neither monomorphization-time const evals
# nor linkage. Skippable for quick iterations with PGRUST_WASM_SKIP_LINK=1.
#
# PGRUST_WASM_PROFILE selects the cargo profile for this leg. The default dev
# profile is the gate's fast path; PGRUST_WASM_PROFILE=wasm-release builds the
# optimized module the web demo (wasm) ships — ~44MB vs the ~217MB
# dev binary (the profile is native-inert: nothing native selects it).
# --------------------------------------------------------------------------
# Exclusion proof. A feature that is merely *declared off* proves nothing: the
# crate can still be in the module because some OTHER crate in main_main's graph
# depends on it (contribs that core's index machinery pulls in directly, for
# instance). So before the link, ask cargo what it actually resolved:
#
#   * which seams_init features this profile turned ON (cargo tree -f '{f}'),
#   * which of seams_init's optional dependencies those features enable,
#   * which crates are in the link graph at all (cargo tree, forward).
#
# Optional deps the profile does NOT enable and that are NOT in the graph are
# the real exclusions -- the N in the line this prints. Ones the profile does
# not enable but that are in the graph anyway are reported as "still linked"
# with the crate that pulls them: declared, not removed, not fought (the gate
# still stops seams_init installing their seams). Then the hard assertion: no
# crate counted as excluded may appear in the graph. `cargo tree` needs no
# -Zbuild-std -- it resolves, it does not compile.
prove_feature_exclusion() {
    if [ "$FEATURES" = "full" ]; then
        echo "wasm-build: profile full excludes 0 crates (every gate on; nothing to prove)"
        return 0
    fi

    local tree graph enabled
    tree=$(cargo +"${TOOLCHAIN}" tree --target "$TARGET" -p main_main \
        --no-default-features --features "$FEATURES" -e normal --prefix none -f '{p}|{f}')
    graph=$(printf '%s\n' "$tree" | awk '{print $1}' | LC_ALL=C sort -u)
    enabled=$(printf '%s\n' "$tree" | awk -F'|' '/^seams_init / && !seen {e=$2; seen=1} END {print e}')
    [ -n "$enabled" ] || { echo "wasm-build: FAIL - seams_init not in the graph for features '$FEATURES'" >&2; exit 1; }

    # Optional deps of seams_init, as PACKAGE names (the aliases in the manifest
    # are not always the package name: contrib_cube is the `cube` package), split
    # into the ones "$enabled" turns on and the ones it does not.
    local off
    off=$(SEAMS_ENABLED="$enabled" python3 - "$ROOT/crates/_support/seams_init/Cargo.toml" <<'PYEOF'
import os, re, sys
manifest = sys.argv[1]
root = os.path.dirname(manifest)
text = open(manifest).read()
optional, feats, section = {}, {}, None
for line in text.split("\n"):
    if line.startswith("["):
        section = line.strip()
        continue
    if section == "[dependencies]":
        m = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*\{([^}]*)\}\s*$', line)
        if m and "optional = true" in m.group(2):
            p = re.search(r'path\s*=\s*"([^"]+)"', m.group(2)).group(1)
            name = re.search(r'^\s*name\s*=\s*"([^"]+)"', open(os.path.join(root, p, "Cargo.toml")).read(), re.M).group(1)
            optional[m.group(1)] = name
# [features]: `name = [ ... ]`, one entry per line or inline
for m in re.finditer(r'^([A-Za-z0-9_-]+)\s*=\s*\[(.*?)\]', text[text.index("[features]"):], re.M | re.S):
    feats[m.group(1)] = re.findall(r'"([^"]+)"', m.group(2))
on = set()
for f in os.environ["SEAMS_ENABLED"].split(","):
    f = f.strip()
    for entry in feats.get(f, []):
        if entry.startswith("dep:"):
            on.add(entry[4:])
print("\n".join(sorted(optional[a] for a in optional if a not in on)))
PYEOF
)

    local excluded="" still=""
    for c in $off; do
        if printf '%s\n' "$graph" | grep -Fxq -- "$c"; then still="$still $c"; else excluded="$excluded $c"; fi
    done
    excluded=$(echo $excluded); still=$(echo $still)
    local n_excluded=0
    [ -n "$excluded" ] && n_excluded=$(echo "$excluded" | wc -w | tr -d ' ')
    echo "wasm-build: profile $FEATURES excludes $n_excluded crates: $excluded"
    if [ -n "$still" ]; then
        echo "wasm-build: profile $FEATURES leaves $(echo "$still" | wc -w | tr -d ' ') gated crates linked (another crate in the graph depends on them; their seams are still not installed):"
        for c in $still; do
            echo "    $c <- $(cargo +"${TOOLCHAIN}" tree --target "$TARGET" -i "$c" -p main_main --no-default-features --features "$FEATURES" -e normal --prefix none --depth 1 2>/dev/null | tail -n +2 | awk '{print $1}' | LC_ALL=C sort -u | tr '\n' ' ')"
        done
    fi
    # The assertion: nothing counted as excluded may be in the graph.
    local bad=0
    for c in $excluded; do
        if printf '%s\n' "$graph" | grep -Fxq -- "$c"; then
            echo "wasm-build: FAIL - $c is counted as excluded but IS in the link graph:" >&2
            cargo +"${TOOLCHAIN}" tree --target "$TARGET" -i "$c" -p main_main \
                --no-default-features --features "$FEATURES" -e normal >&2 || true
            bad=1
        fi
    done
    [ "$bad" = "0" ] || exit 1
    echo "wasm-build: exclusion proof OK (no excluded crate is reachable in the link graph)"
}

PROFILE="${PGRUST_WASM_PROFILE:-dev}"
case "$PROFILE" in
    dev) PROFILE_DIR=debug ;;
    *)   PROFILE_DIR="$PROFILE" ;;
esac

# THE RELEASE CODEGEN SETTINGS LIVE HERE, NOT IN `[profile.wasm-release]`.
#
# The manifest's profile is `opt-level = "s"`, `lto = false`, `codegen-units =
# 16` — chosen for size before anyone measured it for speed — and the root
# Cargo.toml is UPSTREAM'S FILE. This spike line is rebased onto upstream, so
# every byte of that manifest we leave alone is a conflict a squash rebase does
# not have to resolve. Cargo's environment overrides reach the custom profile
# exactly as an edit would (`main_main profile: {"opt_level": "3", "lto":
# "fat", "codegen_units": 1}` in cargo's own unit graph, and `-C opt-level=3
# -C lto -C codegen-units=1` on the rustc lines), so the shipped module is the
# fast one and the manifest still matches upstream byte for byte.
#
# What it is worth, from pglite-v-pgrust
# `docs/results/2026-09-18-speed-first-profile.md` — browser Speedtest,
# `pgrust-postmaster-opfs-repacked-relaxed`, two interleaved rounds each,
# headless Chromium 149 on one machine, Suite totals in ms summed over both
# rounds (lower is better):
#
#     size-first ("s"/false/16, -Oz)   46 508   37 210 023 raw / 12 820 980 gz
#     this build (3/fat/1,      -Oz)   40 396   40 127 758 raw / 14 039 196 gz
#     same link with -O3               40 475   40 635 385 raw / 14 112 911 gz
#
# (gzip -9 -n, so the numbers are the content and not the stored filename.)
#
# 13% off the Suite total for +2.9 MB raw / +1.2 MB gzipped: 1.37x on the big
# transactional write, 1.24-1.29x on the indexed update, select and delete
# rows, and 0.93x on row 1 (1000 autocommit INSERTs), which is the one row that
# gets slower. `-Oz` and `-O3` over the same fat-LTO link are 0.2% apart on the
# Suite — inside the round-to-round spread — so the smaller of the two is the
# default below.
#
# Every variable here is overridable. THE OLD SIZE-FIRST BUILD IS:
#
#     CARGO_PROFILE_WASM_RELEASE_OPT_LEVEL=s \
#     CARGO_PROFILE_WASM_RELEASE_LTO=false \
#     CARGO_PROFILE_WASM_RELEASE_CODEGEN_UNITS=16 \
#       PGRUST_WASM_PROFILE=wasm-release wasm/wasm-build.sh
#
# It costs: a profile change invalidates every unit in the target directory, so
# the first build after flipping any of these recompiles build-std and the
# whole graph — 9 to 10.5 minutes per target here, against roughly two for the
# size-first profile — and a relink of main_main alone into a warm directory is
# still 6 minutes, almost all of it the LTO step. The Binaryen pass is another
# ~3.7 minutes on top, per target.
WASM_OPT_LEVEL="${PGRUST_WASM_OPT_LEVEL:--Oz}"

# Extra Binaryen flags, after the level. The default turns OFF one-caller
# inlining (Binaryen inlines every function with exactly one call site, at any
# size, from -O2 up), which on this link folds 21.6% of the module's functions
# into their callers and hands V8 a small number of enormous ones. The browser
# has to COMPILE what Binaryen builds: TurboFan spends 14.5s of CPU on the
# inlined module against 6.2s without it, and the first workload after boot
# (1000 autocommit INSERTs) takes ~1200ms instead of ~515ms. It is not a size
# trade either — the module is 122 820 B SMALLER without the inlining.
# Measured in pglite-v-pgrust
# docs/findings/0002-pgrust-autocommit-insert-regression.md.
# PGRUST_WASM_OPT_EXTRA="" restores stock `-Oz`.
WASM_OPT_EXTRA="${PGRUST_WASM_OPT_EXTRA:---one-caller-inline-max-function-size=0}"
WASM_OPT_EXTRA_ARGS=()
[ -n "$WASM_OPT_EXTRA" ] && read -r -a WASM_OPT_EXTRA_ARGS <<< "$WASM_OPT_EXTRA"

PROFILE_DESC=""
if [ "$PROFILE" = "wasm-release" ]; then
    export CARGO_PROFILE_WASM_RELEASE_OPT_LEVEL="${CARGO_PROFILE_WASM_RELEASE_OPT_LEVEL:-3}"
    export CARGO_PROFILE_WASM_RELEASE_LTO="${CARGO_PROFILE_WASM_RELEASE_LTO:-fat}"
    export CARGO_PROFILE_WASM_RELEASE_CODEGEN_UNITS="${CARGO_PROFILE_WASM_RELEASE_CODEGEN_UNITS:-1}"
    if [ "${PGRUST_WASM_OPT:-1}" = "0" ]; then
        WASM_OPT_DESC="wasm-opt skipped"
    else
        WASM_OPT_DESC="wasm-opt ${WASM_OPT_LEVEL}${WASM_OPT_EXTRA:+ ${WASM_OPT_EXTRA}}"
    fi
    PROFILE_DESC=" [opt-level ${CARGO_PROFILE_WASM_RELEASE_OPT_LEVEL}, lto ${CARGO_PROFILE_WASM_RELEASE_LTO}, codegen-units ${CARGO_PROFILE_WASM_RELEASE_CODEGEN_UNITS}, ${WASM_OPT_DESC}]"
fi

# PROFILE-GUIDED OPTIMISATION (PGO), off unless PGRUST_WASM_PGO is set. Two legs, the wasm twin of
# the native recipe in pgo/pgo-build.sh; wasm/BUILD-PROFILES.md has the measurement and the whole
# train-and-rebuild loop.
#
#   PGRUST_WASM_PGO=generate       an INSTRUMENTED module (-Cprofile-generate): it counts every
#                                  branch it takes and, when the guest exits, writes a .profraw
#                                  through its own WASI calls, to $LLVM_PROFILE_FILE if the guest
#                                  environment has one, else /pgo/default_%m_%p.profraw.
#   PGRUST_WASM_PGO=use:<profdata> the module rebuilt with that profile (-Cprofile-use), then the
#                                  same Binaryen pass as every release module. A `.zst` profile
#                                  (pgo/wasm32-wasip1-threads.profdata.zst, the one the published
#                                  threads module is built from) is unpacked into target/ first.
#
# Both legs need PGRUST_WASM_PROFILE=wasm-release: a profile only matches the codegen settings it
# was collected under, so the instrumented module is built with exactly the release settings above
# and is never optimised by Binaryen (it is only ever run, to train).
#
# The flags reach OUR crates only -- the workspace and its crates.io dependencies -- through
# wasm/pgo-rustc-wrapper.sh as RUSTC_WRAPPER, never the -Zbuild-std units: core cannot be
# instrumented at all (the wrapper's header says why), and the native recipe instruments no std
# either.
#
# A profile finds a function by its symbol name, and a Rust symbol name carries its crate's hash,
# which cargo derives from the crate's whole dependency graph. So the two legs must hand cargo the
# SAME graph, and the one thing the instrumented build cannot do without is LLVM's profile runtime:
# compiler-rt lib/profile, built as the `profiler_builtins` crate, which -Zbuild-std then makes a
# dependency of every unit. So BOTH legs build with -Zbuild-std=std,panic_unwind,profiler_builtins.
# The use leg compiles the runtime and never links it (no crate asks for it without
# -Cprofile-generate; the leg checks), and pays for that only in needing the same two inputs:
#
#   WASI_SDK_PATH            a wasi-sdk (clang, llvm-ar, and share/wasi-sysroot with the target's
#                            libc headers) to compile the runtime's C for the wasm target
#   PGRUST_WASM_COMPILER_RT  compiler-rt SOURCE from the LLVM the pinned nightly was built with
#                            (rust-src carries only libunwind); the recipe is in BUILD-PROFILES.md
#
# The runtime is built as upstream builds it for WASI (-D_WASI_EMULATED_MMAN
# -D_WASI_EMULATED_GETPID, linking wasi-libc's two emulation archives from the wasi-sdk sysroot),
# with -pthread -matomics -mbulk-memory on the threads target so wasm-ld accepts it into a
# shared-memory module. Cargo never sees the wrapper's flags, so every other input to the crate
# hashes is the release build's as well.
#
# Each leg gets a target directory of its own (the use leg one per profile), because cargo cannot
# tell a wrapped unit from a plain one: the release directory must never be handed one. The
# directory remembers the flags it was built with and is emptied when they change.
# PGRUST_WASM_PGO_LOG names a file that records which units were instrumented and which were not.
# The use leg warns once per function the profile has no counts for
# (-pgo-warn-missing-function; PGRUST_WASM_PGO_WARN_MISSING=0 turns that off) -- the build log's
# own count of what the profile did not reach.
PGO="${PGRUST_WASM_PGO:-}"
LINK_TARGET_DIR="$ROOT/target"
LINK_BUILD_STD="std,panic_unwind"
LINK_ENV=()
PGO_DESC=""
if [ -n "$PGO" ]; then
    [ "$PROFILE" = "wasm-release" ] || { echo "wasm-build: FAIL — PGRUST_WASM_PGO needs PGRUST_WASM_PROFILE=wasm-release (a profile matches only the settings it was collected under)" >&2; exit 1; }
    [ "${PGRUST_WASM_SKIP_LINK:-0}" != "1" ] || { echo "wasm-build: FAIL — PGRUST_WASM_PGO with PGRUST_WASM_SKIP_LINK=1 builds nothing" >&2; exit 1; }
    WASI_SDK="${WASI_SDK_PATH:-}"
    [ -n "$WASI_SDK" ] && [ -x "$WASI_SDK/bin/clang" ] || { echo "wasm-build: FAIL — PGRUST_WASM_PGO needs WASI_SDK_PATH (a wasi-sdk with bin/clang) to build the profile runtime for $TARGET" >&2; exit 1; }
    WASI_SYSROOT="$WASI_SDK/share/wasi-sysroot"
    [ -d "$WASI_SYSROOT/include/$TARGET" ] || { echo "wasm-build: FAIL — $WASI_SYSROOT has no $TARGET headers" >&2; exit 1; }
    COMPILER_RT="${PGRUST_WASM_COMPILER_RT:-}"
    [ -n "$COMPILER_RT" ] && [ -d "$COMPILER_RT/lib/profile" ] || { echo "wasm-build: FAIL — PGRUST_WASM_PGO needs PGRUST_WASM_COMPILER_RT, compiler-rt source from $(rustc +"${TOOLCHAIN}" -vV | sed -n 's/^LLVM version: //p') (the recipe is in wasm/BUILD-PROFILES.md)" >&2; exit 1; }
    RT_CFLAGS="--target=$TARGET --sysroot=$WASI_SYSROOT -D_WASI_EMULATED_MMAN -D_WASI_EMULATED_GETPID"
    if [ "$TARGET" = "wasm32-wasip1-threads" ]; then
        RT_CFLAGS="$RT_CFLAGS -pthread -matomics -mbulk-memory"
    fi
    T_ENV=${TARGET//-/_}
    LINK_ENV+=(
        "RUSTC_WRAPPER=$ROOT/wasm/pgo-rustc-wrapper.sh"
        "PGRUST_WASM_PGO_TARGET=$TARGET"
        "RUST_COMPILER_RT_FOR_PROFILER=$COMPILER_RT"
        "CC_$T_ENV=$WASI_SDK/bin/clang"
        "CXX_$T_ENV=$WASI_SDK/bin/clang++"
        "AR_$T_ENV=$WASI_SDK/bin/llvm-ar"
        "CFLAGS_$T_ENV=$RT_CFLAGS"
        "CXXFLAGS_$T_ENV=$RT_CFLAGS"
    )
    LINK_BUILD_STD="std,panic_unwind,profiler_builtins"
    case "$PGO" in
        generate)
            LINK_ENV+=(
                "PGRUST_WASM_PGO_UNIT_FLAGS=-Cprofile-generate=/pgo"
                # --export=__llvm_profile_runtime: without it the profile is never written.
                # LLVM roots the runtime with a hook function in each instrumented crate that
                # references __llvm_profile_runtime; after fat LTO nothing keeps that hook
                # alive, so wasm-ld extracts the runtime's objects and then garbage-collects
                # them, constructor (the atexit registration) and all. The export makes the
                # runtime's object a GC root; --undefined does not. The instrumented module
                # exports one more global than the release module; nothing reads it.
                "PGRUST_WASM_PGO_BIN_FLAGS=-Clink-arg=--export=__llvm_profile_runtime -Clink-arg=$WASI_SYSROOT/lib/$TARGET/libwasi-emulated-mman.a -Clink-arg=$WASI_SYSROOT/lib/$TARGET/libwasi-emulated-getpid.a"
            )
            LINK_TARGET_DIR="$ROOT/target/pgo-wasm-generate"
            PROFILE_DESC=${PROFILE_DESC/"$WASM_OPT_DESC"/wasm-opt skipped}
            PGO_DESC=", PGO instrumented (-Cprofile-generate)"
            ;;
        use:*)
            PGO_PROFDATA="${PGO#use:}"
            [ -f "$PGO_PROFDATA" ] || { echo "wasm-build: FAIL — no profile at $PGO_PROFDATA" >&2; exit 1; }
            PGO_PROFDATA=$(cd "$(dirname "$PGO_PROFDATA")" && pwd)/$(basename "$PGO_PROFDATA")
            # A committed profile is zstd-compressed (pgo/*.profdata.zst): rustc reads only the
            # indexed file, so it is unpacked into target/ first.
            if [ "${PGO_PROFDATA%.zst}" != "$PGO_PROFDATA" ]; then
                command -v zstd >/dev/null || { echo "wasm-build: FAIL — $PGO_PROFDATA is zstd-compressed and zstd is not on PATH" >&2; exit 1; }
                mkdir -p "$ROOT/target/pgo-wasm-profiles"
                PGO_UNPACKED="$ROOT/target/pgo-wasm-profiles/$(basename "${PGO_PROFDATA%.zst}")"
                zstd -q -d -f "$PGO_PROFDATA" -o "$PGO_UNPACKED"
                PGO_PROFDATA=$PGO_UNPACKED
            fi
            PGO_SHA=$(sha256sum "$PGO_PROFDATA" | cut -c1-12)
            UNIT_FLAGS="-Cprofile-use=$PGO_PROFDATA"
            if [ "${PGRUST_WASM_PGO_WARN_MISSING:-1}" != "0" ]; then
                UNIT_FLAGS="$UNIT_FLAGS -Cllvm-args=-pgo-warn-missing-function"
            fi
            LINK_ENV+=("PGRUST_WASM_PGO_UNIT_FLAGS=$UNIT_FLAGS")
            LINK_TARGET_DIR="$ROOT/target/pgo-wasm-use-$PGO_SHA"
            PGO_DESC=", PGO -Cprofile-use=$(basename "$PGO_PROFDATA") (sha256 ${PGO_SHA}…)"
            ;;
        *)
            echo "wasm-build: FAIL — PGRUST_WASM_PGO must be 'generate' or 'use:<profdata>', not '$PGO'" >&2
            exit 1
            ;;
    esac
    PGO_DESC="$PGO_DESC, runtime: $COMPILER_RT with $("$WASI_SDK/bin/clang" --version | head -1)"
    [ -n "${PGRUST_WASM_PGO_LOG:-}" ] && LINK_ENV+=("PGRUST_WASM_PGO_LOG=$PGRUST_WASM_PGO_LOG")
    LINK_ENV+=("CARGO_TARGET_DIR=$LINK_TARGET_DIR")
    PGO_FLAGS_NOW=$(printf '%s\n' "${LINK_ENV[@]}" | grep -E '^(PGRUST_WASM_PGO_(UNIT|BIN)_FLAGS|RUST_COMPILER_RT_FOR_PROFILER|C(XX)?FLAGS_|CC_|CXX_|AR_)=' ; echo "build-std $LINK_BUILD_STD"; sha256sum "$ROOT/wasm/pgo-rustc-wrapper.sh" | cut -d' ' -f1)
    PGO_FLAGS_STAMP="$LINK_TARGET_DIR/pgrust-wasm-pgo.flags"
    if [ -d "$LINK_TARGET_DIR" ] && [ "$(cat "$PGO_FLAGS_STAMP" 2>/dev/null)" != "$PGO_FLAGS_NOW" ]; then
        echo "wasm-build: PGO flags differ from the ones $LINK_TARGET_DIR was built with; emptying it"
        rm -rf "$LINK_TARGET_DIR"
    fi
    mkdir -p "$LINK_TARGET_DIR"
    printf '%s\n' "$PGO_FLAGS_NOW" > "$PGO_FLAGS_STAMP"
fi

if [ "${PGRUST_WASM_SKIP_LINK:-0}" != "1" ]; then
    prove_feature_exclusion
    env ${LINK_ENV[@]+"${LINK_ENV[@]}"} cargo +"${TOOLCHAIN}" build --target "$TARGET" -Zbuild-std="$LINK_BUILD_STD" -p main_main --bin postgres --profile "$PROFILE" \
        --no-default-features --features "$FEATURES"
    BIN_WASM="$LINK_TARGET_DIR/${TARGET}/${PROFILE_DIR}/postgres.wasm"
    [ -f "$BIN_WASM" ] || { echo "wasm-build: FAIL — postgres.wasm not produced" >&2; exit 1; }
    echo "wasm-build: postgres.wasm linked ($(du -h "$BIN_WASM" | cut -f1), profile ${PROFILE}${PROFILE_DESC}${PGO_DESC}, features $FEATURES)"
    # The profile runtime's own strings say whether it is in the module: it must be in the
    # instrumented one (else nothing is ever written) and must not be in the one built from a profile.
    case "$PGO" in
        generate)
            grep -qa LLVM_PROFILE_FILE "$BIN_WASM" || { echo "wasm-build: FAIL — the instrumented module has no profile runtime linked" >&2; exit 1; } ;;
        use:*)
            if grep -qa LLVM_PROFILE_FILE "$BIN_WASM"; then echo "wasm-build: FAIL — the profile runtime was linked into the use leg's module" >&2; exit 1; fi ;;
    esac

    # Binaryen pass — release profile only (dev builds are untouched), opt out
    # with PGRUST_WASM_OPT=0, level from PGRUST_WASM_OPT_LEVEL (default `-Oz`).
    # Under the size-first profile above (`lto = false`, `codegen-units = 16`)
    # the link left duplicate function bodies behind and `-Oz` took ~27% off
    # the raw bytes (pglite-v-pgrust docs/results/2026-09-08-wasm-size-map.md
    # §9). Fat LTO does that deduplication in the compiler, so the pass now
    # takes ~13% instead — but it is still 5.7 MB, and `-Oz` is both smaller
    # (by 508 KB) and, within the noise, no slower than `-O3` on this link
    # (docs/results/2026-09-18-speed-first-profile.md).
    #
    # Never on the instrumented module (PGRUST_WASM_PGO=generate): it is only ever run, to train.
    if [ "$PROFILE" = "wasm-release" ] && [ "${PGRUST_WASM_OPT:-1}" != "0" ] && [ "$PGO" != "generate" ]; then
        # The feature list is spelled out ONCE, here, and is deliberately NOT
        # `--all-features`: the release profile strips the module's
        # `target_features` section so wasm-opt cannot detect what the module
        # uses, and `--all-features` re-encodes the import section into
        # something V8 refuses to compile ("unknown import kind 0x7e"). The
        # list is the names build's `target_features`; only threads differs
        # between the two targets.
        WASM_OPT_FEATURES=()
        if [ "$TARGET" = "wasm32-wasip1-threads" ]; then
            WASM_OPT_FEATURES+=(--enable-threads)
        fi
        WASM_OPT_FEATURES+=(
            --enable-bulk-memory
            --enable-bulk-memory-opt
            --enable-call-indirect-overlong
            --enable-exception-handling
            --enable-extended-const
            --enable-multivalue
            --enable-mutable-globals
            --enable-nontrapping-float-to-int
            --enable-reference-types
            --enable-sign-ext
        )
        if ! command -v wasm-opt >/dev/null; then
            echo "wasm-build: FAIL — profile $PROFILE runs wasm-opt but Binaryen is not on PATH (install it, or set PGRUST_WASM_OPT=0 to ship the unoptimised module)" >&2
            exit 1
        fi
        WASM_OPT_BEFORE=$(wc -c < "$BIN_WASM")
        WASM_OPT_T0=$SECONDS
        wasm-opt "$WASM_OPT_LEVEL" ${WASM_OPT_EXTRA_ARGS+"${WASM_OPT_EXTRA_ARGS[@]}"} "${WASM_OPT_FEATURES[@]}" "$BIN_WASM" -o "$BIN_WASM.opt"
        mv "$BIN_WASM.opt" "$BIN_WASM"
        WASM_OPT_AFTER=$(wc -c < "$BIN_WASM")
        echo "wasm-build: wasm-opt ${WASM_OPT_LEVEL}${WASM_OPT_EXTRA:+ ${WASM_OPT_EXTRA}} ${WASM_OPT_BEFORE} -> ${WASM_OPT_AFTER} bytes (-$(( (WASM_OPT_BEFORE - WASM_OPT_AFTER) * 100 / WASM_OPT_BEFORE ))%) in $((SECONDS - WASM_OPT_T0))s ($(wasm-opt --version))"
    fi
else
    echo "wasm-build: bin link SKIPPED (PGRUST_WASM_SKIP_LINK=1)"
fi

# Toolchain-validation smoke: catch_unwind must CATCH under a Wasm
# exception-handling runtime, proving the unwind story is real.
(
    cd "$ROOT/wasm/wasm-unwind-smoke"
    cargo +"${TOOLCHAIN}" build --target "$TARGET" -Zbuild-std=std,panic_unwind --release
)
SMOKE_WASM="$ROOT/wasm/wasm-unwind-smoke/target/${TARGET}/release/wasm-unwind-smoke.wasm"
[ -f "$SMOKE_WASM" ] || { echo "wasm-build: FAIL — smoke wasm not produced" >&2; exit 1; }

if [ "${PGRUST_WASM_RUN_SMOKE:-0}" = "1" ]; then
    command -v wasmtime >/dev/null || { echo "wasm-build: FAIL — PGRUST_WASM_RUN_SMOKE=1 but wasmtime not installed" >&2; exit 1; }
    OUT=$(wasmtime run -W exceptions=y "$SMOKE_WASM")
    echo "$OUT"
    echo "$OUT" | grep -q "VERDICT: unwind-smoke PASS" || { echo "VERDICT: wasm-build FAIL (unwind smoke did not catch)" >&2; exit 1; }
else
    echo "wasm-build: smoke built (set PGRUST_WASM_RUN_SMOKE=1 with wasmtime installed to execute it)"
fi

echo "VERDICT: wasm-build PASS (${N_INCLUDE}/${N_MEMBERS} crates @ ${TOOLCHAIN}, panic=unwind, features ${FEATURES})"
