# Mac distribution

Public releases require Apple Developer Program membership, a Developer ID Application certificate with its private key in the login keychain, and a notarytool keychain profile. Apple Development certificates cannot be used. Create the distribution certificate in your Apple Developer account/Xcode; do not commit certificates or credentials.

Store notarization credentials interactively in Keychain:

```sh
xcrun notarytool store-credentials voicepop-notary
```

Build with your exact certificate name from `security find-identity -v -p codesigning`:

```sh
export VOICEPOP_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)'
export VOICEPOP_NOTARY_PROFILE=voicepop-notary
./scripts/make-release.sh
```

`VOXTYPE_BIN` may point to a Parakeet-capable engine; otherwise the installed Voxtype engine is used. `VOXTYPE_PROVENANCE` must point at that engine's `VOXTYPE-BUILD.txt` (defaults to a sibling of the binary). The pipeline signs the helper and containing app, then submits the app ZIP once: Apple generates tickets for both bundles. It staples the helper and app without re-signing, verifies them, and builds and notarizes the DMG containing those stapled bundles. This uses two submissions instead of three and preserves attached tickets for offline verification, including for the separately installed helper. The VoicePop bundle also keeps the engine license and provenance files in Resources. All executables use Hardened Runtime; the recording helper has the audio-input entitlement. An app-only ZIP preserves the stapled app. A failed check stops the release. Submission JSON is retained in dist for diagnosing rejected submissions with `xcrun notarytool log`.

`./scripts/package-app.sh` without a signing identity remains available for local ad-hoc development. Those builds must not be published as notarized releases.

`make-release.sh` requires the Swift tests to pass before packaging and runs `verify-release-artifacts.sh` on the final ZIP and DMG before writing checksums or reporting success. This checks required bundle contents, embedded home paths, and code signatures.

Upload the versioned DMG, ZIP, `VoicePop.dmg`, and `SHA256SUMS` from dist to the new GitHub release. Once the stable asset exists in the latest release, change the README download button to:

https://github.com/caleb-marks/VoicePop/releases/latest/download/VoicePop.dmg

The README links to the stable latest-release asset as of v1.2.2 (v1.2.0 was the first notarized release). Do not upload intermediate notary ZIPs or claim an old release is notarized.

Before publishing, download the actual candidate through a browser on a clean Mac/account with normal Gatekeeper settings. Verify DMG opening, installation, first launch, model download, microphone capture, FN detection, text insertion, relaunch, and upgrade from the previous release. Check that the helper remains signed after installation and that permissions refer to Voxtype. Existing incompatible Voxtype installations are preserved and setup explains how to replace them. Existing compatible installations are retained; their signing and permissions can differ from a clean installation.

The current onboarding still needs user approval for Accessibility, Input Monitoring, and Microphone. Signing does not grant those permissions. A normal downloaded-app confirmation may remain. Test on macOS 13 and the latest supported macOS, including a download interruption. Model download progress is already shown in setup.

## Pre-release checklist

Automated (run from the repo; record the output with the release):

- [ ] `swift test --package-path PopcornHUD` passes.
- [ ] CI (Build and test), CodeQL, Dependabot, and secret-scanning show no open alerts.
- [ ] `scripts/verify-release-artifacts.sh` passes on the final ZIP and DMG (contents, embedded home paths, signatures).
- [ ] On the published assets: `shasum -a 256 -c SHA256SUMS`, `codesign --verify --deep --strict`, `spctl --assess --type execute` reports `Notarized Developer ID`, `xcrun stapler validate` on the app, helper, and DMG, and a byte-level `grep -a` for `/Users/` finds only upstream `/Users/runner` paths.

Manual, on a clean Mac or a fresh user account (these cannot be simulated; the unit tests cover the installer's file operations only):

- [ ] Download the DMG in Safari with default Gatekeeper settings; open it and launch the copy inside the DMG. VoicePop offers to move to Applications and relaunches from there.
- [ ] First-run checklist: engine install, model download with progress, then Accessibility, Input Monitoring, and Microphone prompts name **Voxtype**, and the practice dictation types text.
- [ ] Interrupt the model download (disconnect the network mid-way). The checklist shows the failure with Retry, and Retry completes the download.
- [ ] FN (Globe) hold starts recording; release transcribes; text lands in the focused app (Notes, a browser field, a terminal).
- [ ] Quit and relaunch; log out and back in. The engine and menu bar item come back once.
- [ ] Upgrade: with the previous release installed and running, open the new DMG and launch it. The new version replaces the old one, the old one appears in `~/Library/Application Support/VoicePop/Previous Versions/`, and permissions still work without re-granting.
- [ ] Revoke Accessibility for Voxtype and dictate: confirm the text lands on the clipboard (the documented fallback), then re-grant.
- [ ] Settings → General → Privacy: turn off Save transcript history, dictate, and confirm `history.jsonl` does not grow; Fix Last Dictation explains history is off when nothing was saved.
- [ ] Repeat the install and dictation steps on macOS 13 (the minimum) or record that this was not done.

Record which items were run, on which macOS version and hardware, in the release notes. Do not report the automated checks as clean-machine validation.

### What was verified for 1.2.1

Automated checks all passed on 2026-09-12 (macOS 26.6, Apple M4): 196 unit tests, CI and CodeQL green with no open alerts, and the published ZIP and DMG matched `SHA256SUMS`, verified with `codesign`, `spctl` (`Notarized Developer ID`), and `stapler`, with no embedded builder paths. None of the manual, clean-machine items above were run for 1.2.1, and macOS 13 through 15 have not been tested by hand.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Apple Gatekeeper](https://support.apple.com/en-us/102445), [GitHub release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
