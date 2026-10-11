"""Hermetic AppImage repacking tests; no GUI, downloads or game files."""

import importlib.util
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True

spec = importlib.util.spec_from_file_location(
    "repack", Path(__file__).resolve().parents[1] / "repack-appimage.py")
repack = importlib.util.module_from_spec(spec)
spec.loader.exec_module(repack)


class RepackTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="appimage tests ")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / "Rimmerge.AppImage"
        self.image.write_bytes(b"original image")
        self.image.chmod(0o755)
        self.plugin = self.root / "plugin"
        self.plugin.touch()
        self.source = self.root / "source"
        for name in ("AppRun", "Rimmerge.desktop", "usr/bin/rimmerge-desktop",
                     "usr/lib/Rimmerge/LICENSE-MIT", "usr/lib/Rimmerge/LICENSE-APACHE",
                     "usr/lib/libwayland-client.so.0", "usr/lib/libglib-2.0.so.0",
                     "usr/lib/libgio-2.0.so.0.8000.0", "usr/lib/libwebkit2gtk-4.1.so.0"):
            path = self.source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(name.encode())
            if name in ("AppRun", "usr/bin/rimmerge-desktop"):
                path.chmod(0o755)
        for name in ("libmount.so.1", "libblkid.so.1", "libpcre2-8.so.0", "libffi.so.8"):
            (self.source / "usr/lib" / name).touch()
        (self.source / "usr/lib/libgio-2.0.so.0").symlink_to("libgio-2.0.so.0.8000.0")
        self.packed = self.root / "packed"

    def fake_run(self, arguments, cwd, env=None):
        if arguments[1] == "--appimage-offset":
            return SimpleNamespace(stdout=b"4\n")
        if arguments[1] == "--appimage-extract":
            source = self.source if Path(arguments[0]) == self.image else self.packed
            shutil.copytree(source, cwd / "squashfs-root", symlinks=True)
        else:
            self.assertEqual(Path(env["LDAI_RUNTIME_FILE"]).read_bytes(), b"orig")
            source = Path(arguments[2].split("=", 1)[1])
            shutil.copytree(source, self.packed, symlinks=True)
            Path(env["LDAI_OUTPUT"]).write_bytes(b"new image")

    def assert_original_preserved(self):
        self.assertEqual(self.image.read_bytes(), b"original image")
        self.assertFalse(list(self.root.glob("repack-*")))

    def test_success_removes_libraries_and_symlinks_preserves_payload(self):
        with patch.object(repack, "run", side_effect=self.fake_run):
            repack.repack(self.image, self.plugin)
        self.assertEqual(self.image.read_bytes(), b"new image")
        self.assertFalse(repack.host_libraries(self.packed))
        for name in ("usr/lib/libwebkit2gtk-4.1.so.0", "usr/bin/rimmerge-desktop",
                     "usr/lib/Rimmerge/LICENSE-MIT", "usr/lib/Rimmerge/LICENSE-APACHE"):
            self.assertEqual((self.source / name).read_bytes(), (self.packed / name).read_bytes())
        self.assertTrue(self.image.stat().st_mode & 0o111)

    def test_failed_repacker_preserves_original_and_cleans_partial(self):
        def fail(arguments, cwd, env=None):
            if env:
                Path(env["LDAI_OUTPUT"]).write_bytes(b"partial")
                raise subprocess.CalledProcessError(42, arguments)
            return self.fake_run(arguments, cwd, env)
        with patch.object(repack, "run", side_effect=fail):
            with self.assertRaises(subprocess.CalledProcessError):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()

    def test_missing_output_rejected(self):
        def missing(arguments, cwd, env=None):
            if not env:
                return self.fake_run(arguments, cwd)
        with patch.object(repack, "run", side_effect=missing):
            with self.assertRaisesRegex(RuntimeError, "no AppImage"):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()

    def test_reintroduced_library_rejected(self):
        def reintroduce(arguments, cwd, env=None):
            result = self.fake_run(arguments, cwd, env)
            if env:
                (self.packed / "usr/lib/libwayland-client.so.0").touch()
            return result
        with patch.object(repack, "run", side_effect=reintroduce):
            with self.assertRaisesRegex(RuntimeError, "still contains"):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()

    def test_missing_license_rejected(self):
        (self.source / "usr/lib/Rimmerge/LICENSE-MIT").unlink()
        with patch.object(repack, "run", side_effect=self.fake_run):
            with self.assertRaisesRegex(RuntimeError, "missing license"):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()

    def test_changed_executable_rejected(self):
        def change(arguments, cwd, env=None):
            result = self.fake_run(arguments, cwd, env)
            if env:
                (self.packed / "usr/bin/rimmerge-desktop").write_bytes(b"changed")
            return result
        with patch.object(repack, "run", side_effect=change):
            with self.assertRaisesRegex(RuntimeError, "changed the desktop"):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()

    def test_changed_license_rejected(self):
        def change(arguments, cwd, env=None):
            result = self.fake_run(arguments, cwd, env)
            if env:
                (self.packed / "usr/lib/Rimmerge/LICENSE-MIT").write_bytes(b"changed")
            return result
        with patch.object(repack, "run", side_effect=change):
            with self.assertRaisesRegex(RuntimeError, "changed license"):
                repack.repack(self.image, self.plugin)
        self.assert_original_preserved()


if __name__ == "__main__":
    unittest.main()
