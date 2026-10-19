#!/usr/bin/env bash
# Build a Flutter app for a physical iOS device on Linux: no Mac, no Xcode.
#
#   flutter/build.sh [--install] <flutter app dir> [KEY=VALUE dart-define ...]
#
# Output: <app dir>/build/ios-linux/Runner.ipa (unsigned; `xtool install`
# signs it). Release mode, arm64. Run flutter/setup.sh once first.
#
# Env overrides: FLUTTER, BUNDLE_ID, BUILD_NAME, BUILD_NUMBER, MIN_IOS
# (defaults come from the app's Xcode project and pubspec.yaml).
set -euo pipefail

install=
if [ "${1:-}" = "--install" ]; then install=1; shift; fi
app=$(readlink -f "${1:?usage: build.sh [--install] <flutter app dir> [KEY=VALUE ...]}"); shift
here=$(dirname "$(readlink -f "$0")")
FLUTTER=${FLUTTER:-$(command -v flutter)} || { echo "flutter is not on PATH; set FLUTTER" >&2; exit 1; }
flutter_root=$(dirname "$(dirname "$(readlink -f "$FLUTTER")")")

sdkb=${DARWIN_SDK_BUNDLE:-${XDG_CONFIG_HOME:-$HOME/.config}/swiftpm/swift-sdks/darwin.artifactbundle}
[ -d "$sdkb" ] || sdkb=$HOME/.swiftpm/swift-sdks/darwin.artifactbundle
[ -d "$sdkb" ] || { echo "no darwin SDK bundle; run install-toolchain.sh first" >&2; exit 1; }
ios_sdk=$sdkb/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
tools=$sdkb/Developer/Platforms/iPhoneOS.platform/Developer/usr/bin
# ibtool runs from this checkout, not from the copy install-toolchain.sh put in
# the SDK bundle, so a `git pull` is enough to pick up a newer one.
ibtool=$here/../tools/ibtool
tc=$(dirname "$(readlink -f "$(command -v swift)")")
# The shims forward to LLVM's binutils, which neither the Swift toolchain nor
# the darwin SDK bundle ships.
missing=
for t in llvm-strip llvm-lipo llvm-otool llvm-install-name-tool llvm-ar; do
  command -v "$t" >/dev/null || missing+=" $t"
done
[ -z "$missing" ] || { echo "missing:$missing (package providing llvm-strip, llvm-lipo, llvm-otool, llvm-install-name-tool, llvm-ar; docs/DISTROS.md lists it per distribution)" >&2; exit 1; }
for t in python3 zip file rsync; do
  command -v "$t" >/dev/null || { echo "missing: $t (docs/DISTROS.md lists the package per distribution)" >&2; exit 1; }
done
file -b "$flutter_root/bin/cache/artifacts/engine/ios-release/gen_snapshot_arm64" 2>/dev/null | grep -q ELF ||
  { echo "Flutter's iOS gen_snapshot is not the Linux build; run $here/setup.sh" >&2; exit 1; }

pbx=$app/ios/Runner.xcodeproj/project.pbxproj
setting() { # first value of a build setting that is not the test target's
  grep -E "^\s*$1 = " "$pbx" | grep -v RunnerTests | head -n1 | sed -E 's/.* = "?([^";]*)"?;.*/\1/'
}
BUNDLE_ID=${BUNDLE_ID:-$(setting PRODUCT_BUNDLE_IDENTIFIER)}
MIN_IOS=${MIN_IOS:-$(setting IPHONEOS_DEPLOYMENT_TARGET)}
families=$(setting TARGETED_DEVICE_FAMILY); families=${families:-1,2}
version=$(sed -n 's/^version: *//p' "$app/pubspec.yaml" | head -n1)
BUILD_NAME=${BUILD_NAME:-${version%%+*}}
BUILD_NUMBER=${BUILD_NUMBER:-$([ "${version#*+}" != "$version" ] && echo "${version#*+}" || echo 1)}
sdk_version=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["Version"])' "$ios_sdk/SDKSettings.json")

