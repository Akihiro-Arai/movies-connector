# Acceptance — resilience & performance (#7)

Release-readiness checks for Movies Connector v1. Design targets: [DESIGN.md](../DESIGN.md), spike notes: [SPIKE.md](SPIKE.md), compatibility rules: [COMPATIBILITY.md](COMPATIBILITY.md).

## How to run automated checks

```bash
xcodebuild -scheme MoviesConnector -destination 'platform=macOS' test
```

Issue #7 gap coverage lives in `MoviesConnectorTests/AcceptanceResilienceTests.swift` (plus existing `JoinExporterTests` / `AssetInspectorTests` for disk-full mapping, order markers, and preflight).

| Matrix item | Automated? | Where / how |
| --- | --- | --- |
| Compatible local inputs | yes | `AcceptanceResilienceTests`, `JoinExporterTests` |
| Incompatible local inputs (per-row reasons) | yes | `AcceptanceResilienceTests`, `AssetInspectorTests` |
| Cancel early | yes | `AcceptanceResilienceTests.testEarlyCancellation…` |
| Cancel late (commit boundary) | yes | `AcceptanceResilienceTests.testLateCancellationAtCommit…` |
| Unreadable / moved input after inspection | yes | `AcceptanceResilienceTests` |
| Disk-full mapping + typed error | yes | `JoinExporterTests` (injected `AVError.diskFull` / `ENOSPC`) |
| Duration within 1 frame + order markers | yes | `JoinExporterTests` (color segments) |
| Passthrough / no re-encode evidence | yes | codec FourCC match + `AVAssetExportPresetPassthrough` in exporter |
| Downloaded iCloud via open panel | manual | see [Manual checks](#manual-checks) |
| Long-duration media / UI responsiveness | manual + longer XCTest join | see below |
| Speed KPI (4K×10 ≈ 20 GB) | harness | see [Performance harness](#performance-harness) |

## Manual checks

### Sandbox + downloaded iCloud Drive

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

### Long media

Join several multi-minute compatible clips (or the acceptance fixture set below). Watch Activity Monitor for unbounded memory growth and confirm the UI stays responsive (progress updates, Cancel works). Automated coverage uses longer in-process fixtures (`makeTemporaryCompatibleMovie`) for cleanup/success paths, not multi-GB UI soak.

## Performance harness

Harness (AVFoundation only — no FFmpeg in app or scripts):

| Script | Role |
| --- | --- |
| `Scripts/generate_acceptance_fixtures.swift` | Build N compatible clips from a seed via passthrough |
| `Scripts/run_acceptance_benchmark.swift` | Host info, copy/join, validate, interleaved wall-clock trials |
| `Scripts/run_acceptance_benchmark.sh` | `-O` compile + wall trials + `/usr/bin/time -l` CPU |

### Practical local set (used for measured results below)

True ~20 GB 4K×10 sources were not available on this host. Largest practical compatible set on local SSD:

```bash
# Seed (~29 MB noisy 720p) if missing:
swift Scripts/generate_spike_fixtures.swift Fixtures --bench

# 10 clips × 4 seed repeats ≈ 1.22 GB total (H.264 1280×720 @ 30 fps, 60 s each):
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance --preset practical

# Run harness (warm-up + 5 interleaved copy/join + CPU via time -l):
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance /tmp/movies-connector-acceptance
```

`Fixtures/acceptance/` is gitignored; regenerate locally.

### Full 20 GB KPI set (re-run when available)

Either provide ten compatible ~2 GB 4K clips named `accept_01.mov` … `accept_10.mov`, or synthesize from the bench seed (slow; needs ~20 GB free):

```bash
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance-kpi20 --preset kpi20
# → 10 clips × 67 seed repeats ≈ 20 GB (still 1280×720 unless you replace the seed with 4K)

# Prefer real 4K sources when possible:
#   place 10 compatible 4K .mov files totaling ~20 GB into Fixtures/acceptance-kpi20/
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance-kpi20 /tmp/movies-connector-acceptance-kpi20
```

Record Mac model/SoC, logical cores, macOS, source/output volumes, codecs/sizes, and the exact commands in the results log (`…/results.txt`).

### Method (matches issue #7)

1. Compile harness with `swiftc -O` (no debugger).
2. Warm-up copy + join (discarded from medians).
3. ≥5 measured trials, interleaved **copy then join** of the **same total source bytes** to the same destination volume.
4. CPU: `/usr/bin/time -l` on each join; average logical cores ≈ `(user + sys) / real` (100% = 1 core).
5. Validate with AVFoundation: duration within one frame of sum, output codec/display match inputs, `AVAssetExportPresetPassthrough`.

## Measured results (2026-07-19)

**Host**

| Field | Value |
| --- | --- |
| Model | Mac mini (Macmini9,1) |
| SoC | Apple M1 |
| Cores | 8 logical / 8 physical (4P+4E) |
| Memory | 16 GB |
| macOS | 26.5.1 (25F80) |
| Volumes | source + dest: Macintosh HD (local SSD) |

**Fixture set (`practical`)**

| Field | Value |
| --- | --- |
| Clips | 10 × `accept_XX.mov` |
| Per clip | 122,364,117 bytes, 60.0 s, `avc1`, 1280×720 |
| Total source bytes | 1,223,641,170 (≈ 1.22 GB) |
| Not | 4K × 10 ≈ 20 GB (deferred — see below) |

**Wall-clock (interleaved, post warm-up)**

| Trial | Copy (s) | Join (s) |
| --- | --- | --- |
| 1 | 0.508175 | 1.672660 |
| 2 | 0.455501 | 1.619727 |
| 3 | 0.449672 | 1.268424 |
| 4 | 0.399317 | 0.513212 |
| 5 | 0.423304 | 1.440560 |
| **Median** | **0.449672** | **1.440560** |

| KPI | Target | Observed | Met? |
| --- | --- | --- | --- |
| Median join / median copy | ≤ 1.25× | **3.204×** | **no** (on 1.22 GB 720p set) |
| Output duration | within 1 frame of sum | δ = 0 (600.0 s) | yes |
| Codec / display | match inputs | `avc1` 1280×720 | yes |

**CPU (`/usr/bin/time -l`, 5 join trials after warm-up)**

| Trial | real | user | sys | (user+sys)/real |
| --- | --- | --- | --- | --- |
| 1 | 0.39 | 0.37 | 0.47 | 2.15 |
| 2 | 0.37 | 0.37 | 0.46 | 2.24 |
| 3 | 0.37 | 0.37 | 0.47 | 2.27 |
| 4 | 0.41 | 0.37 | 0.47 | 2.05 |
| 5 | 0.40 | 0.37 | 0.47 | 2.10 |
| **Mean** | | | | **≈ 2.16 cores** |

| KPI | Target | Observed | Met? |
| --- | --- | --- | --- |
| Avg process CPU | < 1 logical core | **≈ 2.16** | **no** (on this set) |

Commands:

```text
swift Scripts/generate_acceptance_fixtures.swift Fixtures/acceptance --preset practical
Scripts/run_acceptance_benchmark.sh Fixtures/acceptance /tmp/movies-connector-acceptance
```

### Interpretation / follow-ups

- Correctness checks on this set (duration, codec identity, validation) **passed**.
- The DESIGN.md **1.25× copy** and **&lt; 1 core** KPIs are specified for Apple Silicon + local SSD + **compatible 4K ×10 ≈ 20 GB**. They are **not claimed met** here; the practical 1.22 GB 720p surrogate shows join still above copy median and multi-core CPU under `time -l`.
- **Deferred before v1:** re-run the harness on a true ~20 GB 4K×10 local dataset. Tracking: [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14).
- Fixed AVFoundation session overhead can dominate at smaller sizes (see also [SPIKE.md](SPIKE.md) ~60 MB bench at 4.4×); multi-GB 4K is the deciding workload.

## Criterion checklist

| Criterion | Status |
| --- | --- |
| Compatible / incompatible local inputs | pass (automated) |
| iCloud downloaded via open panel | manual (procedure above) |
| Long media / no unbounded growth | manual + longer automated join |
| Cancel early / late → actionable, no partial | pass (automated) |
| Moved / unreadable after inspection | pass (automated) |
| Disk-full typed errors | pass (automated mapping) |
| Duration within 1 frame; order markers | pass (automated) |
| Passthrough / no re-encode evidence | pass (codec + preset) |
| Median join ≤ 1.25× copy on 4K×10≈20GB | **deferred** (not met on 1.22 GB surrogate) |
| Avg CPU &lt; 1 core on target workload | **deferred** (not met on 1.22 GB surrogate) |
| Docs + harness + fixture instructions in repo | pass |
| Unmet KPIs tracked as blocking follow-ups | [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14) |
