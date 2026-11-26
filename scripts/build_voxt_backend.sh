#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
revision=$(jq -er .llama_cpp.commit sources.lock.json)
patch_sha=$(shasum -a 256 patches/llama-voxt.patch | cut -d ' ' -f 1)
source_dir=".local/llama-voxt-${revision:0:8}-${patch_sha:0:12}"
if [[ ! -d "$source_dir" ]]; then
  mkdir -p .local
  stage=$(mktemp -d .local/llama-voxt-stage.XXXXXXXX)
  trap 'rm -rf "$stage"' EXIT
  mkdir "$stage/source"
  upstream=".local/llama-${revision:0:8}"
  if [[ -f "$upstream/.source-revision" && "$(cat "$upstream/.source-revision")" == "$revision" ]]; then
    (cd "$upstream" && tar -cf - .) | tar -xf - -C "$stage/source"
  else
    curl --fail --location --retry 3 -o "$stage/source.tar.gz" "https://codeload.github.com/ggml-org/llama.cpp/tar.gz/$revision"
    tar -xzf "$stage/source.tar.gz" --strip-components=1 -C "$stage/source"
  fi
  GIT_CEILING_DIRECTORIES="$(cd "$stage" && pwd -P)" git -C "$stage/source" apply --no-index "$PWD/patches/llama-voxt.patch"
  mv "$stage/source" "$source_dir"
fi
build_dir="${VOXT_BUILD_DIR:-build/voxt-${patch_sha:0:12}}"
cmake -S "$source_dir" -B "$build_dir" -DCMAKE_BUILD_TYPE=Release \
  -DLLAMA_BUILD_COMMIT="$revision" -DLLAMA_BUILD_NUMBER=0 \
  -DLLAMA_VOXT_SOURCE="$PWD/native" -DLLAMA_BUILD_TESTS=OFF \
  -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_TOOLS=ON -DLLAMA_BUILD_SERVER=ON \
  -DLLAMA_BUILD_BORINGSSL=OFF -DLLAMA_OPENSSL=OFF -DLLAMA_BUILD_UI=OFF -DLLAMA_USE_PREBUILT_UI=OFF "$@"
cmake --build "$build_dir" --target qwen3_asr_server --parallel "${BUILD_JOBS:-6}"
