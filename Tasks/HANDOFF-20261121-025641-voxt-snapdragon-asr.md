# llama.cpp 在 Mac 构建通过，MLX Final 基准启动

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 02:56:41 US/Pacific。

当前项目提交 `e045e79d9ea8a2fd5cb2184a4a79105cba82c756`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025523-voxt-snapdragon-asr.md
?? benchmark/
?? patches/
?? scripts/prepare_benchmark.py
?? scripts/run_mlx_baseline.sh
```

- build_upstream_probe.sh finished passed，.local/build-probe.exit 为 0，build/llama-probe/bin/llama-server 已生成。
- prepare_benchmark.py 从锁定提交准备 Voxt，sha256 校验 29 个 WAV 和 clips.json，Go 编译 passed。通过 Voxt 真实客户端观察 SSE 完成事件。
- Mac Apple Silicon 基准 running，命令 ./scripts/run_mlx_baseline.sh /private/tmp/voxt-omni-build/runtime/bin/qwen3_asr_server .local/mac-baseline，见 .local/mac-baseline.log、.local/mac-baseline.exit 及 .local/mac-baseline/*.jsonl。成功门槛为 Target-only、固定 Q4、固定 Q8 各 31 条主评测和 5 条无偏置对照。
- GGUF 模型下载仍在运行，日志和门槛同前一检查点。相邻基准仓库 HEAD 与 Capture.swift 已有改动见上一记录。

下一步：核对三组每组 31 条结果，并用同一中文样本验证 llama.cpp 音频链路
