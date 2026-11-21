# GitHub 克隆与组装入口已推送，模型附件并行上传中

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:25:39 US/Pacific。

当前项目提交 `18c414f47c46cdb053e3403e75c90032bd39a070`。写入本轮检查点前的 Git 状态：

```text
## main
```

- main 最新包含 fetch_veri1.ps1 与六个附件 SHA 列表；模拟中断恢复、拼接校验和再次运行通过。独立 Win ARM64 环境未执行。
- 首个上传进程仍运行，运行包已上传成功。并行上传两个余下 Target 分片，Mac PID 623，命令 python3 .local/upload_remaining_targets.py，.local/github-veri1-parallel.log/.exit。原上传器发现远端同名且同 SHA 的附件时复用。

下一步：待六个附件哈希一致后发布 Release 并验证匿名访问
