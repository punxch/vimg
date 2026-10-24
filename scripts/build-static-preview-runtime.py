"""Build a private FFmpeg 8.1.2 runtime for vimg-preview on Windows x64.

This package is only for the static helper, never for vimg/VCS. Outputs must be
new directories; neither global installations nor the full runtime are changed.
"""
import argparse
import ctypes
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import tarfile

spec = importlib.util.spec_from_file_location("runtime", Path(__file__).with_name("build-preview-runtime.py"))
runtime = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runtime)

FLAGS = ["--target-os=mingw32", "--arch=x86_64", "--cc=gcc", "--disable-everything",
         "--disable-autodetect", "--disable-programs", "--disable-doc", "--disable-debug",
         "--enable-shared", "--disable-static", "--disable-avdevice", "--disable-swresample",
         "--disable-network", "--enable-avcodec", "--enable-avformat", "--enable-avfilter",
         "--enable-swscale", "--enable-decoder=h264,hevc,mjpeg", "--enable-encoder=mjpeg",
         "--enable-parser=h264,hevc,mjpeg", "--enable-demuxer=matroska,mov",
         "--enable-protocol=file", "--enable-filter=buffer,buffersink,scale,format",
         "--disable-pthreads", "--enable-w32threads",
         "--extra-ldflags=-static-libgcc -Wl,--no-insert-timestamp"]
TARGETS = {"avcodec-62.dll": "libavcodec", "avformat-62.dll": "libavformat",
           "avutil-60.dll": "libavutil", "swscale-9.dll": "libswscale",
           "avfilter-11.dll": "libavfilter"}


def inspect(directory):
    result = runtime.inspect_runtime(directory)
    with os.add_dll_directory(str(directory)):
        codec = ctypes.CDLL(str(directory / "avcodec-62.dll"))
        codec.av_codec_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        codec.av_codec_iterate.restype = ctypes.c_void_p
        for name in ["av_codec_is_decoder", "av_codec_is_encoder"]:
            getattr(codec, name).argtypes = [ctypes.c_void_p]
        decoder, encoder, state = [], [], ctypes.c_void_p()
        while pointer := codec.av_codec_iterate(ctypes.byref(state)):
            name = ctypes.cast(pointer, ctypes.POINTER(ctypes.c_char_p))[0].decode()
            if codec.av_codec_is_decoder(pointer):
                decoder.append(name)
            if codec.av_codec_is_encoder(pointer):
                encoder.append(name)
        fmt = ctypes.CDLL(str(directory / "avformat-62.dll"))
        fmt.av_demuxer_iterate.argtypes = [ctypes.POINTER(ctypes.c_void_p)]
        fmt.av_demuxer_iterate.restype = ctypes.c_void_p
        demuxer, state = [], ctypes.c_void_p()
        while pointer := fmt.av_demuxer_iterate(ctypes.byref(state)):
            demuxer.append(ctypes.cast(pointer, ctypes.POINTER(ctypes.c_char_p))[0].decode())
    result["components"] = dict(decoders=sorted(decoder), encoders=sorted(encoder), demuxers=sorted(demuxer))
    return result


