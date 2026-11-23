#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
root="$PWD"
vendor="$root/.local/win-arm64"
mkdir -p "$vendor"
scratch=$(mktemp -d "$vendor/stage.XXXXXXXX")
trap 'rm -rf "$scratch"' EXIT

extract() {
  mkdir "$scratch/source"
  tar -xf "$1" --strip-components=1 -C "$scratch/source"
  mv "$scratch/source" "$2"
}

toolchain="$vendor/llvm-mingw-20261117"
if [[ ! -d "$toolchain" ]]; then
  archive=llvm-mingw-20261117-ucrt-macos-universal.tar.xz
  curl --fail --location --retry 3 -o "$scratch/$archive" \
    "https://github.com/mstorsjo/llvm-mingw/releases/download/20261117/$archive"
  printf '%s  %s\n' 98d340bbb8d46b09ad6886ffba88bd9d5415e131c316de48e6bd7647377446aa "$scratch/$archive" | shasum -a 256 -c -
  extract "$scratch/$archive" "$toolchain"
  rm "$scratch/$archive"
fi
export VOXT_LLVM_MINGW="$toolchain"
toolchain_file="$root/scripts/win-arm64/llvm-mingw.cmake"

fetch_khronos() {
  local repo="$1" revision="$2"
  if [[ ! -d "$vendor/$repo-$revision" ]]; then
    curl --fail --location --retry 3 -o "$scratch/source.tar.gz" \
      "https://codeload.github.com/KhronosGroup/$repo/tar.gz/$revision"
    extract "$scratch/source.tar.gz" "$vendor/$repo-$revision"
  fi
}

headers_revision=$(jq -er .opencl.headers.commit sources.lock.json)
loader_revision=$(jq -er .opencl.loader.commit sources.lock.json)
fetch_khronos OpenCL-Headers "$headers_revision"
fetch_khronos OpenCL-ICD-Loader "$loader_revision"
loader_build="$root/build/opencl-icd-arm64"
cmake -S "$vendor/OpenCL-ICD-Loader-$loader_revision" -B "$loader_build" \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" -DCMAKE_BUILD_TYPE=Release \
  -DOPENCL_ICD_LOADER_HEADERS_DIR="$vendor/OpenCL-Headers-$headers_revision" -DBUILD_TESTING=OFF \
  -DOPENCL_ICD_LOADER_BUILD_TESTING=OFF
cmake --build "$loader_build" --parallel "${BUILD_JOBS:-6}"
: "${VOXT_BUILD_DIR:=$root/build/windows-arm64-$(shasum -a 256 patches/llama-voxt.patch | cut -c1-12)}"
export VOXT_BUILD_DIR
scripts/build_voxt_backend.sh \
  -DCMAKE_TOOLCHAIN_FILE="$toolchain_file" -DGGML_NATIVE=OFF -DGGML_CPU_ARM_ARCH=armv8.2-a+dotprod \
  -DCMAKE_C_FLAGS="-D_WIN32_WINNT=0x0A00" -DCMAKE_CXX_FLAGS="-D_WIN32_WINNT=0x0A00" \
  -DGGML_OPENMP=OFF -DGGML_OPENCL=ON -DGGML_OPENCL_USE_ADRENO_KERNELS=ON \
  -DOpenCL_INCLUDE_DIR="$vendor/OpenCL-Headers-$headers_revision" -DOpenCL_LIBRARY="$loader_build/libOpenCL.dll.a" "$@"
