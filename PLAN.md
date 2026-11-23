# Voxt 在骁龙 X Elite 上的本地推理移植计划

MacBook 负责开发、模型转换、数值对照和优先产包。骁龙笔记本负责 Windows ARM64 上的设备验证。首个里程碑是在 Adreno X1-85 上跑通 Qwen3-ASR 1.7B + DFlash，并用同机 Oryon CPU 和各自的 Target-only 路径解释速度差异。随后必须实测 Hexagon 执行 Target 验证前向的可行性和端到端收益。本文中的「Target 验证」指模型校验草稿 token，「实机验收」指一次跨机交接。

现有骁龙原型曾以 W4A16 运行 ASR + DFlash，使用者观察到 Target 验证占去大部分时间，GPU 占用接近 100%。这是新实现优先调查的现象。工程从干净的上游版本起步，独立实现 Voxt 后端；旧原型的代码、二进制和配置均不是构建依赖。

## 1. Mac 开发与数值基线

1. **固定来源。** 以 llama.cpp `e412c6f4`、本地 Voxt/MLX 基准提交 `6efb121`、MLX 8-bit Target 快照 `a8379a2e` 和 Draft 快照 `23a0db8a` 为起点，在锁文件记录完整提交、权重及 tokenizer 的 SHA-256。本地 Voxt 分支的未提交工作留在原工作树。对 Mac 独有的基准补丁，在公开移植仓库提供可从公开上游重建的源码差异和说明，验收包须能从干净 clone 重建。
2. **冻结 31 条公开基准。** 由 Voxt 的 `eval.Load` 载入 29 个 WAV，按清单、停顿和参考文本生成两条长样本。重跑 Mac MLX 的 W8 Target-only、固定 Q4 Draft 和固定 Q8 Draft。保存每条的原始 token ID、请求参数、词典顺序、分段、停止原因及统计。评分沿用 `eval.Compare` 和 `TermsFound`。
3. **先跑 Target-only。** 用 `libmtmd` 和 `libllama` 接通 16 kHz 单声道 WAV、128 维 Log-Mel、音频编码窗口、尾窗及音频 token 插入位置。Mac 快照中的音频权重以 BF16 保存，MLX 加载时转 FP16。首发导出 F16 音频塔、Q8_0 文本 Target，核对词典 prompt、语言提示、Mel、encoder 输出、首 token 和完整转录，分别记录文件精度及执行时激活、累加和 KV 类型。[上游 ASR 模型转换](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/conversion/qwen3vl.py) · [音频图](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/tools/mtmd/models/qwen3a.cpp)
4. **接入固定 DFlash。** Draft 默认 Q4_0，按 `--draft-bits` 支持 4/6/8。校验 hidden size 2048、三层输入 `[2,14,25]`、`fc.weight=[2048,6144]`、`lm_head.weight=[48000,2048]`、mask ID 151705。导出时把全部 48,000 个偏移转换为绝对 ID `i + d2t[i]`，检查唯一性、范围与往返一致性。核对最终捕获层号，写入并读取 `dflash.attention.causal=true`，使用 `draft-dflash`。每个文本和音频 prefill 微批都追加到 Draft context。每轮从 Target embedding 取一枚 anchor 加七枚 mask，Target 一次验证最多八个位置。按已接受前缀裁剪 Target KV，将对应 aux 张量经 fc 和 hidden_norm 追加为 Draft context，清除草稿块临时 KV。用超过 2048 位置的测试检查完整已确认上下文。[上游转换器](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/conversion/qwen.py) · [DFlash 执行图](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/src/models/dflash.cpp)
5. **对齐贪心和回退行为。** 同设备、同 Target 精度逐 token 比较 Target-only 与 DFlash，覆盖首位拒绝、部分或全部接受、EOS、尾块、静音及复读。遇到首个分歧保存位置、候选、Target top-2 与 KV 长度。固定模式通过后接入 SGLang-Omni 自适应回退：跳过第一轮，比较两个各四轮的窗口，以五个普通 token 探测 ms/token，按 5% 容差决定是否释放 Draft cache 并沿用 Target KV。固定模式用于统计接收长度，自适应模式另测真实延迟。

## 2. 首轮实机验收：Adreno GPU 与 Oryon CPU

