# 骁龙仍在调用旧启动器，已核对远端支持 Route

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-23 23:59:11 US/Pacific。

当前项目提交 `03c5ad52c4bddcf68cdf59c02bcde7d7042a2791`。写入本轮检查点前的 Git 状态：

```text
## experiment/real-qnn-replay...origin/experiment/real-qnn-replay
```

实机照片 .local/snapdragon-device/old-launcher-route.jpg 显示 Windows PowerShell 5.1 在仓库根目录执行 update_and_verify.ps1 -Route GgmlHexagon 时，两次在参数绑定阶段返回 NamedParameterNotFound。中间的不带参数调用打印旧版 [1/2]、[2/2] 和 Live logs，但照片未出现完成报告。此图没有 SDK 安装或 GGML 构建结果。

已对照历史 veri-1-auto-handoff 的 launcher 只收 InstallDirectory，当前远端跟踪分支 veri/native-win-arm64 的 03c5ad52c4bddcf68cdf59c02bcde7d7042a2791 支持 Route 并传给独立工作树的测试脚本。旧入口正常执行只会更新 .local/win-arm64-handoff/source，不会刷新仓库根目录的 launcher。需在设备端从 FETCH_HEAD 只恢复本地 launcher 文件，然后运行 GgmlHexagon。此轮仅记录诊断，远端测试代码已有所需修复。

下一步：骁龙从已发布分支刷新本地启动器，再按 GgmlHexagon 路线运行并回传报告。
