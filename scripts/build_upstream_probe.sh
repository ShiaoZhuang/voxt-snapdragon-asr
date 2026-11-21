#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=$(jq -er .llama_cpp.commit sources.lock.json)
source_dir=".local/llama-${revision:0:8}"
if [[ ! -f "$source_dir/.source-revision" ]]; then
  tarball="$source_dir.tar.gz"
  curl --fail --location --retry 3 -o "$tarball" "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$revision"
  mkdir -p "$source_dir"
  tar -xzf "$tarball" --strip-components=1 -C "$source_dir"
  printf '%s\n' "$revision" > "$source_dir/.source-revision"
  rm "$tarball"
fi
cmake -S "$source_dir" -B build/llama-probe -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON \
  -DLLAMA_BUILD_SERVER=ON -DLLAMA_BUILD_BORINGSSL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_WEBUI=OFF
cmake --build build/llama-probe --target llama-server --parallel "${BUILD_JOBS:-6}"
