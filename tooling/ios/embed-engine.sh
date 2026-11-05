#!/bin/sh
# Xcode build phase: puts the engine into the app when tooling/ios/prepare-engine.sh
# has run. The engine isn't linked at launch: the app dlopens it on first start, so
# someone who only uses remote hosts doesn't pay for 90 MB of Node.
set -eu

ROOT="$(cd "$SRCROOT/../.." && pwd)"
ENGINE="$ROOT/app/ios/Engine"
if [ ! -f "$ENGINE/.ready" ]; then
  echo "note: app/ios/Engine isn't prepared; this build connects to remote hosts only."
  exit 0
fi
case "$PLATFORM_NAME" in
  iphoneos) SLICE=ios-arm64 ;;
  iphonesimulator) SLICE=ios-arm64-simulator ;;
  *) echo "error: no engine for $PLATFORM_NAME"; exit 1 ;;
esac

BUILT="$ENGINE/build/$PLATFORM_NAME"
STAMP="$BUILT/.inputs"
INPUTS="$(cat "$ROOT/runtime/ios/host/"* "$ROOT/runtime/ohos/host/publication_binding.cc" \
  "$ROOT/app/ohos/entry/src/main/cpp/host_core.cpp" "$ROOT/app/ohos/entry/src/main/cpp/host_core.h" \
  "$ROOT/tooling/ios/build-engine-native.sh" | shasum -a 256)"
if [ ! -f "$STAMP" ] || [ "$(cat "$STAMP")" != "$INPUTS" ]; then
  # Xcode's environment selects its own SDK and target, which would override these.
  env -i PATH="$PATH" HOME="$HOME" DEVELOPER_DIR="${DEVELOPER_DIR:-}" \
    /bin/bash "$ROOT/tooling/ios/build-engine-native.sh" "$PLATFORM_NAME" "$BUILT"
  printf '%s' "$INPUTS" >"$STAMP"
fi

FRAMEWORKS="$TARGET_BUILD_DIR/$FRAMEWORKS_FOLDER_PATH"
RESOURCES="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH"
mkdir -p "$FRAMEWORKS" "$RESOURCES/dsh-runtime"
rm -rf "$FRAMEWORKS/NodeMobile.framework" "$FRAMEWORKS/DshNodeHost.framework" \
  "$FRAMEWORKS/DshFlock.framework" "$FRAMEWORKS/DshRequireBuiltin.framework"
# Remove the old layout when rebuilding an existing app directory.
rm -f "$FRAMEWORKS/libdsh_flock.so" "$FRAMEWORKS/libdsh_require_builtin.so"
cp -R "$ENGINE/NodeMobile.xcframework/$SLICE/NodeMobile.framework" "$FRAMEWORKS/"
rm -rf "$FRAMEWORKS/NodeMobile.framework/Headers" "$FRAMEWORKS/NodeMobile.framework/Modules" \
  "$FRAMEWORKS/NodeMobile.framework/_CodeSignature"
cp -R "$BUILT/DshNodeHost.framework" "$FRAMEWORKS/"
cp -R "$BUILT/DshFlock.framework" "$BUILT/DshRequireBuiltin.framework" "$FRAMEWORKS/"
cp "$ENGINE/runtime.zip" "$RESOURCES/dsh-runtime/runtime.zip"
# The phone tools' backend is iOS's own, so it isn't in the archive runtime/ohos composes.
mkdir -p "$RESOURCES/dsh-runtime/phone"
for file in actions.mjs bridge.mjs plugin.mjs catalog.json; do
  cp "$ROOT/runtime/ios/phone/$file" "$RESOURCES/dsh-runtime/phone/"
done
if [ -d "$ROOT/runtime/ios/browser" ]; then
  mkdir -p "$RESOURCES/dsh-runtime/browser"
  for file in actions.mjs catalog.json agent.js; do
    cp "$ROOT/runtime/ios/browser/$file" "$RESOURCES/dsh-runtime/browser/"
  done
fi
if [ -d "$ROOT/runtime/ios/system" ]; then
  mkdir -p "$RESOURCES/dsh-runtime/system"
  for file in actions.mjs results.mjs catalog.json; do
    cp "$ROOT/runtime/ios/system/$file" "$RESOURCES/dsh-runtime/system/"
  done
fi

if [ "${CODE_SIGNING_ALLOWED:-YES}" = "NO" ] || [ -z "${EXPANDED_CODE_SIGN_IDENTITY:-}" ]; then
  exit 0
fi
for item in NodeMobile.framework DshNodeHost.framework DshFlock.framework DshRequireBuiltin.framework; do
  /usr/bin/codesign --force --sign "$EXPANDED_CODE_SIGN_IDENTITY" ${OTHER_CODE_SIGN_FLAGS:-} \
    --preserve-metadata=identifier,entitlements "$FRAMEWORKS/$item"
done
