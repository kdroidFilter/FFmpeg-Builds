macOS Native Build
==================

This repo’s Docker workflow doesn’t support macOS targets, so this helper builds FFmpeg natively on macOS.

Quick start
- Ensure Xcode Command Line Tools: `xcode-select --install` (once)
- Optional: install common libraries with Homebrew (recommended):
  - `brew install pkg-config nasm yasm cmake meson ninja libvmaf libass libvorbis opus libvpx aom dav1d x264 x265 libsoxr zimg libwebp openjpeg rubberband srt librist libbluray`
  - For nonfree AAC (optional): `brew install fdk-aac` and run with `NONFREE=1`
- Build:
  - Minimal/features-auto: `bash macos/build.sh`
  - With nonfree AAC: `NONFREE=1 bash macos/build.sh`
  - Specific FFmpeg branch: `BRANCH=release/7.1 bash macos/build.sh`
  - Custom prefix: `OUT=$HOME/ffmpeg-macos bash macos/build.sh`
  - Intel target on Apple Silicon: `ARCH=x86_64 BREW_X86_PREFIX=/usr/local bash macos/build.sh`
    - Note: install Intel Homebrew + deps under Rosetta first, e.g. `arch -x86_64 /usr/bin/ruby ...` (or follow Homebrew docs), then `arch -x86_64 /usr/local/bin/brew install ...`
  - Build both and lipo (framework-only advised):
    - `ARCH=arm64 bash macos/build.sh && ARCH=x86_64 BREW_X86_PREFIX=/usr/local bash macos/build.sh && UNIVERSAL=1 bash macos/build.sh`
  - Set minimum macOS version: `DEPLOYMENT_TARGET=12.0 bash macos/build.sh`

Output
- Binaries land in `macos/out-<arch>/bin` (or your custom `OUT` path)
- Examples: `macos/out-arm64/bin/ffmpeg`, `macos/out-x64/bin/ffprobe`

Notes
- The script auto-detects available libraries via `pkg-config` and enables them if present.
- VideoToolbox (hardware accel) is enabled by default on macOS.
- Static linking of Homebrew libs on macOS is generally not available; this produces a shared/dynamic build.
- This doesn’t replicate the Linux/Windows Docker builds 1:1, but yields a practical FFmpeg for macOS.
- Universal (fat) binaries require that any linked dynamic libraries are also universal. If your Homebrew deps are per-arch, prefer shipping two separate builds: `macos/out-arm64` and `macos/out-x64`.
