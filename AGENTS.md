# App Store Connect

For App Store Connect tasks, use the installed `asc` skills and the command reference in [ASC.md](ASC.md).

Yah's current Xcode bundle identifiers are `local.yah.ios` for iOS, `local.yah.ios.keyboard` for the keyboard extension, and `local.yah.inputmethod.mac` for macOS. Verify the relevant App Store Connect app record before using an app ID in a workflow. macOS input method bundle IDs must contain `.inputmethod.`.

# Build & Artifact Cleanup

As a mandatory final step of every `xcodebuild`, `asc xcode archive`, `asc xcode export`, UI test run, or TestFlight release (see [TESTFLIGHT.md](TESTFLIGHT.md) Section 4), automatically reclaim build disk space before finishing so artifacts never accumulate on disk:

- **Reuse or delete temporary DerivedData**: Prefer reusing the shared Xcode DerivedData directory rather than creating new `/tmp/yah-*` directories per run. Whenever a temporary `-derivedDataPath`, `./build`, or `.xcresult` directory is created for verification, delete it automatically as soon as verification finishes (`rm -rf /tmp/yah-* ./build`).
- **Automatically delete TestFlight archives and IPAs after distribution**: Once a TestFlight upload is confirmed `VALID` and distributed (or if an archive/export fails and is superseded), immediately run `rm -rf "$artifact_dir/Yah.xcarchive" "$artifact_dir/Yah.ipa"` (keep only small `.json`/`.log` receipts if needed, and prune superseded build directories).
- **Verify disk usage after cleanup**: Run `du -sh .asc/artifacts/* /tmp/yah-* 2>/dev/null || true` at the end of packaging or repeated test runs to confirm no stale archives, IPAs, or temporary DerivedData folders remain.
