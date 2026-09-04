#!/bin/zsh
set -euo pipefail

# Xcode Cloud clones the bare repo; Turnip.xcodeproj / Turnip.xcworkspace / Pods/
# are gitignored generated artifacts (see CONTRIBUTING.md), so they must be
# recreated here before Xcode Cloud looks for the workspace.

export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8

# Skip brew's formula-index sync (the slow part of `brew install` on CI);
# only install what isn't already on the Xcode Cloud image.
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_INSTALL_CLEANUP=1

cd "$CI_PRIMARY_REPOSITORY_PATH"

step() {
  local label="$1"; shift
  local start=$SECONDS
  "$@"
  echo "[ci_post_clone] $label took $((SECONDS - start))s"
}

# Pinned to the exact versions GitHub Actions CI installs (see
# .github/workflows/ci.yml) so the two pipelines can't silently drift —
# Homebrew only bottles the latest formula, so `brew install xcodegen`/
# `cocoapods` here would float independently of GitHub Actions' pins.
# Unconditional, matching ci.yml: Xcode Cloud provisions a fresh VM per
# build, so there's nothing to skip.
install_xcodegen() {
  curl -sL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
  unzip -q xcodegen.zip -d xcodegen-pkg
  sudo ./xcodegen-pkg/xcodegen/install.sh
  rm -rf xcodegen.zip xcodegen-pkg
}

step "install xcodegen 2.46.0" install_xcodegen
step "xcodegen generate" xcodegen generate
step "bundle install (cocoapods 1.17.0)" bundle install
step "pod install" bundle exec pod install
