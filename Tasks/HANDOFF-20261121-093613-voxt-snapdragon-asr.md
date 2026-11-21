# Veri 1 已发布到公开 GitHub，从克隆到下载的入口就绪

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:36:13 US/Pacific。

当前项目提交 `18c414f47c46cdb053e3403e75c90032bd39a070`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-092539-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-092557-voxt-snapdragon-asr.md
```

- 公开仓库 https://github.com/ShiaoZhuang/voxt-snapdragon-asr 无凭据浅克隆 passed，检出约 492 KiB，包含 fetch_veri1.ps1 与 SHA 清单。
- Release https://github.com/ShiaoZhuang/voxt-snapdragon-asr/releases/tag/veri-1 已公开。上传、并行上传、发布三个进程均退出 0，六项附件的 GitHub 服务端 SHA-256 与提交清单一致。匿名下载运行包逐字节比对通过，五项模型附件匿名 Range 请求均返回 HTTP 206 和预期长度。
- 安装器在 Mac PowerShell 使用小型本地复刻数据通过校验、Target 短分片合并、半途恢复和再次运行。公司网络能否访问 GitHub Release 重定向地址和骁龙 GPU/CPU 实机结果仍未验证。
- Target 为 Hugging Face 公布的 Q8_0 GGUF 原始字节。音频塔是 BF16 源 GGUF 转 F16，Draft 从公开 safetensors 转成含因果和正确 d2t 的 Q4_0 GGUF。Hugging Face 元数据显示两源权重均 Apache-2.0，附件包含上游来源说明。
- 无运行作业。代码仓库无模型、大附件和音频提交，分发资产单独放在同一个 GitHub Release。

下一步：在骁龙本从 GitHub 安装 Veri 1 并回传 CPU/OpenCL 快速或完整结果
