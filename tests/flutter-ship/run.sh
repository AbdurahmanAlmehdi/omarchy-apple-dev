#!/usr/bin/env bash
# Checks flutter/ship.sh against a synthetic build/ios-linux/Payload/Runner.app
# with two frameworks. The pymobile3 python and rcodesign are stubs that log
# their calls (no Apple account, no SDK): the rows check the order of the
# steps, their arguments, and what is left on disk.
#
# Rows (expected results written before the code):
#   1  default:   no ASC_KEY_ID -> stamp with build.sh's CFBundleVersion (7),
#     frameworks, test-identity, fill-team-prefix, rcodesign on both
#     frameworks, then the app with the entitlements, then validate on
#     Runner-store.ipa; no upload. The ipa holds the signed copy; the built
#     bundle has no _CodeSignature and no embedded.mobileprovision
#   2  build no:  BUILD_NUMBER=42 -> stamp gets 42
#   3  no key:    --upload without ASC_KEY_ID exits non-zero before any step
#   4  upload:    --upload with the three ASC variables -> identity (not
#     test-identity), upload after validate
#   5  no build:  an app dir without build/ios-linux/Payload/Runner.app exits 1
#     and names flutter/build.sh
#   6  read-only: a read-only built bundle (SwiftPM outputs are) still signs
#   7  bad team:  an entitlements team id that is not 10 characters stops
#     before rcodesign runs
#   8  given:     ASC_PROFILE (with ASC_KEY_ID set too) -> given-identity, not
#     identity or test-identity, and no TEST-identity warning
# Requested entitlements, with the app's ios/ from tests/flutter-configuration
# and the configuration build.sh records in build/ios-linux/configuration:
#   9  flavor:    Release-dev -> the identity step gets ASC_ENTITLEMENTS_PATH=
#     <app>/ios/Runner/dev.entitlements (its CODE_SIGN_ENTITLEMENTS, made absolute)
#   10 env:       ASC_ENTITLEMENTS_PATH set -> that file, not the configuration's
#   11 $(SRCROOT): Release-Prod's "$(SRCROOT)/Runner/Runner.entitlements" -> that file
#   12 missing:   "Release staging" names a file that is not there -> exit 1
#     before any step, naming it
#   13 none:      Release of the stock template (no CODE_SIGN_ENTITLEMENTS), or no
#     recorded configuration -> no ASC_ENTITLEMENTS_PATH, as before
# Mutants (each must fail its row; checked by hand when the test was written):
#   M1  sign the app before the frameworks -> row 1 (order)
#   M2  sign $built instead of the staged copy -> row 1 (built bundle changed)
#   M3  drop the chmod -R u+w line -> row 6
#   M4  drop the team-id regex check -> row 7
#   M5  test ASC_KEY_ID before ASC_PROFILE -> row 8
#   M6  ignore a set ASC_ENTITLEMENTS_PATH -> row 10
#   M7  leave the path relative to ios/ -> row 9
#   M8  drop the file check -> row 12
# usage: run.sh [path-to-flutter/ship.sh]   default: ../../flutter/ship.sh
set -uo pipefail
here=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
SHIP=${1:-$here/../../flutter/ship.sh}
tmp=$(mktemp -d)
trap 'chmod -R u+w "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
fail=0
ok() { echo "ok   $*"; }
bad() { echo "FAIL $*"; fail=1; }

# Stubs live under a fake HOME: ship.sh runs $HOME/pymobile3-venv/bin/python
# and puts $HOME/.local/bin first on PATH.
home=$tmp/home
mkdir -p "$home/pymobile3-venv/bin" "$home/.local/bin"
cat >"$home/pymobile3-venv/bin/python" <<'STUB'
#!/usr/bin/env bash
# Inline -c snippets run for real; tools/*.py calls are logged.
if [ "$1" = "-c" ]; then exec python3 "$@"; fi
tool=$(basename "$1"); shift
case "$tool" in
  asc.py)
    echo "asc $1 $(basename "$2")${3:+ $(basename "$3")}${ASC_ENTITLEMENTS_PATH:+ ent=$ASC_ENTITLEMENTS_PATH}" >>"$STUB_LOG"
    case "$1" in
      identity|given-identity|test-identity)
        mkdir -p "$3"
        python3 - "$3/entitlements.plist" "${STUB_TEAM:-TEAM000000}" <<'PY'
import plistlib, sys
plistlib.dump({"com.apple.developer.team-identifier": sys.argv[2]}, open(sys.argv[1], "wb"))
PY
        : >"$3/key.pem"; : >"$3/cert.der"
        cp "$3/entitlements.plist" "$2/embedded.mobileprovision" ;;
      validate)
        unzip -l "$2" | grep -q 'Payload/Runner.app/_CodeSignature/' || { echo "validate stub: unsigned" >&2; exit 1; } ;;
    esac ;;
  fill-team-prefix.py) echo "fill-team-prefix $1 $2 $(basename "$3")" >>"$STUB_LOG" ;;
  *) echo "python stub: unexpected $tool" >&2; exit 9 ;;
