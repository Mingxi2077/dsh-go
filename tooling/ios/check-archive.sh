#!/usr/bin/env bash
# An archive is how a TestFlight build gets made, and it isn't `flutter build ios`: another
# action, other folders, the Release settings Xcode adds for installing. It can't be run here
# (no signing, and Release doesn't run on the simulator), so this builds one without signing and
# looks inside for what a phone would need to get to its first frame.
# Run from the repository root, with the engine prepared. Everything goes up as annotations.
set -uo pipefail

note() { printf '::notice title=%s::%s\n' "$1" "$(printf '%s' "$2" | tr '\n' ' ' | cut -c1-900)"; }
fail() { printf '::error title=archive::%s\n' "$(printf '%s' "$1" | tr '\n' ' ' | cut -c1-900)"; failed=1; }
failed=0

archive="$RUNNER_TEMP/Runner.xcarchive"
log="$(mktemp)"
(cd app && flutter build ios --release --no-codesign --config-only) >"$log" 2>&1 || {
  tail -20 "$log"
  fail "flutter couldn't write the configuration: $(tail -3 "$log")"
  exit 1
}
xcodebuild archive -workspace app/ios/Runner.xcworkspace -scheme Runner -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$archive" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO >"$log" 2>&1
status=$?
tail -5 "$log"
if [ "$status" -ne 0 ]; then
  grep -E 'error:|\(Xcode\):|\*\* ARCHIVE' "$log" | awk '!seen[$0]++' | head -8 | cut -c1-600 \
    | sed -e 's/%/%25/g' -e 's/^/::error title=archive::/'
  exit 1
fi

app="$archive/Products/Applications/Runner.app"
[ -d "$app" ] || { fail "no Runner.app in the archive"; exit 1; }
frameworks="$app/Frameworks"
for name in DshFlock DshRequireBuiltin; do
  [ -f "$frameworks/$name.framework/$name" ] || fail "native addon $name.framework/$name is missing"
done
note 'archive frameworks' "$(ls "$frameworks" | tr '\n' ' ')"
note 'archive size' "$(du -sh "$app" | cut -f1), top level: $(ls "$app" | grep -vE '\.(png|car|nib|storyboardc|lproj)$' | head -30 | tr '\n' ' ')"

# Dart's compiled code, and the snapshot symbols the engine looks for in it.
binary="$frameworks/App.framework/App"
if [ -f "$binary" ]; then
  note 'archive App' "$(du -h "$binary" | cut -f1) $(lipo -archs "$binary"), exports: $(nm -gU "$binary" | awk '{print $NF}' | head -8 | tr '\n' ' ')"
  nm -gU "$binary" | grep -qE "kDartSnapshotText|kDartIsolateSnapshotInstructions" || fail "App.framework/App exports no Dart snapshot"
else
  fail "App.framework/App is missing"
fi

assets="$frameworks/App.framework/flutter_assets"
[ -d "$assets" ] || fail "flutter_assets is missing"
[ -f "$assets/kernel_blob.bin" ] && fail "flutter_assets has kernel_blob.bin: a Debug build's Dart in a Release app"
note 'archive assets' "$(ls "$assets" | head -14 | tr '\n' ' ')"

# Native assets (objective_c is what shared_preferences reads through): each one Dart was compiled
# to look for has to be in the app.
manifest="$assets/NativeAssetsManifest.json"
if [ -f "$manifest" ]; then
  note 'archive native assets' "$(tr -d ' \n' <"$manifest")"
  for name in $(grep -oE '[A-Za-z0-9_.-]+\.framework/[A-Za-z0-9_.-]+' "$manifest" | sort -u); do
    [ -f "$frameworks/$name" ] || fail "native asset $name is in the manifest and not in the app"
  done
else
  note 'archive native assets' 'no NativeAssetsManifest.json'
fi

# What dyld has to find before main.
for binary in "$app/Runner" "$frameworks"/*.framework/*; do
  [ -f "$binary" ] && [ -x "$binary" ] || continue
  otool -L "$binary" 2>/dev/null | awk 'NR>1 {print $1}' | grep '^@rpath/' | while read -r lib; do
    [ -e "$frameworks/${lib#@rpath/}" ] || [ -e "/usr/lib/swift/$(basename "$lib")" ] || case "$lib" in
      @rpath/libswift*) ;;
      *) echo "$(basename "$binary") needs $lib" ;;
    esac
  done
done | sort -u >"$log"
if [ -s "$log" ]; then fail "missing at launch: $(cat "$log")"; else note 'archive links' 'everything linked is in the app'; fi

# Native addon filenames that IPA re-signers do not recognize as frameworks.
loose="$(find "$app" \( -name '*.so' -o -name '*.node' \) -not -path '*/Frameworks/*.framework/*' | sed "s|$app/||" | head -10 | tr '\n' ' ')"
[ -n "$loose" ] && fail "native binaries outside frameworks can be missed by IPA signing: $loose"

note 'archive' "$( [ "$failed" -eq 0 ] && echo 'looks whole' || echo 'see the errors')"
exit "$failed"
