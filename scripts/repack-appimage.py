#!/usr/bin/env python3
"""Keep host Wayland and GLib/GIO libraries out of the Tauri AppImage.

Run after Tauri bundling, before package-linux.ps1/checksums. Reuses the
linuxdeploy output plugin downloaded by Tauri; does not download tools.
See https://github.com/tauri-apps/tauri/issues/15665.
"""

import argparse
import fnmatch
import os
from pathlib import Path
import subprocess
import sys
import tempfile


# Host Mesa uses host Wayland. Host GIO modules (including GVFS/portals)
# require matching GLib symbols. Keep the GLib family together.
HOST_LIBRARIES = (
    "libwayland-client.so*", "libwayland-cursor.so*",
    "libwayland-egl.so*", "libwayland-server.so*",
    "libglib-2.0.so*", "libgobject-2.0.so*", "libgio-2.0.so*",
    "libgmodule-2.0.so*", "libgthread-2.0.so*",
    # Host GLib/GIO must also use their supporting libraries. In particular,
    # recent GIO needs MOUNT_2_40, absent from Ubuntu 24.04's bundled libmount.
    "libmount.so*", "libblkid.so*", "libpcre2-8.so*", "libffi.so*",
)


def host_libraries(appdir):
    return sorted(
        path for path in appdir.rglob("*")
        if (path.is_file() or path.is_symlink())
        and any(fnmatch.fnmatchcase(path.name, pattern) for pattern in HOST_LIBRARIES)
    )


def validate_appdir(appdir):
    for name in ("AppRun", "Rimmerge.desktop", "usr/bin/rimmerge-desktop"):
        if not (appdir / name).is_file():
            raise RuntimeError(f"missing AppImage payload: {name}")
    for name in ("AppRun", "usr/bin/rimmerge-desktop"):
        if not (appdir / name).stat().st_mode & 0o111:
            raise RuntimeError(f"not executable: {name}")
    for name in ("LICENSE-MIT", "LICENSE-APACHE"):
        if not any(path.is_file() for path in appdir.rglob(name)):
            raise RuntimeError(f"missing license: {name}")


def run(arguments, cwd, env=None):
    output = subprocess.PIPE if arguments[1] == "--appimage-offset" else None
    if arguments[1] == "--appimage-extract":
        output = subprocess.DEVNULL
    return subprocess.run(arguments, cwd=cwd, env=env, check=True, stdout=output)


def repack(image, plugin):
    image, plugin = image.resolve(), plugin.resolve()
    if not image.is_file() or not plugin.is_file():
        raise RuntimeError("AppImage and linuxdeploy output plugin must exist")
    # The temporary output is on the same filesystem for atomic replacement.
    with tempfile.TemporaryDirectory(prefix="repack-", dir=image.parent) as temp:
        scratch = Path(temp)
        # Reuse the runtime already supplied by Tauri, rather than downloading
        # an unpinned continuous runtime when invoking appimagetool again.
        offset = int(run([str(image), "--appimage-offset"], scratch).stdout.strip())
        if offset <= 0 or offset >= image.stat().st_size:
            raise RuntimeError("invalid AppImage filesystem offset")
        runtime = scratch / "runtime-x86_64"
        with image.open("rb") as source:
            runtime.write_bytes(source.read(offset))
        run([str(image), "--appimage-extract"], scratch)
        appdir = scratch / "squashfs-root"
        validate_appdir(appdir)
        payload = (appdir / "usr/bin/rimmerge-desktop").read_bytes()
        licenses = {
            path.relative_to(appdir): path.read_bytes()
            for name in ("LICENSE-MIT", "LICENSE-APACHE")
            for path in appdir.rglob(name) if path.is_file()
        }
        for path in host_libraries(appdir):
            print(f"Use host library: {path.relative_to(appdir)}")
            path.unlink()
        if host_libraries(appdir):
            raise RuntimeError("host libraries remain in AppDir")
        output = scratch / image.name
        env = os.environ.copy()
        env.update(LDAI_OUTPUT=str(output), LDAI_RUNTIME_FILE=str(runtime), ARCH="x86_64")
        run([str(plugin), "--appimage-extract-and-run", f"--appdir={appdir}"], scratch, env)
        if not output.is_file() or output.stat().st_size == 0:
            raise RuntimeError("repacker produced no AppImage")
        output.chmod(image.stat().st_mode | 0o111)
        verification = scratch / "verification"
        verification.mkdir()
        run([str(output), "--appimage-extract"], verification)
        verified = verification / "squashfs-root"
        validate_appdir(verified)
        if host_libraries(verified):
            raise RuntimeError("repacked AppImage still contains host libraries")
        if (verified / "usr/bin/rimmerge-desktop").read_bytes() != payload:
            raise RuntimeError("repacker changed the desktop executable")
        for relative, content in licenses.items():
            if not (verified / relative).is_file() or (verified / relative).read_bytes() != content:
                raise RuntimeError(f"repacker changed license: {relative}")
        os.replace(output, image)
    print(f"Repacked and verified: {image}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=Path)
    cache = Path(os.environ.get("XDG_CACHE_HOME", Path.home() / ".cache"))
    parser.add_argument("--plugin", type=Path,
                        default=cache / "tauri/linuxdeploy-plugin-appimage.AppImage")
    args = parser.parse_args()
    if not sys.platform.startswith("linux"):
        parser.error("AppImage repacking requires Linux")
    repack(args.image, args.plugin)


if __name__ == "__main__":
    main()
