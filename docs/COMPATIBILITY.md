# CompatibilitySignature (v1)

Lossless passthrough join (`AVAssetExportPresetPassthrough`) requires every input to share the same track topology and encoded parameters. Movies Connector **rejects** the set when any normalized field differs. There is no re-encode path in v1.

Implementation types: `MoviesConnector/Media/CompatibilitySignature.swift`, `AssetInspector.swift`.

## Supported topology

| Rule | v1 expectation |
| --- | --- |
| Video tracks | Exactly **1** per file |
| Audio tracks | **0 or 1**, and the count must match across all inputs |
| Other tracks | **Unsupported** (timecode, subtitle/forced text, closed caption, metadata media, etc.) → reject |
| Chapters / attachments | Not part of the signature; ignore for compare, do not require |

## Fields and normalization

### Topology

| Field | Source | Normalization |
| --- | --- | --- |
| `videoTrackCount` | `AVAsset.tracks` filtered by `.video` | Integer count |
| `audioTrackCount` | `AVAsset.tracks` filtered by `.audio` | Integer count |
| `hasUnsupportedTracks` | Any track whose media type is not video/audio | `true` → always incompatible |

### Video

| Field | Source | Normalization |
| --- | --- | --- |
| `videoCodec` | `CMFormatDescription` media subtype FourCC | ISO-Latin1 FourCC → trim whitespace → **lowercase** (e.g. `hvc1`, `avc1`, `apcn`) |
| `videoDisplayWidth` / `videoDisplayHeight` | `naturalSize` × `preferredTransform` | Absolute values, rounded to `Int` (display pixels) |
| `videoPreferredTransform` | `AVAssetTrack.preferredTransform` | Components `a,b,c,d,tx,ty` quantized to **6 decimal places** |
| `videoFrameDuration` | Prefer `minFrameDuration`; else `1 / nominalFrameRate` | Reduced `value/timescale` rational |
| `videoTimescale` | Primary video track time range timescale | `Int32`; must match exactly |

### Audio (when `audioTrackCount == 1`)

| Field | Source | Normalization |
| --- | --- | --- |
| `audioCodec` | Audio format description FourCC | Same FourCC normalization as video |
| `audioSampleRate` | `AudioStreamBasicDescription.mSampleRate` | Compare with ε = `1e-6` |
| `audioChannelCount` | `mChannelsPerFrame` | Exact `Int` |
| `audioFormatFlags` | `mFormatFlags` | Exact `UInt32` (relevant for LPCM); `0` vs absent still compared as stored |

When `audioTrackCount == 0`, audio fields are `nil` / unused and must match the peer (also zero audio).

## Comparison algorithm

1. Build a signature for each URL via `AssetInspector.makeSignature`.
2. Use the first file as the reference.
3. Reject immediately if the reference has unsupported tracks or `videoTrackCount != 1`.
4. For each subsequent file, collect every `CompatibilityMismatch` from `CompatibilityComparer.mismatches`.
5. If the mismatch list is non-empty, disable export and surface per-row reasons (UI in later issues).

`Equatable` on `CompatibilitySignature` is a convenience; production gating should use `CompatibilityComparer` so callers receive concrete reasons.

## Explicitly out of scope for signature (v1)

- Color primaries / transfer / matrix (HDR vs SDR) — **candidate for a later hardening issue** if passthrough fails in the wild
- Bitrate, file size, container brand (`ftyp`)
- Exact sample timing beyond frame duration + timescale
- Multi-channel layout tags beyond channel count + format flags

## Incompatible examples (expected reject reasons)

| Pair | Typical reason |
| --- | --- |
| HEVC 4K + H.264 4K | `Video codec mismatch (hvc1 vs avc1)` |
| 1920×1080 + 1280×720 | `Video display size mismatch` |
| 30 fps + 24 fps | `Video frame duration mismatch` |
| Stereo AAC + mono AAC | `Audio channel count mismatch` |
| Video+audio + video-only | `Audio track count mismatch` |
| Portrait transform vs identity | `Video preferred transform mismatch` |
