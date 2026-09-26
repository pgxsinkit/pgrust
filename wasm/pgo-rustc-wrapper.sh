#!/usr/bin/env bash
# RUSTC_WRAPPER for the profile-guided legs of wasm/wasm-build.sh (PGRUST_WASM_PGO).
#
# Cargo runs `$RUSTC_WRAPPER rustc <args>` for every unit. This adds the words of
# $PGRUST_WASM_PGO_UNIT_FLAGS to the units that are OURS -- the workspace crates and their
# crates.io dependencies, compiled for the wasm target -- and the words of
# $PGRUST_WASM_PGO_BIN_FLAGS to the one bin among them (link arguments). Everything else runs
# exactly as cargo asked:
#
#   * the -Zbuild-std units: core, alloc, std, std's own dependencies and profiler_builtins.
#     Cargo marks every one of them `-Z force-unstable-if-unmarked`. core CANNOT be
#     instrumented: rustc makes every crate compiled with -Cprofile-generate depend on
#     profiler_builtins (rustc_metadata creader.rs, inject_profiler_runtime, which has no
#     exception for core), and profiler_builtins itself depends on core -- RUSTFLAGS with
#     -Cprofile-generate over a -Zbuild-std build fails in core with E0463 and six thousand
#     cascading errors. Leaving the whole standard library uninstrumented is also what the native
#     recipe does (pgo/pgo-build.sh links the prebuilt, uninstrumented std). The generic parts of
#     std (Vec, hashbrown, iterators, Option/Result) are monomorphised into our crates and are
#     instrumented there.
#   * host units (build scripts, proc macros): no --target on their command line.
#   * cargo's probes (`--crate-name ___ --print=...`).
#
# Cargo never sees these flags, so they are in no fingerprint and in no -C metadata hash: the
# instrumented build and the build that uses its profile have the same crate hashes, and so the
# same symbol names, by construction. That is also why wasm-build.sh gives every PGO leg a target
# directory of its own (one per profile for the use leg): cargo cannot tell that a unit built
# here differs from the same unit built without the wrapper.
#
# PGRUST_WASM_PGO_TARGET   the wasm target triple whose units get the flags (required)
# PGRUST_WASM_PGO_LOG      optional file: one line per compiled unit, instrumented or not, and why
set -euo pipefail

rustc=$1
shift

read -r -a unit_flags <<< "${PGRUST_WASM_PGO_UNIT_FLAGS:-}"
read -r -a bin_flags <<< "${PGRUST_WASM_PGO_BIN_FLAGS:-}"

crate="" target="" std=0 bin=0 prev=""
for a in "$@"; do
    case "$prev" in
        --crate-name) crate=$a ;;
        --target) target=$a ;;
        --crate-type) [ "$a" = "bin" ] && bin=1 ;;
        -Z) [ "$a" = "force-unstable-if-unmarked" ] && std=1 ;;
    esac
    case "$a" in
        --target=*) target=${a#--target=} ;;
        -Zforce-unstable-if-unmarked) std=1 ;;
        --crate-type=bin) bin=1 ;;
    esac
    prev=$a
done

why=""
if [ -z "$crate" ] || [ "$crate" = "___" ]; then
    why="probe"
elif [ "$target" != "${PGRUST_WASM_PGO_TARGET:?PGRUST_WASM_PGO_TARGET is not set}" ]; then
    why="host"
elif [ "$std" = "1" ]; then
    why="build-std"
fi

if [ -n "$why" ]; then
    [ -n "${PGRUST_WASM_PGO_LOG:-}" ] && [ "$why" != "probe" ] && echo "plain $why $crate" >> "$PGRUST_WASM_PGO_LOG"
    exec "$rustc" "$@"
fi

extra=(${unit_flags[@]+"${unit_flags[@]}"})
[ "$bin" = "1" ] && extra+=(${bin_flags[@]+"${bin_flags[@]}"})
if [ -n "${PGRUST_WASM_PGO_LOG:-}" ]; then
    if [ "$bin" = "1" ]; then echo "pgo $crate (bin)"; else echo "pgo $crate"; fi >> "$PGRUST_WASM_PGO_LOG"
fi
exec "$rustc" "$@" ${extra[@]+"${extra[@]}"}
