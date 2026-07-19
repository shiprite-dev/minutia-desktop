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
- A running Minutia instance to connect to

## Permissions

macOS prompts for two permissions the first time you record, never before:

- **Microphone**: captures your side of the conversation.
- **System audio recording** (via the CoreAudio process tap): captures everything else playing on your Mac so the other participants' audio makes it into the transcript.

## Download

Grab the latest `Minutia-<version>.dmg` from the [Releases](https://github.com/shiprite-dev/minutia-desktop/releases/latest) page, open it, and drag **Minutia** into **Applications**. Launch it from Applications; it lives in the menu bar (no Dock icon).

The first time you record, macOS prompts once for **Microphone** and once for **System audio recording** (never before). Grant both so the other participants' audio makes it into the transcript. The app checks for and installs its own updates via Sparkle.

## Building from source

```bash
brew install xcodegen
make build  # generates the Xcode project and builds the app
make run    # builds and opens the app
```

This project uses [XcodeGen](https://github.com/yonaskolb/XcodeGen) to generate the Xcode project from `project.yml`, so the `.xcodeproj` is not checked in. `make gen` regenerates it on its own if you want to open it in Xcode directly.

```bash
make test   # generates the project and runs the test suite
make dmg    # packages a runnable local DMG (unsigned fallback if no Developer ID cert)
```

## Releasing (maintainers)

Releases are cut by [`.github/workflows/release.yml`](.github/workflows/release.yml): push a `vX.Y.Z` tag and it produces a Developer ID signed, notarized, stapled DMG plus a Sparkle `appcast.xml`, and uploads both to the GitHub Release. The tag drives `MARKETING_VERSION`; the workflow run number drives the (strictly increasing) build number Sparkle needs to detect updates.

One-time setup:

1. **Developer ID Application certificate.** Export it (with its private key) as a `.p12`, then `base64` it into the `DEVELOPER_ID_CERT_P12` secret; put the export password in `DEVELOPER_ID_CERT_PASSWORD` and your 10-character Team ID in `DEVELOPMENT_TEAM`.
2. **App Store Connect API key** (for notarization). Create a key in App Store Connect, `base64` the `.p8` into `ASC_KEY_P8`, and set `ASC_KEY_ID` and `ASC_ISSUER_ID`.
3. **Sparkle EdDSA key pair.** Run `generate_keys` from the [Sparkle](https://github.com/sparkle-project/Sparkle/releases) distribution once. Put the **private** key in the `SPARKLE_PRIVATE_KEY` secret and the **public** key in `SUPublicEDKey` in `project.yml` (it currently holds the `REPLACE_WITH_SPARKLE_PUBLIC_ED_KEY` placeholder, which builds fine but must be swapped in before the first real release).

Required GitHub secrets: `DEVELOPER_ID_CERT_P12`, `DEVELOPER_ID_CERT_PASSWORD`, `DEVELOPMENT_TEAM`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, `ASC_KEY_P8`, `SPARKLE_PRIVATE_KEY`.

Then: `git tag v0.2.0 && git push origin v0.2.0`.

## Configuration

Minutia Desktop connects to the managed Minutia Cloud instance by default, so there is nothing to configure: launch it and sign in. Self-hosters point it at their own instance in Settings, paste the URL (for example `https://minutia.example.com`), hit Reconnect, and a status line confirms the connection. Launch-at-login, sign out, and the app version (0.1.0) live in the same Settings window.

## Privacy

- Raw audio is discarded once the transcript has been safely captured, by default. This is configurable per instance (an admin can switch to keep-forever) in that instance's admin settings, not in this app.
- Nothing is stored outside the Minutia instance you connect to. There is no separate Minutia Desktop backend.
- Recording never starts silently: it is always a Record button press or an explicit notification action.

## License

MIT, see [LICENSE](LICENSE).
