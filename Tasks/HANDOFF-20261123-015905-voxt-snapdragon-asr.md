# OpenCL-only 全量复验通过，固定入口切到 Hexagon HTP 投影探针

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 01:59:05 US/Pacific。

当前项目提交 `de2faabaa81ad57b01bd8b699f3a5c967e5c4e5a`。写入本轮检查点前的 Git 状态：

```text
## experiment/hexagon-verify...origin/experiment/hexagon-verify
 M Handoff.MD
 M PLAN.md
 M scripts/win-arm64/current_handoff.ps1
```

- 用户重新上传 IMG_6343大.jpeg。报告 2026-11-23 17:31:33 +08:00、提交 76f75d8eb40ab91dec2eb59d80885ab7e53352cc。固定入口确实只运行两组 OpenCL，均 31 条 PASS，综合错误率 3.07%、词典 7/10、零逐 token 差异。DFlash avg_accept 3.32、avg_step 4.32、47.5%、clean 6.00，zh-plain/en 0.00%、long 2.65%。
- 当次纯 Target / Q4 DFlash 累计 110.5 / 108.2 s，比本轮纯 Target 少 2.1%。Draft / Target / Context 29.16 / 195.85 / 6.48 ms/轮，分别占 12.6% / 84.6% / 2.8%。首跑两条累计为 123.8 / 116.5 s。CPU 沿用首次结果，不在本轮执行。后续判定混合加速需要同机配对。
- 把 Windows 固定验收连接到已做 CPU 数值对照的静态 QNN 投影。优先使用用户仓库 .local/qnn-probe-venv 的 Python，其余情况用当前 PATH。脚本在本机生成合成图，保存标准输出、错误、ORT profile、JSON 和拍照摘要。要求选用 QNN HTP 且出现 QAIRT backend execute 事件。既有 OpenCL 全量路径可通过 run_verify.ps1 -OpenCLOnly 复现。
- 使用 Mac 验证了工作流选择隔离 venv、空 ASR 模型/构建目录仍可执行、结果输出、缺依赖与 CPU fallback 拒绝等场景。真实 ORT CPU 数值再对照 0 LSB。QNN HTP 真实设备、安装可用性和完整验证图未验证。锁定 Windows ARM64 ONNX/ORT/QNN wheel 版本，依赖由用户以公司允许的渠道一次性准备。

下一步：用获准的 QNN ARM64 Python 依赖运行固定入口，回传 HTP 事件及投影数值和延迟
