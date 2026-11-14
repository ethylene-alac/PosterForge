"""Host integration tests execute the real Objective-C scanner and ZIP importer.

Run Tests/run-host-tests.sh on macOS. Portable packaging checks also run on Windows.
All container/archive fixtures are synthetic and live in temporary directories.
"""
import io
import json
import os
from pathlib import Path
import plistlib
import stat
import struct
import subprocess
import tempfile
import unittest
import uuid
import zipfile

ROOT = Path(__file__).resolve().parents[1]
BIN = os.environ.get("PF_HOST_TEST_BIN")


class PackagingTests(unittest.TestCase):
    def test_daemon_entitlements_and_launch_identity(self):
        with (ROOT / "Entitlements.plist").open("rb") as stream:
            entitlements = plistlib.load(stream)
        for key in ("platform-application", "com.apple.private.security.no-container",
                    "com.apple.private.security.no-sandbox", "com.apple.private.security.storage.AppDataContainers"):
            self.assertIs(entitlements[key], True)
        with (ROOT / "layout/Library/LaunchDaemons/com.posterforge.daemon.plist").open("rb") as stream:
            launch = plistlib.load(stream)
        self.assertEqual(launch["UserName"], "root")
        self.assertEqual(launch["ProgramArguments"], ["/var/jb/usr/libexec/posterforged"])
        self.assertEqual(launch["Umask"], 0o22)

    def test_package_version_arch_and_script_line_endings(self):
        control = dict(line.split(": ", 1) for line in (ROOT / "control").read_text().splitlines())
        with (ROOT / "Preferences/Resources/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        self.assertEqual(control["Version"], info["CFBundleShortVersionString"])
        self.assertEqual(control["Architecture"], "iphoneos-arm64")
        for path in (ROOT / "layout/DEBIAN").iterdir():
            self.assertTrue(path.read_bytes().startswith(b"#!/bin/sh\n"), path.name)
            self.assertNotIn(b"\r\n", path.read_bytes())


@unittest.skipUnless(BIN, "Objective-C harness requires macOS; use Tests/run-host-tests.sh")
class RuntimeTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)

    def run_harness(self, *args):
        run = subprocess.run([BIN, *map(str, args)], capture_output=True, text=True, check=False)
        self.assertIn(run.returncode, (0, 1), f"Harness exited abnormally: {run.returncode}\n{run.stderr}")
        self.assertTrue(run.stdout.strip(), f"Harness returned no JSON: {run.stderr}")
        result = json.loads(run.stdout)
        self.assertEqual(run.returncode, 0 if result["success"] else 1, run.stderr)
        return result

    def container(self, identifier="com.apple.PosterBoard", malformed=False):
        path = self.root / str(uuid.uuid4()).upper()
        path.mkdir()
        meta = path / ".com.apple.mobile_container_manager.metadata.plist"
        meta.write_bytes(b"not a plist" if malformed else plistlib.dumps({"MCMMetadataIdentifier": identifier}))
        return path

    def test_random_uuid_container_lookup(self):
        self.container("com.example.unrelated")
        expected = self.container()
        (self.root / "not-a-uuid").mkdir()
        result = self.run_harness("scan", self.root)
        self.assertTrue(result["success"])
        self.assertEqual(Path(result["value"]), expected)

    def test_duplicate_matching_containers_rejected(self):
        self.container()
        self.container()
        result = self.run_harness("scan", self.root)
        self.assertFalse(result["success"])
        self.assertIn("Multiple", result["error"])

    def test_missing_base_preserves_enumeration_error(self):
        result = self.run_harness("scan", self.root / "missing")
        self.assertFalse(result["success"])
        self.assertIn("enumerate", result["error"])

    def test_corrupt_or_missing_metadata_reported(self):
        path = self.container(malformed=True)
        result = self.run_harness("scan", self.root)
        self.assertIn("invalid", result["error"])
        (path / ".com.apple.mobile_container_manager.metadata.plist").unlink()
        result = self.run_harness("scan", self.root)
        self.assertIn("could not be read", result["error"])

    def test_unreadable_metadata_reported(self):
        if os.geteuid() == 0:
            self.skipTest("permission test must run as an unprivileged user")
        path = self.container()
        meta = path / ".com.apple.mobile_container_manager.metadata.plist"
        meta.chmod(0)
        self.addCleanup(meta.chmod, 0o600)
        result = self.run_harness("scan", self.root)
        self.assertFalse(result["success"])
        self.assertIn("could not be read", result["error"])

    @staticmethod
    def descriptor(prefix="descriptors/Example"):
        return {
            prefix + "/com.apple.posterkit.provider.descriptor.identifier": b"12345",
            prefix + "/com.apple.posterkit.role.identifier": b"PRPosterRoleLockScreen",
            prefix + "/versions/1/contents/Example.wallpaper/Wallpaper.plist": plistlib.dumps({"identifier": 12345}),
        }

    def archive(self, files, compression=zipfile.ZIP_DEFLATED):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w", compression=compression) as archive:
            for name, value in files.items():
                archive.writestr(name, value)
        return buffer.getvalue()

    def import_bytes(self, data):
        path = self.root / (str(uuid.uuid4()) + ".tendies")
        path.write_bytes(data)
        return self.run_harness("archive", path, self.root / (str(uuid.uuid4()) + "-stage"))

    def test_descriptor_and_descriptors_stored_and_deflated(self):
        for name in ("descriptor", "descriptors", "Wrapper/DeScRiPtOrS"):
            for compression in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                with self.subTest(name=name, compression=compression):
                    files = self.descriptor(name + "/Example")
                    files[name + "/"] = b""
                    result = self.import_bytes(self.archive(files, compression))
                    self.assertTrue(result["success"], result)
                    self.assertEqual(len(result["value"]), 1)

    def test_container_and_mixed_formats_rejected(self):
        for prefix in ("Container/Library/descriptors/Example", "wrapper/container/Example"):
            files = self.descriptor(prefix)
            files.update(self.descriptor())
            result = self.import_bytes(self.archive(files))
            self.assertFalse(result["success"])
            self.assertIn("Container-format", result["error"])

    def test_substring_and_unsupported_provider_formats_rejected(self):
        for group in ("not-descriptors", "video-descriptors", "ordered-descriptors"):
            self.assertFalse(self.import_bytes(self.archive(self.descriptor(group + "/Example")))["success"])

    def test_path_traversal_absolute_and_control_paths_rejected(self):
        for path in ("../escape", "/tmp/escape", "a/../../escape", "a\\escape", "a//escape", "a/./escape", "C:/escape", "a/\nescape"):
            files = self.descriptor()
            files[path] = b"should never be written"
            with self.subTest(path=path):
                self.assertFalse(self.import_bytes(self.archive(files))["success"])
        self.assertFalse((self.root.parent / "escape").exists())

    def test_symlink_case_collision_and_file_parent_rejected(self):
        for mode in (stat.S_IFLNK | 0o777, stat.S_IFIFO | 0o600):
            buffer = io.BytesIO()
            with zipfile.ZipFile(buffer, "w") as archive:
                info = zipfile.ZipInfo("descriptors/link")
                info.create_system = 3
                info.external_attr = mode << 16
                archive.writestr(info, "/tmp/escape")
            self.assertFalse(self.import_bytes(buffer.getvalue())["success"])
        for files in ({"a": b"x", "A": b"y"}, {"a": b"x", "a/child": b"y"}):
            self.assertFalse(self.import_bytes(self.archive(files))["success"])

    def test_invalid_layout_corrupt_data_and_local_header_mismatch(self):
        self.assertFalse(self.import_bytes(self.archive({"descriptors/Bad/random": b"x"}))["success"])
        self.assertFalse(self.import_bytes(b"not a zip")["success"])
        data = bytearray(self.archive(self.descriptor(), zipfile.ZIP_STORED))
        name_length, extra_length = struct.unpack_from("<HH", data, 26)
        data[30 + name_length + extra_length] ^= 1
        self.assertIn("checksum", self.import_bytes(data)["error"])
        data = bytearray(self.archive(self.descriptor()))
        data[30] ^= 1
        self.assertIn("headers disagree", self.import_bytes(data)["error"])

    def test_randomization_preserves_nested_asset_references(self):
        files = self.descriptor()
        wallpaper = "descriptors/Example/versions/1/contents/Example.wallpaper/Wallpaper.plist"
        user_info = "descriptors/Example/versions/1/contents/com.apple.posterkit.provider.contents.userInfo"
        nested = {"lockAndHome": {"default": {"identifier": 987, "reference": "keep-me"}}}
        files[wallpaper] = plistlib.dumps({"identifier": 12345, "assets": nested})
        files[user_info] = plistlib.dumps({"wallpaperRepresentingIdentifier": "12345", "wallpaperRepresentingFileName": "Example.wallpaper"})
        result = self.import_bytes(self.archive(files))
        self.assertTrue(result["success"])
        descriptor = Path(result["value"][0])
        result = self.run_harness("randomize", descriptor, 54321)
        self.assertTrue(result["success"])
        self.assertEqual((descriptor / "com.apple.posterkit.provider.descriptor.identifier").read_text(), "54321")
        with (descriptor / "versions/1/contents/Example.wallpaper/Wallpaper.plist").open("rb") as stream:
            updated = plistlib.load(stream)
        self.assertEqual(updated["identifier"], 54321)
        self.assertEqual(updated["assets"], nested)
        with (descriptor / "versions/1/contents/com.apple.posterkit.provider.contents.userInfo").open("rb") as stream:
            updated = plistlib.load(stream)
        self.assertEqual(str(updated["wallpaperRepresentingIdentifier"]), "54321")
        self.assertEqual(updated["wallpaperRepresentingFileName"], "Example.wallpaper")

    def test_randomization_rejects_corrupt_metadata(self):
        files = self.descriptor()
        files["descriptors/Example/versions/1/contents/Example.wallpaper/Wallpaper.plist"] = b"bad plist"
        result = self.import_bytes(self.archive(files))
        self.assertTrue(result["success"])
        self.assertFalse(self.run_harness("randomize", result["value"][0], 54321)["success"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
