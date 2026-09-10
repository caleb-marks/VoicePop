# Contributing

Issues and pull requests are welcome.

## Build

Swift Package Manager, no Xcode project.

```bash
swift build --package-path PopcornHUD
swift test  --package-path PopcornHUD   # 57 tests
```

Requires macOS 13+ on Apple Silicon and Swift 5.9.

## Where things live

| Target | What it holds |
|---|---|
| `PopcornCore` | Audio framing, physics, text clean, style, corrections — **the tested target** |
| `PopcornArt` | Renderers (popcorn tub, beagle) |
| `PopcornHUD` | Menu bar, windows, watchers |
| `VoxtypeClean` | The post-processor Voxtype shells out to |
| `PopcornCapture` | Still and GIF capture tool for `docs/visuals/` |

Put logic in `PopcornCore` where it can be tested. The physics use a fixed timestep and a seeded RNG so HUD frames are reproducible in tests — keep it that way.

## Before you open a PR

- `swift test --package-path PopcornHUD` passes.
- If you changed how the HUD renders, regenerate the affected stills with `PopcornCapture` so `docs/visuals/` matches the code.
- No audio, transcript text, screenshots of personal content, or absolute `/Users/...` paths. Config templates use `__VOICEPOP_ROOT__`.

## Running a local build

```bash
./scripts/setup-launch-agents.sh   # rebuilds, signs, replaces /Applications/VoicePop.app, relaunches
```

Never run a second HUD binary alongside the installed one.

## Commit messages

Imperative mood, a real subject line, and a body explaining why when the change is not obvious. Match what is already in `git log`.
