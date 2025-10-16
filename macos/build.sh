#!/usr/bin/env bash
set -euo pipefail

# Simple macOS-native FFmpeg build helper
# - Defaults to a minimal, fast build with Apple VideoToolbox
# - Optionally enables common libraries detected via pkg-config
# - Supports ARCH=arm64 or ARCH=x86_64 builds
# - Installs into ./macos/out[-${ARCH}] (overridable via OUT)
#
# Usage examples:
#   bash macos/build.sh                    # minimal, uses any libs already present
#   NONFREE=1 bash macos/build.sh          # also enable libfdk_aac if found
#   BRANCH=release/7.1 bash macos/build.sh # build a specific FFmpeg branch
#   OUT=$HOME/ffmpeg-macos bash macos/build.sh
#   ARCH=x86_64 bash macos/build.sh        # cross-build for Intel on Apple Silicon
#   UNIVERSAL=1 bash macos/build.sh        # lipo ffmpeg/ffprobe if both arch builds exist

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORK_DIR="${ROOT_DIR}/macos"
SRC_DIR="${WORK_DIR}/src"
FFMPEG_DIR="${SRC_DIR}/ffmpeg"
FFMPEG_REMOTE="https://github.com/FFmpeg/FFmpeg.git"
# Normalize ARCH input and pick output tag
ARCH_IN="${ARCH:-$(uname -m)}"
case "${ARCH_IN}" in
  arm64|aarch64)
    ARCH="arm64"; ARCH_TAG="arm64" ;;
  x86_64|x64|amd64)
    ARCH="x86_64"; ARCH_TAG="x64" ;;
  *)
    echo "Unknown ARCH=${ARCH_IN} (use arm64 or x86_64/x64)"; exit 2 ;;
esac

OUT_DEFAULT="${WORK_DIR}/out-${ARCH_TAG}"
OUT_DIR="${OUT:-${OUT_DEFAULT}}"
BRANCH="${BRANCH:-master}"
JOBS="${JOBS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

mkdir -p "${SRC_DIR}" "${OUT_DIR}"

echo "[macos-build] Arch: ${ARCH}"
echo "[macos-build] Output dir: ${OUT_DIR}"
echo "[macos-build] Branch: ${BRANCH}"

# Toolchain and Homebrew discovery per-arch
export CC=${CC:-clang}
export CXX=${CXX:-clang++}

DEPLOY="${DEPLOYMENT_TARGET:-${MACOSX_DEPLOYMENT_TARGET:-12.0}}"
export MACOSX_DEPLOYMENT_TARGET="${DEPLOY}"

if [[ "${ARCH}" == "arm64" ]]; then
  if command -v brew >/dev/null 2>&1; then
    BREW_PREFIX_ARM64="$(brew --prefix)"
    export PATH="${BREW_PREFIX_ARM64}/opt/llvm/bin:${PATH}"
    export PKG_CONFIG_PATH="${BREW_PREFIX_ARM64}/lib/pkgconfig:${BREW_PREFIX_ARM64}/opt/openssl@3/lib/pkgconfig:${BREW_PREFIX_ARM64}/opt/librist/lib/pkgconfig:${BREW_PREFIX_ARM64}/opt/libvmaf/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LDFLAGS="-L${BREW_PREFIX_ARM64}/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I${BREW_PREFIX_ARM64}/include ${CPPFLAGS:-}"
  fi