**服务契约。** 生成原生 ARM64 `qwen3_asr_server.exe`，用 Voxt 的 Go 客户端验证真实启动参数，包括 `--supervised --host 127.0.0.1 --port 0`、模型目录、Draft 路径及位数，以及启动超时、模型种类、解码间隔、分段和缓存参数。模型就绪后 stdout 发送含 host、port、model_name、server_pid 的单行 ready JSON；stderr 记录诊断。测试 stdin shutdown、EOF、取消、空闲释放及重启。

**转录与评测。** 用 CivetWeb 提供 `POST /v1/audio/transcriptions`。接受 Voxt 的 WAV、language、prompt、max_new_tokens、stream、include_generation_metadata 和两个停止开关，兼容客户端发出的 model 与 response_format。SSE 等待期间每 250 ms 发送心跳，完成时发送 `transcript.text.done` 和 `[DONE]`。移植语言前缀提取和 token-loop 检测、折叠。元数据包含 `generated_token_count`、`language`、`finish_reason`、`verify_round_count`、`proposed_draft_token_count`、`accepted_draft_token_count`。启用 `OMNI_DFLASH_PROFILE=1` 时返回 `draft_ms`、`target_ms`、`draft_context_ms`。Windows 先用 Final-only 验证程序复用原 Go 请求与评分路径；Mac 对照原评测校验分数。

| 要回答的问题 | 运行方式与验收线 |
|---|---|
| CPU 和 GPU 都能正确执行吗？ | 相同的 F16 音频塔、Q8_0 Target，在 CPU 和 OpenCL 上各跑 Target-only 与固定 Q4_0 Draft，四组各 31 条。每个设备分别核对贪心序列。记录各阶段实际设备、CPU 回退算子和同步。GPU 初始化失败时继续出 CPU 结果，并把 GPU 项标为失败。 |
| 转录质量达标吗？ | `main zh` 全集按总编辑数除以总参考单位数，目标 3.1%，通过线 ≤3.4%。七个子集独立列出，关注 zh-plain、en 约 0%，long 约 2.2%。dict 五条的十个词项精确命中 ≥7，附去词典对照，dict2 单列。 |
| Draft 接收健康吗？ | 按总数计算 `avg_accept=accepted/rounds`、`avg_step=1+avg_accept`、`accept_rate=accepted/proposed`。全集目标 3.2 / 4.2 / 约45%，通过线 avg_accept ≥3.0。预先固定干净组 zh-plain-1、en-3、en-4，Mac 同口径复测；目标 5.5–5.7 / 6.5–6.7 / 约80%，通过线 avg_accept ≥5.3。单条干净样本接收率 <40% 触发逐轮排错。 |
| GPU 时间具体花在哪里？ | 同设备对比普通贪心与 DFlash，报告冷启动、热运行、encoder、prefill、Draft 提议、Target 验证、context 更新、同步与搬运、端到端延迟和 RTF。三段投机耗时给出每轮毫秒及占三段合计的比例，另报每个实际提交 token 的毫秒数。短句和长音频分别报告。带设备同步的 profiling 与关闭 profiling 的热运行配对测量。速度不设首轮淘汰线。 |

首轮质量门槛通过后，加跑 Q4_0 Target 的 CPU/GPU 对照；记录实际权重、激活和 KV 精度。保留 Q8_0 结果作为跨设备比较基准。GPU 忙碌率与按阶段耗时并列展示；用同机对照检验重复 prefill、跨设备拷贝、过度同步以及每轮 KV 重建是否拖慢了验证。

## 3. 必做的 Hexagon Target 验证实验

