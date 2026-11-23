# 骁龙 FFN 复测通过，attention 停在 Windows CPU 对照

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:17:34 US/Pacific。

当前项目提交 `a071fe83bf427c08fa2c0176a0c10391cb341ae9`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

- 骁龙 2026-11-24 00:13 Asia/Shanghai，在 `a071fe8` 的同次采集、构建、转录均通过。完整 FFN 热态中位数/P95 为 1.827/1.974 ms，QAIRT 事件 216，HTP 相对同图 CPU 的 L2 为 0.0354%，正常退出。
- Attention 捕获的 256 个 KV 列中各 query 可见 110–117 个位置。独立 FP16 数值参考与 Adreno 原输出相对 L2 约 0.0227%。随后 `attention-cpu` 返回 1，入口未运行 attention HTP。旧入口在 CPU 非零退出时提前抛出，截图没有 CPU 实际误差或可定位的异常，原因仍待确认。

下一步：保留相同样本和精度门槛，补上 CPU 误差报告及稳定对照，让 HTP 实测与 CPU 对照分别出结果。
