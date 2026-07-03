# Minutia Desktop

A native macOS menu bar companion for [Minutia](https://github.com/shiprite-dev/minutia), the open-source Outstanding Issues Log for recurring meetings.

Minutia Desktop captures meeting audio (system audio from Zoom, Teams, Meet, plus your microphone) directly on your Mac, so meeting notes and action items land in your Minutia instance without a bot joining the call.

## Status

Early scaffold. Capture, authentication, and upload are not implemented yet.

## Requirements

- macOS 14.4 or later
- A running Minutia instance (self-hosted or hosted) to connect to

## Building

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`, so the `.xcodeproj` is not checked in.

```bash
brew install xcodegen
make test   # generates the project and runs the test suite
make build  # generates the project and builds the app
make run    # builds and opens the app
```

## Configuration

Minutia Desktop connects to a Minutia instance URL that you configure at first launch. It does not assume any particular hosting provider; point it at any Minutia instance, for example `https://minutia.example.com`.

## License

MIT, see [LICENSE](LICENSE).
