#!/usr/bin/env python3
"""Build settings of a Flutter app's Runner target in one build configuration.

  xcode_settings.py <ios dir> <configuration> NAME...

Prints the value of each NAME on its own line, with its $(VAR)s expanded.
The configuration is matched ignoring case, as Flutter does; a configuration
the Runner target lacks is an error that lists the ones it has.

As in Xcode, the target's settings win over the target's xcconfig, then the
project's settings, then the project's xcconfig, and $(inherited) is the value
one level down. project.pbxproj is read with tools/xcodeproj2xtool.py's parser.
xcconfig files are read with read_xcconfig below: `//` starts a comment, `$()`
is empty, a later assignment wins, a missing `#include?` file is skipped, an
include cycle is cut by file, and conditional settings (`A[sdk=iphoneos*]`)
are skipped. gen-info-plist.py reads the same settings for Info.plist values.
"""
import os
import re
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "tools"))
import xcodeproj2xtool  # noqa: E402


def read_xcconfig(path, settings, seen=()):
    path = os.path.realpath(path)  # `./A.xcconfig`, `A.xcconfig` and a symlink to it are one file
    if path in seen or not os.path.isfile(path):
        return settings
    for line in open(path, errors="replace"):
        line = line.split("//", 1)[0].strip()
        inc = re.match(r'#include\??\s+"([^"]+)"', line)
        if inc:
            read_xcconfig(os.path.join(os.path.dirname(path), inc.group(1)), settings, seen + (path,))
            continue
        m = re.match(r"(\w+)\s*=\s*(.*)", line)
        if m:
            settings[m.group(1)] = m.group(2).replace("$(inherited)", "").replace("$()", "").strip()
    return settings


def expand(text, lookup, resolving=()):
    """$(NAME)s in text, each replaced by lookup(NAME), recursively."""
    def setting(m):
        name = m.group(1)
        if name in resolving:  # A = $(A), or A = $(B) and B = $(A): Xcode refuses these
            print(f"warning: $({name}) refers to itself; substituting empty", file=sys.stderr)
            return ""
        return expand(lookup(name), lookup, resolving + (name,))
    return re.sub(r"\$\((\w+)\)", setting, text)


class Settings:
    def __init__(self, ios_dir, configuration):
        gen = xcodeproj2xtool.Generator(os.path.join(ios_dir, "Runner.xcodeproj"), "Runner")
        _oid, target = gen.pick_target()
        cfg_list = gen.objs.get(target.get("buildConfigurationList"), {})
        names = [gen.objs[c].get("name") for c in cfg_list.get("buildConfigurations", [])]
        found = [n for n in names if n.lower() == configuration.lower()]
        if not found:
            raise SystemExit(f"error: the Runner target has no {configuration!r} build configuration "
                             f"(it has: {', '.join(names) or 'none'})")
        self.configuration = found[0]
        self.builtin = {"CONFIGURATION": self.configuration, "TARGET_NAME": "Runner",
                        "PROJECT_DIR": os.path.abspath(ios_dir), "SRCROOT": os.path.abspath(ios_dir)}
        self.layers = []  # lowest precedence first
        for owner in (gen.project, target):
            for layer in gen.config_layers(owner.get("buildConfigurationList"), self.configuration):
                if isinstance(layer, str):
                    layer = read_xcconfig(os.path.join(gen.proj_dir, layer), {})
                self.layers.append(layer)

    def raw(self, name, below=None):
        """The setting as the highest level that sets it writes it, $(inherited)
        filled in; None when no level sets it."""
        for i in reversed(range(len(self.layers) if below is None else below)):
            if name in self.layers[i]:
                value = self.layers[i][name]
                if isinstance(value, list):  # LD_RUNPATH_SEARCH_PATHS = ( ... )
                    value = " ".join(value)
                if "$(inherited)" in value:
                    value = value.replace("$(inherited)", self.raw(name, i) or "").strip()
                return value
        return self.builtin.get(name)

    def value(self, name):
        def lookup(ref):
            found = self.raw(ref)
            if found is None:
                print(f"warning: no value for $({ref}) in {name}; substituting empty", file=sys.stderr)
            return found or ""
        return expand(self.raw(name) or "", lookup, (name,))


if __name__ == "__main__":
    if len(sys.argv) < 4:
        sys.exit("usage: xcode_settings.py <ios dir> <configuration> NAME...")
    settings = Settings(sys.argv[1], sys.argv[2])
    for setting_name in sys.argv[3:]:
        print(settings.value(setting_name))
