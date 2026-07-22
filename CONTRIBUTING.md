# Contributing to NotchFlow

Thanks for taking a look. The codebase is small, focused, and meant to stay that
way — contributions that keep it that way are very welcome.

## Requirements

- **macOS 14+**
- **Swift 6 toolchain** (Xcode 16, or a Swift 6 toolchain from swift.org).
  ⚠️ The Command Line Tools that ship with macOS 14 include Swift 5.10, which
  **cannot** read this package's `swift-tools-version: 6.0`. If `swift build`
  fails to parse the manifest, install Xcode 16 and
  `sudo xcode-select -s /Applications/Xcode_16.4.app` (this is exactly what CI
  does — see `.github/workflows/ci.yml`).

## Build & test

```bash
swift build                          # compile
swift test                           # run all tests (Core + NotchKit)
./Packaging/build-app.sh --install   # build the .app and install to ~/Applications
swiftlint lint                       # style check (see .swiftlint.yml)
```

Please run `swift test` and `swiftlint lint` before opening a PR. SwiftLint's
size warnings are advisory for now — you don't need to drive them to zero, but
don't add new violations.

## Where things live

- `Sources/NotchFlowCore` — the model, fully unit-tested: agent events, the
  session reducer, pricing, the hook protocol and normalizer.
- `Sources/NotchKit` — the notch UI, the observer (`AppModel`), quota/usage
  monitors, plugins, the Piper voice.
- `Sources/NotchApp` — the thin `@main` that puts the notch on screen.
- `Sources/NotchFlowHook` / `NotchFlowInstaller` — the agent hook + installer.
- `Tests/` — `NotchFlowCoreTests` and `NotchKitTests`.

## Testing philosophy

Prefer pulling pure logic out of SwiftUI views into small, testable functions
(as `QuotaVisibility.relevant`, `AppModel.shouldAutoApprove`, and
`Voice.cacheKey` already are) and testing *that*, rather than trying to test a
`View`. Assert on data — labels, enum cases, numbers — never on a SwiftUI
`Color`, which has no reliable value equality.

## License

NotchFlow is MIT licensed. By contributing you agree your contributions are
licensed under the same terms (inbound = outbound). There is no CLA.