out=$app/build/ios-linux
asm=$out/assemble; shell_pkg=$out/shell; stage=$out/stage; bundle=$out/Payload/Runner.app
# Everything but the Swift build directory is rebuilt from scratch.
for d in "$asm" "$stage" "$out/Payload"; do
  [ ! -d "$d" ] || find "$d" -mindepth 1 -delete
done
mkdir -p "$asm" "$shell_pkg" "$stage/sbc" "$bundle/Frameworks" "$bundle/Base.lproj"

export PATH="$here/shims:$sdkb/toolset/bin:$tc:$PATH"
export XCRUN_SHIM_LOG=$out/shims.log
export XCODE_EXTRA_PLATFORM_FOLDERS=$sdkb/Developer/Platforms
unset SDKROOT
ulimit -n 65536 2>/dev/null || true

echo "== 1. Flutter: Dart AOT, assets, engine framework, native assets"
defines=""
for d in "$@"; do defines+="${defines:+,}$(printf '%s' "$d" | base64 -w0)"; done
(cd "$app" && "$FLUTTER" pub get >/dev/null && "$FLUTTER" assemble --no-version-check --output="$asm" \
  -dTargetPlatform=ios -dTargetFile=lib/main.dart -dBuildMode=release -dIosArchs=arm64 \
  -dSdkRoot="$ios_sdk" -dTrackWidgetCreation=false -dTreeShakeIcons=true -dCodesignIdentity=- \
  ${defines:+--DartDefines="$defines"} release_ios_bundle_flutter_assets) >"$out/assemble.log" 2>&1 ||
  { tail -n 40 "$out/assemble.log" >&2; exit 1; }

