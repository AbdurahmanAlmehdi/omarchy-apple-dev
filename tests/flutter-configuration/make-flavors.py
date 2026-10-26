"""Writes tests/flutter-configuration/flavors from the stock fixture: per-flavor configurations
in the layout flutter_flavorizr writes (an xcconfig per flavor and configuration, ASSET_PREFIX),
a non-localized launch storyboard, per-flavor icon sets,
plus the shapes Flutter's matching has to handle: a scheme spelled with a capital (Prod), a
configuration found only by the fuzzy match (Release staging), two candidates (qa) and none (nocfg).

  python3 tests/flutter-configuration/make-flavors.py tests/flutter-configuration
"""
import plistlib, re, shutil, sys
from pathlib import Path
root = Path(sys.argv[1]); stock = root / "stock"; dest = root / "flavors"
shutil.rmtree(dest, ignore_errors=True); shutil.copytree(stock, dest)
pbx = dest / "Runner.xcodeproj/project.pbxproj"; text = pbx.read_text()

def block(cfg_id):
    m = re.search(rf"\t\t{cfg_id} /\* Release \*/ = \{{\n.*?\n\t\t\}};\n", text, re.S)
    return m.group(0)
proj_rel, targ_rel = block("97C147041CF9000F007C117D"), block("97C147071CF9000F007C117D")
# name, xcconfig text or None, target overrides
flavors = [
    ("Debug-dev", "devDebug", {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp.dev.debug"}),
    ("Release-dev", "devRelease", {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp.dev",
                                   "CODE_SIGN_ENTITLEMENTS": "Runner/dev.entitlements"}),
    ("Release-Prod", "prodRelease", {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp",
                                     "CODE_SIGN_ENTITLEMENTS": '"$(SRCROOT)/Runner/Runner.entitlements"'}),
    ("Release staging", "stagingRelease", {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp.staging",
                                           "CODE_SIGN_ENTITLEMENTS": "Runner/staging.entitlements"}),
    ("Release-qa-a", None, {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp.qa.a"}),
    ("Release-qa-b", None, {"PRODUCT_BUNDLE_IDENTIFIER": "ly.example.stockApp.qa.b"}),
]
xcconfigs = {
    "devDebug": "#include \"Generated.xcconfig\"\nFLUTTER_TARGET=lib/main_dev.dart\nASSET_PREFIX=dev\nBUNDLE_DISPLAY_NAME=Dev App\n",
    "devRelease": "#include \"Generated.xcconfig\"\nFLUTTER_TARGET=lib/main_dev.dart\nASSET_PREFIX=dev\nBUNDLE_DISPLAY_NAME=Dev App\n",
    "prodRelease": "#include \"Generated.xcconfig\"\nFLUTTER_TARGET=lib/main_prod.dart\nASSET_PREFIX=prod\nBUNDLE_DISPLAY_NAME=App\n",
    "stagingRelease": "#include \"Generated.xcconfig\"\nASSET_PREFIX=staging\nBUNDLE_DISPLAY_NAME=App Staging\n",
}
new_cfgs, new_refs, proj_ids, targ_ids, group_children = "", "", [], [], ""
for n, (name, xc, over) in enumerate(flavors):
    pid, tid, rid = f"F1A0000000000000000001{n:02X}", f"F1A0000000000000000002{n:02X}", f"F1A0000000000000000003{n:02X}"
    p = proj_rel.replace("97C147041CF9000F007C117D /* Release */", f"{pid} /* {name} */").replace("name = Release;", f'name = "{name}";')
    t = targ_rel.replace("97C147071CF9000F007C117D /* Release */", f"{tid} /* {name} */").replace("name = Release;", f'name = "{name}";')
    if xc:
        t = t.replace("7AFA3C8E1D35360C0083082E /* Release.xcconfig */", f"{rid} /* {xc}.xcconfig */")
        new_refs += (f"\t\t{rid} /* {xc}.xcconfig */ = {{isa = PBXFileReference; lastKnownFileType = text.xcconfig; "
                     f"name = {xc}.xcconfig; path = Flutter/{xc}.xcconfig; sourceTree = \"<group>\"; }};\n")
        group_children += f"\t\t\t\t{rid} /* {xc}.xcconfig */,\n"
        (dest / "Flutter" / f"{xc}.xcconfig").write_text(xcconfigs[xc])
    t = t.replace("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;", 'ASSETCATALOG_COMPILER_APPICON_NAME = "$(ASSET_PREFIX)AppIcon";' if xc else "ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon;")
    for k, v in over.items():
        t = re.sub(rf"{k} = [^;]*;", f"{k} = {v};", t) if k in t else \
            t.replace("\t\t\tbuildSettings = {\n", f"\t\t\tbuildSettings = {{\n\t\t\t\t{k} = {v};\n", 1)
    new_cfgs += p + t
    proj_ids.append(f"\t\t\t\t{pid} /* {name} */,\n"); targ_ids.append(f"\t\t\t\t{tid} /* {name} */,\n")
text = text.replace("/* End XCBuildConfiguration section */", new_cfgs + "/* End XCBuildConfiguration section */")
text = text.replace("/* End PBXFileReference section */", new_refs + "/* End PBXFileReference section */")
text = text.replace("\t\t\t\t9740EEB31CF90195004384FC /* Generated.xcconfig */,\n", "\t\t\t\t9740EEB31CF90195004384FC /* Generated.xcconfig */,\n" + group_children)
for list_id, ids in (("97C146E91CF9000F007C117D", proj_ids), ("97C147051CF9000F007C117D", targ_ids)):
    i = text.index(f"\t\t{list_id} /* Build configuration list"); j = text.index("\t\t\t);\n", i)
    text = text[:j] + "".join(ids) + text[j:]
# A launch screen that is not localized, as flutter_native_splash writes one per flavor.
text = text.replace("/* End PBXFileReference section */",
                    "\t\tF1A000000000000000000401 /* devLaunchScreen.storyboard */ = {isa = PBXFileReference; "
                    "lastKnownFileType = file.storyboard; path = devLaunchScreen.storyboard; sourceTree = \"<group>\"; };\n"
                    "/* End PBXFileReference section */")
text = text.replace("/* End PBXBuildFile section */",
                    "\t\tF1A000000000000000000402 /* devLaunchScreen.storyboard in Resources */ = {isa = PBXBuildFile; "
                    "fileRef = F1A000000000000000000401 /* devLaunchScreen.storyboard */; };\n/* End PBXBuildFile section */")
text = text.replace("\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,\n",
                    "\t\t\t\t74858FAD1ED2DC5600515810 /* Runner-Bridging-Header.h */,\n"
                    "\t\t\t\tF1A000000000000000000401 /* devLaunchScreen.storyboard */,\n")
text = text.replace("\t\t\t\t97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,\n",
                    "\t\t\t\t97C146FC1CF9000F007C117D /* Main.storyboard in Resources */,\n"
                    "\t\t\t\tF1A000000000000000000402 /* devLaunchScreen.storyboard in Resources */,\n")
shutil.copy(dest / "Runner/Base.lproj/LaunchScreen.storyboard", dest / "Runner/devLaunchScreen.storyboard")
pbx.write_text(text)
# Icon sets: devAppIcon is single-size, prodAppIcon is the template's multi-size set, and
# stagingAppIcon is missing.
assets = dest / "Runner/Assets.xcassets"
(assets / "devAppIcon.appiconset").mkdir()
(assets / "devAppIcon.appiconset/Contents.json").write_text(
    '{\n  "images" : [\n    {\n      "filename" : "dev-1024.png",\n      "idiom" : "universal",\n'
    '      "platform" : "ios",\n      "size" : "1024x1024"\n    }\n  ],\n'
    '  "info" : {\n    "author" : "xcode",\n    "version" : 1\n  }\n}\n')
shutil.copytree(assets / "AppIcon.appiconset", assets / "prodAppIcon.appiconset")

# Entitlements for dev and prod; staging's file is missing.
(dest / "Runner").mkdir(exist_ok=True)
for name, aps in (("dev", "development"), ("Runner", "production")):
    (dest / f"Runner/{name}.entitlements").write_bytes(plistlib.dumps({"aps-environment": aps}))
schemes = dest / "Runner.xcodeproj/xcshareddata/xcschemes"; schemes.mkdir(parents=True, exist_ok=True)
for s in ("Runner", "dev", "Prod", "staging", "qa", "nocfg"):
    (schemes / f"{s}.xcscheme").write_text(f'<?xml version="1.0" encoding="UTF-8"?>\n<Scheme version = "1.3">\n</Scheme>\n')
