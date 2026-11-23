# 骁龙整链 1200 秒超时，补测第 0 层通过

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 10:56:57 US/Pacific。

当前项目提交 `ac2c3503bc63957116a9dfcde11f8719f3b9a531`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

Windows 实机提交 `ac2c350` 报告 Target 链超出 1200 秒，原生 28 层批次和初始转录通过，第 0 层完整图、post-RoPE 和 KV 可见性补测通过。超时后只有 ONNX Runtime 重复 provider 配置和已存在自定义域的提示，截图未包含逐层已完成结果或最后停留处。这些提示不能定位超时点。先前提交 `bc6f9c0` 已完成前 27 层，109.53 ms 为各层热态中位数之和。

下一步：隔离各层的 QNN 会话并保存实时阶段标记，优先验证末层，同一入口回传有界运行结果。
