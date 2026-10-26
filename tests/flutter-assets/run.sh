#!/usr/bin/env bash
# Checks the per-configuration app icon set and storyboards of flutter/build.sh:
# three blocks are extracted verbatim from build.sh and run on their own
# against tests/flutter-configuration/stock and .../flavors (the rest of the
# script needs Flutter and the darwin SDK). tools/xcode_settings.py and the
# repo's tools/ibtool run for real.
#
# Rows (expected results written before the code):
#   1  stock icon:    Release -> --app-icon AppIcon, and a warning citing
#                     FINDINGS.md item 68 (the template's set lists every size)
#   2  flavor icon:   Release-dev -> --app-icon devAppIcon, no warning (one
#                     1024x1024 universal image)
#   3  missing set:   "Release staging" names stagingAppIcon, which is not in
#                     Assets.xcassets -> exit 1, names it
#   4  no icon name:  ASSETCATALOG_COMPILER_APPICON_NAME empty -> no --app-icon,
#                     a warning
#   5  stock boards:  Base.lproj/LaunchScreen.storyboardc and Main.storyboardc,
#                     nothing else, byte for byte what the old Base.lproj glob built
#   6  flavor boards: plus devLaunchScreen.storyboardc at the bundle root (it is
#                     not localized)
#   7  launch ok:     UILaunchStoryboardName LaunchScreen, compiled in Base.lproj
#   8  launch root:   UILaunchStoryboardName devLaunchScreen, at the root
#   9  launch gone:   UILaunchStoryboardName stagingLaunchScreen -> exit 1, names it
#   10 wired:         actool gets "${icon_args[@]...}", not a fixed AppIcon
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  always --app-icon AppIcon -> row 2
#   M2  drop the missing-set check -> row 3
#   M3  compile every storyboard into Base.lproj -> row 6
#   M4  drop the launch screen check -> row 9
# usage: run.sh [path-to-flutter/build.sh]   default: ../../flutter/build.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
BUILD=${1:-$here/../../flutter/build.sh}
fixtures=$here/../flutter-configuration
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

awk '/^appicon=/,/FINDINGS.md item 68/' "$BUILD" >"$tmp/icon.sh"
awk '/^storyboards=/{f=1} /gen-info-plist.py/{f=0} f' "$BUILD" >"$tmp/boards.sh"
awk '/^launch=/,/^done <<<"\$launch"$/' "$BUILD" >"$tmp/launch.sh"
for b in icon boards launch; do
  [ -s "$tmp/$b.sh" ] || { echo "FAIL no $b block in $BUILD"; exit 1; }
done

# run <block> <app dir> <configuration> [command]: sources the block with
# build.sh's variables set, then runs the command.
run() {
  bash -c '
    set -euo pipefail
    here=$1 app=$2 configuration=$3 bundle=$2/bundle stage=$2/stage out=$2 MIN_IOS=15.0
    ibtool=$here/../tools/ibtool
    setting() { python3 "$here/tools/xcode_settings.py" "$app/ios" "$configuration" "$1"; }
    mkdir -p "$bundle" "$stage/sbc"
    source "$4"
    eval "${5:-}"' _ "$(dirname "$BUILD")" "$1" "$2" "$tmp/$3.sh" "${4:-}"
}

mkapp() { mkdir -p "$1"; cp -R "$fixtures/$2" "$1/ios"; }
mkapp "$tmp/stock" stock
mkapp "$tmp/flavors" flavors

got=$(run "$tmp/stock" Release icon 'echo "${icon_args[*]}"' 2>"$tmp/r1.err")
[ "$got" = "--app-icon AppIcon" ] && grep -q "FINDINGS.md item 68" "$tmp/r1.err" && ok "row 1 stock icon" ||
  bad "row 1 stock icon: $got $(cat "$tmp/r1.err")"

got=$(run "$tmp/flavors" Release-dev icon 'echo "${icon_args[*]}"' 2>"$tmp/r2.err")
[ "$got" = "--app-icon devAppIcon" ] && [ ! -s "$tmp/r2.err" ] && ok "row 2 flavor icon" ||
  bad "row 2 flavor icon: $got $(cat "$tmp/r2.err")"

