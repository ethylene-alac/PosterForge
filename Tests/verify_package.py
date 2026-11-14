from pathlib import Path
import plistlib
import sys

package, control = map(Path, sys.argv[1:])
assert sorted(p.name for p in package.iterdir()) == ["var"], "Unexpected rootful payload"
assert sorted(p.name for p in (package / "var").iterdir()) == ["jb"], "Payload must stay under /var/jb"
daemon = package / "var/jb/usr/libexec/posterforged"
prefs = package / "var/jb/Library/PreferenceBundles/PosterForgePrefs.bundle/PosterForgePrefs"
assert daemon.is_file() and prefs.is_file()
with (package / "var/jb/Library/LaunchDaemons/com.posterforge.daemon.plist").open("rb") as stream:
    launch = plistlib.load(stream)
assert launch["ProgramArguments"] == ["/var/jb/usr/libexec/posterforged"]
assert launch["UserName"] == "root"
for name in ("postinst", "prerm"):
    script = control / name
    assert script.stat().st_mode & 0o111, f"{name} must be executable"
    assert script.read_bytes().startswith(b"#!/bin/sh\n") and b"\r\n" not in script.read_bytes()
print("Rootless package layout and maintainer scripts verified")
