#!/usr/bin/env bash
# Checks step 5 of flutter/build.sh (debug symbols) on a synthetic build: the
# step is extracted verbatim from build.sh and run with the variables the
# earlier steps set ($out, $asm, $products, $bundle, $flutter_root) pointing
# at fake trees. dsymutil is a stub that logs its call and writes a DWARF
# file, or none for a binary whose content is "nodebug" (a prebuilt image).
#
# Rows (expected results written before the code):
#   1  App.framework: copied from flutter assemble's App.framework.dSYM
#   2  Flutter.framework: copied from assemble's output when there; else
#      (row 2b) from the engine artifacts' Flutter.xcframework dSYMs
#   3  native asset: copied from assemble's native_assets/<name>.framework.dSYM
#   4  Runner, SwiftBuild wrote Runner.dSYM: copied as Runner.app.dSYM, no
#      dsymutil call for it
#   5  Runner, no dSYM: dsymutil on the unstripped products/Runner, -o
#      dSYMs/Runner.app.dSYM
#   6  prebuilt framework (no debug map): no dSYM left, a warning names it,
#      the step still succeeds
#   7  SwiftPM dylib: dsymutil on products/libfoo.dylib -> libfoo.dylib.dSYM
#   8  rebuild: a read-only dSYMs tree from the last build is replaced
#   9  count: the summary line counts the dSYMs written
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  drop the DWARF-file check -> row 6
#   M2  drop the products/<name>.dSYM candidate -> row 4
#   M3  drop the chmod before rm -> row 8 (non-root only, as on CI)
# usage: run.sh [path-to-flutter/build.sh]   default: ../../flutter/build.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
BUILD=${1:-$here/../../flutter/build.sh}
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

step=$tmp/step.sh
awk '/^echo "== 5\. Debug symbols"$/,/^fi$/' "$BUILD" >"$step"
grep -q 'add_dsym' "$step" || { echo "FAIL no debug-symbols step in $BUILD"; exit 1; }

mkdir -p "$tmp/bin"
cat >"$tmp/bin/dsymutil" <<'STUB'
#!/usr/bin/env bash
bin=$1 out=
prev=
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
echo "dsymutil $bin -o $out" >>"$STUB_LOG"
mkdir -p "$out/Contents/Resources"
grep -q nodebug "$bin" || { mkdir -p "$out/Contents/Resources/DWARF"; : >"$out/Contents/Resources/DWARF/$(basename "$bin")"; }
STUB
chmod +x "$tmp/bin/dsymutil"

# mktree <root> [runner-dsym] [flutter-from-engine]: one build's trees.
mktree() {
  local r=$1
  rm -rf "$r"
  mkdir -p "$r/out" "$r/asm/native_assets" "$r/products" "$r/flutter/bin/cache/artifacts/engine/ios-release/Flutter.xcframework/ios-arm64/dSYMs"
  local b=$r/out/Payload/Runner.app
  mkdir -p "$b/Frameworks"
  for n in App Flutter sqlite3 Plug Prebuilt; do mkdir -p "$b/Frameworks/$n.framework"; done
  : >"$b/Frameworks/libfoo.dylib"
  mkdir -p "$r/asm/App.framework.dSYM/Contents/Resources/DWARF" "$r/asm/native_assets/sqlite3.framework.dSYM"
  if [ "${3:-}" = engine ]; then
    mkdir -p "$r/flutter/bin/cache/artifacts/engine/ios-release/Flutter.xcframework/ios-arm64/dSYMs/Flutter.framework.dSYM/engine"
  else
    mkdir -p "$r/asm/Flutter.framework.dSYM/assemble"
  fi
  echo debug >"$r/products/Runner"
  [ "${2:-}" = runner-dsym ] && mkdir -p "$r/products/Runner.dSYM/swiftbuild"
  mkdir -p "$r/products/Plug.framework" "$r/products/Prebuilt.framework"
  echo debug >"$r/products/Plug.framework/Plug"
  echo nodebug >"$r/products/Prebuilt.framework/Prebuilt"
  echo debug >"$r/products/libfoo.dylib"
}

# run_step <root>: runs the extracted step in its own bash, so set -e holds even
# though the caller tests the status; stdout+stderr to <root>.out.
run_step() {
  local r=$1
  : >"$r.log"
  PATH=$tmp/bin:$PATH STUB_LOG=$r.log out=$r/out asm=$r/asm products=$r/products \
    bundle=$r/out/Payload/Runner.app flutter_root=$r/flutter \
    bash -c 'set -euo pipefail; source "$1"' _ "$step" >"$r.out" 2>&1
}

r=$tmp/a; mktree "$r"
if run_step "$r"; then
  d=$r/out/dSYMs
  [ -d "$d/App.framework.dSYM/Contents/Resources/DWARF" ] && ok "row 1 App.framework" || bad "row 1 App.framework"
  [ -d "$d/Flutter.framework.dSYM/assemble" ] && ok "row 2 Flutter.framework from assemble" || bad "row 2 Flutter.framework"
  [ -d "$d/sqlite3.framework.dSYM" ] && ok "row 3 native asset" || bad "row 3 native asset"
  grep -qx "dsymutil $r/products/Runner -o $d/Runner.app.dSYM" "$r.log" && [ -f "$d/Runner.app.dSYM/Contents/Resources/DWARF/Runner" ] &&
    ok "row 5 Runner via dsymutil" || bad "row 5 Runner via dsymutil"
  if [ ! -e "$d/Prebuilt.framework.dSYM" ] && grep -q 'warning: no dSYM for Prebuilt.framework' "$r.out"; then
    ok "row 6 prebuilt framework warned"; else bad "row 6 prebuilt framework"; sed 's/^/  /' "$r.out"; fi
  grep -qx "dsymutil $r/products/libfoo.dylib -o $d/libfoo.dylib.dSYM" "$r.log" && [ -d "$d/libfoo.dylib.dSYM" ] &&
    ok "row 7 dylib" || bad "row 7 dylib"
  grep -qx "dSYMs: 6 in $d" "$r.out" && ok "row 9 count" || { bad "row 9 count"; sed 's/^/  /' "$r.out"; }
else
  bad "rows 1-9: step failed"; sed 's/^/  /' "$r.out"
fi

r=$tmp/b; mktree "$r" "" engine
run_step "$r" && [ -d "$r/out/dSYMs/Flutter.framework.dSYM/engine" ] && ok "row 2b Flutter.framework from the engine" ||
  bad "row 2b Flutter.framework from the engine"

r=$tmp/c; mktree "$r" runner-dsym
if run_step "$r" && [ -d "$r/out/dSYMs/Runner.app.dSYM/swiftbuild" ] && ! grep -q "products/Runner -o" "$r.log"; then
  ok "row 4 SwiftBuild's Runner.dSYM"; else bad "row 4 SwiftBuild's Runner.dSYM"; fi

r=$tmp/d; mktree "$r"
run_step "$r"
chmod -R a-w "$r/out/dSYMs"
chmod u+w "$r/out"
if run_step "$r" && [ -d "$r/out/dSYMs/Runner.app.dSYM" ]; then ok "row 8 read-only rebuild"; else
  bad "row 8 read-only rebuild"; sed 's/^/  /' "$r.out"; fi

exit "$fail"
