# CompatibilitySignature (v1)

Lossless passthrough join (`AVAssetExportPresetPassthrough`) requires every input to share the same track topology and encoded parameters. Movies Connector **rejects** the set when any normalized field differs. There is no re-encode path in v1.

Implementation types: `MoviesConnector/Media/CompatibilitySignature.swift`, `AssetInspector.swift`.

## Supported topology

| Rule | v1 expectation |
| --- | --- |
| Video tracks | Exactly **1** per file |
| Audio tracks | Any count `N >= 0`; every input must share the same `N`, and each track index `i` must match across inputs |
| Other tracks | **Ignorable side-cars** are limited to metadata and timecode (common Photos/iPhone attachments). Text / closed caption / subtitle and any other non-AV media type → reject |
| Chapters / attachments | Not part of the signature; ignore for compare, do not require |

## Fields and normalization

### Topology

| Field | Source | Normalization |
| --- | --- | --- |
| `videoTrackCount` | `AVAsset.tracks` filtered by `.video` | Integer count |
| `audioTracks` / `audioTrackCount` | `AVAsset.tracks` filtered by `.audio` (order preserved) | Ordered `[AudioTrackSignature]`; count is `audioTracks.count` |
| `hasUnsupportedTracks` | Any non-AV track that is not an ignorable side-car | `true` → always incompatible |

### Video

| Field | Source | Normalization |
| --- | --- | --- |
| `videoCodec` | `CMFormatDescription` media subtype FourCC | ISO-Latin1 FourCC → trim whitespace → **lowercase** (e.g. `hvc1`, `avc1`, `apcn`) |
| `videoDisplayWidth` / `videoDisplayHeight` | `naturalSize` × `preferredTransform` | Absolute values, rounded to `Int` (display pixels) |
| `videoPreferredTransform` | `AVAssetTrack.preferredTransform` | Components `a,b,c,d,tx,ty` quantized to **6 decimal places** |
| `videoFrameDuration` | Prefer `minFrameDuration`; else `1 / nominalFrameRate` | Reduced `value/timescale` rational; compare as seconds with **relative tolerance 6%** (allows iPhone ~30fps jitter such as `19/600` vs `20/600`; rejects 30 vs 24) |
| `videoTimescale` | Primary video track `AVAssetTrack.naturalTimeScale` | `Int32`; must match exactly (not `timeRange.start.timescale`) |

### Audio (per track index `i` in `audioTracks`)

| Field | Source | Normalization |
| --- | --- | --- |
| `codec` | Audio format description FourCC | Same FourCC normalization as video |
| `sampleRate` | `AudioStreamBasicDescription.mSampleRate` | Compare with ε = `1e-6` |
| `channelCount` | `mChannelsPerFrame` | Exact `Int` |
| `formatFlags` | `mFormatFlags` | Exact `UInt32` (relevant for LPCM); `0` vs absent still compared as stored |

When `audioTrackCount == 0`, `audioTracks` is empty and must match the peer (also zero audio). Typical multi-audio case: iPhone AAC + APAC (`N = 2`) with matching per-index parameters.

## Comparison algorithm

1. Build a signature for each URL via `AssetInspector.makeSignature`.
2. Use the first file as the reference.
3. Reject immediately if the reference has unsupported tracks or `videoTrackCount != 1`.
4. For each subsequent file, collect every `CompatibilityMismatch` from `CompatibilityComparer.mismatches` (audio-count mismatch and per-track field mismatches identify the track index).
5. If the mismatch list is non-empty, disable export and surface per-row reasons (UI in later issues).

`Equatable` on `CompatibilitySignature` is a convenience; production gating should use `CompatibilityComparer` so callers receive concrete reasons.

## Explicitly out of scope for signature (v1)

- Color primaries / transfer / matrix (HDR vs SDR) — **candidate for a later hardening issue** if passthrough fails in the wild
- Bitrate, file size, container brand (`ftyp`)
- Exact sample timing beyond frame duration + timescale
- Multi-channel layout tags beyond channel count + format flags
- Frame-duration tolerance (exact rational match only)

## Incompatible examples (expected reject reasons)

| Pair | Typical reason |
| --- | --- |
| HEVC 4K + H.264 4K | `Video codec mismatch (hvc1 vs avc1)` |
| 1920×1080 + 1280×720 | `Video display size mismatch` |
| 30 fps + 24 fps | `Video frame duration mismatch` |
| Stereo AAC + mono AAC (same track index) | `Audio track[0] channel count mismatch` |
| Video+audio + video-only | `Audio track count mismatch` |
| AAC+APAC + AAC-only | `Audio track count mismatch (2 vs 1)` |
| Matching AAC on track 0, APAC vs AAC on track 1 | `Audio track[1] codec mismatch` |
| Portrait transform vs identity | `Video preferred transform mismatch` |
