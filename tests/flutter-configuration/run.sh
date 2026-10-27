#!/usr/bin/env bash
# Checks how flutter/build.sh picks the build configuration and reads its
# settings: the block from `configuration=` to `families=` is extracted
# verbatim from build.sh and run on its own against the stock template in
# tests/flutter-configuration/stock (the rest of the script needs Flutter and
# the darwin SDK). tools/xcode_settings.py runs for real.
#
# Rows (expected results written before the code):
#   1  stock:      no overrides -> Release, ly.example.stockApp, 15.0, 1,2
#   2  overrides:  BUNDLE_ID and MIN_IOS set -> used as given
#   3  no Release: the Runner target has no Release configuration -> exit 1,
#                  message lists the configurations
#   4  wired:      gen-info-plist.py gets "$configuration"
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  pass no configuration to gen-info-plist.py -> row 4
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
awk '/^configuration=/,/^families=/' "$BUILD" >"$block"
[ -s "$block" ] || { echo "FAIL no configuration block in $BUILD"; exit 1; }

# settings <app dir> [VAR=VALUE ...]: prints configuration, bundle id, minimum iOS and families.
settings() {
  local app=$1; shift
  env -u BUNDLE_ID -u MIN_IOS "$@" bash -c '
    set -euo pipefail
    here=$1 app=$2
    source "$3"
    printf "%s\n" "$configuration" "$BUNDLE_ID" "$MIN_IOS" "$families"' _ "$(dirname "$BUILD")" "$app" "$block"
}

mkdir -p "$tmp/stock"
cp -R "$here/stock" "$tmp/stock/ios"
got=$(settings "$tmp/stock")
[ "$got" = "Release
ly.example.stockApp
15.0
1,2" ] && ok "row 1 stock" || bad "row 1 stock: $got"

got=$(settings "$tmp/stock" BUNDLE_ID=com.example.other MIN_IOS=17.0)
[ "$got" = "Release
com.example.other
17.0
1,2" ] && ok "row 2 overrides" || bad "row 2 overrides: $got"

mkdir -p "$tmp/norelease"
cp -R "$here/stock" "$tmp/norelease/ios"
sed -i.bak 's/name = Release;/name = Store;/' "$tmp/norelease/ios/Runner.xcodeproj/project.pbxproj"
if got=$(settings "$tmp/norelease" 2>&1); then bad "row 3 no Release accepted: $got"
elif [[ "$got" == *"Debug, Store, Profile"* ]]; then ok "row 3 no Release stops"
else bad "row 3 message: $got"; fi

if awk '/gen-info-plist.py/,/families/' "$BUILD" | grep -qF '"$families" "$configuration"'; then
  ok "row 4 gen-info-plist gets the configuration"
else bad "row 4 gen-info-plist call does not pass the configuration"; fi

exit "$fail"
