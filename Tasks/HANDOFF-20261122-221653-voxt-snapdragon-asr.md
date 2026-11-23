# 固定验收入口已完成更新、验证和报告测试，当前发布任务仍是原生 OpenCL 单条转录

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 22:16:53 US/Pacific。

当前项目提交 `922b74871b37e3fbb7daeea52825fe7654e1cdf6`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Handoff.MD
 M PLAN.md
 M README.md
?? scripts/win-arm64/current_handoff.ps1
?? scripts/win-arm64/update_and_verify.ps1
```

- 用户决定把骁龙端所有操作归到同一个固定入口，每轮从 GitHub 更新当前验证任务并统一拍照回传。新增 update_and_verify.ps1 与 current_handoff.ps1，首次使用标签 veri-1-auto-handoff。
- 固定入口从此项目自己的 origin/veri/native-win-arm64 获取提交，只在专用的 .local/win-arm64-handoff/source 工作树快进，复用现有 dist 和本地编译缓存。原工作区保持用户的 Git 状态，冲突会生成失败摘要。运行中的日志按次保存，返回非零时列出失败阶段和关键错误。
- 当前发布任务执行 -BackendOnly 本机编译及 Zh 单条环回 SSE 转录，和上一轮任务一致。后续可通过提交更新 current_handoff.ps1 切换评测，用户使用同一入口。设备现有缺 Clang 仍会如实显示。无新 EXE 上传或模型下载。
- Mac PowerShell 用临时远端实际执行连续 Git fetch 和快进，覆盖三版任务、UTF-8 文本、两流各超过 128 KiB 的日志、工具缺失、与当前 PID 匹配的崩溃事件、保留原工作区和拒绝覆盖专用目录改动。脚本语法和 git diff 检查通过。Windows PowerShell 5.1 与 Adreno 仍需实机验证。

下一步：骁龙本首次切换 veri-1-auto-handoff 后运行 update_and_verify.ps1，回传屏幕摘要验证 Windows 5.1 与下一项实机结果
