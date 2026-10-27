"""A Flutter app's ios/ directory for tests, from the template `flutter create` wrote
(Flutter 3.47.6, tests/flutter-configuration/stock, DEVELOPMENT_TEAM removed).
"""
import shutil
from pathlib import Path

STOCK = Path(__file__).resolve().parent / "flutter-configuration" / "stock"
FLAVORS = STOCK.parent / "flavors"  # written by flutter-configuration/make-flavors.py
# XCBuildConfiguration ids in the stock project.pbxproj.
PROJECT_DEBUG, PROJECT_RELEASE = "97C147031CF9000F007C117D", "97C147041CF9000F007C117D"
TARGET_DEBUG, TARGET_RELEASE = "97C147061CF9000F007C117D", "97C147071CF9000F007C117D"
TESTS_RELEASE = "331C8089294A63A400263BE5"
DEBUG_XCCONFIG = "9740EEB21CF90195004384FC"  # Flutter/Debug.xcconfig


def stock_ios(dest, settings=None, xcconfig=None):
    """Copies the stock ios/ directory to dest. settings maps a configuration id
    to pbxproj lines added to its buildSettings ("baseConfigurationReference = <id>;"
    goes before them); xcconfig maps a file name under Flutter/ to its text."""
    dest = Path(dest)
    shutil.copytree(STOCK, dest)
    pbx = dest / "Runner.xcodeproj" / "project.pbxproj"
    text = pbx.read_text()
    for cfg, lines in (settings or {}).items():
        start = text.index(f"\n\t\t{cfg} /* ")
        at = text.index("buildSettings = {\n", start) + len("buildSettings = {\n")
        body = "".join(f"\t\t\t\t{line}\n" for line in lines if not line.startswith("baseConfigurationReference"))
        text = text[:at] + body + text[at:]
        for line in lines:
            if line.startswith("baseConfigurationReference"):
                at = text.index("isa = XCBuildConfiguration;\n", start) + len("isa = XCBuildConfiguration;\n")
                text = text[:at] + f"\t\t\t{line}\n" + text[at:]
    pbx.write_text(text)
    for name, content in (xcconfig or {}).items():
        path = dest / "Flutter" / name
        path.write_bytes(content) if isinstance(content, bytes) else path.write_text(content)
    return dest
