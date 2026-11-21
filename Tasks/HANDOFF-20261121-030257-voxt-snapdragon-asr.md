# Mac 31 条质量基准与 CPU、Metal 的 llama.cpp 投机探针完成

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 03:02:57 US/Pacific。

当前项目提交 `322dcfd4c3e3aaee890967fd04e5bb5cb8ffa30f`。写入本轮检查点前的 Git 状态：

```text
## main
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025523-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025641-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025657-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025826-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-025904-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-030019-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-030046-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261121-030138-voxt-snapdragon-asr.md
```

- 当前工程提交 322dcfd 包含基准复现、GGUF 转换、llama.cpp 探针及复现说明。原始日志、评测 WAV、构建产物和 GGUF 文件保存在被忽略的目录。
- Apple M3 Pro 18 GiB，MLX 三组各 31 条 main zh。错误率 29/946 = 3.066%，long 2.245%，zh-plain 和 en 均 0%，词典命中 7/10（无偏置 4/10）。Q4 761/1554，222 轮，avg_accept=3.428，avg_step=4.428，接收率 48.97%，干净组 6.286。Q8 762/1547，221 轮，avg_accept=3.448，干净组 6.286。Q4 的 Draft / Target / Context 均值 3.335 / 17.495 / 0.526 ms/轮、占比 15.62% / 81.92% / 2.46%。.local/mac-baseline-full/summary.json 可用 benchmark/summarize.py 重建。
- MLX 的 long-zh 在 Target-only 与固定 Draft 之间差两处逗号，首段 generated token count 为 139 对 142。其余 30 条正文相同。这次 SSE 没有逐 token ID，故不能宣称全量贪心 token 等价。固定 Q4 和 Q8 的全部 31 条正文相同。
- llama.cpp e412c6f468b7b9e0f16f2540244236f8ad68e9ae 的正常版本标识、同 WAV 四组（Apple CPU / Metal，各自 Target-only / DFlash）均通过。四组原 SSE 完成文本一致，去掉上游 language Chinese<asr_text> 后与 MLX 同句一致。CPU/Metal 的草稿均接受 15/21，3 轮 avg_accept=5.00。上游 SSE 确实泄漏该前缀，且只提供 usage。尚未接入 Voxt 实际托管协议或跑全量 llama.cpp 评测。
- F16 音频塔 150 个 F16 张量、248 个 F32 张量（原 bias、归一化和位置数据）。量化后 Draft 36 个 Q4_0 张量、一个 Q6_K 输出权重和 F32 norm，约 219.12 MiB，d2t 为 I64，实读 48,000 个 ID，范围 0 至 151704，量化前后完全相同。复读元数据确认因果、block 8 和提取层 2、14、25。
- Go Final-only 验证程序 Mac 和 Windows ARM64 编译通过，file 确认后者是 Aarch64 PE32+。设备未运行该 EXE，native C++ Windows 后端仍待构建。无运行作业。
- 相邻 sglang-omni 维持 feat/dflash-profile-benchmark @ 6efb1212b6e1196ed1140040d9e4e3069f6cb0a8，原有 Capture.swift 修改未触及。

下一步：实现 Voxt 托管与转录适配，并用原 Go 客户端跑通首条真实协议转录