def build(args):
    root = args.build_root
    if any(c.isspace() for c in str(root)):
        raise ValueError("MinGW make requires a build root without spaces")
    if runtime.digest(args.source_archive) != runtime.SOURCE_SHA256:
        raise RuntimeError("FFmpeg source archive checksum mismatch")
    root.mkdir(parents=True, exist_ok=True)
    source = root / f"ffmpeg-{runtime.VERSION}"
    directory = root / "build"
    marker = root / "build-inputs.json"
    inputs = {"source_sha256": runtime.SOURCE_SHA256, "flags": FLAGS,
              "compiler": subprocess.check_output([str(args.mingw_bin / "gcc.exe"), "--version"], text=True).splitlines()[0],
              "nasm": subprocess.check_output([str(args.nasm), "-v"], text=True).strip()}
    env = os.environ.copy()
    env["PATH"] = os.pathsep.join(map(str, [args.mingw_bin, args.nasm.parent, args.bash.parent])) + os.pathsep + env["PATH"]
    if marker.exists():
        if json.loads(marker.read_text()) != inputs:
            raise RuntimeError("Build inputs changed; choose a new build root")
    else:
        if source.exists() or directory.exists():
            raise FileExistsError("Unmanaged build directory; choose a new build root")
        with tarfile.open(args.source_archive) as archive:
            archive.extractall(root, filter="data")
        directory.mkdir()
        command = " ".join(shlex.quote(value) for value in [runtime.unix_path(source / "configure"), *FLAGS])
        with (root / "configure.log").open("w") as log:
            subprocess.run([str(args.bash), "-c", command], cwd=directory, env=env,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        for relative in ["Makefile", "ffbuild/config.mak"]:
            path = directory / relative
            path.write_text(path.read_text().replace(runtime.unix_path(source), source.as_posix()), newline="\n")
        marker.write_text(json.dumps(inputs, indent=2))
    with (root / "make.log").open("w") as log:
        subprocess.run([str(args.mingw_bin / "make.exe"), f"-j{args.jobs}",
                        "SHELL=" + runtime.short_path(args.bash.with_name("sh.exe")),
                        *[f"{parent}/{name}" for name, parent in TARGETS.items()]],
                       cwd=directory, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    return directory, inputs


def main():
    if os.name != "nt":
        raise RuntimeError("This package targets Windows x64")
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, required=True)
    parser.add_argument("--source-archive", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--build-root", type=Path, default=Path("target/static-preview-ffmpeg"))
    parser.add_argument("--bash", type=Path, default=Path("C:/Program Files/Git/usr/bin/bash.exe"))
    parser.add_argument("--mingw-bin", type=Path, default=Path("D:/Scoop/apps/mingw/current/bin"))
    parser.add_argument("--nasm", type=Path, default=Path("D:/Scoop/apps/nasm/current/nasm.exe"))
    parser.add_argument("--jobs", type=int, choices=range(1, 33), default=4)
    args = parser.parse_args()
    for name in ["exe", "source_archive", "output_dir", "build_root", "bash", "mingw_bin", "nasm"]:
        setattr(args, name, getattr(args, name).resolve())
    if args.output_dir.exists():
        raise FileExistsError("Output directory must be new")
    build_dir, inputs = build(args)
    args.output_dir.mkdir(parents=True)
    incomplete = args.output_dir / "INCOMPLETE"
    incomplete.write_text("Static runtime validation has not completed.\n")
    for name, parent in TARGETS.items():
        shutil.copy2(build_dir / parent / name, args.output_dir / name)
    # MinGW's clock_gettime implementation pulls in its small pthread runtime,
    # even though FFmpeg itself uses native Windows decoder threads.
    shutil.copy2(args.mingw_bin / "libwinpthread-1.dll", args.output_dir / "libwinpthread-1.dll")
    shutil.copy2(args.mingw_bin.parent / "licenses/winpthreads/COPYING",
                 args.output_dir / "COPYING.winpthreads")
    shutil.copy2(args.build_root / f"ffmpeg-{runtime.VERSION}/COPYING.LGPLv2.1",
                 args.output_dir / "COPYING.LGPLv2.1")
    shutil.copy2(args.exe, args.output_dir / "vimg-preview.exe")
    actual = json.loads(subprocess.check_output([sys.executable, "-B", "-X", "utf8", __file__,
                                                "--inspect", str(args.output_dir)], text=True))
    if set(actual["avfilter-11.dll"]["filters"]) != runtime.FILTERS:
        raise RuntimeError("Unexpected static preview filter set")
    if actual["components"] != dict(decoders=["h264", "hevc", "mjpeg"], encoders=["mjpeg"],
                                     demuxers=["matroska,webm", "mov,mp4,m4a,3gp,3g2,mj2"]):
        raise RuntimeError("Unexpected static preview codec/container set")
    version = subprocess.check_output([str(args.output_dir / "vimg-preview.exe"), "--version"], text=True).strip()
    if not version.startswith("vimg-preview "):
        raise ValueError("Use the vimg-preview helper, not the full vimg executable")
    inputs = dict(inputs, mingw_runtime_sha256=runtime.digest(args.output_dir / "libwinpthread-1.dll"))
    manifest = {"helper_version": version, "scope": "static-preview-only; never load with vimg/VCS",
                "ffmpeg_source": runtime.SOURCE_URL, "build_inputs": inputs, "runtime": actual,
                "files": {p.name: {"sha256": runtime.digest(p), "bytes": p.stat().st_size}
                          for p in args.output_dir.iterdir() if p.suffix in (".exe", ".dll")}}
    (args.output_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    (args.output_dir / "FFMPEG-SOURCE.txt").write_text(
        f"FFmpeg {runtime.VERSION}: {runtime.SOURCE_URL}\nSHA-256: {runtime.SOURCE_SHA256}\n"
        "Static-preview-only runtime; LGPL-2.1-or-later.\n"
        "Build flags and toolchain are recorded in manifest.json.\n")
    incomplete.unlink()
    print(f"Validated static runtime: {args.output_dir}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--inspect":
        print(json.dumps(inspect(Path(sys.argv[2]).resolve())))
    else:
        main()
