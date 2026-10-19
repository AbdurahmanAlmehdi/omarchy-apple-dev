#!/usr/bin/env python3
"""Produce the app's final Info.plist the way an Xcode build would.

  gen-info-plist.py <source Info.plist> <actool partial plist> <output>
                    <bundle id> <build name> <build number> <min iOS> <iPhoneOS.sdk>
                    <device families, e.g. 1,2>

Expands the $(BUILD_SETTING) references Flutter's template uses, merges the
icon keys actool reported, and adds the platform and toolchain keys Xcode
stamps on a device build.
"""
import json
import os
import plistlib
import re
import sys

src, icon, out, bundle_id, build_name, build_number, min_ios, sdk, families = sys.argv[1:10]

settings = {
    "DEVELOPMENT_LANGUAGE": "en",
    "EXECUTABLE_NAME": "Runner",
    "PRODUCT_NAME": "Runner",
    "PRODUCT_MODULE_NAME": "Runner",
    "PRODUCT_BUNDLE_IDENTIFIER": bundle_id,
    "FLUTTER_BUILD_NAME": build_name,
    "FLUTTER_BUILD_NUMBER": build_number,
    "MARKETING_VERSION": build_name,
    "CURRENT_PROJECT_VERSION": build_number,
}

# Apps whose template goes beyond Flutter's own variable set (MARKETING_VERSION
# is common) define the values as build settings; take them from the Runner
# project the plist lives in, first value wins as in build.sh's setting().
pbx = os.path.join(os.path.dirname(os.path.dirname(src)), "Runner.xcodeproj", "project.pbxproj")
pbx_settings = {}
if os.path.isfile(pbx):
    for m in re.finditer(r"^\s*(\w+) = \"?([^\";\n]*?)\"?;", open(pbx).read(), re.M):
        pbx_settings.setdefault(m.group(1), m.group(2))

def lookup(name):
    if name in settings:
        return settings[name]
    value = pbx_settings.get(name, "")
    if not value:
        print(f"warning: no value for $({name}); substituting empty", file=sys.stderr)
    return value

def expand(value):
    if isinstance(value, str):
        return re.sub(r"\$\((\w+)\)", lambda m: expand(lookup(m.group(1))), value)
    if isinstance(value, dict):
        return {k: expand(v) for k, v in value.items()}
    if isinstance(value, list):
        return [expand(v) for v in value]
    return value

info = expand(plistlib.load(open(src, "rb")))
info.update(plistlib.load(open(icon, "rb")))

sdk_version = json.load(open(os.path.join(sdk, "SDKSettings.json")))["Version"]
sdk_build = plistlib.load(
    open(os.path.join(sdk, "System/Library/CoreServices/SystemVersion.plist"), "rb"))["ProductBuildVersion"]
info.update({
    "CFBundleSupportedPlatforms": ["iPhoneOS"],
    "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
    "DTPlatformName": "iphoneos",
    "DTPlatformVersion": sdk_version,
    "DTPlatformBuild": sdk_build,
    "DTSDKName": "iphoneos" + sdk_version,
    "DTSDKBuild": sdk_build,
    "MinimumOSVersion": min_ios,
    "UIDeviceFamily": [int(f) for f in families.split(",")],
    "UIRequiredDeviceCapabilities": ["arm64"],
})
# DTXcode / DTXcodeBuild name the Xcode the SDK was built from; install-toolchain.sh
# keeps that Xcode's version.plist beside the SDK cache (the file asc.py reads).
import glob
candidates = sorted(glob.glob(os.path.expanduser("~/.cache/xtool/darwin-*.xtoolsdk.version.plist")))
if candidates:
    v = plistlib.load(open(candidates[-1], "rb"))
    parts = (v["CFBundleShortVersionString"].split(".") + ["0", "0"])[:3]
    info["DTXcode"] = "%02d%s%s" % (int(parts[0]), parts[1], parts[2])
    info["DTXcodeBuild"] = v["ProductBuildVersion"]

plistlib.dump(info, open(out, "wb"), fmt=plistlib.FMT_BINARY)
