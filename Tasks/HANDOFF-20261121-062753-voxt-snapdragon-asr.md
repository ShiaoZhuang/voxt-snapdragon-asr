# 修正 JSON 解析和 Windows SDK 目标版本，重试两端构建

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:27:53 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062623-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062656-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac 第二次构建 failed，固定版本包装 JSON 只有单参 parse，已改为捕获无效控制行。
- Windows 首次交叉构建 failed，MinGW 默认目标较低，cpp-httplib 的 CreateFile2 未声明。Khronos loader 已编译成功。后端构建改用 Windows 10 ABI 宏（目标设备 Windows 11）。
- Mac running，PID 75925，.local/voxt-backend-v3.log/.exit。Windows running，PID 75926，.local/windows-arm64-v2.log/.exit。命令与目标同前序检查点。

下一步：用原 Voxt 客户端跑 Mac 后端并检查 Windows ARM64 链接
