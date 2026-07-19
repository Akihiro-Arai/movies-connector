# Acceptance — resilience & performance (#7)

Release-readiness checks for Movies Connector v1. Design targets: [DESIGN.md](../DESIGN.md), spike notes: [SPIKE.md](SPIKE.md), compatibility rules: [COMPATIBILITY.md](COMPATIBILITY.md).

## How to run automated checks

```bash
xcodebuild -scheme MoviesConnector -destination 'platform=macOS' test
```

Issue #7 gap coverage lives in `MoviesConnectorTests/AcceptanceResilienceTests.swift` (plus existing `JoinExporterTests` / `AssetInspectorTests` for disk-full mapping, order markers, and preflight). Production speed harness: `AcceptanceProductionBenchmarkTests` (opt-in; see below).

| Matrix item | Automated? | Where / how |
| --- | --- | --- |
| Compatible local inputs | yes | `AcceptanceResilienceTests`, `JoinExporterTests` |
| Incompatible local inputs (per-row reasons) | yes | `AcceptanceResilienceTests`, `AssetInspectorTests` |
| Cancel early | yes | `AcceptanceResilienceTests.testEarlyCancellation…` |
| Cancel late (commit boundary) | yes | `AcceptanceResilienceTests.testLateCancellationAtCommit…` |
| Unreadable / moved input after inspection | yes | `AcceptanceResilienceTests` |
| Disk-full mapping + typed error | yes | `JoinExporterTests` (injected `AVError.diskFull` / `ENOSPC`) |
| Duration within 1 frame + order markers | yes | `JoinExporterTests` (color segments) |
| Passthrough / no re-encode evidence | yes | full `CompatibilitySignature` + format descriptions + `AVAssetExportPresetPassthrough` |
| Downloaded iCloud via open panel | **blocking follow-up** | [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16) — procedure below |
| Long-duration media / UI responsiveness | **blocking follow-up** | [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17) — procedure below |
| Speed KPI (4K×10 ≈ 20 GB) | harness + **blocking** | see [Performance harness](#performance-harness); [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14) |

## Manual checks

### Sandbox + downloaded iCloud Drive

Status: **not yet verified on a Release build** — tracked as v1 blocking [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16).

1. Build **Release** (no debugger):

   ```bash
   xcodebuild -scheme MoviesConnector -configuration Release -destination 'platform=macOS' \
     -derivedDataPath /tmp/MoviesConnector-Release build
   open /tmp/MoviesConnector-Release/Build/Products/Release/MoviesConnector.app
   ```

2. Confirm entitlements (expect sandbox + user-selected R/W only; no `get-task-allow`):

   ```bash
   codesign -d --entitlements - \
     /tmp/MoviesConnector-Release/Build/Products/Release/MoviesConnector.app
   ```

3. In the app: **Add** → select already-downloaded movies from iCloud Drive (Finder download complete). Join to a user-chosen `.mov` on local SSD. Expect success under shipping sandbox.

4. Optionally select a cloud-only (not downloaded) file: app should wait/download or surface an actionable error; cancel must leave no partial output.

Record host, macOS, whether files were downloaded vs cloud-only, and pass/fail in [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16).

### Long media

Status: **not yet verified as a UI soak on multi-minute / multi-GB media** — tracked as v1 blocking [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17).

Automated coverage uses longer in-process fixtures (`makeTemporaryCompatibleMovie`) for cleanup/success paths, not a multi-GB UI soak.

Procedure when verifying: join several multi-minute compatible clips (or a large acceptance set). Watch Activity Monitor for unbounded memory growth and confirm the UI stays responsive (progress updates, Cancel works). Record results in [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17).

## Performance harness

Harness measures the **Release** build of the production engine (`JoinExporter.join`) — not an independent `swiftc -O` exporter. AVFoundation only (no FFmpeg).

| Piece | Role |
| --- | --- |
| `Scripts/run_acceptance_benchmark.sh` | `xcodebuild -configuration Release` → `AcceptanceProductionBenchmarkTests` |
| `MoviesConnectorTests/AcceptanceProductionBenchmarkTests.swift` | Warm-up + 5 interleaved copy/`JoinExporter.join`, eligibility gate, full signature validation, `getrusage` CPU |
| `Scripts/run_acceptance_benchmark.swift` | Support only (`--host-info` / `--copy` / `--validate` / `--eligibility`) — **no KPI join** |
| `Scripts/generate_acceptance_fixtures.swift` | Build N compatible clips from a seed via passthrough |

### Target eligibility (required before KPI yes/no)

DESIGN.md KPIs apply only when **all** of the following hold:

| Check | Requirement |
| --- | --- |
| Clip count | exactly 10 |
| Resolution | every clip 4K display (≥3840×2160 or 2160×3840) |
| Total size | ≈20 GB (18e9…22e9 bytes) |
| Host | Apple Silicon |
| Volumes | source + destination local |

Otherwise the harness sets `workload_class=surrogate_only` and:

- `kpi_1_25x_met=n/a`
- `cpu_under_1_core=n/a`

**Important:** preset `kpi20` only approximates total bytes by repeating a (usually 720p) seed. It is **not** target-eligible unless the seed itself is 4K. Never treat a 720p / ~1.22 GB (or non-4K ~20 GB) run as a DESIGN.md KPI pass.

### Practical local set (measured below — surrogate only)

True ~20 GB 4K×10 sources were not available on this host. Largest practical compatible set on local SSD:

```bash
# Seed (~29 MB noisy 720p) if missing:
swift Scripts/generate_spike_fixtures.swift Fixtures --bench

# 10 clips × 4 seed repeats ≈ 1.22 GB total (H.264 1280×720 @ 30 fps, 60 s each):
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance --preset practical

# Run harness (Release JoinExporter; warm-up + 5 trials + CPU):
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance /tmp/movies-connector-acceptance
```

`Fixtures/acceptance/` is gitignored; regenerate locally.

### Full 20 GB KPI set (re-run when available)

Prefer **real** ten compatible ~2 GB **4K** clips named `accept_01.mov` … `accept_10.mov`.

```bash
# Optional byte-scale synthesis (still 720p unless seed is 4K → surrogate_only):
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance-kpi20 --preset kpi20

# Prefer real 4K sources:
#   place 10 compatible 4K .mov files totaling ~20 GB into Fixtures/acceptance-kpi20/
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance-kpi20 /tmp/movies-connector-acceptance-kpi20
```

Record Mac model/SoC, logical cores, macOS, source/output volumes, codecs/sizes, eligibility lines, and the exact commands in `…/results.txt`.

### Method (matches issue #7)

1. Build/run with `xcodebuild -configuration Release` (no debugger) via the shell wrapper.
2. Time production `JoinExporter.join` (security-scope mocked only for local fixture paths; staging + passthrough path is production).
3. Warm-up copy + join (discarded from medians).
4. ≥5 measured trials, interleaved **copy then join** of the **same total source bytes** to the same destination volume.
5. CPU: `getrusage(RUSAGE_SELF)` around each join; average logical cores ≈ `(user + sys) / wall` (100% = 1 core).
6. Validate with AVFoundation: every input + output compared via `CompatibilitySignature` / format descriptions / track topology; duration within one frame of sum; `AVAssetExportPresetPassthrough`.
7. Score `kpi_*` **only** when `target_eligible=yes`.

## Measured results (2026-07-19)

> **Surrogate only — not a 20GB 4K KPI result.**  
> `workload_class=surrogate_only` → `kpi_1_25x_met=n/a`, `cpu_under_1_core=n/a`.  
> Earlier independent-harness timings are retained below as historical surrogate evidence; re-run `Scripts/run_acceptance_benchmark.sh` on this branch to refresh numbers against Release `JoinExporter`. Tracking: [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14).

**Host**

| Field | Value |
| --- | --- |
| Model | Mac mini (Macmini9,1) |
| SoC | Apple M1 |
| Cores | 8 logical / 8 physical (4P+4E) |
| Memory | 16 GB |
| macOS | 26.5.1 (25F80) |
| Volumes | source + dest: Macintosh HD (local SSD) |
| Target eligible? | **no** (720p, 1.22 GB ≠ 4K×10≈20GB) |

**Fixture set (`practical`)**

| Field | Value |
| --- | --- |
| Clips | 10 × `accept_XX.mov` |
| Per clip | 122,364,117 bytes, 60.0 s, `avc1`, 1280×720 |
| Total source bytes | 1,223,641,170 (≈ 1.22 GB) |
| Not | 4K × 10 ≈ 20 GB (deferred — see below) |

**Wall-clock (interleaved, post warm-up) — historical surrogate**

| Trial | Copy (s) | Join (s) |
| --- | --- | --- |
| 1 | 0.508175 | 1.672660 |
| 2 | 0.455501 | 1.619727 |
| 3 | 0.449672 | 1.268424 |
| 4 | 0.399317 | 0.513212 |
| 5 | 0.423304 | 1.440560 |
| **Median** | **0.449672** | **1.440560** |

| Metric | Target (eligible only) | Observed on surrogate | KPI scored? |
| --- | --- | --- | --- |
| Median join / median copy | ≤ 1.25× | **3.204×** | **n/a** (`surrogate_only`) |
| Output duration | within 1 frame of sum | δ = 0 (600.0 s) | yes (correctness) |
| Codec / topology | match all inputs | `avc1` 1280×720 | yes (correctness) |

**CPU (`time -l` on prior harness, 5 join trials after warm-up) — historical surrogate**

| Trial | real | user | sys | (user+sys)/real |
| --- | --- | --- | --- |
| 1 | 0.39 | 0.37 | 0.47 | 2.15 |
| 2 | 0.37 | 0.37 | 0.46 | 2.24 |
| 3 | 0.37 | 0.37 | 0.47 | 2.27 |
| 4 | 0.41 | 0.37 | 0.47 | 2.05 |
| 5 | 0.40 | 0.37 | 0.47 | 2.10 |
| **Mean** | | | | **≈ 2.16 cores** |

| Metric | Target (eligible only) | Observed on surrogate | KPI scored? |
| --- | --- | --- | --- |
| Avg process CPU | < 1 logical core | **≈ 2.16** | **n/a** (`surrogate_only`) |

Commands:

```text
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance --preset practical
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance /tmp/movies-connector-acceptance
```

### Interpretation / follow-ups

- Correctness checks on the practical set (duration, codec/topology identity) **passed**.
- The DESIGN.md **1.25× copy** and **&lt; 1 core** KPIs are specified for Apple Silicon + local SSD + **compatible 4K ×10 ≈ 20 GB**. They are **not scored** on surrogates; the harness emits `n/a` / `surrogate_only` instead of yes/no.
- **Blocking before v1:**
  - Re-measure on true ~20 GB 4K×10: [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14)
  - Release iCloud open-panel join: [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16)
  - Long-media UI soak: [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17)
- Fixed AVFoundation session overhead can dominate at smaller sizes (see also [SPIKE.md](SPIKE.md) ~60 MB bench at 4.4×); multi-GB 4K is the deciding workload.

## Criterion checklist

| Criterion | Status |
| --- | --- |
| Compatible / incompatible local inputs | pass (automated) |
| iCloud downloaded via open panel | **blocking** [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16) |
| Long media / no unbounded growth | **blocking** [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17) |
| Cancel early / late → actionable, no partial | pass (automated) |
| Moved / unreadable after inspection | pass (automated) |
| Disk-full typed errors | pass (automated mapping) |
| Duration within 1 frame; order markers | pass (automated) |
| Passthrough / no re-encode evidence | pass (full signature + format descriptions + preset) |
| Median join ≤ 1.25× copy on 4K×10≈20GB | **blocking** [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14) (`n/a` on surrogate) |
| Avg CPU &lt; 1 core on target workload | **blocking** [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14) (`n/a` on surrogate) |
| Docs + harness + fixture instructions in repo | pass |
| Unmet criteria tracked as blocking follow-ups | [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14), [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16), [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17) |