else
  # x86_64: prefer Intel Homebrew (Rosetta) prefix; override with BREW_X86_PREFIX
  if [[ -z "${BREW_X86_PREFIX:-}" ]]; then
    # Try common locations under Rosetta
    for CAND in \
      "/usr/local" \
      "/usr/local/homebrew" \
      "/opt/homebrew-intel"; do
      if [[ -d "${CAND}/Cellar" ]]; then BREW_X86_PREFIX="${CAND}"; break; fi
    done
  fi
  if [[ -n "${BREW_X86_PREFIX:-}" ]]; then
    export PATH="${BREW_X86_PREFIX}/opt/llvm/bin:${BREW_X86_PREFIX}/bin:${PATH}"
    export PKG_CONFIG_PATH="${BREW_X86_PREFIX}/lib/pkgconfig:${BREW_X86_PREFIX}/opt/openssl@3/lib/pkgconfig:${BREW_X86_PREFIX}/opt/librist/lib/pkgconfig:${BREW_X86_PREFIX}/opt/libvmaf/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
    export LDFLAGS="-L${BREW_X86_PREFIX}/lib ${LDFLAGS:-}"
    export CPPFLAGS="-I${BREW_X86_PREFIX}/include ${CPPFLAGS:-}"
  else
    echo "[macos-build] Warning: Intel Homebrew not found. x86_64 build will likely be minimal (framework-only)."
  fi
fi

# Force target arch flags
export CFLAGS="-arch ${ARCH} -mmacosx-version-min=${DEPLOY} ${CFLAGS:-}"
export CXXFLAGS="-arch ${ARCH} -mmacosx-version-min=${DEPLOY} ${CXXFLAGS:-}"
export LDFLAGS="-arch ${ARCH} -mmacosx-version-min=${DEPLOY} ${LDFLAGS:-}"

# Ensure FFmpeg source is the actual upstream, not this builder repo
ensure_ffmpeg_src() {
  if [[ -d "${FFMPEG_DIR}/.git" ]]; then
    local url
    url="$(git -C "${FFMPEG_DIR}" remote get-url origin 2>/dev/null || echo '')"
    if [[ "${url}" != *"FFmpeg/FFmpeg"* ]]; then
      echo "[macos-build] Existing ${FFMPEG_DIR} is not upstream FFmpeg (origin=${url}). Moving aside."
      local bak="${FFMPEG_DIR}.bad-$(date +%s)"
      mv "${FFMPEG_DIR}" "${bak}"
    fi
  elif [[ -d "${FFMPEG_DIR}" && ! -f "${FFMPEG_DIR}/configure" ]]; then
    echo "[macos-build] Existing ${FFMPEG_DIR} has no configure. Moving aside."
    local bak="${FFMPEG_DIR}.bad-$(date +%s)"
    mv "${FFMPEG_DIR}" "${bak}"
  fi

  if [[ ! -d "${FFMPEG_DIR}" ]]; then
    echo "[macos-build] Cloning FFmpeg upstream..."
    git clone --filter=blob:none --branch "${BRANCH}" "${FFMPEG_REMOTE}" "${FFMPEG_DIR}"
  else
    echo "[macos-build] Updating FFmpeg repo..."
    git -C "${FFMPEG_DIR}" fetch --depth=1 origin "${BRANCH}" || true
    git -C "${FFMPEG_DIR}" checkout -q "${BRANCH}" || true
    git -C "${FFMPEG_DIR}" reset --hard "origin/${BRANCH}" || true
  fi
}

ensure_ffmpeg_src

pushd "${FFMPEG_DIR}" >/dev/null

# Ensure a clean tree (avoid mixed-arch objects)
make distclean >/dev/null 2>&1 || true
git reset --hard -q || true
git clean -xdf -q || true

# Base options
CONF=(
  --prefix="${OUT_DIR}"
  --pkg-config-flags="--static"
  --enable-gpl
  --enable-version3
  --disable-debug
  --disable-doc
  --enable-videotoolbox
  --extra-version="$(date +%Y%m%d)-macos"
)

# Cross parameters for x86_64 on Apple Silicon (clang handles via -arch)
CONF+=( --arch="${ARCH}" --target_os=darwin )

# If building x86_64 on Apple Silicon without Rosetta, avoid running target tests
if [[ "${ARCH}" == "x86_64" ]]; then
  if ! arch -x86_64 /usr/bin/true >/dev/null 2>&1; then
    echo "[macos-build] Rosetta not detected; enabling cross-compile checks"
    CONF+=( --enable-cross-compile )
  fi
  if ! command -v nasm >/dev/null 2>&1 && ! command -v yasm >/dev/null 2>&1; then
    echo "[macos-build] nasm/yasm not found; disabling x86 asm optimizations"
    CONF+=( --disable-x86asm )
  fi
