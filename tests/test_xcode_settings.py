"""flutter/tools/xcode_settings.py: the Runner target's build settings in one configuration,
which flutter/build.sh reads the bundle id, minimum iOS and device families from.

Rows (expected results written before the code):
  1  stock template, Release -> the values build.sh's old first-match grep read
     (ly.example.stockApp, 15.0, 1,2): the stock template builds as before
  2  one setting at every level -> the target's, then the target's xcconfig, then the
     project's, then the project's xcconfig, as in Xcode
  3  $(inherited) in the target's setting -> the project's value takes its place
  4  configuration Debug -> the Debug settings; "release" matches Release, as Flutter matches
  5  a configuration the target lacks -> exit 1, listing Debug, Release, Profile
  6  $(VAR)s expand from any level, including the configuration's xcconfig
--flavor, on tests/flutter-configuration/flavors (Flutter 3.47.6's matching):
  7  dev -> Release-dev, scheme dev; its settings: bundle id .dev, devAppIcon,
     FLUTTER_TARGET lib/main_dev.dart, display name from its xcconfig
  8  prod -> scheme Prod (the flavor in sentence case), Release-Prod
  9  STAGING -> scheme staging (ignoring case), "Release staging" (the one name with both)
  10 qa -> exit 1: Release-qa-a and Release-qa-b both match
  11 nocfg -> exit 1, no Release configuration; missing -> exit 1, lists the schemes
  12 the stock template (no schemes but Runner) with dev -> exit 1, lists Runner
Mutants (each must fail its row; checked by hand when the test was written):
  M1  look the levels up lowest first (drop reversed) -> row 2
  M2  leave $(inherited) as written -> row 3
  M3  always read Release (config_layers without the name) -> row 4
  M4  drop the fuzzy configuration match -> row 9
  M5  take the first of several configurations -> row 10
  M6  print FLAVOR instead of the scheme -> row 8
"""
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from flutter_fixture import (DEBUG_XCCONFIG, FLAVORS, PROJECT_RELEASE, STOCK, TARGET_DEBUG,  # noqa: E402
                             TARGET_RELEASE, stock_ios)

TOOL = Path(__file__).resolve().parents[1] / "flutter/tools/xcode_settings.py"


def old_setting(pbx, name):
    """build.sh's setting() before configurations: the first value in the file not on a RunnerTests line."""
    for line in pbx.read_text().splitlines():
        if re.match(rf"^\s*{name} = ", line) and "RunnerTests" not in line:
            return re.sub(r'.* = "?([^";]*)"?;.*', r"\1", line)
    return ""


class SettingsCase(unittest.TestCase):
    def run_tool(self, ios, configuration, *names):
        return subprocess.run([sys.executable, str(TOOL), str(ios), configuration, *names],
                              capture_output=True, text=True)

    def values(self, ios, configuration, *names):
        proc = self.run_tool(ios, configuration, *names)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.splitlines()


class XcodeSettingsTest(SettingsCase):

    def test_row1_stock_template_as_before(self):
        names = ["PRODUCT_BUNDLE_IDENTIFIER", "IPHONEOS_DEPLOYMENT_TARGET", "TARGETED_DEVICE_FAMILY"]
        pbx = STOCK / "Runner.xcodeproj/project.pbxproj"
        self.assertEqual(self.values(STOCK, "Release", *names), [old_setting(pbx, n) for n in names])
        self.assertEqual(self.values(STOCK, "Release", *names), ["ly.example.stockApp", "15.0", "1,2"])

    def test_row2_levels(self):
        with tempfile.TemporaryDirectory() as tmp:
            levels = {
                PROJECT_RELEASE: [f"baseConfigurationReference = {DEBUG_XCCONFIG};",
                                  "B = project;", "C = project;", "D = project;"],
                TARGET_RELEASE: ["D = target;"],
            }
            ios = stock_ios(Path(tmp) / "ios", levels, {
                "Debug.xcconfig": "A = project-xcconfig\nB = project-xcconfig\nC = project-xcconfig\n"
                                  "D = project-xcconfig\n",
                "Release.xcconfig": "C = target-xcconfig\nD = target-xcconfig\n"})
            self.assertEqual(self.values(ios, "Release", "A", "B", "C", "D"),
                             ["project-xcconfig", "project", "target-xcconfig", "target"])

    def test_row3_inherited(self):
        with tempfile.TemporaryDirectory() as tmp:
            ios = stock_ios(Path(tmp) / "ios", {PROJECT_RELEASE: ['FLAGS = "-a";'],
                                                TARGET_RELEASE: ['FLAGS = "$(inherited) -b";']})
            self.assertEqual(self.values(ios, "Release", "FLAGS"), ["-a -b"])

    def test_row4_configuration(self):
        with tempfile.TemporaryDirectory() as tmp:
            ios = stock_ios(Path(tmp) / "ios", {TARGET_RELEASE: ["A = release;"], TARGET_DEBUG: ["A = debug;"]})
            self.assertEqual(self.values(ios, "Debug", "A"), ["debug"])
            self.assertEqual(self.values(ios, "release", "A", "CONFIGURATION"), ["release", "Release"])

    def test_row5_missing_configuration(self):
        proc = self.run_tool(STOCK, "Release-dev", "A")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("'Release-dev'", proc.stderr)
        self.assertIn("Debug, Release, Profile", proc.stderr)

    def test_row6_expansion(self):
        with tempfile.TemporaryDirectory() as tmp:
            ios = stock_ios(Path(tmp) / "ios", {TARGET_RELEASE: ['APP_ID = "com.example.$(SUFFIX)";']},
                            {"Release.xcconfig": '#include "Suffix.xcconfig"\n', "Suffix.xcconfig": "SUFFIX = app\n"})
            self.assertEqual(self.values(ios, "Release", "APP_ID"), ["com.example.app"])


class FlavorTest(SettingsCase):
    def pick(self, ios, flavor):
        return self.run_tool(ios, "--flavor", flavor)

    def test_row7_dev(self):
        self.assertEqual(self.values(FLAVORS, "--flavor", "dev"), ["Release-dev", "dev"])
        self.assertEqual(self.values(FLAVORS, "Release-dev", "PRODUCT_BUNDLE_IDENTIFIER",
                                     "ASSETCATALOG_COMPILER_APPICON_NAME", "FLUTTER_TARGET", "BUNDLE_DISPLAY_NAME"),
                         ["ly.example.stockApp.dev", "devAppIcon", "lib/main_dev.dart", "Dev App"])

    def test_row8_sentence_case(self):
        self.assertEqual(self.values(FLAVORS, "--flavor", "prod"), ["Release-Prod", "Prod"])

    def test_row9_fuzzy(self):
        self.assertEqual(self.values(FLAVORS, "--flavor", "STAGING"), ["Release staging", "staging"])

    def test_row10_several(self):
        proc = self.pick(FLAVORS, "qa")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("more than one", proc.stderr)
        self.assertIn("Release-qa-a, Release-qa-b", proc.stderr)

    def test_row11_none(self):
        proc = self.pick(FLAVORS, "nocfg")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("no Release build configuration for scheme nocfg", proc.stderr)
        proc = self.pick(FLAVORS, "missing")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("schemes: Prod, Runner, dev, nocfg, qa, staging", proc.stderr)

    def test_row12_no_custom_schemes(self):
        proc = self.pick(STOCK, "dev")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("schemes: Runner", proc.stderr)


if __name__ == "__main__":
    unittest.main()
