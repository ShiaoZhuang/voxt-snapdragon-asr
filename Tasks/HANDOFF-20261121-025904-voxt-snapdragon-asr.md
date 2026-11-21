# 确认长音频标点差异并重建具有正确版本标识的 llama.cpp

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 02:59:04 US/Pacific。

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
?? benchmark/
?? patches/
?? scripts/prepare_benchmark.py
?? scripts/probe_transcription.py
?? scripts/run_mlx_baseline.sh
```

- 三组共有 30/31 逐条转录正文完全一致。唯一差异为 long-zh 的两处逗号，Q4 和 Q8 输出彼此一致，首个分段 metadata 的 token 数为 139 对 142。
- 构建生成的上游探针曾错误显示父目录 Git SHA，已显式传入锁定的 llama.cpp 提交。Mac 重建 running，PID 64138，命令 ./scripts/build_upstream_probe.sh，.local/build-probe-pinned.log，退出文件 .local/build-probe-pinned.exit。

下一步：用相同中文样本验证上游 Target-only 路径
