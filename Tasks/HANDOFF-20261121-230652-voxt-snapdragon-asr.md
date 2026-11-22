# 实机已识别 Adreno，最新 Quick 的 OpenCL DFlash 返回退出码 1

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 23:06:52 US/Pacific。

当前项目提交 `c7b3e824a0a82609bd56f1e0b4a72aa0d29c0da4`。写入本轮检查点前的 Git 状态：

```text
## main
```

- 根据用户 11 月 22 日截图，14:57:40 报告识别到 Qualcomm Adreno X1-85。四组失败于 Process.Start 访问被拒绝，尚未获取推理结果。该次 JSON 的 quick=false。
- 15:02:36 用户执行源码入口 run_verify.ps1 -Quick，生成新 Results。最新 PowerShell 异常明确指向 opencl-draft-q4.log，显示子进程退出码 1。runner 仅在成功启动并等待子进程退出后抛出此消息，说明这次已通过架构与清单检查，也越过该组评测进程的启动关卡。没有该轮报告或 stderr，其他三组和实际推理状态仍未知。
- 当前只记录实机证据。尚无新模型、程序或验证代码改动。相邻 sglang-omni 不是这轮实机运行目录。

下一步：读取 15:02:36 那轮 verify_report.md 与 opencl-draft-q4.log，定位设备或进程故障
