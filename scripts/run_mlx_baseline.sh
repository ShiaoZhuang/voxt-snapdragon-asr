#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ $# -lt 2 || $# -gt 3 ]]; then
  echo "usage: $0 MLX_SERVER OUTPUT_DIRECTORY [CLIP_ID]" >&2
  exit 2
fi
export SNAPDRAGON_MLX_SERVER="$1"
if [[ ! -x "$SNAPDRAGON_MLX_SERVER" ]]; then
  echo "missing MLX server: $SNAPDRAGON_MLX_SERVER" >&2
  exit 2
fi
output="$2"
mkdir "$output"
output=$(cd "$output" && pwd)
model_root="${VOXT_MODEL_ROOT:-$HOME/Library/Application Support/SGLang Omni/models}"
target_name=mlx-community/Qwen3-ASR-1.7B-8bit
draft_name=wilsonzheng0327/Qwen3-ASR-1.7B-dflash
snapshot() {
  local repo="$1" revision directory filename sha
  revision=$(jq -er --arg repo "$repo" '.mlx_models[$repo].revision' sources.lock.json)
  directory="$model_root/models--${repo//\//--}/snapshots/$revision"
  while IFS=$'\t' read -r filename sha; do
    printf '%s  %s\n' "$sha" "$directory/$filename" | shasum -a 256 -c - >&2 || return 1
  done < <(jq -er --arg repo "$repo" '.mlx_models[$repo].files | to_entries[] | [.key,.value] | @tsv' sources.lock.json)
  printf '%s\n' "$directory"
}
target=$(snapshot "$target_name")
draft=$(snapshot "$draft_name")
launcher="$output/mlx-server"
cat > "$launcher" <<'LAUNCHER'
#!/usr/bin/env bash
exec "$SNAPDRAGON_MLX_SERVER" "$@" --draft-policy fixed
LAUNCHER
chmod +x "$launcher"
eval_dir=.local/voxt-benchmark/Voxt/testdata/eval
for mode in target-only draft-q4 draft-q8; do
  args=(-binary "$launcher" -target "$target" -eval "$eval_dir" -only "${3:-}")
  case "$mode" in
    draft-q4) args+=(-draft "$draft" -draft-bits 4) ;;
    draft-q8) args+=(-draft "$draft" -draft-bits 8) ;;
  esac
  ./build/final-benchmark "${args[@]}" \
    > "$output/$mode.jsonl" 2> "$output/$mode.log"
done
