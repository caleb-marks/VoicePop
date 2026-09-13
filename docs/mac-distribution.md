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

The README links to the stable latest-release asset as of v1.2.1 (v1.2.0 was the first notarized release). Do not upload intermediate notary ZIPs or claim an old release is notarized.

Before publishing, download the actual candidate through a browser on a clean Mac/account with normal Gatekeeper settings. Verify DMG opening, installation, first launch, model download, microphone capture, FN detection, text insertion, relaunch, and upgrade from the previous release. Check that the helper remains signed after installation and that permissions refer to Voxtype. Existing incompatible Voxtype installations are preserved and setup explains how to replace them. Existing compatible installations are retained; their signing and permissions can differ from a clean installation.

The current onboarding still needs user approval for Accessibility, Input Monitoring, and Microphone. Signing does not grant those permissions. A normal downloaded-app confirmation may remain. Test on macOS 13 and the latest supported macOS, including a download interruption. Model download progress is already shown in setup.

References: [Apple notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow), [Apple Gatekeeper](https://support.apple.com/en-us/102445), [GitHub release links](https://docs.github.com/en/repositories/releasing-projects-on-github/linking-to-releases).
