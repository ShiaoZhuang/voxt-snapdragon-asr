# Metal 上相同 ASR 样本完成 Target-only 与 Q4 DFlash 推理

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 03:01:38 US/Pacific。

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
?? Tasks/HANDOFF-20261121-030046-voxt-snapdragon-asr.md
?? benchmark/
?? patches/
?? scripts/convert_asr_models.py
?? scripts/prepare_benchmark.py
?? scripts/probe_transcription.py
?? scripts/run_mlx_baseline.sh
```

- Metal Draft 探针 passed，.local/probe-draft-q4.exit=0。与 Target-only 的原始完成事件正文完全相同。上游日志实际接受 15/21，三轮 avg_accept=5.00、含 anchor 的 avg_step=6.00。
- Mac Oryon 对照前先补 Apple CPU reference，PID 64778。命令 python3 scripts/probe_transcription.py --cpu，分别加入或省略 --draft .local/gguf-probe/draft-q4_0.gguf，见 .local/probe-cpu.log/.exit 和 .local/probe-cpu-{plain,draft}/。门槛为两组完成且正文一致。

下一步：完成 CPU 样本复核与 ARM64 验证程序交叉构建检查