echo "== 2. Native: Runner and plugins as one Swift package"
python3 "$here/tools/gen-shell-package.py" "$app" "$shell_pkg" "$MIN_IOS"
# Native-asset frameworks (flutter_soloud, objective_c, sqlite3, ...) are
# dlopen'ed by the Dart runtime only on demand, but plugins whose SwiftPM
# package compiles with -undefined dynamic_lookup against the asset's exports
# need them in the initial link closure: give Runner an LC_LOAD_DYLIB for each
# (what Xcode's native-assets phase does on a Mac).
natargs=()
if [ -d "$asm/native_assets" ]; then
  natargs+=(-Xlinker -F -Xlinker "$asm/native_assets")
  for f in "$asm"/native_assets/*.framework; do
    [ -d "$f" ] || continue
    natargs+=(-Xlinker -framework -Xlinker "$(basename "${f%.framework}")")
  done
fi
(cd "$shell_pkg" && swift build --configuration release --build-system swiftbuild \
  --triple "arm64-apple-ios$MIN_IOS" --toolset "$sdkb/toolset-swb.json" --product Runner \
  -Xswiftc "-F$asm" -Xcc "-F$asm" -Xlinker "-F$asm" -Xlinker -framework -Xlinker Flutter \
  "${natargs[@]+"${natargs[@]}"}" \
  -Xlinker -rpath -Xlinker @executable_path/Frameworks \
  -Xlinker -platform_version -Xlinker ios -Xlinker "$MIN_IOS" -Xlinker "$sdk_version") \
  >"$out/shell-build.log" 2>&1 || { grep -E 'error' "$out/shell-build.log" | head -n 40 >&2; exit 1; }
products=$shell_pkg/.build/out/Products/Release-iphoneos

echo "== 3. Wrapper: icons, storyboards, Info.plist"
"$tools/actool" "$app/ios/Runner/Assets.xcassets" --compile "$bundle" --platform iphoneos \
  --app-icon AppIcon --minimum-deployment-target "$MIN_IOS" --target-device iphone --target-device ipad \
  --output-partial-info-plist "$stage/icon.plist" --output-format human-readable-text >"$out/actool.log" 2>&1 ||
  { cat "$out/actool.log" >&2; exit 1; }
for sb in "$app"/ios/Runner/Base.lproj/*.storyboard; do
  "$ibtool" --module Runner --minimum-deployment-target "$MIN_IOS" --target-device iphone \
    --target-device ipad --output-partial-info-plist "$stage/$(basename "$sb").plist" "$sb" \
    --compilation-directory "$stage/sbc" 2>"$out/ibtool.log" || { cat "$out/ibtool.log" >&2; exit 1; }
done
"$ibtool" --module Runner --target-device iphone --target-device ipad \
  --link "$bundle/Base.lproj" "$stage"/sbc/*.storyboardc 2>"$out/ibtool.log" || { cat "$out/ibtool.log" >&2; exit 1; }
python3 "$here/tools/gen-info-plist.py" "$app/ios/Runner/Info.plist" "$stage/icon.plist" "$bundle/Info.plist" \
  "$BUNDLE_ID" "$BUILD_NAME" "$BUILD_NUMBER" "$MIN_IOS" "$ios_sdk" "$families"

echo "== 4. Assemble"
cp "$products/Runner" "$bundle/Runner"
strip -x "$bundle/Runner"
for b in "$products"/*.bundle; do [ ! -d "$b" ] || cp -R "$b" "$bundle/"; done
# Dynamic SwiftPM products: a plugin may vend a .dylib product (flutter_soloud
# is type: .dynamic) or a dynamic framework (ScreenPreventerKit); Runner's load
# commands reference them under @rpath, which resolves to Frameworks. SwiftBuild
# also stages unreferenced binaryTargets into products (Sentry.framework here,
# which rcodesign cannot re-sign), so embed only what is actually loaded. The
# scan repeats until no new product is embedded, so a chain of any depth
# (Runner -> F0 -> F1 -> ...) closes; App/Flutter/native-asset frameworks are
# copied first so their binaries are scanned too.
find "$products" -maxdepth 1 -name '*.dylib' -exec cp {} "$bundle/Frameworks/" \;
cp -R "$asm/App.framework" "$asm/Flutter.framework" "$bundle/Frameworks/"
for f in "$asm"/native_assets/*.framework; do [ ! -d "$f" ] || cp -R "$f" "$bundle/Frameworks/"; done
for _ in $(seq 1 64); do  # ponytail: fixed 64-iteration cap; products are finite so the loop exits on its own first
  before=$(find "$bundle/Frameworks" -maxdepth 1 | wc -l)
  {
    llvm-otool -l "$bundle/Runner" "$bundle"/Frameworks/*.dylib 2>/dev/null || true
    for fw in "$bundle"/Frameworks/*.framework; do
      bin=$(basename "${fw%.framework}")
      [ -f "$fw/$bin" ] && llvm-otool -l "$fw/$bin" 2>/dev/null || true
    done
  } | sed -n 's/.*name @rpath\/\([^ ]*\).*/\1/p' | sort -u |
    while read -r name; do
      case $name in
        *.framework/*) rel=${name%%.framework/*}.framework ;;
        *) rel=$name ;;
      esac
      if [ -e "$products/$rel" ] && [ ! -e "$bundle/Frameworks/$rel" ]; then
        echo "embedding $rel"
        cp -R "$products/$rel" "$bundle/Frameworks/"
      fi
    done
  after=$(find "$bundle/Frameworks" -maxdepth 1 | wc -l)
  [ "$after" -gt "$before" ] || break
done
cp "$app/ios/Flutter/AppFrameworkInfo.plist" "$bundle/"
printf 'APPL????' >"$bundle/PkgInfo"
rm -f "$out/Runner.ipa"
(cd "$out" && zip -qry Runner.ipa Payload)
echo "Built $out/Runner.ipa ($BUNDLE_ID $BUILD_NAME+$BUILD_NUMBER, iOS $MIN_IOS+)"

if [ -n "$install" ]; then
  xt=${XTOOL:-$HOME/.local/bin/xtool}
  [ -x "$xt" ] || xt=$(command -v xtool || echo "$xt") # on PATH with a packaged toolchain
  "$xt" install --usb "$out/Runner.ipa"
fi
