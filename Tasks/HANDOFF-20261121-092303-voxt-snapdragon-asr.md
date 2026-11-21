# 创建公开仓库并开始从 GitHub 分发 Veri 1 模型及程序

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:23:03 US/Pacific。

当前项目提交 `b4e4e56dc89e3e50f61fb194db3b26905f50c725`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-085746-voxt-snapdragon-asr.md
```

- 用户只能通过 GitHub 远程 clone，验收交付改用公开仓库和同 tag 的 Release 资产。授权 GitHub 账户 ShiaoZhuang 已验证，创建并推送 https://github.com/ShiaoZhuang/voxt-snapdragon-asr，main 与 veri-1 均可见。
- 现有离线包主要由权重构成。Target 2165034944 字节，mmproj 641773920 字节，Draft 235695328 字节，bin 约 35 MiB。
- GitHub Release 草稿编号 453855158。上传 running，Mac PID 385，命令 python3 .local/upload_veri1.py，日志 .local/github-veri1-upload.log，退出文件 .local/github-veri1-upload.exit。成功门槛是运行包、两个独立权重和 Target 三段均匹配 SHA-256。
- 工作区原有未提交的基准摘要检查点保留。

下一步：完成 Release 资产上传并验证克隆后下载和校验
