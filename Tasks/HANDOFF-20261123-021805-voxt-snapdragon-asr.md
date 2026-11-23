# 骁龙端 HTP 探针因缺 NumPy 未启动，固定入口已加入隔离环境和依赖安装

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 02:18:05 US/Pacific。

当前项目提交 `25879598a464c33e13cf74536bf2f05a351a2117`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/requirements-win-arm64.txt
```

- 2026-11-23 18:11:42 +08:00 骁龙实机照片，提交 25879598a464c33e13cf74536bf2f05a351a2117。从 C:\Python314\python.exe 启动，投影脚本在 import numpy 时报 ModuleNotFoundError，尚未加载 QNN EP 或接触 HTP。上方 OpenCL PASS 为已登记的前一轮结果。
- 固定入口会校验 Python 的 Windows ARM64 平台与支持版本，并在仓库 .local/qnn-probe-venv 内创建或复用环境。从已配置的 pip 软件源同步固定的 NumPy、ONNX、ORT、QNN EP Windows wheel。pip 被限制在 venv 中，既有全局 Python 及 ASR 模型不参与安装。失败显示对应阶段和日志，不会继续假报 HTP。
- Mac PowerShell fixture 验证首次创建、复用、架构不符、源失败和禁止 CPU fallback。真实 pip 跨目标 dry run 完整解析并取到 CPython 3.14 Windows ARM64 的官方 wheel 及依赖。实际公司软件源和 Windows HTP 执行仍待回传。

下一步：重跑固定 update_and_verify.ps1，回传依赖安装结果及 HTP 执行事件
