#!/usr/bin/env bash
# Checks how flutter/build.sh picks the build configuration, reads its
# settings and picks the Dart entry point: the block from `configuration=` to
# the entry point check is extracted verbatim from build.sh and run on its own
# against the stock template and the flavored one in tests/flutter-configuration
# (the rest of the script needs Flutter and the darwin SDK).
# tools/xcode_settings.py runs for real.
#
# Rows (expected results written before the code):
#   1  stock:      no overrides -> Release, ly.example.stockApp, 15.0, 1,2,
#                  lib/main.dart, no flavor defines (the assemble call as before)
#   2  overrides:  BUNDLE_ID and MIN_IOS set -> used as given
#   3  no Release: the Runner target has no Release configuration -> exit 1,
#                  message lists the configurations
#   4  wired:      gen-info-plist.py gets "$configuration"
#   5  FLAVOR=dev: Release-dev, its bundle id, lib/main_dev.dart (its
#                  FLUTTER_TARGET), -dFlavor=dev -dConfiguration=Release-dev
#   6  FLAVOR=prod: scheme Prod -> -dFlavor=Prod, and a warning naming Prod
#   7  TARGET:     TARGET=lib/other.dart wins over FLUTTER_TARGET
#   8  no entry:   FLUTTER_TARGET names a missing file -> exit 1, names it
#   9  FLAVOR=qa:  two configurations match -> exit 1
#   10 plist:      the configuration's INFOPLIST_FILE is not Runner/Info.plist
#                  -> exit 1, names it
#   11 wired:      flutter assemble gets -dTargetFile="$target" and the flavor defines
#   12 recorded:   build.sh writes the configuration to build/ios-linux/configuration
#                  for flutter/ship.sh
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  pass no configuration to gen-info-plist.py -> row 4
#   M2  ignore FLUTTER_TARGET -> row 5
#   M3  drop the entry point check -> row 8
#   M4  drop flavor_opts from the assemble call -> row 11
# usage: run.sh [path-to-flutter/build.sh]   default: ../../flutter/build.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
BUILD=${1:-$here/../../flutter/build.sh}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

block=$tmp/block.sh
awk '/^configuration=/,/no Dart entry point/' "$BUILD" >"$block"
[ -s "$block" ] || { echo "FAIL no configuration block in $BUILD"; exit 1; }

# settings <app dir> [VAR=VALUE ...]: prints configuration, bundle id, minimum
# iOS, families, entry point and the flavor defines (space-separated; with none,
# $(settings ...) ends at the entry point).
settings() {
  local app=$1; shift
  env -u BUNDLE_ID -u MIN_IOS -u FLAVOR -u TARGET "$@" bash -c '
    set -euo pipefail
    here=$1 app=$2
    source "$3"
    printf "%s\n" "$configuration" "$BUNDLE_ID" "$MIN_IOS" "$families" "$target" \
      "${flavor_opts[*]+"${flavor_opts[*]}"}"' _ "$(dirname "$BUILD")" "$app" "$block"
}

# mkapp <dir> <fixture>: an app dir with the fixture as ios/ and the entry points it names.
mkapp() {
  mkdir -p "$1/lib"
  cp -R "$here/$2" "$1/ios"
  touch "$1/lib/main.dart" "$1/lib/main_dev.dart" "$1/lib/main_prod.dart" "$1/lib/other.dart"
}

mkapp "$tmp/stock" stock
got=$(settings "$tmp/stock")
[ "$got" = "Release
ly.example.stockApp
15.0
1,2
lib/main.dart" ] && ok "row 1 stock" || bad "row 1 stock: $got"

got=$(settings "$tmp/stock" BUNDLE_ID=com.example.other MIN_IOS=17.0)
[ "$got" = "Release
com.example.other
17.0
1,2
lib/main.dart" ] && ok "row 2 overrides" || bad "row 2 overrides: $got"

mkapp "$tmp/norelease" stock
sed -i.bak 's/name = Release;/name = Store;/' "$tmp/norelease/ios/Runner.xcodeproj/project.pbxproj"
if got=$(settings "$tmp/norelease" 2>&1); then bad "row 3 no Release accepted: $got"
elif [[ "$got" == *"Debug, Store, Profile"* ]]; then ok "row 3 no Release stops"
else bad "row 3 message: $got"; fi

if awk '/gen-info-plist.py/,/families/' "$BUILD" | grep -qF '"$families" "$configuration"'; then
  ok "row 4 gen-info-plist gets the configuration"
else bad "row 4 gen-info-plist call does not pass the configuration"; fi

mkapp "$tmp/flavors" flavors
got=$(settings "$tmp/flavors" FLAVOR=dev 2>"$tmp/r5.err")
[ "$got" = "Release-dev
ly.example.stockApp.dev
15.0
1,2
lib/main_dev.dart
-dFlavor=dev -dConfiguration=Release-dev" ] && [ ! -s "$tmp/r5.err" ] && ok "row 5 FLAVOR=dev" ||
  bad "row 5 FLAVOR=dev: $got $(cat "$tmp/r5.err")"

got=$(settings "$tmp/flavors" FLAVOR=prod 2>"$tmp/r6.err" | tail -n1)
[ "$got" = "-dFlavor=Prod -dConfiguration=Release-Prod" ] && grep -q "scheme Prod" "$tmp/r6.err" &&
  ok "row 6 scheme spelling" || bad "row 6 scheme spelling: $got $(cat "$tmp/r6.err")"

got=$(settings "$tmp/flavors" FLAVOR=dev TARGET=lib/other.dart | sed -n 5p)
[ "$got" = lib/other.dart ] && ok "row 7 TARGET wins" || bad "row 7 TARGET: $got"

rm "$tmp/flavors/lib/main_dev.dart"
if got=$(settings "$tmp/flavors" FLAVOR=dev 2>&1); then bad "row 8 missing entry point accepted: $got"
elif [[ "$got" == *"no Dart entry point lib/main_dev.dart"* ]]; then ok "row 8 missing entry point stops"
else bad "row 8 message: $got"; fi

if got=$(settings "$tmp/flavors" FLAVOR=qa 2>&1); then bad "row 9 two configurations accepted: $got"
else ok "row 9 FLAVOR=qa stops"; fi

mkapp "$tmp/plist" stock
sed -i.bak 's|INFOPLIST_FILE = Runner/Info.plist;|INFOPLIST_FILE = "Runner/Info-$(CONFIGURATION).plist";|' \
  "$tmp/plist/ios/Runner.xcodeproj/project.pbxproj"
if got=$(settings "$tmp/plist" 2>&1); then bad "row 10 other Info.plist accepted: $got"
elif [[ "$got" == *"Runner/Info-Release.plist"* ]]; then ok "row 10 other Info.plist stops"
else bad "row 10 message: $got"; fi

assemble=$(awk '/"\$FLUTTER" assemble/,/release_ios_bundle_flutter_assets\)/' "$BUILD")
if grep -qF -- '-dTargetFile="$target"' <<<"$assemble" &&
   grep -qF '"${flavor_opts[@]+"${flavor_opts[@]}"}"' <<<"$assemble"; then ok "row 11 assemble gets target and flavor"
else bad "row 11 assemble call does not pass the target and flavor defines"; fi

if grep -qxF "printf '%s\n' \"\$configuration\" >\"\$out/configuration\"" "$BUILD"; then ok "row 12 configuration recorded"
else bad "row 12 build.sh does not record the configuration"; fi

exit "$fail"
