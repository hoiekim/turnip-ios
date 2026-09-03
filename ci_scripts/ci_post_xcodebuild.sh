#!/bin/zsh
set -euo pipefail

# Persist CocoaPods' spec index and downloaded pod source archives into
# $CI_DERIVED_DATA_PATH so ci_post_clone.sh can restore them on the next
# build (see the comment there). Xcode Cloud saves this directory after
# this script runs.

cache="$CI_DERIVED_DATA_PATH/pod-cache"
mkdir -p "$cache/dot-cocoapods" "$cache/caches-cocoapods"

rsync -a --delete ~/.cocoapods/ "$cache/dot-cocoapods/"
rsync -a --delete ~/Library/Caches/CocoaPods/ "$cache/caches-cocoapods/"
