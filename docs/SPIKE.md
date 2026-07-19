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

## Measured notes (2026-07-19)

Host:

- Chip: Apple M1
- macOS: 26.5.1 (25F80)
- Xcode / SDK: Xcode 26.4 (17E192) / macOS 26.4 SDK

Compatible join (`compat_a` + `compat_b`):

| Metric | Value |
| --- | --- |
| Copy baseline (first input → same volume) | 0.000s (tiny fixture; below timer resolution) |
| Passthrough join wall time | 0.019s |
| Join / copy ratio | N/A for tiny fixtures — re-measure with multi‑GB sources for KPI |
| Output playable | yes (`.mov`, duration 1.000s = sum of inputs) |
| Output video codec FourCC matches inputs | yes (`avc1`) |
| Output duration ≈ sum of inputs | yes (600/600 vs 600/600) |

Incompatible reject:

| Pair | Rejected before export? | Reason observed |
| --- | --- | --- |
| `compat_a` + `incompat_size` | yes | `display size 320x240 vs 640x360` |
| `compat_a` + `incompat_fps` | yes | `frame duration 20/600 vs 25/600` |

CPU: not instrumented on this micro-fixture run; wall time alone is consistent with remux/passthrough rather than a heavy re-encode. Use Activity Monitor / `sample` on large compatible sets when validating the DESIGN.md KPI.

## App-target engine

The same pipeline lives in `MoviesConnector/Media/JoinExporter.swift` for the sandboxed app. UI add/export wiring is deferred to later issues; this spike removes engine uncertainty.
