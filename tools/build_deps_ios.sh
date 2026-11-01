#!/bin/bash
# make ios-deps: the libraries the iOS app links, built from pinned sources as static libraries for an iOS SDK into
# build/deps-<sdk> (SDK=iphonesimulator, the default, or iphoneos): SDL3, zstd, and FFmpeg with what the games' movies
# need (as tools/build_deps_macos.sh: LGPL only - WebM / MP4, VP9 / VP8 / Vorbis / Opus / H.264 / AAC, swscale).
# IOS_MIN: the oldest iOS to run on (default 17.0). Needs: Xcode, cmake, ninja. Each step is skipped when its output
# exists (delete build/deps-<sdk>/lib/<lib> to redo).
set -euo pipefail
cd "$(dirname "$0")/.."
SDK=${SDK:-iphonesimulator}
MIN=${IOS_MIN:-17.0}
P=$PWD/build/deps-$SDK
S=$PWD/build/deps-src
mkdir -p "$S" "$P/lib" "$P/include"
SYSROOT=$(xcrun --sdk "$SDK" --show-sdk-path)
CC=$(xcrun --sdk "$SDK" --find clang)
TARGET=arm64-apple-ios$MIN$([ "$SDK" = iphonesimulator ] && echo -simulator)
JOBS=$(sysctl -n hw.ncpu)

fetch() {  # url sha256 file
    [ -f "$S/$3" ] || curl -fsSL -o "$S/$3.part" "$1" && { [ -f "$S/$3" ] || mv "$S/$3.part" "$S/$3"; }
    echo "$2  $S/$3" | shasum -a 256 -c --quiet
}
unpack() { rm -rf "$S/$2" && mkdir -p "$S/$2" && tar -xf "$S/$1" -C "$S/$2" --strip-components 1; }

fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.18/SDL3-3.4.18.tar.gz \
      9c75cf16330322c217dedd2e0609f1124f1b54b8633e763467b4684d0f4334a3 SDL3-3.4.18.tar.gz
fetch https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz \
      8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e ffmpeg-9.0.2.tar.xz
fetch https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz \
      eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3 zstd-1.5.7.tar.gz

CMAKE_IOS=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$P" -DCMAKE_SYSTEM_NAME=iOS
           -DCMAKE_OSX_SYSROOT="$SDK" -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MIN")

if [ ! -f "$P/lib/libSDL3.a" ]; then
    unpack SDL3-3.4.18.tar.gz sdl-$SDK
    cmake -S "$S/sdl-$SDK" -B "$S/sdl-$SDK/build" "${CMAKE_IOS[@]}" -DSDL_SHARED=OFF -DSDL_STATIC=ON \
          -DSDL_TESTS=OFF -DSDL_EXAMPLES=OFF -DSDL_INSTALL_DOCS=OFF
    cmake --build "$S/sdl-$SDK/build" -j"$JOBS" && cmake --install "$S/sdl-$SDK/build"
fi

if [ ! -f "$P/lib/libzstd.a" ]; then
    unpack zstd-1.5.7.tar.gz zstd-$SDK
    cmake -S "$S/zstd-$SDK/build/cmake" -B "$S/zstd-$SDK/out" "${CMAKE_IOS[@]}" -DZSTD_BUILD_SHARED=OFF \
          -DZSTD_BUILD_STATIC=ON -DZSTD_BUILD_PROGRAMS=OFF -DZSTD_BUILD_TESTS=OFF
    cmake --build "$S/zstd-$SDK/out" -j"$JOBS" && cmake --install "$S/zstd-$SDK/out"
fi

if [ ! -f "$P/lib/libavcodec.a" ]; then
    unpack ffmpeg-9.0.2.tar.xz ffmpeg-$SDK
    (cd "$S/ffmpeg-$SDK" && ./configure --prefix="$P" --enable-cross-compile --target-os=darwin --arch=arm64 \
        --cc="$CC" --sysroot="$SYSROOT" --extra-cflags="-target $TARGET" --extra-ldflags="-target $TARGET" \
        --enable-static --disable-shared \
        --disable-autodetect --disable-programs --disable-doc --disable-network --disable-avdevice --disable-avfilter \
        --disable-swresample --disable-everything \
        --enable-protocol=file --enable-demuxer=matroska,mov \
        --enable-decoder=vp9,vp8,vorbis,opus,h264,aac --enable-parser=vp9,vp8,vorbis,opus,h264,aac \
        && make -j"$JOBS" && make install)
fi
echo "deps for $SDK ($TARGET) in $P"
