# 等待 Release 附件全部通过 GitHub 服务端 SHA 校验

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:25:57 US/Pacific。

当前项目提交 `18c414f47c46cdb053e3403e75c90032bd39a070`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-092539-voxt-snapdragon-asr.md
```

- 附件校验并发布进程 running，Mac PID 678，命令 python3 .local/publish_veri1.py，.local/github-veri1-publish.log/.exit。门槛为六个 GitHub 服务端 SHA 与已提交清单一致，再发布草稿。上传进程状态见前一记录。

下一步：发布后检查所有附件的匿名下载及克隆入口
