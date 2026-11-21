#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
repo=$(jq -er .gguf_probe.repo sources.lock.json)
revision=$(jq -er .gguf_probe.revision sources.lock.json)
directory=.local/gguf-probe
mkdir -p "$directory"
while IFS=$'\t' read -r name sha; do
  path="$directory/$name"
  if [[ -f "$path" ]] && printf '%s  %s\n' "$sha" "$path" | shasum -a 256 -c -; then
    continue
  fi
  curl --fail --location --retry 3 -C - -o "$path.part" "https://huggingface.co/$repo/resolve/$revision/$name"
  printf '%s  %s\n' "$sha" "$path.part" | shasum -a 256 -c -
  mv "$path.part" "$path"
done < <(jq -er '.gguf_probe.files | to_entries[] | [.key,.value] | @tsv' sources.lock.json)
