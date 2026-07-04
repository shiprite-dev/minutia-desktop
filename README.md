<img src="Minutia/Resources/brand/icon-512.png" alt="Minutia" width="80" />

# Minutia Desktop

A native macOS menu bar companion for [Minutia](https://github.com/shiprite-dev/minutia), the open-source Outstanding Issues Log for recurring meetings.

Minutia Desktop records meeting audio directly on your Mac, microphone plus system audio from Zoom, Teams, Meet, or anything else playing, so meeting notes and action items land in your Minutia instance without a bot joining the call.

## What it does

- **Records mic + system audio.** A CoreAudio process tap captures everything playing on your Mac (macOS 14.4+), mixed with your microphone into a single stream.
- **Uploads while the meeting runs.** Audio is cut into 5-minute m4a segments and queued for transcription as each one closes, so the recap is already assembling before you hang up.
- **Finalizes on stop.** Stopping uploads the tail of the recording, requests the final transcription pass, and opens the flowing recap for that meeting in your browser.
- **Detects meetings automatically.** Watches for a live microphone plus a corroborating signal: Zoom's `CptHost` helper process, the Teams bundle id, or a calendar event in progress, then surfaces a "Record this meeting?" notification with a one-click Record action.
- **Signs in three ways.** "Sign in with browser" hands off to your Minutia instance and completes via a `minutia://` callback; email/password and Google are available as a fallback.

## Requirements

- macOS 14.4 or later
- Xcode (to build; no signed release yet, see below)
- A running Minutia instance to connect to

## Permissions

macOS prompts for two permissions the first time you record, never before:

- **Microphone**: captures your side of the conversation.
- **System audio recording** (via the CoreAudio process tap): captures everything else playing on your Mac so the other participants' audio makes it into the transcript.

## Installing

There are no signed releases yet; build from source:

```bash
brew install xcodegen
make build  # generates the Xcode project and builds the app
make run    # builds and opens the app
```

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`, so the `.xcodeproj` is not checked in. `make gen` regenerates it on its own if you want to open it in Xcode directly.

```bash
make test   # generates the project and runs the test suite
```

## Configuration

Minutia Desktop connects to the managed Minutia Cloud instance by default, so there is nothing to configure: launch it and sign in. Self-hosters point it at their own instance in Settings, paste the URL (for example `https://minutia.example.com`), hit Reconnect, and a status line confirms the connection. Launch-at-login, sign out, and the app version (0.1.0) live in the same Settings window.

## Privacy

- Raw audio is discarded once the transcript has been safely captured, by default. This is configurable per instance (an admin can switch to keep-forever) in that instance's admin settings, not in this app.
- Nothing is stored outside the Minutia instance you connect to. There is no separate Minutia Desktop backend.
- Recording never starts silently: it is always a Record button press or an explicit notification action.

## License

MIT, see [LICENSE](LICENSE).
