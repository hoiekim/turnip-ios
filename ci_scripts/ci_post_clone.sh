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

# CocoaPods' spec index (~/.cocoapods) and downloaded pod source archives
# (~/Library/Caches/CocoaPods) live outside the repo, so a fresh Xcode Cloud
# VM has neither and `pod install` re-downloads TensorFlowLiteSwift's
# xcframework every build. Xcode Cloud restores $CI_DERIVED_DATA_PATH before
# this script runs and saves it again after ci_post_xcodebuild.sh — round
# both caches through there to persist them across builds on this workflow.
restore_pod_caches() {
  local cache="$CI_DERIVED_DATA_PATH/pod-cache"
  [ -d "$cache/dot-cocoapods" ] && rsync -a "$cache/dot-cocoapods/" ~/.cocoapods/
  [ -d "$cache/caches-cocoapods" ] && rsync -a "$cache/caches-cocoapods/" ~/Library/Caches/CocoaPods/
  return 0
}

# Pinned to the exact versions GitHub Actions CI installs (see
# .github/workflows/ci.yml) so the two pipelines can't silently drift —
# Homebrew only bottles the latest formula, so `brew install xcodegen`/
# `cocoapods` here would float independently of GitHub Actions' pins.
install_xcodegen() {
  command -v xcodegen >/dev/null && return 0
  curl -sL -o xcodegen.zip https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip
  unzip -q xcodegen.zip -d xcodegen-pkg
  sudo ./xcodegen-pkg/xcodegen/install.sh
  rm -rf xcodegen.zip xcodegen-pkg
}

step "restore pod caches" restore_pod_caches
step "install xcodegen 2.46.0" install_xcodegen
step "xcodegen generate" xcodegen generate
step "bundle install (cocoapods 1.17.0)" bundle install
step "pod install" bundle exec pod install
