# 完整第 0 层与 KV 可见性实机通过

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 09:01:03 US/Pacific。

当前项目提交 `636c260c855f7e630aa751012bef618bb089077d`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
```

用户报告 `636c260`，Windows 本机构建、Adreno 采集与转录、完整第 0 层与 post-RoPE 对照均 PASS（2026-11-24 00:51:25 +08:00）。两图的历史屏蔽和接受 0/1/3 候选检查全部通过，QAIRT 各记录 240 个执行事件。完整图 HTP 对独立参考的相对 L2 0.1432%，对 CPU 0.1430%，相对捕获原生层输出的重编码误差 1.633%，30 次中位数/P95 3.049/3.458 ms。post-RoPE 对照相对 CPU 0.1309%，中位数/P95 2.794/4.508 ms。同一静态层的 KV 可见性已实测，原生 KV 更新仍待连续推理验证。

下一步：把全部 Target 层串联回放，并用同批 Adreno logits 验证输出 token，沿用单次固定入口。
