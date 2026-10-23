"""Build a minimal FFmpeg 8.1.2 avfilter and package a native Windows vimg runtime.

Only avfilter is replaced; all other supplied runtime DLLs are copied unchanged.
Requires Git Bash, MinGW GCC/make and NASM. Builds/caches stay in --build-root;
the output directory must be new. Does not alter PATH, installations or releases.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile
import urllib.request

VERSION = "8.1.2"
SOURCE_URL = f"https://ffmpeg.org/releases/ffmpeg-{VERSION}.tar.xz"
SOURCE_SHA256 = "464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c"
FLAGS = ["--target-os=mingw32", "--arch=x86_64", "--cc=gcc", "--disable-everything",
         "--disable-autodetect", "--disable-programs", "--disable-doc", "--disable-debug",
         "--enable-shared", "--disable-static", "--disable-avcodec", "--disable-avformat",
         "--disable-avdevice", "--disable-swresample", "--disable-network", "--enable-avfilter",
         "--enable-swscale", "--enable-filter=buffer,buffersink,scale,format",
         "--disable-pthreads", "--enable-w32threads",
         "--extra-ldflags=-static-libgcc -Wl,--no-insert-timestamp"]
LIBRARIES = {"avfilter-11.dll": ("avfilter", [11, 14, 102]),
             "avcodec-62.dll": ("avcodec", [62, 28, 102]),
             "avformat-62.dll": ("avformat", [62, 12, 102]),
             "avutil-60.dll": ("avutil", [60, 26, 102]),
             "swscale-9.dll": ("swscale", [9, 5, 102])}
FILTERS = {"buffer", "buffersink", "abuffer", "abuffersink", "scale", "format"}


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def inspect_runtime(directory):
    result = {}
    with os.add_dll_directory(str(directory.resolve())):
        for filename, (prefix, expected) in LIBRARIES.items():
            lib = ctypes.CDLL(str((directory / filename).resolve()))
            version_fn = getattr(lib, prefix + "_version")
            version_fn.restype = ctypes.c_uint
            value = version_fn()
            version = [value >> 16, (value >> 8) & 255, value & 255]
            if version != expected:
                raise RuntimeError(f"{filename}: expected {expected}, found {version}")
            result[filename] = {"version": version, "sha256": digest(directory / filename)}
            if prefix == "avfilter":
                lib.avfilter_configuration.restype = ctypes.c_char_p
                result[filename]["configuration"] = lib.avfilter_configuration().decode()
                # AVFilter starts with its public name pointer.
                lib.av_filter_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
                lib.av_filter_iterate.restype = ctypes.c_void_p
                state = ctypes.c_void_p()
                names = []
                while pointer := lib.av_filter_iterate(ctypes.byref(state)):
                    names.append(ctypes.cast(pointer, ctypes.POINTER(ctypes.c_char_p))[0].decode())
                result[filename]["filters"] = sorted(names)
    return result


def inspect(directory):
    # Separate processes prevent Windows from reusing DLLs from a prior runtime.
    return json.loads(subprocess.check_output([sys.executable, "-B", "-X", "utf8", __file__,
                                               "--inspect", str(directory)]))


def unix_path(path):
    path = path.resolve().as_posix()
    if len(path) < 3 or path[1:3] != ":/":
        raise ValueError("Build paths must be local Windows drive paths")
    return "/" + path[0].lower() + path[2:]


def short_path(path):
    buffer = ctypes.create_unicode_buffer(32768)
    if not ctypes.windll.kernel32.GetShortPathNameW(str(path.resolve()), buffer, len(buffer)):
        raise ctypes.WinError()
    return buffer.value.replace("\\", "/")


def build_filter(args):
    root = args.build_root.resolve()
    if any(c.isspace() for c in str(root)):
        raise ValueError("MinGW make requires --build-root without spaces")
    root.mkdir(parents=True, exist_ok=True)
    archive = root / f"ffmpeg-{VERSION}.tar.xz"
    if not archive.exists():
        download = archive.with_suffix(".download")
        with urllib.request.urlopen(SOURCE_URL, timeout=60) as response, download.open("wb") as stream:
            shutil.copyfileobj(response, stream)
        if digest(download) != SOURCE_SHA256:
            raise RuntimeError("Downloaded FFmpeg source checksum mismatch")
        download.rename(archive)
    if digest(archive) != SOURCE_SHA256:
        raise RuntimeError("Cached FFmpeg source checksum mismatch")
    source = root / f"ffmpeg-{VERSION}"
    build = root / "filter-build"
    marker = root / "build-inputs.json"
    inputs = {"source_sha256": SOURCE_SHA256, "flags": FLAGS,
              "compiler": subprocess.check_output([str(args.mingw_bin / "gcc.exe"), "--version"], text=True).splitlines()[0],
              "nasm": subprocess.check_output([str(args.nasm), "-v"], text=True).strip()}
    if marker.exists():
        if json.loads(marker.read_text()) != inputs:
            raise RuntimeError("Build inputs changed; choose a new --build-root")
    else:
        if build.exists() or source.exists():
            raise FileExistsError("Unmanaged build directory exists; choose a new --build-root")
        with tarfile.open(archive) as package:
            package.extractall(root, filter="data")
        build.mkdir()
        env = os.environ.copy()
        env["PATH"] = os.pathsep.join(map(str, [args.mingw_bin, args.nasm.parent, args.bash.parent])) + os.pathsep + env["PATH"]
        command = " ".join(shlex.quote(value) for value in [unix_path(source / "configure"), *FLAGS])
        with (root / "configure.log").open("w") as log:
            subprocess.run([str(args.bash), "-c", command], cwd=build, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        # Configure emits MSYS paths; native MinGW make needs Windows paths in
        # its includes/VPATH. Change generated files, never upstream sources.
        for relative in ["Makefile", "ffbuild/config.mak"]:
            path = build / relative
            path.write_text(path.read_text().replace(unix_path(source), source.as_posix()), newline="\n")
        marker.write_text(json.dumps(inputs, indent=2))
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(map(str, [args.mingw_bin, args.nasm.parent, args.bash.parent])) + os.pathsep + env["PATH"]
    with (root / "make.log").open("w") as log:
        subprocess.run([str(args.mingw_bin / "make.exe"), f"-j{args.jobs}",
                        "SHELL=" + short_path(args.bash.with_name("sh.exe")), "libavfilter/avfilter-11.dll"],
                       cwd=build, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    return build / "libavfilter/avfilter-11.dll", inputs


def main():
    if os.name != "nt":
        raise RuntimeError("This packaging profile targets Windows x64")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", required=True, type=Path)
    parser.add_argument("--runtime-dir", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    parser.add_argument("--build-root", type=Path, default=Path("target/preview-ffmpeg"))
    parser.add_argument("--bash", type=Path, default=Path("C:/Program Files/Git/usr/bin/bash.exe"))
    parser.add_argument("--mingw-bin", type=Path, default=Path("D:/Scoop/apps/mingw/current/bin"))
    parser.add_argument("--nasm", type=Path, default=Path("D:/Scoop/apps/nasm/current/nasm.exe"))
    parser.add_argument("--jobs", type=int, choices=range(1, 33), default=4)
    parser.add_argument("--filter-dll", type=Path, help="Package an already-built minimal DLL; still validate its ABI and filter set")
    args = parser.parse_args()
    for name in ["exe", "runtime_dir", "output_dir", "build_root", "bash", "mingw_bin", "nasm"]:
        setattr(args, name, getattr(args, name).resolve())
    if args.output_dir.exists():
        raise FileExistsError("Output directory must be new")
    original = inspect(args.runtime_dir)
    if args.filter_dll:
        library, inputs = args.filter_dll.resolve(), {"prebuilt_filter": str(args.filter_dll.resolve())}
    else:
        library, inputs = build_filter(args)
    args.output_dir.mkdir(parents=True)
    # Keep a clear incomplete marker if validation fails; no partial package is
    # presented as ready and no existing package/install is overwritten.
    incomplete = args.output_dir / "INCOMPLETE"
    incomplete.write_text("Runtime validation has not completed.\n")
    for source in args.runtime_dir.glob("*.dll"):
        shutil.copy2(source, args.output_dir / source.name)
    shutil.copy2(library, args.output_dir / "avfilter-11.dll")
    shutil.copy2(args.exe, args.output_dir / "vimg.exe")
    actual = inspect(args.output_dir)
    if set(actual["avfilter-11.dll"]["filters"]) != FILTERS:
        raise RuntimeError("Minimal avfilter has an unexpected filter set")
    for filename in LIBRARIES:
        if filename != "avfilter-11.dll" and actual[filename] != original[filename]:
            raise RuntimeError(f"Unexpected core-library change: {filename}")
    output = subprocess.check_output([str(args.output_dir / "vimg.exe"), "--version"], text=True).strip()
    manifest = {"vimg_version": output, "ffmpeg_source": SOURCE_URL, "ffmpeg_source_sha256": SOURCE_SHA256,
                "build_inputs": inputs, "runtime": actual,
                "files": {p.name: {"sha256": digest(p), "bytes": p.stat().st_size}
                          for p in args.output_dir.iterdir() if p.suffix in (".exe", ".dll")}}
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (args.output_dir / "FFMPEG-SOURCE.txt").write_text(
        f"FFmpeg {VERSION}: {SOURCE_URL}\nSHA-256: {SOURCE_SHA256}\n"
        "Minimal avfilter: LGPL-2.1-or-later. Other DLLs retain their supplied build/licenses.\n"
        "Build flags and library configuration are recorded in manifest.json.\n")
    incomplete.unlink()
    print(f"Validated runtime: {args.output_dir}")
    print(f"avfilter: {(args.runtime_dir / 'avfilter-11.dll').stat().st_size} -> {library.stat().st_size} bytes")


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--inspect":
        print(json.dumps(inspect_runtime(Path(sys.argv[2]))))
    else:
        main()
