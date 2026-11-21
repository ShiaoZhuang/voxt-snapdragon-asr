# 修复 macOS Bash 3 的空数组问题并重跑 MLX 基准

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 02:56:57 US/Pacific。

当前项目提交 `e045e79d9ea8a2fd5cb2184a4a79105cba82c756`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025523-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025641-voxt-snapdragon-asr.md
?? benchmark/
?? patches/
?? scripts/prepare_benchmark.py
?? scripts/run_mlx_baseline.sh
```

- 首次脚本运行 failed，退出码 1，原因是系统 Bash 3 在 nounset 下展开空数组。模型哈希已全部通过。已用固定参数初始化数组并重试。
- Mac 基准 running，PID 63935，命令 ./scripts/run_mlx_baseline.sh /private/tmp/voxt-omni-build/runtime/bin/qwen3_asr_server .local/mac-baseline-full，日志 .local/mac-baseline-full.log 和输出目录同名，退出码文件 .local/mac-baseline-full.exit。成功门槛是三种模式各 31 条主评测与 5 条无偏置。
- llama.cpp 构建 passed，GGUF 下载此前仍在执行，见前序检查点。相邻基准仓库 HEAD 和已有 Capture.swift 修改未动。

下一步：汇总 Mac 三组基准和 llama.cpp 同样本探针
