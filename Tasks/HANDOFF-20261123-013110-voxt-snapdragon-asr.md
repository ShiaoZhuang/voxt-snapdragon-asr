# CPU 31 条对照已冻结，固定验收入口改为只跑 Adreno OpenCL

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 01:31:10 US/Pacific。

当前项目提交 `036dce3b0834782032cad031209cd85ae8f4652f`。写入本轮检查点前的 Git 状态：

```text
## experiment/hexagon-verify...origin/experiment/hexagon-verify [ahead 1]
```

- 用户决定后续常规实机验收跳过已经完成的 CPU 两组。cd064eb 的 Oryon 纯 Target 和 Q4 DFlash 各 31 条均通过，同设备逐 token 一致，累计请求耗时 303.8 + 492.4 = 796.2 秒，约 13 分 16 秒。
- 发布分支 veri/native-win-arm64 已推送 76f75d8。固定入口下次自动更新后只运行 OpenCL 纯 Target 和 Q4 DFlash。手动的 run_verify.ps1 仍可按需执行完整 CPU/OpenCL 矩阵；现有脚本调用和历史数据保留。Hexagon 实验分支已同步此行为，未来混合路径以 Adreno 对照为主。
- 在 Mac 模拟验收中把任何 CPU 启动设为错误，确认固定工作流只生成两个 OpenCL 31 条结果。另测手动四组、原生组件哈希校验和失败报告仍通过。这个改动无需为了验证跳过 CPU 而在骁龙本复跑。

下一步：后续混合推理复用 Oryon 对照，继续验证 Hexagon HTP 加速路径
