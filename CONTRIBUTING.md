# Contributing to LocalFlow

Start with a focused issue or pull request describing a user-visible problem, the change, and how you checked it. Code and commit messages are in English; Russian and English bug reports are welcome.

## Development

Use an Apple Silicon Mac with Xcode **26.6**, its Metal toolchain, and XcodeGen. The runtime deployment target is macOS 15; the build toolchain is newer because of the pinned MLX dependencies.

```sh
brew install xcodegen
xcodebuild -downloadComponent MetalToolchain
Scripts/test.sh
Scripts/build.sh
```

The unit and interface tests run without model weights or microphone permissions. Initial dependency resolution needs internet access. Use `LOCALFLOW_DATA_DIR` to point test or experimental runs to a separate directory. Never point a test fixture at a real session identifier.

GitHub Actions runs tests and compiles both the app and benchmark tool on `macos-26` with Xcode 26.6. It does not sign, publish or install a release. The runner choice follows the [official image inventory](https://github.com/actions/runner-images/blob/main/images/macos/macos-26-arm64-Readme.md).

## Changes that need particular care

- **Speech and editing:** add a synthetic example of the failure and a regression check. Keep the original transcript and rejected proposals. Report recognition accuracy separately from editing fidelity and latency.
- **Archive:** migrate forwards in a transaction. Test fresh, previous, newer and invalid schemas. Preserve dictionary, voices, text and search results; never delete a database to recover from a migration error.
- **Privacy:** do not submit real recordings, transcripts, clipboard contents, summaries, database files, credentials or signing certificates. Reports should contain aggregate measurements and synthetic examples. A model download is the only intended network operation in the app.
- **UI and hardware:** say which checks were manual and which were automated. CPU tests cannot establish microphone reliability, accessibility permissions, actual paste success, or meeting diarization quality.

## Evidence

See [diagnostics](docs/diagnostics.md) and [validation](docs/validation.md). Write down the machine, build, model, sample count, conditions, failures and limits of every quality claim. A replay of recorded audio does not measure the shortcut-to-insertion experience. A safety check passing does not prove unchanged meaning.

Before proposing a public binary, complete the outstanding distribution and compatibility checks in [the plan](docs/plan.md). The local build is not notarized.
