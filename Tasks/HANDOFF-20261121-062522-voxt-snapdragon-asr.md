# Voxt 原生后端的首版实现已开始构建

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 06:25:22 US/Pacific。

当前项目提交 `d9bbc8f224b8dd18d2267d9e8b713e2238b6568c`。写入本轮检查点前的 Git 状态：

```text
## main
?? native/
?? patches/llama-voxt.patch
?? scripts/build_voxt_backend.sh
```

- 实现独立 qwen3_asr_server 进程，复用锁定的 llama.cpp/mtmd 调度，接入 Voxt localhost 动态端口、stdin 退出、原版上下文提示、Final SSE 心跳、语言清洗与计数。当前未提交。
- Mac build running，命令 ./scripts/build_voxt_backend.sh，PID 70201，.local/voxt-backend-build.log，.local/voxt-backend-build.exit，完成条件为成功生成原生后端。

下一步：运行原 Voxt Go 客户端和 SSE 生命周期探针，验证 Token 与统计
