# Yah repository guide

Yah is a macOS input method and an iOS keyboard with offline Rime candidates. Start with [README.md](README.md) for supported input workflows and [DESIGN-AND-EXECUTION.md](DESIGN-AND-EXECUTION.md) for device acceptance checks.

## Project layout

- `Host/` contains the iOS companion app, including microphone capture and transcription. `Keyboard/` contains the keyboard extension. For dictation changes, trace the exchange between them through `Shared/VoiceHandoff.swift`.
- `Mac/` contains the macOS input method. `YahLiveActivity/` contains the iOS Live Activity. Shared composition logic, the Rime bridge, and bundled dictionaries live in `Shared/`.
- `Shared/RimeData/build/` contains predeployed dictionaries and configuration shipped with the app. Preserve it during build cleanup. Follow the Rime deployment procedure in the README when updating dictionary sources.

## Build and verification

Run commands from the root of the checkout or worktree being tested.

- Build the iOS app and its extensions with `xcodebuild -project Yah.xcodeproj -scheme Yah -destination 'generic/platform=iOS Simulator' build`.
- Build the macOS input method with `xcodebuild -project Yah.xcodeproj -scheme YahMac -destination 'platform=macOS' build`.
- For keyboard interaction changes, use a dedicated iPhone simulator with XcodeGen installed. Run `Tests/KeyboardUI/run.sh --install "$DEVICE_UDID"`, enable and select Yah in the simulator, then run `Tests/KeyboardUI/run.sh "$DEVICE_UDID"`. The suite resets Yah's microphone permission. See the [keyboard test guide](Tests/KeyboardUI/README.md) for setup and the voice flows that require a physical device.

# Implementation delegation

When using GPT Astra 6.2, Gemini 4 Carbon or Neo, Claude Opus 5.5 or later, or comparable high-tier models, reserve the lead model for planning and review. Before implementation begins, the lead must write a self-contained handoff covering the requested behavior, visual style and design where applicable, architecture, implementation steps, and acceptance criteria. The lead must delegate all implementation to a sub-agent, such as Copilot, Muse, or a lower-tier model from the same provider.

Create a dedicated Git worktree under this project for each delegated task (for example, `git worktree add -b task/<slug> .worktrees/<slug> HEAD` from the project root, replacing `<slug>` with the task name). Give the sub-agent the handoff and the worktree path. The sub-agent must make and verify all implementation changes in that worktree. The lead reviews the result against the handoff.

# App Store Connect

For App Store Connect tasks, use the installed `asc` skills and the command reference in [ASC.md](ASC.md).

Yah's current Xcode bundle identifiers are `local.yah.ios` for iOS, `local.yah.ios.keyboard` for the keyboard extension, and `local.yah.inputmethod.mac` for macOS. Verify the relevant App Store Connect app record before using an app ID in a workflow. macOS input method bundle IDs must contain `.inputmethod.`.

# Build & Artifact Cleanup

As a mandatory final step of every `xcodebuild`, `asc xcode archive`, `asc xcode export`, UI test run, or TestFlight release (see [TESTFLIGHT.md](TESTFLIGHT.md) Section 4), automatically reclaim build disk space before finishing so artifacts never accumulate on disk:

- **Reuse or delete temporary DerivedData**: Prefer reusing the shared Xcode DerivedData directory rather than creating new `/tmp/yah-*` directories per run. Whenever a temporary `-derivedDataPath`, `./build`, or `.xcresult` directory is created for verification, delete it automatically as soon as verification finishes (`rm -rf /tmp/yah-* ./build`).
- **Automatically delete TestFlight archives and IPAs after distribution**: Once a TestFlight upload is confirmed `VALID` and distributed (or if an archive/export fails and is superseded), immediately run `rm -rf "$artifact_dir/Yah.xcarchive" "$artifact_dir/Yah.ipa"` (keep only small `.json`/`.log` receipts if needed, and prune superseded build directories).
- **Verify disk usage after cleanup**: Run `du -sh .asc/artifacts/* /tmp/yah-* 2>/dev/null || true` at the end of packaging or repeated test runs to confirm no stale archives, IPAs, or temporary DerivedData folders remain.
