#!/usr/bin/env bash
# Profile-guided (PGO) build of the native postgres binary.
#
#   pgo/pgo-build.sh
#
# 1. builds an instrumented binary (-Cprofile-generate) into $PGO_WORKDIR/gen,
# 2. runs pgo/train.sql against a fresh cluster of it (each statement its own simple query),
# 3. merges the raw profile with llvm-profdata,
# 4. rebuilds with -Cprofile-use into $PGO_WORKDIR/use; the result is
#    $PGO_WORKDIR/use/$PGO_PROFILE/postgres.
#
# Nothing in the source changes: the profile only steers LLVM's inlining, block layout and
# hot/cold placement. Environment:
#   PGO_PROFILE      cargo profile (default dist; a dist build needs libre2, as ever)
#   PGO_CARGO_ARGS   extra cargo arguments for both builds (e.g. --config 'profile.x.inherits="dev"')
#   PGO_RUSTFLAGS    extra RUSTFLAGS for both builds (default empty)
#   PGO_WORKDIR      work directory (default target/pgo)
#   PGO_GEN_BIN      use this already-instrumented binary and skip step 1
#   PG_BINDIR        where initdb and psql live (default: pg_config --bindir)
#   LLVM_PROFDATA    llvm-profdata to use (default: rustup's llvm-tools copy, else PATH)
#   PGO_PORT         port for the training server (default 55999)
# The training server inherits the environment (PGRUST_TZDIR, PGRUST_PGSHAREDIR, ... as needed).
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
PROFILE=${PGO_PROFILE:-dist}
WORK=${PGO_WORKDIR:-$ROOT/target/pgo}
PORT=${PGO_PORT:-55999}
PG_BINDIR=${PG_BINDIR:-$(pg_config --bindir 2> /dev/stderr || echo /usr/lib/postgresql/18/bin)}
read -r -a CARGO_ARGS <<< "${PGO_CARGO_ARGS:-}"
if [[ -z "${LLVM_PROFDATA:-}" ]]; then
  LLVM_PROFDATA=llvm-profdata
  for cand in "$(rustc --print sysroot)"/lib/rustlib/*/bin/llvm-profdata; do
    if [[ -x "$cand" ]]; then
      LLVM_PROFDATA=$cand
      break
    fi
  done
fi
mkdir -p "$WORK"
cd "$ROOT"

if [[ -z "${PGO_GEN_BIN:-}" ]]; then
  echo "pgo: 1/4 instrumented build ($PROFILE)"
  CARGO_TARGET_DIR="$WORK/gen" RUSTFLAGS="${PGO_RUSTFLAGS:-} -Cprofile-generate=$WORK/raw" \
    cargo build -p main_main --bin postgres --profile "$PROFILE" "${CARGO_ARGS[@]}"
  PGO_GEN_BIN="$WORK/gen/$PROFILE/postgres"
fi

echo "pgo: 2/4 training run ($PGO_GEN_BIN)"
rm -rf "$WORK/raw" "$WORK/data" "$WORK/sock"
mkdir -p "$WORK/raw" "$WORK/sock"
"$PG_BINDIR/initdb" -D "$WORK/data" --no-locale --encoding=UTF8 -U postgres -A trust > "$WORK/initdb.log"
LLVM_PROFILE_FILE="$WORK/raw/%m_%p.profraw" "$PGO_GEN_BIN" -D "$WORK/data" -p "$PORT" -k "$WORK/sock" \
  -c listen_addresses= -c fsync=off -c synchronous_commit=off -c autovacuum=off > "$WORK/server.log" 2>&1 &
server=$!
for _ in $(seq 1 120); do
  "$PG_BINDIR/psql" -h "$WORK/sock" -p "$PORT" -U postgres -d postgres -Atqc 'SELECT 1' > "$WORK/ready.log" 2>&1 && break
  sleep 0.5
done
"$PG_BINDIR/psql" -h "$WORK/sock" -p "$PORT" -U postgres -d postgres -q -f "$ROOT/pgo/train.sql" > "$WORK/train.log"
kill -INT "$server"
wait "$server" || true
ls "$WORK"/raw/*.profraw > "$WORK/raw.list"

echo "pgo: 3/4 merge ($LLVM_PROFDATA)"
"$LLVM_PROFDATA" merge -o "$WORK/pgo.profdata" "$WORK"/raw/*.profraw

echo "pgo: 4/4 optimized build with the profile"
CARGO_TARGET_DIR="$WORK/use" RUSTFLAGS="${PGO_RUSTFLAGS:-} -Cprofile-use=$WORK/pgo.profdata" \
  cargo build -p main_main --bin postgres --profile "$PROFILE" "${CARGO_ARGS[@]}"
echo "pgo: done: $WORK/use/$PROFILE/postgres"
