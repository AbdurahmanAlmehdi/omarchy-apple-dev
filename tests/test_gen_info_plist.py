import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[1] / "flutter/tools/gen-info-plist.py"


class GenInfoPlistXcconfigTest(unittest.TestCase):
    """$(VAR)s an app defines in an xcconfig that Flutter/Release.xcconfig includes."""

    def run_tool(self, xcconfigs, info, pbx="", **extra):
        with tempfile.TemporaryDirectory() as tmp:
            ios = Path(tmp) / "ios"
            for name, text in xcconfigs.items():
                (ios / "Flutter").mkdir(parents=True, exist_ok=True)
                (ios / "Flutter" / name).write_text(text)
            (ios / "Runner").mkdir(parents=True, exist_ok=True)
            (ios / "Runner.xcodeproj").mkdir()
            (ios / "Runner.xcodeproj/project.pbxproj").write_text(pbx)
            src = ios / "Runner/Info.plist"
            src.write_bytes(plistlib.dumps(info))
            icon = Path(tmp) / "icon.plist"
            icon.write_bytes(plistlib.dumps({}))
            sdk = Path(tmp) / "iPhoneOS.sdk"
            (sdk / "System/Library/CoreServices").mkdir(parents=True)
            (sdk / "SDKSettings.json").write_text(json.dumps({"Version": "27.0"}))
            (sdk / "System/Library/CoreServices/SystemVersion.plist").write_bytes(
                plistlib.dumps({"ProductBuildVersion": "24A1"}))
            out = Path(tmp) / "out.plist"
            proc = subprocess.run(
                [sys.executable, str(TOOL), str(src), str(icon), str(out), "ly.example.app",
                 "1.0.0", "7", "15.0", str(sdk), "1,2"],
                capture_output=True, text=True, env={"HOME": tmp})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return plistlib.loads(out.read_bytes()), proc.stderr

    def test_included_xcconfig_values_expand(self):
        info, err = self.run_tool(
            {"Release.xcconfig": '#include "Generated.xcconfig"\n#include? "Pods/missing.xcconfig"\n'
                                 '#include "Google.xcconfig"\n',
             "Generated.xcconfig": "FLUTTER_BUILD_NUMBER=1\n",
             "Google.xcconfig": "// the ids\nGOOGLE_IOS_CLIENT_ID = 123-abc.apps.googleusercontent.com\n"
                                "GOOGLE_REVERSED_CLIENT_ID = com.googleusercontent.apps.123-abc // reversed\n"},
            {"GIDClientID": "$(GOOGLE_IOS_CLIENT_ID)",
             "CFBundleURLTypes": [{"CFBundleURLSchemes": ["$(GOOGLE_REVERSED_CLIENT_ID)"]}],
             "CFBundleVersion": "$(FLUTTER_BUILD_NUMBER)"})
        self.assertEqual(info["GIDClientID"], "123-abc.apps.googleusercontent.com")
        self.assertEqual(info["CFBundleURLTypes"][0]["CFBundleURLSchemes"], ["com.googleusercontent.apps.123-abc"])
        self.assertEqual(info["CFBundleVersion"], "7")  # build.sh's number, not Generated.xcconfig's
        self.assertNotIn("warning", err)

    def test_later_assignment_and_project_settings_win(self):
        info, _ = self.run_tool(
            {"Release.xcconfig": "A = first\nA = second\nB = $(inherited) from-xcconfig\nC = xc\n"},
            {"A": "$(A)", "B": "$(B)", "C": "$(C)"},
            pbx="\t\t\t\tC = project;\n")
        self.assertEqual((info["A"], info["B"], info["C"]), ("second", "from-xcconfig", "project"))

    def test_empty_project_setting_still_wins(self):
        info, _ = self.run_tool({"Release.xcconfig": "C = xc\n"}, {"C": "$(C)"}, pbx='\t\t\t\tC = "";\n')
        self.assertEqual(info["C"], "")

    def test_self_reference_is_cut(self):
        info, err = self.run_tool({"Release.xcconfig": "A = x$(A)\nB = $(C)\nC = $(B)\n"},
                                  {"A": "$(A)", "B": "$(B)"})
        self.assertEqual((info["A"], info["B"]), ("x", ""))
        self.assertIn("$(A) refers to itself", err)
        self.assertIn("$(B) refers to itself", err)

    def test_include_cycle_and_unknown_variable(self):
        info, err = self.run_tool(
            {"Release.xcconfig": '#include "Other.xcconfig"\n', "Other.xcconfig": '#include "Release.xcconfig"\n'},
            {"X": "$(NOT_SET)"})
        self.assertEqual(info["X"], "")
        self.assertIn("no value for $(NOT_SET)", err)


if __name__ == "__main__":
    unittest.main()
