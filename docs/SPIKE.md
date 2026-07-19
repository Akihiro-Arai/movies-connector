# Passthrough join spike notes (#1)

Goal: validate `AVMutableComposition` + `AVAssetExportSession` + `AVAssetExportPresetPassthrough` → `.mov` on Apple Silicon, and lock `CompatibilitySignature` rules (see [COMPATIBILITY.md](COMPATIBILITY.md)).

No FFmpeg. Fixtures and the CLI spike use AVFoundation only.

## Generate fixtures

From the repo root:

```bash
swift Scripts/generate_spike_fixtures.swift Fixtures
```

Produces:

| File | Role |
| --- | --- |
| `Fixtures/compat_a.mov` | H.264 320×240 @ 30 fps |
| `Fixtures/compat_b.mov` | Same signature, different solid color |
| `Fixtures/incompat_size.mov` | 640×360 @ 30 fps (size mismatch) |
| `Fixtures/incompat_fps.mov` | 320×240 @ 24 fps (frame-duration mismatch) |

Larger noisy bench pair (gitignored; for non-zero copy/join timing):

```bash
swift Scripts/generate_spike_fixtures.swift Fixtures --bench
```

| File | Role |
| --- | --- |
| `Fixtures/bench_a.mov` | H.264 1280×720 @ 30 fps, 450 noisy frames (~29 MB) |
| `Fixtures/bench_b.mov` | Same signature, independent noise seed (~29 MB) |

## Run the CLI spike

Compatible join (expect success + matching output codec):

```bash
swift Scripts/run_passthrough_spike.swift /tmp/movies-connector-join.mov \
  Fixtures/compat_a.mov Fixtures/compat_b.mov
```

Incompatible reject (expect non-zero exit + concrete reasons, no output write):

```bash
swift Scripts/run_passthrough_spike.swift /tmp/movies-connector-reject.mov \
  Fixtures/compat_a.mov Fixtures/incompat_size.mov
```

```bash
swift Scripts/run_passthrough_spike.swift /tmp/movies-connector-reject-fps.mov \
  Fixtures/compat_a.mov Fixtures/incompat_fps.mov
```

Bench timing (compile once for cleaner CPU numbers):

```bash
swiftc -O -o /tmp/run_passthrough_spike Scripts/run_passthrough_spike.swift
/usr/bin/time -l /tmp/run_passthrough_spike /tmp/movies-connector-bench-join.mov \
  Fixtures/bench_a.mov Fixtures/bench_b.mov
```

The spike copies a payload equal to **total source bytes** (all inputs concatenated) to the destination volume before joining, then prints join/copy ratio.

## Measured notes (2026-07-19)

Host:

- Chip: Apple M1
- macOS: 26.5.1 (25F80)
- Xcode / SDK: Xcode 26.4 (17E192) / macOS 26.4 SDK

### Functional micro-fixtures

Compatible join (`compat_a` + `compat_b`): playable `.mov`, codec `avc1`, duration = sum of inputs.

Incompatible reject:

| Pair | Rejected before export? | Reason observed |
| --- | --- | --- |
| `compat_a` + `incompat_size` | yes | `display size 320x240 vs 640x360` |
| `compat_a` + `incompat_fps` | yes | `frame duration` mismatch |

### Bench pair (non-zero copy baseline)

Inputs: `bench_a` + `bench_b` (total source bytes **61,183,392** ≈ 58.3 MiB), same destination volume (`/tmp`).

| Metric | Value |
| --- | --- |
| Copy baseline (concatenated total source bytes → same volume) | **0.017589s** |
| Passthrough join wall time (spike timer) | **0.077334s** |
| Join / copy ratio | **4.397×** |
| Output playable | yes (`.mov`, duration 30.000s = sum of inputs) |
| Output video codec FourCC matches inputs | yes (`avc1`) |
| Output duration ≈ sum of inputs | yes (18000/600 vs 18000/600) |

Ratio is above the DESIGN.md multi‑GB KPI (≤1.25×) because fixed AVFoundation session overhead dominates at ~60 MB. Re-measure on multi‑GB 4K sources for the acceptance KPI.

### CPU observation method / results

Method:

1. `swiftc -O` the spike CLI (exclude interpreter/compile cost).
2. Run under `/usr/bin/time -l` for `real` / `user` / `sys`.
3. Approximate average logical cores as `(user + sys) / real`.

Observed on the bench join above:

| `time -l` field | Value |
| --- | --- |
| real | 0.55s |
| user | 0.06s |
| sys | 0.06s |
| Approx. avg logical cores | **(0.06 + 0.06) / 0.55 ≈ 0.22** |

Well under the DESIGN.md “avg CPU < 1 logical core” target for this fixture size. For multi‑GB acceptance, use the same `/usr/bin/time -l` method (or Activity Monitor / `sample` on the join process).

## Release entitlements verification

Release builds set `CODE_SIGN_INJECT_BASE_ENTITLEMENTS = NO` so ad-hoc Release signing does not inject `com.apple.security.get-task-allow`.

Verify:

```bash
xcodebuild -scheme MoviesConnector -configuration Release -destination 'platform=macOS' \
  -derivedDataPath /tmp/MoviesConnector-Release build
codesign -d --entitlements - \
  /tmp/MoviesConnector-Release/Build/Products/Release/MoviesConnector.app
```

Expected keys only:

- `com.apple.security.app-sandbox` = true
- `com.apple.security.files.user-selected.read-write` = true

Verified 2026-07-19 on this host: `get-task-allow` absent.

## App-target engine

The same pipeline lives in `MoviesConnector/Media/JoinExporter.swift` for the sandboxed app (temp-file export then replace on success). UI add/export wiring is deferred to later issues; this spike removes engine uncertainty.
