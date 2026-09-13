# Contributing

Issues and pull requests are welcome.

## Build

Swift Package Manager, no Xcode project.

```bash
swift build --package-path PopcornHUD
swift test --package-path PopcornHUD
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

## Checking UI and performance without touching your install

- **Settings, correction, and setup windows:** `VOICEPOP_UI_SNAPSHOT=/tmp/ui VOICEPOP_CONFIG_DIR=$(mktemp -d) VOICEPOP_SETUP_SKIP=1 PopcornHUD/.build/debug/PopcornHUD` renders every window in light and dark to PNGs, logs menu states and the keyboard focus order, and exits. It starts no services and refuses to run without a separate `VOICEPOP_CONFIG_DIR`.
- **HUD art and motion:** `PopcornCapture --review <dir>` (stills on light, dark, and busy backdrops) and `PopcornCapture --motion <dir>` (contact sheets, heap trace, GIF/MP4).
- **Performance:** `PopcornCapture --bench` for simulation and offscreen rendering, and `PopcornHUD/Benchmarks/build.sh` for the state-watcher, publication, and timing-report tools. Record results in [docs/metrics.md](docs/metrics.md), labelled as measured, target, or not measured.
- **Persistence tests:** use `VOICEPOP_CONFIG_DIR` or injected URLs. Never exercise failure paths against `~/.config/voicepop`.

## Before you open a PR

- `swift test --package-path PopcornHUD` passes.
- If you changed how the HUD renders, regenerate the affected stills with `PopcornCapture` so `docs/visuals/` matches the code. The beagle stills must stay pixel-identical unless you meant to change the beagle.
- If you changed a window, run the UI snapshot harness and look at the result.
- No audio, transcript text, screenshots of personal content, or absolute `/Users/...` paths. Config templates use `__VOICEPOP_ROOT__`.

## Running a local build

```bash
./scripts/setup-launch-agents.sh   # rebuilds, signs, replaces /Applications/VoicePop.app, relaunches
```

Never run a second HUD binary alongside the installed one.

## Commit messages

Imperative mood, a real subject line, and a body explaining why when the change is not obvious. Match what is already in `git log`.
