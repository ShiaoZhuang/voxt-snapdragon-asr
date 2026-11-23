# 第 0 层 post-RoPE 整图实机通过，下一轮合并多项验证

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 08:43:27 US/Pacific。

当前项目提交 `f14b7d0d920cc7e5f63db1bced6fc94e02c2da97`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
```

用户返回骁龙实机报告，`f14b7d0` 以真实 DFlash 八位置、109 历史位置、256 列执行。QAIRT 记录 216 个执行事件，HTP 对独立参考 L2 0.1307%，与 CPU FP32 attention 对照 L2 0.1309%，30 次热态中位数/P95 2.322/2.881 ms。用户要求一次上机多跑几步，减少手工往返。沿用原有入口和 GPU 对照，CPU 仅用于局部校验。

下一步：一次固定脚本调用验证真实第 0 层完整前向、KV 提交场景和基线对照。
