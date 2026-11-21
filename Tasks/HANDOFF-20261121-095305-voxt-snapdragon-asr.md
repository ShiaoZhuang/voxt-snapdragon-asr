# 新增 Hugging Face 原版 Target 下载路线

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 09:53:05 US/Pacific。

当前项目提交 `300a0faf8685a36ac7f50d6afb91940287317b4c`。写入本轮检查点前的 Git 状态：

```text
## main
 M README.md
 M scripts/win-arm64/fetch_veri1.ps1
```

- 用户报告 GitHub Release 下载很慢。fetch_veri1.ps1 新增 -TargetSource HuggingFace，从锁定的 ggml-org 上游获取字节相同的 Q8_0 Target，校对源锁和 Veri 1 manifest 的 SHA；默认 GitHub 保留。运行包及两个转换权重仍从 GitHub。两条路各保留未完成进度，已验哈希的资产复用。
- Mac 对 HF 固定链接请求 16 字节，HTTP 206。PowerShell 复刻测试 GitHub 分片与 HF 单文件两路均组装出相同字节，重跑复用；TLS 回归通过。骁龙本连接和速度未知。
- 原 Draft safetensors 725684336 字节，本地量化稿 235695328 字节；BF16 源投影器 641773984 字节，F16 投影器 641773920 字节。一次性转换可行，但冷机下载源文件只会增加字节。没有启动新模型发布或长作业。

下一步：在骁龙本比较可达性和速度并回传 Veri 1 结果