fi

# Helper: enable flag if pkg-config finds the lib
have_pc() { pkg-config --exists "$1" 2>/dev/null; }

# Common libs (enabled if present)
if have_pc libx264; then CONF+=( --enable-libx264 ); fi
if have_pc x265; then CONF+=( --enable-libx265 ); fi
if have_pc vpx; then CONF+=( --enable-libvpx ); fi
if have_pc libaom; then CONF+=( --enable-libaom ); fi
if have_pc dav1d; then CONF+=( --enable-libdav1d ); fi
if have_pc opus; then CONF+=( --enable-libopus ); fi
if have_pc vorbis; then CONF+=( --enable-libvorbis ); fi
if have_pc libvmaf; then CONF+=( --enable-libvmaf ); fi
if have_pc libass; then CONF+=( --enable-libass ); fi
if have_pc libsoxr; then CONF+=( --enable-libsoxr ); fi
if have_pc zimg; then CONF+=( --enable-libzimg ); fi
if have_pc libwebp; then CONF+=( --enable-libwebp ); fi
if have_pc openjpeg; then CONF+=( --enable-libopenjpeg ); fi
if have_pc rubberband; then CONF+=( --enable-librubberband ); fi
if have_pc srt; then CONF+=( --enable-libsrt ); fi
if have_pc librist; then CONF+=( --enable-librist ); fi
if have_pc libbluray; then CONF+=( --enable-libbluray ); fi
if have_pc libsvtav1; then CONF+=( --enable-libsvtav1 ); fi

# Optional nonfree AAC encoder
if [[ "${NONFREE:-0}" == "1" ]] && have_pc fdk-aac; then
  CONF+=( --enable-nonfree --enable-libfdk_aac )
fi

echo "[macos-build] Configure flags: ${CONF[*]}"

./configure "${CONF[@]}"
make -j"${JOBS}"
make install

echo "[macos-build] Done. Binaries in: ${OUT_DIR}/bin"
ls -la "${OUT_DIR}/bin" || true

popd >/dev/null

# Optional universal merge (requires both out-arm64 and out-x86_64 present)
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARM_DIR="${OUT:-${WORK_DIR}/out-arm64}"
  X86_DIR="${OUT:-${WORK_DIR}/out-x64}"
  FAT_DIR="${WORK_DIR}/out-universal"
  mkdir -p "${FAT_DIR}/bin"
  for BIN in ffmpeg ffprobe ffplay; do
    if [[ -x "${ARM_DIR}/bin/${BIN}" && -x "${X86_DIR}/bin/${BIN}" ]]; then
      echo "[macos-build] Creating universal ${BIN}"
      lipo -create -output "${FAT_DIR}/bin/${BIN}" "${ARM_DIR}/bin/${BIN}" "${X86_DIR}/bin/${BIN}" || true
      chmod +x "${FAT_DIR}/bin/${BIN}" || true
    fi
  done
  echo "[macos-build] Universal merge complete (framework-only builds recommended). Output: ${FAT_DIR}/bin"
fi

# Package per-arch zip with ffmpeg and ffprobe
ART_DIR="${ROOT_DIR}/artifacts"
ZIP_NAME="ffmpeg-darwin-${ARCH_TAG}.zip"
mkdir -p "${ART_DIR}"
if [[ -x "${OUT_DIR}/bin/ffmpeg" && -x "${OUT_DIR}/bin/ffprobe" ]]; then
  echo "[macos-build] Packaging ${ART_DIR}/${ZIP_NAME}"
  ( cd / && zip -j -9 "${ART_DIR}/${ZIP_NAME}" "${OUT_DIR}/bin/ffmpeg" "${OUT_DIR}/bin/ffprobe" )
else
  echo "[macos-build] Warning: ffmpeg/ffprobe not found at ${OUT_DIR}/bin; skipping zip"
fi
