import json
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flutter_fixture import PROJECT_RELEASE, TARGET_DEBUG, TARGET_RELEASE, TESTS_RELEASE, stock_ios  # noqa: E402

TOOL = Path(__file__).resolve().parents[1] / "flutter/tools/gen-info-plist.py"


class ToolCase(unittest.TestCase):
    def run_tool(self, xcconfigs, info, pbx=(), settings=None, configuration=()):
        with tempfile.TemporaryDirectory() as tmp:
            ios = stock_ios(Path(tmp) / "ios", settings or {TARGET_RELEASE: pbx}, xcconfigs)
            (ios / "Runner").mkdir(exist_ok=True)
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
                 "1.0.0", "7", "15.0", str(sdk), "1,2", *configuration],
                capture_output=True, text=True, env={"HOME": tmp})
            self.assertEqual(proc.returncode, 0, proc.stderr)
            return plistlib.loads(out.read_bytes()), proc.stderr


class GenInfoPlistXcconfigTest(ToolCase):
    """$(VAR)s an app defines in an xcconfig that Flutter/Release.xcconfig includes."""

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
            pbx=["C = project;"])
        self.assertEqual((info["A"], info["B"], info["C"]), ("second", "from-xcconfig", "project"))

    def test_empty_project_setting_still_wins(self):
        info, _ = self.run_tool({"Release.xcconfig": "C = xc\n"}, {"C": "$(C)"}, pbx=['C = "";'])
        self.assertEqual(info["C"], "")

    def test_self_reference_is_cut(self):
        info, err = self.run_tool({"Release.xcconfig": "A = x$(A)\nB = $(C)\nC = $(B)\n"},
                                  {"A": "$(A)", "B": "$(B)"})
        self.assertEqual((info["A"], info["B"]), ("x", ""))
        self.assertIn("$(A) refers to itself", err)
        self.assertIn("$(B) refers to itself", err)

    def test_empty_reference_writes_a_url(self):
        info, _ = self.run_tool({"Release.xcconfig": "API = https:/$()/api.example.com/v1 // the API\n"},
                                {"API": "$(API)"})
        self.assertEqual(info["API"], "https://api.example.com/v1")

    def test_self_reference_in_its_own_value(self):
        info, err = self.run_tool({"Release.xcconfig": "A = $(A) x\n"}, {"A": "$(A)"})
        self.assertEqual(info["A"].strip(), "x")
        self.assertIn("$(A) refers to itself", err)

    def test_file_that_is_not_utf8(self):
        info, _ = self.run_tool({"Release.xcconfig": b"// caf\xe9\nA = ok\n"}, {"A": "$(A)"})
        self.assertEqual(info["A"], "ok")

    def test_conditional_setting_is_skipped(self):
        info, _ = self.run_tool({"Release.xcconfig": "A = plain\nA[sdk=iphoneos*] = conditional\n"}, {"A": "$(A)"})
        self.assertEqual(info["A"], "plain")

    def test_include_cycle_spelled_differently(self):
        info, _ = self.run_tool(
            {"Release.xcconfig": '#include "./Other.xcconfig"\nA = release\n',
             "Other.xcconfig": '#include "./Release.xcconfig"\nB = other\n'},
            {"A": "$(A)", "B": "$(B)"})
        self.assertEqual((info["A"], info["B"]), ("release", "other"))

    def test_same_file_included_twice_is_read_twice(self):
        # Only the include stack is guarded: a later #include of the same file still assigns again.
        info, _ = self.run_tool(
            {"Release.xcconfig": '#include "A.xcconfig"\nA = middle\n#include "./A.xcconfig"\n',
             "A.xcconfig": "A = from-a\n"},
            {"A": "$(A)"})
        self.assertEqual(info["A"], "from-a")

    def test_include_cycle_and_unknown_variable(self):
        info, err = self.run_tool(
            {"Release.xcconfig": '#include "Other.xcconfig"\n', "Other.xcconfig": '#include "Release.xcconfig"\n'},
            {"X": "$(NOT_SET)"})
        self.assertEqual(info["X"], "")
        self.assertIn("no value for $(NOT_SET)", err)


class GenInfoPlistConfigurationTest(ToolCase):
    """Values come from the Runner target's settings in the configuration being built.

    Rows (expected results written before the code):
      1  the target's setting wins over the project's, as in Xcode
      2  a setting only the RunnerTests target has is not used (the old first match used it)
      3  configuration Debug reads the Debug settings and Flutter/Debug.xcconfig
      4  a configuration the target lacks stops the tool, listing the ones it has
    """

    def test_row1_target_over_project(self):
        info, _ = self.run_tool(xcconfigs={"Release.xcconfig": ""}, info={"A": "$(A)"},
                                settings={PROJECT_RELEASE: ["A = project;"], TARGET_RELEASE: ["A = target;"]})
        self.assertEqual(info["A"], "target")

    def test_row2_not_the_test_target(self):
        info, err = self.run_tool(xcconfigs={"Release.xcconfig": ""}, info={"A": "$(A)"},
                                  settings={TESTS_RELEASE: ["A = tests;"]})
        self.assertEqual(info["A"], "")
        self.assertIn("no value for $(A)", err)

    def test_row3_debug_configuration(self):
        info, _ = self.run_tool(xcconfigs={"Release.xcconfig": "X = release\n", "Debug.xcconfig": "X = debug\n"},
                                info={"A": "$(A)", "X": "$(X)"},
                                settings={TARGET_RELEASE: ["A = release;"], TARGET_DEBUG: ["A = debug;"]},
                                configuration=["Debug"])
        self.assertEqual((info["A"], info["X"]), ("debug", "debug"))

    def test_row4_missing_configuration(self):
        with self.assertRaises(AssertionError) as e:
            self.run_tool(xcconfigs={}, info={}, configuration=["Release-dev"])
        self.assertIn("Debug, Release, Profile", str(e.exception))


if __name__ == "__main__":
    unittest.main()
