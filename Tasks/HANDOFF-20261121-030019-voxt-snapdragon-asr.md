# 已导出 F16 音频塔和因果 Draft，启动实际推理探针

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 03:00:19 US/Pacific。

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
?? benchmark/
?? patches/
?? scripts/convert_asr_models.py
?? scripts/prepare_benchmark.py
?? scripts/probe_transcription.py
?? scripts/run_mlx_baseline.sh
```

- Mac 重建 passed，.local/build-probe-pinned.exit=0，llama-server 和 llama-quantize 可用。源权重哈希检查与 F16 投影器、BF16 因果 Draft 导出均通过。
- Target-only 探针 running，PID 64635，Mac Metal，命令 python3 scripts/probe_transcription.py --wav .local/voxt-benchmark/Voxt/testdata/eval/zh-plain-1.wav --output .local/probe-target-f16 --projector .local/gguf-probe/mmproj-Qwen3-ASR-1.7B-f16.gguf，日志与退出文件 .local/probe-target-f16.log/.exit。成功门槛为收到完成事件和正确的样本正文。
- Draft Q4_0 量化 running，PID 64636，命令 build/llama-probe/bin/llama-quantize .local/gguf-probe/draft-bf16.gguf .local/gguf-probe/draft-q4_0.gguf Q4_0，日志和退出文件 .local/quantize-draft.log/.exit。成功门槛为可被上游运行时加载，并保留 d2t 映射。

下一步：确认上游 Target-only 转录和 Draft Q4_0 格式，随后跑相同音频的投机探针
