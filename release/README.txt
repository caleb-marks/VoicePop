VoicePop for macOS (Apple Silicon, macOS 13+)

Install:  open Terminal, drag this folder in after "cd ", then run  ./install.sh

What install.sh does:
  - installs Voxtype.app (speech engine, MIT, https://github.com/peteonrails/voxtype;
    the bundled voxtype-bin is Voxtype 1.0.1 rebuilt with NVIDIA Parakeet support)
  - downloads the Parakeet model (about 2.4 GB, one time)
  - writes ~/.config/voxtype/config.toml if you have none
  - installs and opens /Applications/VoicePop.app

Not notarized. If macOS refuses to open an app, right-click it and choose Open, or re-run install.sh.

Source, docs, issues: https://github.com/caleb-marks/VoicePop
