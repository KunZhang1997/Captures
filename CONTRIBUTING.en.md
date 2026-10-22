# Contributing to Captures

[简体中文](CONTRIBUTING.md) · **English**

Issues, suggestions, documentation fixes, and pull requests are welcome. See the [README](README.en.md#build-from-source) for the development environment and first build.

## Reporting a problem

Include your macOS version, Captures version or commit, reproduction steps, and the expected and actual results. Use fictional content in images and remove personal information.

## Making changes

1. Fork the repository and create a feature branch.
2. Keep each change focused on a specific problem and preserve existing local work.
3. Run checks appropriate to the change. State the results and any gaps in your pull request.

The native app uses Swift, SwiftUI, AppKit, ScreenCaptureKit, and Apple Vision. `project.yml` is the source of Xcode configuration. Run `xcodegen generate` after changing it; do not commit the generated `.xcodeproj`.

## Signing and tests

All builds must use a valid Apple Developer signing certificate. After configuring your own team and certificate, run tests in Xcode or override the command-line settings explicitly:

```bash
xcodebuild test \
  -project Captures.xcodeproj \
  -scheme Captures \
  -configuration Debug \
  -destination 'platform=macOS' \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="Apple Development: Your Name (YOUR_CERTIFICATE_ID)"
```

Push and pull request CI checks project generation, property lists, and script syntax. Maintainers can manually enable signed builds and tests in Actions using the `CERTIFICATE_P12` and `CERTIFICATE_PASSWORD` repository secrets. Source checks can run without signing configuration; passing them does not establish a successful app build or interaction verification.

## Prototypes and assets

`design/all-in-one-prototype.html` is the single interaction prototype. Read the [prototype guide](docs/prototype-guide.md) and [AGENTS.md](AGENTS.md) before changing it. Use fictional content in screenshot and recording examples. Regenerate the prototype reference image with:

```bash
swift design/generate-demo-reference.swift
```

Do not commit local design review evidence, original screenshots, signing material, or environment configuration. Publishing an installer requires separate Apple signing, notarization, and artifact verification. A configuration example is retained in `docs/release-workflow.example.yml`; automated binary releases are not enabled. Public installers are built, notarized, and verified locally by the maintainer, then uploaded manually.

## License

Contributed project code follows the [MIT](LICENSE) license. Preserve [NOTICE](NOTICE) and existing third-party licenses, and identify the source of any external code or assets you introduce.
