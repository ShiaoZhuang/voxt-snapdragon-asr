# Q8_0 Target 和 F16 音频塔完成上游样本转录

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 03:00:46 US/Pacific。

当前项目提交 `e045e79d9ea8a2fd5cb2184a4a79105cba82c756`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/build_upstream_probe.sh
?? Tasks/HANDOFF-20261121-025523-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025641-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025657-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025826-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025904-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-030019-voxt-snapdragon-asr.md
?? benchmark/
?? patches/
?? scripts/convert_asr_models.py
?? scripts/prepare_benchmark.py
?? scripts/probe_transcription.py
?? scripts/run_mlx_baseline.sh
```

- Metal 上游 Target-only 探针 passed（.local/probe-target-f16.exit=0）。zh-plain-1 去除 language Chinese<asr_text> 后等于 MLX 参考。实测这条 SSE 路径仍会泄漏前缀，且无 Voxt generation_metadata。
- Draft Q4_0 量化 passed（.local/quantize-draft.exit=0），691.96 MiB BF16 权重输出约 219.12 MiB。尚待加载和接收检查。
- 同一 WAV 的 Metal + Draft 探针 running，PID 64678，命令 scripts/probe_transcription.py --wav .local/voxt-benchmark/Voxt/testdata/eval/zh-plain-1.wav --output .local/probe-draft-q4 --projector .local/gguf-probe/mmproj-Qwen3-ASR-1.7B-f16.gguf --draft .local/gguf-probe/draft-q4_0.gguf。日志与退出文件 .local/probe-draft-q4.log/.exit，门槛为完成转录且上游记录实际提议与接受。

下一步：检查因果 Q4_0 Draft 的实际接收长度和输出一致性
