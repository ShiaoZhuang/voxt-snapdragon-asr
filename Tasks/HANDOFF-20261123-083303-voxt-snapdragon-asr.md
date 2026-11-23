# 真实八位置 attention 和完整 FFN 均在骁龙 HTP 通过

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:33:03 US/Pacific。

当前项目提交 `e935d5cbd5e431d97cb764fe3b24eda216873c33`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

- `e935d5c` 在骁龙总体 PASS，实际验证位置 109–116，每个 query 可见 110–117 个 KV 位置。
- Windows FP16 CPU 的 attention 参考未达标，内部 FP32 对照通过。Attention HTP 与稳定 CPU 参考相对 L2 约 0.164%，正常退出，QAIRT 后端事件 216，30 次热态主机往返中位数约 1.08 ms。完整 FFN 再次通过。
- 该实机结果覆盖分开的完整 FFN 与 post-RoPE attention 两个子图。后续用一张混合精度子图串联，测跨算子的误差和延迟。

下一步：将同一真实批次的 KV 追加、attention、输出投影、残差、FFN norm 和 FFN 接成一个子图回放。
