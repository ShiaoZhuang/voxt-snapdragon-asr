# 可直接从 Hugging Face 下载并加载原版音频编码器

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 10:10:49 US/Pacific。

当前项目提交 `46c00afa7771722eb61fc1e7d70b3e8904a88c4f`。写入本轮检查点前的 Git 状态：

```text
## main
 M README.md
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/win-arm64/fetch_veri1.ps1
?? Tasks/HANDOFF-20261121-100857-voxt-snapdragon-asr.md
```

- fetch_veri1.ps1 增加 -ProjectorSource HuggingFace，可与 -TargetSource HuggingFace 同用。下载锁定上游 BF16 mmproj 并直接加载，无本地量化或重打包。Target 与 Draft 已校验文件原地复用。原 F16 路线仍可选，报告据实际选择记录音频塔 SHA 与精度。仅约 225 MiB Draft 和 19 MiB 运行包走 GitHub（若未下载）。
- Mac Metal 的原 BF16 音频塔 Target-only 与固定 Q4 各跑 31 条，均为 30/946=3.171%，词典 7/10。两者 token 31/31 一致，各自与上一轮 F16 配置 token 31/31 一致。BF16 Q4 全集 avg_accept=3.284，干净组 6.00。CPU 快测零错误、14/14 接受。原始输出 .local/upstream-projector/results/。Adreno 实机 BF16 路径未验证。
- HF 原版投影器固定下载链接匿名 Range 返回 206/16 字节。PowerShell 模拟切换 HF/F16、SHA、缓存重跑和 TLS 回归通过。没有新上传或运行作业。

下一步：在骁龙验证原版 BF16 音频塔的下载、CPU 与 Adreno 快速验收
