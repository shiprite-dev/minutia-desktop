# Changelog

All notable changes to this project are documented in this file.

## [Unreleased]

## [0.2.0]

### Distribution
- Developer ID signing, notarization, and DMG packaging pipeline: a `v*` tag drives a signed, notarized, stapled `Minutia-<version>.dmg` published to GitHub Releases. `make dmg` also builds a runnable local DMG.
- Self-updating via Sparkle: an in-app "Check for Updates" control plus automatic background checks against a signed appcast, with nested Sparkle helpers signed individually (never `codesign --deep`).
- Version and build number are stamped from the pushed git tag and the CI run number, so every release advertises a strictly increasing build to Sparkle.

### Security
- Added the `com.apple.security.device.audio-input` Hardened Runtime entitlement so microphone capture keeps working under a signed, hardened, notarized build (unsigned dev builds did not surface this).
- Sign-in callbacks and web-triggered record commands are gated: a `minutia://record` deep link never starts a covert recording; capture requires an explicit confirm, and consent expires.
- Fixed a Supabase upload RLS denial caused by an uppercase meeting UUID.

### Reliability
- Warm `minutia://` deep links are delivered through a `kAEGetURL` Apple Event handler so already-running sign-ins are no longer dropped.
- Quitting mid-recording prompts to finish the upload; the durable capture directory lets the next launch recover and finalize any recording orphaned by a crash or forced quit.
- Bounded the stop/finalize path so a stuck upload can no longer hang termination.

### Capture robustness
- CoreAudio process tap mixes microphone and system audio into a single stream, cut into 5-minute segments uploaded while the meeting is still running.
- Automatic meeting detection (Zoom/Teams/calendar) with a quiet menu-bar hint for mic-only activity and a one-click record notification for corroborated meetings.

### Added
- Repo scaffold: XcodeGen project, menu bar app shell, `AppPhase` state machine core, CI smoke test.
