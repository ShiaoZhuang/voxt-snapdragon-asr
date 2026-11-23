# 修复版已在骁龙上完成 Adreno 枚举，四组推理复验被公司 Defender 规则拦在评测器启动

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 21:37:18 US/Pacific。

当前项目提交 `4a396111ae2556b9e7bc11379d121f55a87a5120`。写入本轮检查点前的 Git 状态：

```text
## diagnose/veri-1-opencl-startup...origin/diagnose/veri-1-opencl-startup
```

- 骁龙实机 2026-11-23 13:30 +08:00，报告目录 `verify-20261123-133006-351`。清单哈希通过，修复版源码 `41c20c6` 及 EXE SHA 正确，`--list-devices` 枚举 Adreno X1-85 成功。四组均在 `Process.Start` 返回 Access is denied，模型加载、OpenCL 缓冲区修复与 CPU/GPU 推理未验证。
- 同时刻 Protection History 显示 PowerShell 启动的受影响文件为原 Veri 1 `bin/final-benchmark.exe`，原因为 Defender Attack surface reduction 的 Use advanced protection against ransomware。新 OpenCL EXE 通过枚举，候选补丁复用原评测器。源码用 UseShellExecute=false 启动，并未请求提升权限；本地确认原评测器没有 Authenticode 证书表。签名、文件信誉等是文档里的规则信号，截图不足以确定具体命中因素。
- 单独的 Qualcomm IT Security 提权窗命名 Microsoft Windows `SecurityHealthAgent.dll`/`SecurityHealthHost.exe`。没有证据确认是哪次界面操作引出该弹窗。用户本轮询问原因，没有改动脚本、策略或发布产物。

下一步：通过公司 IT 审核评测器或在允许此程序的获授权 Windows ARM64 环境重跑同一 Veri 快测
