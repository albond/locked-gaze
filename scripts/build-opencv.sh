#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
version=4.12.0
digest=44c106d5bb47efec04e531fd93008b3fcd1d27138985c5baf4eafac0e1ec9e9d
mkdir -p build/deps
archive="build/deps/opencv-$version.tar.gz"
if [[ ! -f "$archive" ]]; then
    curl -L --fail --silent --show-error "https://github.com/opencv/opencv/archive/refs/tags/$version.tar.gz" -o "$archive"
fi
[[ "$(shasum -a 256 "$archive" | cut -d ' ' -f1)" == "$digest" ]] || { echo "OpenCV archive checksum mismatch" >&2; exit 1; }
if [[ ! -d "build/deps/opencv-$version" ]]; then tar -xzf "$archive" -C build/deps; fi
cmake -S "build/deps/opencv-$version" -B build/deps/opencv-build \
    -DCMAKE_INSTALL_PREFIX="$PWD/build/deps/opencv" -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 \
    -DBUILD_LIST=core,imgproc,calib3d -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTS=OFF -DBUILD_PERF_TESTS=OFF -DBUILD_EXAMPLES=OFF \
    -DBUILD_opencv_apps=OFF -DBUILD_JAVA=OFF -DBUILD_opencv_python3=OFF \
    -DWITH_IPP=OFF -DWITH_ITT=OFF -DWITH_OPENCL=OFF \
    -DWITH_FFMPEG=OFF -DWITH_AVFOUNDATION=OFF > build/deps/configure.log 2>&1
cmake --build build/deps/opencv-build --parallel 6 > build/deps/compile.log 2>&1
cmake --install build/deps/opencv-build > build/deps/install.log 2>&1
echo "OpenCV $version static arm64 build ready"
