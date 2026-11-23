# 整链超时已记录，末层优先和单层超时保护已就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 11:06:12 US/Pacific。

当前项目提交 `ac2c3503bc63957116a9dfcde11f8719f3b9a531`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
 M Handoff.MD
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/win-arm64/current_handoff.ps1
 M tools/qnn-probe/replay_target.py
?? Tasks/HANDOFF-20261123-105657-voxt-snapdragon-asr.md
?? tools/qnn-probe/target_htp_worker.py
```

### 实机证据
- Windows `ac2c350` 截图报告在 1200 秒结束 Target replay，Adreno 28 层真实采集和转录通过，第 0 层两个补测通过。报告只露出 QNN provider options 与自定义域重复提示，缺少退出前层数和最后执行位置，超时根因未确认。上一版 `bc6f9c0` 的 27/28 与 109.53 ms 仍是已有实测证据。

### 处置与验证
- 固定入口先执行末层原生输入的独立 HTP 回放，再启动 28 层串联。每图单独进程，单层上限 45 秒，串联启动预算 270 秒，回放外层上限 360 秒。出错后从下一份原生状态继续，CPU 对照独立推进。已经完成的 HTP 输出与 QAIRT profiling 在会话清理前保存，超时仍保留失败标记。每层细分注册、初始化、执行、profiling、清理阶段。
- PowerShell 汇总末层独立结果、旧未完成回放的层数、当前已完成层数、必要时具体超时阶段和可用 logits。已有逐层记录时免去重复第 0 层补测。固定启动脚本、模型及数值门槛不变。
- `.local/isolated-worker-handoff-test.log` 中使用真实 Mac 捕获和 CPU 模型，HTP 进程替换为测试实现。正常流程 28/28、四组 top-1 均 8/8。注入末层初始化卡住后，测试版 1.5 秒终止该进程，保留 CPU 28/28、HTP 27/28 和 CPU top-1 8/8，正确报告失败。另外验证清理挂起可保留结果、启动预算耗尽可保留原生 logits、worker 异常可保留原始阶段及 PowerShell 可读取旧逐层日志。首次 Mac 夹具在已输出结果后本地运行时退出异常，提前释放 CPU 会话后完整重测通过。
- `git diff --check`、PowerShell 解析和 Python 语法检查通过。Windows 实机新进程模式、末层阶段与真实 QAIRT 结果仍待回传。

下一步：骁龙固定入口运行一次，查看末层独立结果、若超时的具体阶段及 28 层串联、top-1 汇总。
