#!/usr/bin/env bash
# Orchestrates the acceptance speed KPI harness against the **production** JoinExporter
# built with `-configuration Release` (not an independent swiftc exporter).
#
#   - xcodebuild Release test: AcceptanceProductionBenchmarkTests
#   - warm-up + ≥5 interleaved copy / JoinExporter.join trials
#   - CPU via getrusage around each join (100% = 1 logical core)
#   - Target eligibility gate: out-of-target → kpi_* = n/a / surrogate_only
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
DERIVED="${ACCEPTANCE_DERIVED_DATA:-/tmp/MoviesConnector-AcceptanceBench}"
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

echo "Building + running production JoinExporter benchmark (Release)…"
echo "  fixtures=$FIXTURE_DIR"
echo "  work_dir=$WORK_DIR"
echo "  derived_data=$DERIVED"
echo
echo "NOTE: DESIGN.md 1.25× / <1-core KPIs are scored only for target-eligible workloads"
echo "      (10 clips, 4K, ≈20GB, Apple Silicon, local SSD). Surrogates report n/a."
echo

export ACCEPTANCE_BENCHMARK=1
export ACCEPTANCE_FIXTURE_DIR="$FIXTURE_DIR"
export ACCEPTANCE_WORK_DIR="$WORK_DIR"

set +e
xcodebuild \
  -scheme MoviesConnector \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  test \
  -only-testing:MoviesConnectorTests/AcceptanceProductionBenchmarkTests/testProductionJoinExporterAcceptanceBenchmark
STATUS=$?
set -e

if [[ -f "$RESULT_LOG" ]]; then
  echo
  echo "=== Results ($RESULT_LOG) ==="
  cat "$RESULT_LOG"
else
  echo "Benchmark did not write $RESULT_LOG (xcodebuild status=$STATUS)" >&2
fi

exit "$STATUS"
