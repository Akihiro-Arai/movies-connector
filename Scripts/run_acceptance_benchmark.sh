#!/usr/bin/env bash
# Orchestrates the acceptance speed KPI harness:
#   - compiles Scripts/run_acceptance_benchmark.swift with -O (Release-equivalent)
#   - warm-up + ≥5 interleaved copy/join trials (Swift harness)
#   - re-runs each measured join under /usr/bin/time -l for CPU
#     (100% = 1 logical core → avg cores ≈ (user + sys) / real)
#
# Usage:
#   Scripts/run_acceptance_benchmark.sh [fixtureDir] [workDir]
#
# Defaults:
#   fixtureDir = Fixtures/acceptance
#   workDir    = /tmp/movies-connector-acceptance

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FIXTURE_DIR="${1:-$ROOT/Fixtures/acceptance}"
WORK_DIR="${2:-/tmp/movies-connector-acceptance}"
BIN="/tmp/run_acceptance_benchmark"
RESULT_LOG="$WORK_DIR/results.txt"

mkdir -p "$WORK_DIR"

shopt -s nullglob
INPUTS=("$FIXTURE_DIR"/accept_*.mov)
if [[ ${#INPUTS[@]} -lt 2 ]]; then
  echo "Need ≥2 accept_*.mov in $FIXTURE_DIR" >&2
  echo "Generate practical set:" >&2
  echo "  swift Scripts/generate_spike_fixtures.swift Fixtures --bench" >&2
  echo "  swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance --preset practical" >&2
  exit 1
fi

echo "Compiling harness (-O) → $BIN"
swiftc -O -o "$BIN" "$ROOT/Scripts/run_acceptance_benchmark.swift"

{
  echo "# Movies Connector acceptance benchmark"
  echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "fixture_dir=$FIXTURE_DIR"
  echo "work_dir=$WORK_DIR"
  echo "harness=$BIN"
  echo "command=$0 $*"
  echo
  "$BIN" --host-info
  echo
  if [[ -f "$FIXTURE_DIR/MANIFEST.txt" ]]; then
    echo "=== Fixture manifest ==="
    cat "$FIXTURE_DIR/MANIFEST.txt"
    echo
  fi
} | tee "$RESULT_LOG"

echo
echo "=== Wall-clock interleaved benchmark ===" | tee -a "$RESULT_LOG"
"$BIN" --benchmark "$WORK_DIR/wall" "${INPUTS[@]}" | tee -a "$RESULT_LOG"

echo
echo "=== Join CPU via /usr/bin/time -l (5 trials, after warm-up) ===" | tee -a "$RESULT_LOG"
CPU_DIR="$WORK_DIR/cpu"
mkdir -p "$CPU_DIR"
# Warm-up join (not measured for CPU)
"$BIN" --join "$CPU_DIR/warmup.mov" "${INPUTS[@]}" >/dev/null

USER_SUM=0
SYS_SUM=0
REAL_SUM=0
for trial in 1 2 3 4 5; do
  OUT="$CPU_DIR/join-$trial.mov"
  TIME_ERR="$CPU_DIR/time-$trial.txt"
  # /usr/bin/time -l writes stats to stderr
  set +e
  /usr/bin/time -l "$BIN" --join "$OUT" "${INPUTS[@]}" >"$CPU_DIR/join-$trial.stdout" 2>"$TIME_ERR"
  STATUS=$?
  set -e
  if [[ $STATUS -ne 0 ]]; then
    echo "Join trial $trial failed; see $TIME_ERR" | tee -a "$RESULT_LOG"
    cat "$TIME_ERR" | tee -a "$RESULT_LOG"
    exit "$STATUS"
  fi

  # Parse real / user / sys from time -l (macOS format: "real 0.12" etc. or "0.12 real")
  REAL=$(awk '/real/{for(i=1;i<=NF;i++) if($i=="real"){if(i>1) print $(i-1); else print $(i+1); exit}}' "$TIME_ERR")
  USER=$(awk '/user/{for(i=1;i<=NF;i++) if($i=="user"){if(i>1) print $(i-1); else print $(i+1); exit}}' "$TIME_ERR")
  SYS=$(awk '/sys/{for(i=1;i<=NF;i++) if($i=="sys"){if(i>1) print $(i-1); else print $(i+1); exit}}' "$TIME_ERR")
  # Fallback: first three floating numbers often real/user/sys on some locales
  if [[ -z "${REAL:-}" || -z "${USER:-}" || -z "${SYS:-}" ]]; then
    read -r REAL USER SYS < <(awk 'BEGIN{c=0} /^[[:space:]]*[0-9]+\.[0-9]+/{print; c++; if(c==3) exit}' "$TIME_ERR" | tr '\n' ' ')
  fi

  CORES=$(python3 -c "u=float('$USER'); s=float('$SYS'); r=float('$REAL'); print((u+s)/r if r>0 else float('nan'))")
  echo "trial=$trial real=$REAL user=$USER sys=$SYS avg_cores=$CORES" | tee -a "$RESULT_LOG"
  USER_SUM=$(python3 -c "print($USER_SUM + float('$USER'))")
  SYS_SUM=$(python3 -c "print($SYS_SUM + float('$SYS'))")
  REAL_SUM=$(python3 -c "print($REAL_SUM + float('$REAL'))")
  rm -f "$OUT"
done

AVG_CORES=$(python3 -c "print(($USER_SUM + $SYS_SUM) / $REAL_SUM if $REAL_SUM>0 else float('nan'))")
echo "mean_avg_cores_over_trials=$AVG_CORES" | tee -a "$RESULT_LOG"
python3 -c "c=float('$AVG_CORES'); print('cpu_under_1_core=' + ('yes' if c < 1.0 else 'no'))" | tee -a "$RESULT_LOG"

echo
echo "Results written to $RESULT_LOG"
