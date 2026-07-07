#!/usr/bin/env bash
set -euo pipefail

ROOT="/Users/kabir/Projects/LocalDrop"
TMP_ROOT="/private/tmp/localdrop"
DERIVED_DATA_PATH="$TMP_ROOT/DerivedData"
SPM_PATH="$TMP_ROOT/SPM"
RESULT_BUNDLE_PATH="$TMP_ROOT/LocalDropBuild.xcresult"
PACKAGE_CACHE_SOURCE="$ROOT/Modules/LocalSendKit/.build"

mkdir -p "$TMP_ROOT" "$SPM_PATH/checkouts" "$SPM_PATH/repositories"
rm -rf "$DERIVED_DATA_PATH" "$RESULT_BUNDLE_PATH"

if [[ "${RESET_PACKAGE_CACHE:-0}" == "1" ]]; then
  rm -rf "$SPM_PATH"
  mkdir -p "$SPM_PATH/checkouts" "$SPM_PATH/repositories"
fi

if [[ ! -d "$SPM_PATH/checkouts/swift-crypto" && -d "$PACKAGE_CACHE_SOURCE/checkouts/swift-crypto" ]]; then
  cp -R "$PACKAGE_CACHE_SOURCE/checkouts/." "$SPM_PATH/checkouts/"
fi

if [[ -z "$(find "$SPM_PATH/repositories" -mindepth 1 -maxdepth 1 2>/dev/null)" && -d "$PACKAGE_CACHE_SOURCE/repositories" ]]; then
  cp -R "$PACKAGE_CACHE_SOURCE/repositories/." "$SPM_PATH/repositories/"
fi

cd "$ROOT"

HOME="/Users/kabir" TMPDIR="/private/tmp" \
xcodebuild \
  -project LocalDrop.xcodeproj \
  -scheme LocalDrop \
  build \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$SPM_PATH" \
  -resultBundlePath "$RESULT_BUNDLE_PATH"

cd "$ROOT/Modules/LocalSendKit"
HOME="/Users/kabir" TMPDIR="/private/tmp" swift test

cd "$ROOT/Modules/FeatureTransfer"
HOME="/Users/kabir" TMPDIR="/private/tmp" swift test
