# Mac 三套 31 条基准通过质量复测

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 02:58:26 US/Pacific。

当前项目提交 `e045e79d9ea8a2fd5cb2184a4a79105cba82c756`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025523-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025641-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025657-voxt-snapdragon-asr.md
?? benchmark/
?? patches/
?? scripts/prepare_benchmark.py
?? scripts/run_mlx_baseline.sh
```

- MLX 基准通过，.local/mac-baseline-full.exit=0，三组各 37 个结果（1 个预热、31 个主评测、5 个无偏置）。模型文件哈希全部通过。
- 三组主评测均为 29/946 编辑，错误率 3.066%，词典 7/10，去偏置 4/10，long 2.245%。固定 Q4/Q8 全集 avg_accept 为 3.428/3.448，clean 组均 6.286。Q4 Target 验证占三段总时间 81.92%。逐条文本有差异，待进一步确认。
- 独立 llama.cpp 构建及 GGUF 下载已结束，.local/build-probe.exit 和 .local/fetch-probe.exit 均为 0。

下一步：在固定 llama.cpp 上试跑相同公开 WAV 并核对输出
