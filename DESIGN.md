# Movies Connector — Design (v1)

Source: Codex `gpt-5.6-sol` / reasoning `high` (2026-07-19).

## Goal

macOS-native app that concatenates video files in a user-specified order as fast as possible. No other features in v1 (no preview, trim, effects, or audio mix).

## Decisions

1. **UI**: SwiftUI macOS app, minimum macOS 14. Single window. No external UI libs.
2. **Engine**: AVFoundation lossless passthrough only.
   - `AVMutableComposition` insert tracks in order
   - `AVAssetExportSession` + `AVAssetExportPresetPassthrough`
   - Output: QuickTime Movie (`.mov`)
   - No FFmpeg / no external processes
3. **Incompatible inputs**: Reject build. No re-encode. Inspect on add; disable export with clear per-row reasons.
4. **Sandbox**: App Sandbox on; `com.apple.security.files.user-selected.read-write` only. Security-scoped access during job; no bookmarks in v1.
5. **Speed KPI** (Apple Silicon, local SSD, compatible 4K ×10 ≈ 20GB):
   - Median join time ≤ 1.25× same-destination file copy
   - Avg CPU < 1 logical core
   - No re-encode; duration within 1 frame of sum; order exact

## UI (single screen)

- Add videos / Finder drop
- Reorderable list (name, duration, compatibility)
- Output path + Join button
- Progress + cancel while exporting

## Project layout

```text
MoviesConnector.xcodeproj
├── MoviesConnector
│   ├── App/
│   ├── Join/          # JoinView, JoinViewModel
│   ├── Media/         # AssetInspector, CompatibilitySignature, JoinExporter
│   ├── FileAccess/
│   └── MoviesConnector.entitlements
└── MoviesConnectorTests/
```

## MVP milestones

1. Tech spike: passthrough join + compatibility check on device
2. Minimal UI: multi-select, drop, reorder, delete, output picker
3. Join complete: preflight, progress, cancel, delete partial output on failure
4. Acceptance: local + iCloud inputs, sandbox, long media, disk-full; meet KPIs
