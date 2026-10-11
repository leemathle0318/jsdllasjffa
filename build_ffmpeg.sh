#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
VERSION=7.1.5
SHA256=de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f
[ "$(uname -s)" = Darwin ] || { echo 'This dependency build requires macOS + Xcode.'; exit 1; }
SDK="${IOS_SDK_PATH:-$(xcrun --sdk iphoneos --show-sdk-path)}"
[ -d "$SDK" ] || { echo "Missing iOS SDK: $SDK"; exit 1; }
CC="$(xcrun --find clang)"
AR="$(xcrun --find ar)"
RANLIB="$(xcrun --find ranlib)"
LIPO="$(xcrun --find lipo)"
MAKE="${MAKE_BIN:-make}"
JOBS="$(sysctl -n hw.ncpu)"
mkdir -p work vendor/ffmpeg/lib vendor/ffmpeg/share/licenses
TARBALL="$ROOT/work/ffmpeg-$VERSION.tar.xz"
if [ ! -f "$TARBALL" ]; then
  curl --fail --location --retry 3 "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz" -o "$TARBALL"
fi
printf '%s  %s\n' "$SHA256" "$TARBALL" | shasum -a 256 -c -
if [ ! -d "work/ffmpeg-$VERSION" ]; then tar -xJf "$TARBALL" -C work; fi
SOURCE="$ROOT/work/ffmpeg-$VERSION"
for ARCH in arm64 arm64e; do
  BUILD="$ROOT/work/ffmpeg-build-$ARCH"
  PREFIX="$ROOT/work/ffmpeg-install-$ARCH"
  mkdir -p "$BUILD"
  (
    cd "$BUILD"
    "$SOURCE/configure" \
      --prefix="$PREFIX" --target-os=darwin --arch=aarch64 --enable-cross-compile \
      --cc="$CC" --ar="$AR" --ranlib="$RANLIB" --sysroot="$SDK" \
      --extra-cflags="-arch $ARCH -miphoneos-version-min=15.0 -fPIC" \
      --extra-ldflags="-arch $ARCH -miphoneos-version-min=15.0" \
      --disable-everything --disable-autodetect --disable-network \
      --disable-programs --disable-doc --disable-debug --disable-shared --enable-static \
      --disable-asm --enable-pic --disable-avdevice --disable-avfilter --disable-postproc \
      --enable-avcodec --enable-avformat --enable-avutil --enable-swscale --enable-swresample \
      --enable-decoder=h264,aac --enable-parser=h264,aac --enable-demuxer=mpegts \
      --enable-videotoolbox --enable-hwaccel=h264_videotoolbox
    "$MAKE" -j"$JOBS"
    "$MAKE" install
  )
done
cp -R work/ffmpeg-install-arm64/include vendor/ffmpeg/
for LIB in avformat avcodec swscale swresample avutil; do
  "$LIPO" -create "work/ffmpeg-install-arm64/lib/lib$LIB.a" \
      "work/ffmpeg-install-arm64e/lib/lib$LIB.a" -output "vendor/ffmpeg/lib/lib$LIB.a"
  "$LIPO" -info "vendor/ffmpeg/lib/lib$LIB.a"
done
cp "$SOURCE/COPYING.LGPLv2.1" vendor/ffmpeg/share/licenses/
cp "$SOURCE/LICENSE.md" vendor/ffmpeg/share/licenses/
echo "FFmpeg $VERSION (LGPL configuration, H.264 + AAC decode only), SHA256 $SHA256"
