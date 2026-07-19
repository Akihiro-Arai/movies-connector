# Movies Connector

macOS app that joins video files in a specified order using AVFoundation passthrough (no re-encode).

See [DESIGN.md](DESIGN.md) for v1 scope and architecture.

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
