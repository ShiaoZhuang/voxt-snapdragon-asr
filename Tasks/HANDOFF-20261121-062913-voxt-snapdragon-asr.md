# 真实 Voxt Go 客户端已读到首条转录和三段投机统计

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:29:13 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062522-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062623-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062656-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-062753-voxt-snapdragon-asr.md
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
?? scripts/win-arm64/
```

- Mac 原生后端构建 passed（.local/voxt-backend-v3.exit=0）。原 Voxt Go 客户端通过托管定位、上传 WAV、SSE 完成和 stdin 退出，zh-plain-1 零错误，14/14 接受、2 轮，generated_token_count=15；三段耗时均非零。
- ARM64 loader 已通过 PE 检查。Windows 后端 v2 已到链接阶段，见 .local/windows-arm64-v2.log/.exit。
- 加入按请求记录 token ID 和前三轮草稿/验证前缀的开关。Mac 新构建 running PID 79922，.local/voxt-backend-trace.log/.exit。Windows 新构建 running PID 79923，.local/windows-arm64-trace.log/.exit。

下一步：用新增 token 追踪跑全量 Mac 对照并生成 Windows 上机包
