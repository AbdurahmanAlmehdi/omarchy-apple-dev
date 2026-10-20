#!/usr/bin/env bash
# Checks the Dart symbol options of flutter/build.sh (SPLIT_DEBUG_INFO and
# DART_OBFUSCATION): the block that turns them into flutter assemble defines
# is extracted verbatim from build.sh and run on its own (the rest of the
# script needs Flutter and the darwin SDK). The defines are the ones Flutter's
# xcode_backend.dart passes to `flutter assemble` (Flutter 3.47.6).
#
# Rows (expected results written before the code):
#   1  default:     neither set -> no defines
#   2  split:       SPLIT_DEBUG_INFO=out/syms from /tmp/x ->
#                   -dSplitDebugInfo=/tmp/x/out/syms (relative to where build.sh runs)
#   3  obfuscate:   both set -> -dSplitDebugInfo=<abs> -dDartObfuscation=true
#   4  alone:       DART_OBFUSCATION=true without SPLIT_DEBUG_INFO -> exit 1,
#                   message names SPLIT_DEBUG_INFO
#   5  bad value:   DART_OBFUSCATION=yes -> exit 1
#   6  false:       DART_OBFUSCATION=false with SPLIT_DEBUG_INFO -> split only
#   7  wired:       the flutter assemble call passes "${dart_opts[@]...}"
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  drop realpath -m -> row 2
#   M2  drop the needs-SPLIT_DEBUG_INFO check -> row 4
#   M3  drop the dart_opts line from the assemble call -> row 7
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
awk '/^dart_opts=\(\)$/,/^esac$/' "$BUILD" >"$block"
[ -s "$block" ] || { echo "FAIL no dart_opts block in $BUILD"; exit 1; }
mkdir -p "$tmp/cwd"

# opts [VAR=VALUE ...]: prints one define per line, or exits with the block's status.
opts() {
  (cd "$tmp/cwd" && env -u SPLIT_DEBUG_INFO -u DART_OBFUSCATION "$@" bash -c '
    set -euo pipefail
    source "$1"
    printf "%s\n" "${dart_opts[@]+"${dart_opts[@]}"}"' _ "$block")
}

[ -z "$(opts)" ] && ok "row 1 default" || bad "row 1 default: $(opts)"

got=$(opts SPLIT_DEBUG_INFO=out/syms)
[ "$got" = "-dSplitDebugInfo=$tmp/cwd/out/syms" ] && ok "row 2 split" || bad "row 2 split: $got"

got=$(opts SPLIT_DEBUG_INFO=/abs/syms DART_OBFUSCATION=true)
[ "$got" = "-dSplitDebugInfo=/abs/syms
-dDartObfuscation=true" ] && ok "row 3 obfuscate" || bad "row 3 obfuscate: $got"

if got=$(opts DART_OBFUSCATION=true 2>&1); then bad "row 4 obfuscation alone accepted"
elif [[ "$got" == *SPLIT_DEBUG_INFO* ]]; then ok "row 4 obfuscation needs SPLIT_DEBUG_INFO"
else bad "row 4 message: $got"; fi

if opts SPLIT_DEBUG_INFO=/abs DART_OBFUSCATION=yes >/dev/null 2>&1; then bad "row 5 bad value accepted"
else ok "row 5 bad value"; fi

got=$(opts SPLIT_DEBUG_INFO=/abs/syms DART_OBFUSCATION=false)
[ "$got" = "-dSplitDebugInfo=/abs/syms" ] && ok "row 6 false" || bad "row 6 false: $got"

if awk '/"\$FLUTTER" assemble/,/release_ios_bundle_flutter_assets\)/' "$BUILD" |
   grep -qF '"${dart_opts[@]+"${dart_opts[@]}"}"'; then ok "row 7 assemble gets the defines"
else bad "row 7 assemble call does not pass dart_opts"; fi

exit "$fail"