esac
STUB
cat >"$home/.local/bin/rcodesign" <<'STUB'
#!/usr/bin/env bash
target=${*: -1}
ent=
prev=
for a in "$@"; do
  [ "$prev" = "--entitlements-xml-file" ] && ent=" ent=$(basename "$a")"
  prev=$a
done
echo "rcodesign $(basename "$target")$ent" >>"$STUB_LOG"
mkdir "$target/_CodeSignature"
STUB
chmod +x "$home/pymobile3-venv/bin/python" "$home/.local/bin/rcodesign"

# mkapp <dir>: a Flutter app dir as build.sh leaves it.
mkapp() {
  local bundle=$1/build/ios-linux/Payload/Runner.app
  rm -rf "$1"
  mkdir -p "$bundle/Frameworks/App.framework" "$bundle/Frameworks/Flutter.framework"
  python3 - "$bundle/Info.plist" <<'PY'
import plistlib, sys
plistlib.dump({"CFBundleIdentifier": "com.example.counter", "CFBundleVersion": "7",
               "CFBundleShortVersionString": "1.0.0"}, open(sys.argv[1], "wb"))
PY
  : >"$bundle/Runner"
}

# drive <log> [env args for env(1)...] -- <ship.sh args...>: runs ship.sh with the
# stubs, without any ASC_* variable from the caller's environment.
drive() {
  local log=$1; shift
  local envargs=()
  while [ "$1" != "--" ]; do envargs+=("$1"); shift; done
  shift
  : >"$log"
  env -u ASC_KEY_ID -u ASC_ISSUER_ID -u ASC_KEY_PATH -u ASC_PROFILE -u ASC_ENTITLEMENTS_PATH -u BUILD_NUMBER \
    HOME="$home" STUB_LOG="$log" "${envargs[@]}" bash "$SHIP" "$@"
}

# Row 1
mkapp "$tmp/r1"
log=$tmp/r1.log
if drive "$log" -- "$tmp/r1" >"$tmp/r1.out" 2>&1; then
  expected="asc stamp Runner.app 7
asc frameworks Runner.app
asc test-identity Runner.app ship-signing
fill-team-prefix --team TEAM000000 Runner.app
rcodesign App.framework
rcodesign Flutter.framework
rcodesign Runner.app ent=entitlements.plist
asc validate Runner-store.ipa"
  if [ "$(cat "$log")" = "$expected" ]; then ok "row 1 steps and order"; else
    bad "row 1 steps and order"; diff <(echo "$expected") "$log" | sed 's/^/  /'; fi
  built=$tmp/r1/build/ios-linux/Payload/Runner.app
  if [ ! -e "$built/_CodeSignature" ] && [ ! -e "$built/embedded.mobileprovision" ] &&
     [ ! -e "$built/Frameworks/App.framework/_CodeSignature" ]; then
    ok "row 1 built bundle untouched"; else bad "row 1 built bundle was changed"; fi
  if unzip -l "$tmp/r1/build/ios-linux/Runner-store.ipa" | grep -q 'Payload/Runner.app/Frameworks/Flutter.framework/_CodeSignature/'; then
    ok "row 1 ipa holds the signed frameworks"; else bad "row 1 ipa frameworks unsigned"; fi
else
  bad "row 1 exited non-zero"; sed 's/^/  /' "$tmp/r1.out"
fi

# Row 2
mkapp "$tmp/r2"
if drive "$tmp/r2.log" BUILD_NUMBER=42 -- "$tmp/r2" >/dev/null 2>&1 &&
   grep -qx 'asc stamp Runner.app 42' "$tmp/r2.log"; then ok "row 2 BUILD_NUMBER"; else bad "row 2 BUILD_NUMBER"; fi

# Row 3
mkapp "$tmp/r3"
if drive "$tmp/r3.log" -- --upload "$tmp/r3" >/dev/null 2>&1; then
  bad "row 3 --upload without a key succeeded"
elif [ -s "$tmp/r3.log" ]; then bad "row 3 ran steps before failing"; else ok "row 3 --upload needs the key"; fi

