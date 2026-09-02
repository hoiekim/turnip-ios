# Contributing to Turnip

Thanks for your interest in contributing. This repo is early — see the
[README](README.md) for current status and [`docs/DESIGN.md`](docs/DESIGN.md)
for the full architecture plan, including the "Contribution ramp" section
that names areas most open to new contributors.

## Development environment

- **Xcode 15 or later**
- **iOS 16** minimum deployment target
- An A11 Bionic device or later (iPhone 8/X+) if you want to test Neural
  Engine acceleration; the simulator works for everything else

Clone the repo and open it in Xcode. There's no dependency manager step yet
beyond what Xcode resolves automatically — this will be documented here as
soon as the app scaffolding lands.

## Branching workflow

1. Fork the repo
2. Branch from `main` (`git checkout -b your-feature-name`)
3. Make your changes, with focused commits
4. Open a PR against `hoiekim/turnip-ios` `main`

## Pull request conventions

- Fill out the PR template — summary, screenshots (for UI changes), test
  plan, and linked issues
- Keep PRs scoped to one change. Large, unrelated changes bundled together
  are harder to review and slower to merge
- Reference the issue a PR closes with `Closes #N` in the description
- Squash-friendly commit history is appreciated but not required

## Review process

- At least one reviewer approval is required before merge
- CI (once added) must pass before merge; until then, describe how you
  tested your change in the PR's test plan
- Be responsive to review feedback — if a thread goes quiet, a ping is fine

## Testing guidance

The app codebase hasn't landed yet, so there's no test suite to run
against. Once it does:

- New logic (clip detection, crop-rect math, pose-signal processing) should
  ship with unit tests (XCTest)
- UI changes should include a description of manual testing performed
  (device/simulator, iOS version) in the PR's test plan, since UI tests are
  not expected to cover everything

This section will be expanded with concrete commands once the project
scaffolding exists.

## Areas of contribution

From the design doc's "Contribution ramp":

- **iOS**: Swift/SwiftUI, AVFoundation, Vision framework, TFLite iOS
- **Backend** (`turnip-farm`, separate repo): TypeScript, Bun, Postgres, Docker
- **ML** (`turnip-ml`, separate repo): Python, TensorFlow, coremltools, model evaluation

Good first issues are tagged as they're identified.

## Contributor License Agreement (CLA)

**No CLA is required.** Turnip is licensed under [Apache 2.0](LICENSE), and
Section 5 of that license already grants the project the necessary rights
to your contributions. This matches the design doc's recommendation
(`docs/DESIGN.md`, "Contribution guide surface"). By submitting a PR, you
agree your contribution is made under the terms of the Apache 2.0 license.

## Code of Conduct

This project follows the [Code of Conduct](CODE_OF_CONDUCT.md). By
participating, you're expected to uphold it.

## Reporting bugs and requesting features

Use the issue templates under `.github/ISSUE_TEMPLATE/` — separate ones
exist for bug reports and feature requests.

## Security issues

Do not open a public issue for security vulnerabilities. See
[SECURITY.md](SECURITY.md) for the responsible disclosure process.
