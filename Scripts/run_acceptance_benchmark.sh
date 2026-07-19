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
FIXTURE_DIR_RAW="${1:-$ROOT/Fixtures/acceptance}"
WORK_DIR_RAW="${2:-/tmp/movies-connector-acceptance}"
# Sandboxed Release test host resolves relative paths under its container — always absolute.
FIXTURE_DIR="$(cd "$FIXTURE_DIR_RAW" && pwd)"
mkdir -p "$WORK_DIR_RAW"
WORK_DIR="$(cd "$WORK_DIR_RAW" && pwd)"
DERIVED="${ACCEPTANCE_DERIVED_DATA:-/tmp/MoviesConnector-AcceptanceBench}"
RESULT_LOG="$WORK_DIR/results.txt"

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

# xcodebuild only forwards env vars into the XCTest host when prefixed with TEST_RUNNER_.
# Those become ACCEPTANCE_* inside the test process (prefix stripped).
export TEST_RUNNER_ACCEPTANCE_BENCHMARK=1
export TEST_RUNNER_ACCEPTANCE_FIXTURE_DIR="$FIXTURE_DIR"
export TEST_RUNNER_ACCEPTANCE_WORK_DIR="$WORK_DIR"

# Release normally omits -enable-testing, and hardened-runtime + ad-hoc signing
# prevents the XCTest host from loading the test bundle (Team ID mismatch / hang).
# Shipping entitlements enable app sandbox, which blocks /tmp work + fixture reads.
# These overrides apply only to this harness DerivedData path:
#   ENABLE_TESTABILITY=YES              → -enable-testing on the Release app module
#   CODE_SIGN_INJECT_BASE_ENTITLEMENTS  → testmanagerd / debugger entitlements
#   ENABLE_HARDENED_RUNTIME=NO          → allow host↔xctest bundle load under ad-hoc sign
#   CODE_SIGN_ENTITLEMENTS=…Harness…   → sandbox + absolute-path read-write for fixture/work I/O
# Compiler settings stay Release (-O / wholemodule). Shipping
# `xcodebuild … build -configuration Release` (no overrides) is unchanged.
HARNESS_ENTS="$ROOT/MoviesConnector/MoviesConnectorAcceptanceHarness.entitlements"
set +e
xcodebuild \
  -scheme MoviesConnector \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  ENABLE_TESTABILITY=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES \
  ENABLE_HARDENED_RUNTIME=NO \
  CODE_SIGN_ENTITLEMENTS="$HARNESS_ENTS" \
  test \
  -only-testing:MoviesConnectorTests/AcceptanceProductionBenchmarkTests/testProductionJoinExporterAcceptanceBenchmark
STATUS=$?
set -e

if [[ -f "$RESULT_LOG" ]]; then
  echo
  echo "=== Results ($RESULT_LOG) ==="
  cat "$RESULT_LOG"
else
  echo "Benchmark did not write $RESULT_LOG (xcodebuild status=$STATUS)." >&2
  echo "If the test was SKIPPED, ensure TEST_RUNNER_ACCEPTANCE_BENCHMARK=1 is set" >&2
  echo "(plain ACCEPTANCE_* exports are not forwarded into the macOS test host)." >&2
  exit 1
fi

# Treat missing KPI output as failure even if xcodebuild reported skip-as-success.
if ! grep -q '^engine=JoinExporter.join$' "$RESULT_LOG"; then
  echo "results.txt missing engine=JoinExporter.join — benchmark did not run" >&2
  exit 1
fi

exit "$STATUS"