首轮 GPU 验收完成即可启动该实验，与 Windows 桌面移植独立推进。首个 NPU 交付物是 **Target 固定八位置验证前向** 的实机报告。Audio Encoder 上 NPU 作为后续独立实验，可按首轮 profiling 排序。[QNN Execution Provider](https://onnxruntime.ai/docs/execution-providers/QNN-ExecutionProvider.html)

1. **先回放同一批真实状态。** 从公开样本捕获短、中、长上下文中的 anchor、候选、位置、掩码和 Target KV。在同一台骁龙上用 GPU 或 CPU 参考路径与 QNN/QAIRT HTP 路径回放，比较各位置的 logits、argmax、三层 aux 输入和 KV 更新。为静态图规定上下文容量档位、有效长度和尾块掩码；对首次拒绝、EOS、非满八位的情况验证 KV 提交边界。
2. **再接连续解码。** 先固定 Draft 与 prefill 的设备，替换 Target 验证这一项。明确 KV 由哪一侧持有，单列首次 prefill KV 转移、每轮 KV 增量、候选、aux 与输出的搬运字节和同步时间。验证设备跟踪能证明 Target 图确实在 HTP 上执行。涉及精度变化时，额外跑对应精度的参考对照。
3. **用整条链路做决策。** 对相同 31 条数据比较纯 GPU、纯 CPU 和混合方案的质量、接收长度、热态端到端耗时，以及可测时的能耗。满足质量门槛且计入传输后有可重复收益，再启用混合路径作为默认配置。若受算子、驱动、KV 布局或传输限制，交付实际失败位置、已跑通的上下文长度及对照数据，保留可用的 GPU/CPU 默认路径。

## 4. 公开 GitHub 仓库与实机交接

- **仓库归属与内容。** 在用户的 GitHub 账户下使用公开仓库，发布可从干净 clone 重建的源码、上游版本锁、脚本、许可证说明和简短进展。普通 Git 提交只收工程文件。权重、测试音频、构建物和运行日志均放在 Git 历史之外。进展记录分别写明 Mac 已验证、待骁龙验证及实机结果。
- **提交与验收分开。** 开发按可测试的小步正常 commit。只有准备交给骁龙实机验证的大阶段提交，标题从第一个字符起写 `Veri`，例如 `Veri: validate Adreno DFlash against Oryon baseline`。该提交表示「可开始实机验收」。每轮用指向该 commit 的固定 tag 关联测试包、SHA-256 清单和回传报告。下一轮可以据此精确复现上一轮。
- **分发优先顺序。** 公司骁龙机从 GitHub 固定标签获取源码和构建脚本，使用获批准的 Windows ARM64 工具链在本机编译后端、OpenCL loader 和评测器，再运行同一套验收。模型与评测集按哈希复用。Mac 交叉编译可用于开发检查，预编译包可供允许执行该产物的环境使用。交付时将适用的入口写入交接页。[上游 Windows OpenCL 构建](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/.github/workflows/build-opencl.yml)
- **每轮交接一页。** 每个 Veri 提交更新仓库根目录的 `Handoff.MD`。按「本轮验证什么 → 取哪个 tag → 在哪里运行 → 怎样算通过 → 回传什么」书写，供人和骁龙端 Agent 直接照做。源码交付使用 `scripts/win-arm64/build_native.ps1`，随后用 `scripts/win-arm64/run_verify.ps1` 验收。
- **失败也能交接。** 脚本先校验 ARM64、模型和运行库哈希、设备、驱动与内存，运行一条 sanity 后执行本轮矩阵。通过一份可直接阅读的 `verify_report.md` 回传结论，另附 `verify_stats.json` 供 Mac 自动分析。报告包含 tag/commit、编译参数、实际设备、dtype、逐条成绩、耗时、前 3 轮 Draft/Target token 对照及首个失败步骤。实机报告默认由用户带回 Mac，公开进展使用汇总结果。

## 5. Windows 桌面与实时听写

1. **桌面听写。** 保留 Voxt Go/MyGo 界面、词典、历史和转录业务。修复已知的 Windows 编译阻点 `syscall.Stat_t`，适配模型目录、EXE 发现、SQLite 与平台 helper。按现有 helper 协议实现 WASAPI 录音、全局快捷键、取消与前台窗口回填。以原 CapsWriter 和维护中的 CapsWriter-Offline 的 Windows 行为为参考，测试短按与长按、松键结束、Unicode 上屏、Ctrl+V 粘贴及剪贴板恢复。重点复测记事本、浏览器输入框、录音期间切换焦点和用户中途复制内容。[CapsWriter](https://github.com/HaujetZhao/CapsWriter) · [CapsWriter-Offline 热键与输入配置](https://github.com/HaujetZhao/CapsWriter-Offline/blob/master/config_client.py) · [回填实现](https://github.com/HaujetZhao/CapsWriter-Offline/blob/master/core/client/output/text_output.py)
2. **实时听写。** 补齐 `/v1/realtime` WebSocket 会话、音频追加、partial、Final 和取消。参考 SGLang-Omni 的刷新边界，复用已完成窗口的音频特征、Target KV 和 Draft context KV，用上次尾部预测作 `guessed_token_ids`。恢复 Voxt 原评测的 live 部分，单列首个 partial、松键到 Final 的延迟及与离线转录的差异。桌面验收通过实际按键录音、回填、词典命中及重启后历史可见来判定。
