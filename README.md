# Movies Connector

macOS app that joins video files in a specified order using AVFoundation passthrough (no re-encode).

See [DESIGN.md](DESIGN.md) for v1 scope and architecture.

## Adding videos

Supported input routes:

- **Finder** drag-and-drop onto the queue
- **Add Videos** (open panel; multi-select)

Direct drag-and-drop from the Photos app is not supported. Export the movie from Photos to a Finder folder first, then drop it from Finder or choose it with Add Videos.

## Requirements

- macOS 14+
- Xcode 16+ (Xcode 26 recommended)

## Build

```bash
xcodebuild -scheme MoviesConnector -destination 'platform=macOS' build
```

Or open `MoviesConnector.xcodeproj` in Xcode and run the `MoviesConnector` scheme.

## Layout

```text
MoviesConnector.xcodeproj
├── MoviesConnector
│   ├── App/
│   ├── Join/
│   ├── Media/
│   ├── FileAccess/
│   └── MoviesConnector.entitlements
└── MoviesConnectorTests/
```

## Spike (#1)

Passthrough join validation and `CompatibilitySignature` rules:

- [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md)
- [docs/SPIKE.md](docs/SPIKE.md)

## Acceptance (#7)

Release-readiness checks (correctness, sandbox, failure cleanup, speed KPI):

- [docs/ACCEPTANCE.md](docs/ACCEPTANCE.md)
- Harness: `Scripts/run_acceptance_benchmark.sh` (Release `JoinExporter`; surrogates report `n/a`, not KPI yes/no)
- Fixtures: `Scripts/generate_acceptance_fixtures.swift`
- Blocking follow-ups: [#14](https://github.com/Akihiro-Arai/movies-connector/issues/14) (4K×10≈20GB), [#16](https://github.com/Akihiro-Arai/movies-connector/issues/16) (iCloud), [#17](https://github.com/Akihiro-Arai/movies-connector/issues/17) (long media)