# Row 4
mkapp "$tmp/r4"
if drive "$tmp/r4.log" ASC_KEY_ID=KEY1234567 ASC_ISSUER_ID=issuer ASC_KEY_PATH=/dev/null -- \
   --upload "$tmp/r4" >/dev/null 2>&1 &&
   grep -qx 'asc identity Runner.app ship-signing' "$tmp/r4.log" &&
   ! grep -q 'test-identity' "$tmp/r4.log" &&
   [ "$(tail -n 2 "$tmp/r4.log")" = "asc validate Runner-store.ipa
asc upload Runner-store.ipa" ]; then ok "row 4 identity and upload"; else
  bad "row 4 identity and upload"; sed 's/^/  /' "$tmp/r4.log"; fi

# Row 5
mkdir -p "$tmp/r5"
if drive "$tmp/r5.log" -- "$tmp/r5" >"$tmp/r5.out" 2>&1; then bad "row 5 succeeded without a build"
elif grep -q 'flutter/build.sh' "$tmp/r5.out"; then ok "row 5 names build.sh"; else bad "row 5 message"; fi

# Row 6
mkapp "$tmp/r6"
chmod -R a-w "$tmp/r6/build/ios-linux/Payload"
if drive "$tmp/r6.log" -- "$tmp/r6" >"$tmp/r6.out" 2>&1; then ok "row 6 read-only build signs"; else
  bad "row 6 read-only build"; sed 's/^/  /' "$tmp/r6.out"; fi
chmod -R u+w "$tmp/r6"

# Row 7
mkapp "$tmp/r7"
if drive "$tmp/r7.log" STUB_TEAM="Apple Distribution: X" -- "$tmp/r7" >/dev/null 2>&1; then
  bad "row 7 bad team id accepted"
elif grep -q '^rcodesign' "$tmp/r7.log"; then bad "row 7 signed with a bad team id"; else ok "row 7 bad team id stops"; fi

# Row 8
mkapp "$tmp/r8"
if drive "$tmp/r8.log" ASC_KEY_ID=KEY1234567 ASC_PROFILE=/dev/null -- "$tmp/r8" >"$tmp/r8.out" 2>&1 &&
   grep -qx 'asc given-identity Runner.app ship-signing' "$tmp/r8.log" &&
   ! grep -q '^asc identity\|test-identity' "$tmp/r8.log" &&
   ! grep -q 'TEST identity' "$tmp/r8.out"; then ok "row 8 given identity"; else
  bad "row 8 given identity"; sed 's/^/  /' "$tmp/r8.log" "$tmp/r8.out"; fi

# flavored <dir> <fixture> <configuration>: mkapp plus ios/ and the recorded configuration.
flavored() {
  mkapp "$1"
  cp -R "$here/../flutter-configuration/$2" "$1/ios"
  printf '%s\n' "$3" >"$1/build/ios-linux/configuration"
}

# Row 9
flavored "$tmp/r9" flavors Release-dev
if drive "$tmp/r9.log" -- "$tmp/r9" >"$tmp/r9.out" 2>&1 &&
   grep -qx "asc test-identity Runner.app ship-signing ent=$tmp/r9/ios/Runner/dev.entitlements" "$tmp/r9.log"; then
  ok "row 9 the flavor's entitlements"; else bad "row 9 flavor entitlements"; sed 's/^/  /' "$tmp/r9.log" "$tmp/r9.out"; fi

# Row 10
flavored "$tmp/r10" flavors Release-dev
if drive "$tmp/r10.log" ASC_ENTITLEMENTS_PATH=/given.entitlements -- "$tmp/r10" >"$tmp/r10.out" 2>&1 &&
   grep -qx "asc test-identity Runner.app ship-signing ent=/given.entitlements" "$tmp/r10.log"; then
  ok "row 10 ASC_ENTITLEMENTS_PATH wins"; else bad "row 10 ASC_ENTITLEMENTS_PATH"; sed 's/^/  /' "$tmp/r10.log"; fi

# Row 11
flavored "$tmp/r11" flavors Release-Prod
if drive "$tmp/r11.log" -- "$tmp/r11" >"$tmp/r11.out" 2>&1 &&
   grep -qx "asc test-identity Runner.app ship-signing ent=$tmp/r11/ios/Runner/Runner.entitlements" "$tmp/r11.log"; then
  ok "row 11 \$(SRCROOT) path"; else bad "row 11 \$(SRCROOT) path"; sed 's/^/  /' "$tmp/r11.log" "$tmp/r11.out"; fi

# Row 12
flavored "$tmp/r12" flavors "Release staging"
if drive "$tmp/r12.log" -- "$tmp/r12" >"$tmp/r12.out" 2>&1; then bad "row 12 missing file accepted"
elif [ -s "$tmp/r12.log" ]; then bad "row 12 ran steps before failing"
elif grep -q "staging.entitlements" "$tmp/r12.out"; then ok "row 12 missing file stops"
else bad "row 12 message"; sed 's/^/  /' "$tmp/r12.out"; fi

# Row 13
flavored "$tmp/r13" stock Release
mkapp "$tmp/r13b"
if drive "$tmp/r13.log" -- "$tmp/r13" >/dev/null 2>&1 && drive "$tmp/r13b.log" -- "$tmp/r13b" >/dev/null 2>&1 &&
   ! grep -q "ship-signing ent=" "$tmp/r13.log" "$tmp/r13b.log"; then ok "row 13 no entitlements as before"
else bad "row 13 no entitlements"; sed 's/^/  /' "$tmp/r13.log" "$tmp/r13b.log"; fi

exit "$fail"
