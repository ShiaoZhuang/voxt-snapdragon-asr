# 骁龙真实 DFlash up 投影已通过 HTP，开始完整 FFN 回放

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 07:49:53 US/Pacific。

当前项目提交 `162597b43077e632695abbd8144b4c4c480ddbea`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

- 骁龙本 2026-11-23 23:30 Asia/Shanghai，在 `162597b` 运行固定入口总体 PASS。原模型与 WAV 哈希、原生构建、Adreno 捕获和转录全部通过。真实八位置为 109–116。
- dense Q8_0 相对 Adreno 捕获的 L2 误差 0.6093%，A16/U8 逐输出通道重编码相对 dense Q8_0 的 L2 误差 0.7759%。CPU 与 HTP 相对独立整数参考均最多差 1 步，HTP 相对同图 CPU 的 max/P95 为 1/1 步，0/49,152 超限。
- 216 个 QAIRT 后端执行事件、退出 0，30 次热态主机往返中位数/P95 为 1.381/1.820 ms。该结果覆盖单个 FFN up 投影，后续扩到 gate、SwiGLU 和 down。

下一步：捕获同批次 FFN 输出并验证 gate、SwiGLU 与 down 在同一 QDQ 图内的数值。