if got=$(run "$tmp/flavors" "Release staging" icon 2>&1); then bad "row 3 missing set accepted: $got"
elif [[ "$got" == *"no app icon set stagingAppIcon"* ]]; then ok "row 3 missing set stops"
else bad "row 3 message: $got"; fi

mkapp "$tmp/noicon" stock
sed -i.bak 's/ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;/ASSETCATALOG_COMPILER_APPICON_NAME = "";/' \
  "$tmp/noicon/ios/Runner.xcodeproj/project.pbxproj"
got=$(run "$tmp/noicon" Release icon 'echo "args:${icon_args[*]+${icon_args[*]}}"' 2>"$tmp/r4.err")
[ "$got" = "args:" ] && grep -q "no app icon set" "$tmp/r4.err" && ok "row 4 no icon name" ||
  bad "row 4 no icon name: $got $(cat "$tmp/r4.err")"

# boards <app dir>: the compiled storyboards in the bundle, relative to it.
boards() { (cd "$1/bundle" && find . -name '*.storyboardc' -prune | sort); }
# The old step 3: every Base.lproj storyboard compiled into one plain directory,
# then linked into Base.lproj.
ibtool=$(dirname "$BUILD")/../tools/ibtool
mkdir -p "$tmp/old/sbc" "$tmp/old/Base.lproj"
for sb in "$tmp"/stock/ios/Runner/Base.lproj/*.storyboard; do
  "$ibtool" --module Runner --minimum-deployment-target 15.0 --target-device iphone --target-device ipad \
    --output-partial-info-plist "$tmp/old/$(basename "$sb").plist" "$sb" --compilation-directory "$tmp/old/sbc" >/dev/null
done
"$ibtool" --module Runner --target-device iphone --target-device ipad --link "$tmp/old/Base.lproj" "$tmp"/old/sbc/*.storyboardc >/dev/null
if run "$tmp/stock" Release boards >"$tmp/r5.out" 2>&1 &&
   [ "$(boards "$tmp/stock")" = "./Base.lproj/LaunchScreen.storyboardc
./Base.lproj/Main.storyboardc" ] && diff -r "$tmp/old/Base.lproj" "$tmp/stock/bundle/Base.lproj"; then
  ok "row 5 stock storyboards"
else bad "row 5 stock storyboards: $(boards "$tmp/stock")"; cat "$tmp/r5.out"; fi

if run "$tmp/flavors" Release-dev boards >"$tmp/r6.out" 2>&1 &&
   [ "$(boards "$tmp/flavors")" = "./Base.lproj/LaunchScreen.storyboardc
./Base.lproj/Main.storyboardc
./devLaunchScreen.storyboardc" ]; then ok "row 6 flavor storyboards"
else bad "row 6 flavor storyboards: $(boards "$tmp/flavors")"; cat "$tmp/r6.out"; fi

# launch <name>: runs the launch block on the flavors bundle (row 6 compiled it)
# with an Info.plist naming <name>.
launch() {
  python3 -c 'import plistlib, sys
plistlib.dump({"UILaunchStoryboardName": sys.argv[2]}, open(sys.argv[1], "wb"))' "$tmp/flavors/bundle/Info.plist" "$1"
  run "$tmp/flavors" Release-dev launch
}
launch LaunchScreen >"$tmp/r7.out" 2>&1 && ok "row 7 launch screen in Base.lproj" || bad "row 7: $(cat "$tmp/r7.out")"
launch devLaunchScreen >"$tmp/r8.out" 2>&1 && ok "row 8 launch screen at the root" || bad "row 8: $(cat "$tmp/r8.out")"
if got=$(launch stagingLaunchScreen 2>&1); then bad "row 9 missing launch screen accepted"
elif [[ "$got" == *"launch screen stagingLaunchScreen"* ]]; then ok "row 9 missing launch screen stops"
else bad "row 9 message: $got"; fi

actool=$(awk '/"\$tools\/actool"/,/--output-format/' "$BUILD")
if grep -qF '"${icon_args[@]+"${icon_args[@]}"}"' <<<"$actool" && ! grep -q -- '--app-icon AppIcon' <<<"$actool"; then
  ok "row 10 actool gets the configuration's icon set"
else bad "row 10 actool call: $actool"; fi

exit "$fail"
