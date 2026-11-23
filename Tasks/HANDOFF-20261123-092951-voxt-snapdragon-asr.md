# 骁龙前 27 层 HTP 通过，最后一层重建门槛失败

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 09:29:51 US/Pacific。

当前项目提交 `bc6f9c01ca3a646f62c1d8a71324338cb0e4f2ee`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

截图中 Windows 实机提交 `bc6f9c0` 报告 28 层采集及转录成功、已完成的 HTP 与 CPU 均 27/28。前 27 层 QAIRT 648 个执行事件，逐层热态中位数合计 109.53 ms。零基 27 在生成图后、调用 CPU/HTP 之前触发 dense 重建 3% 相对 L2 门槛。第 0 层两张图和八项 KV 可见性诊断均通过。截图无实际末层重建误差与各边界值，根因仍待同步证实。

下一步：验证第 27 层原生各边界与数值基线，并让固定脚本输出完整的末层 HTP、logits 和诊断。
