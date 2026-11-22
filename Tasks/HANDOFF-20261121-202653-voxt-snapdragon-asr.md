# 修复 PowerShell 5.1 的 ARM64 检查并通过分支发布

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 20:26:53 US/Pacific。

当前项目提交 `117085b929413f899fa1f5d5dd05a3d8ec97f8c7`。写入本轮检查点前的 Git 状态：

```text
## fix/veri1-powershell51-arm64
 M Handoff.MD
 M README.md
```

- 用户侧截图确认 Windows PowerShell 5.1 在快测架构检查处因 RuntimeInformation.OSArchitecture 空值调用 ToString 早退。已用 PROCESSOR_ARCHITEW6432 优先、PROCESSOR_ARCHITECTURE 回退识别 ARM64，并保留失败退出码。
- 仓库入口可直接用已组装 dist/voxt-snapdragon-veri-1 或 -InstallDirectory 指定目录。已发布的包、脚本副本及 SHA 清单不需要修改。
- Mac PowerShell 回放使用原包脚本作为锁定资产，原生 ARM64 与模拟 AMD64 上的 ARM64 两个环境分支都触发四组请求，AMD64 或缺变量给出明确错误，篡改 EXE 在哈希检查处失败。骁龙与 PowerShell 5.1 待实测。无运行作业。
- 在 fix/veri1-powershell51-arm64 分支保留修复与交接两次提交，通过 PR squash 合入 main，以免小步试错堆在 main。

下一步：骁龙从 main 拉取更新，用源码仓库验收脚本跑 -Quick 并回传报告
