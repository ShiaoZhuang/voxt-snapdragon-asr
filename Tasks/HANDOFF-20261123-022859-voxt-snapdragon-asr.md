# 骁龙 HTP 探针停在 Python 预检，固定入口已加入 ARM64 解释器发现与诊断

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 02:28:59 US/Pacific。

当前项目提交 `3bbfb70477e3700829543b023026854dd56b650b`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M scripts/win-arm64/current_handoff.ps1
```

- Windows 截图中 `3bbfb70` 的重试进入 Python runtime 检查并退出 1，未进入 pip 或 QNN HTP。旧运行找到 `C:\Python314\python.exe` 并报缺 NumPy，现有截图未打印进程架构，暂不能确认该路径是否为 x64。
- 固定验收任务查找项目隔离环境、PATH、PEP 514 注册信息和 `py -0p`。按实际进程选择标准版 Win ARM64 CPython 3.11–3.14，屏幕摘要记录已检查候选的架构与版本。已有不兼容的项目环境会保留，兼容基础解释器可创建独立 ARM64 环境。
- Mac PowerShell 语法检查以及本地模拟通过，覆盖 x64 PATH 后选中注册的 ARM64、无兼容解释器、首次创建与复用、保留旧环境、pip 失败和拒绝 CPU fallback。四个固定依赖均发布了适用于 CPython 3.11 至 3.14 的 Win ARM64 wheels。
- 最新 Adreno 31 条基线已通过。当前验收只跑合成 QDQ 投影，Windows 依赖安装和 HTP 执行仍未验证。

下一步：骁龙本在仓库根目录运行 .\scripts\win-arm64\update_and_verify.ps1，拍回 VOXT SNAPDRAGON REPORT，确认是否选到 ARM64 解释器及是否出现 QAIRT backend execute 事件。
