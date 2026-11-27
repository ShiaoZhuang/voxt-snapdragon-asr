# Voxt 骁龙实机验收

## Windows ARM64 用户测试版 Pilot 1

在此前已经完成 HTP 实测的骁龙本仓库根目录，用普通 PowerShell 执行。若当前窗口曾设置过实验路由，请先移除该覆盖，或打开新窗口。

```powershell
.\scripts\win-arm64\update_and_verify.ps1
```

默认入口安装并打开原版 Voxt 桌面应用的 Windows 移植版。首次安装校验已有的模型、后端、签名 DSP 库及桌面包，用公开短句检查真实转录和 HTP 放置。通过后生成固定版本目录及桌面快捷方式 **Voxt Snapdragon Pilot 1**。之后用快捷方式即可离线打开同一版。手动入口是 `.local/voxt-user-test/voxt-snapdragon-user-test-1/open_voxt_user_test.ps1`。三个 GGUF 优先与已有模型建立硬链接，跨卷时复制。应用使用原始卷积布局、全 HTP0 音频编码、Q8_0 Target、Q4_0 DFlash、队列深度 8 和 ubatch 512。

首次如看到 Voxt 欢迎引导，可选稍后设置，模型会自动识别。打开普通记事本，把光标放在正文，按一次 **Ctrl+Alt+Space** 开始录音，说完再按一次。观察文字是否进入原输入框、Voxt 左侧「历史」是否出现同一句话。此版本测试停止录音后的最终转录。录音使用 Windows 默认麦克风，需要允许桌面应用访问麦克风。建议各试一条短句和一段日常长话，记录第二次按键后到文字出现的时间。安装报告在命令最后显示；应用启动日志在固定版本目录的 `logs` 下。

## 性能实验入口

旧启动器只更新独立工作树中的测试代码。要启用实时进度和超时保护，请在骁龙本仓库根目录刷新本地启动器一次：

```powershell
git fetch origin veri/native-win-arm64
if ($LASTEXITCODE -eq 0) { git restore --source=FETCH_HEAD -- scripts/win-arm64/update_and_verify.ps1 }
```

要继续做性能实验，在同一仓库根目录运行：

```powershell
.\scripts\win-arm64\update_and_verify.ps1 -Route Explore
```

启动器会显示正在运行的阶段、错误和每 30 秒的等待提示。验证阶段超过 35 分钟会退出并保留已有报告。可用 `-Route QnnLive` 单独跑混合转录对照，或用 `-Route GgmlHexagon` 单独跑 GGML。

需要回到原性能验证流程时，显式选择 `-Route Explore`。736e7af 实机已完成的 Hetero、Wait、Fusion、Dispatch、QnnHtpAudio 和 HtpSuite 已退出自动队列。即使归档已移走也不会重新调度这些整套实验。保留两次全 HTP 原始 JSONL 的机器会离线对比 3a82b3f 与 736e7af 的长音频耗时，并把完整对照写入本次日志中的 `historical-htp-comparison.txt`。

本轮依次运行以下项目。各项目计时串行。之前已通过 LongPair 的机器跳过该项；后续重复执行固定命令也会跳过本机相同试验版本和 DSP 库的成功项。到达 35 分钟启动器时限或手动中断后，再执行同一命令即可继续。新候选的配对测量会在相同条件下运行对照。可以在新 PowerShell 的仓库根目录无参执行。需要单独运行某项时，可设置 `$env:VOXT_VERIFY_ROUTE` 为实验名并执行原命令。

| 实验 | 骁龙本运行的工作 |
|---|---|
| LongPair | 用 104 秒 long-all 对照全 HTP Target-only 与 Q4 DFlash，每个独立服务用同一音频预热，交换测试顺序。 |
| QnnReply | 读取旧 QnnHtpAudio 的 28 层校准捕获，轮换比较原始分块回包与复用缓冲区的合并回包。报告字节一致性、打包及 TCP 回环接收耗时。该计时仅覆盖回包。 |
| Queue | 固定每批最多 2048 个算子、融合开、阻塞等待。先测实际在途批次，队列满 8 则试 16，否则缩到观察到的峰值。记录共享队列大小、CPU 时间和同一短句的端到端耗时。 |
| ConvLayout | 在同一份签名 v73 库上比较原有音频卷积布局和减少中间重排的新布局，记录短句与长中文的编码和整请求耗时、实际设备证据与输出一致性。 |

如果上一轮在 `79c8ac8` 报 `HTP convolution output shapes or multiplicities differ`，运行 Explore。脚本优先读取那一轮的四条请求和两份原始 HTP 日志，从每层 IM2COL 恢复逻辑形状，再核对 GELU 实际执行的形状和步幅。看到 `Rechecking both archived HTP profiles` 表示已找到归档。若归档缺失，Explore 会补采。两条音频各做四对新的热态计时，报告给出编码和端到端的配对速度比，超过 1 表示新布局更快。

成功和失败详情在各项目子目录；最终照片请包含 `VOXT SNAPDRAGON REPORT` 中的新实验结果。历史实验仍可按路由名称显式重测。

选择 `HtpSuite` 可运行全 HTP 的长短音频对照。`zh-plain-1`、`en-3`、`mix-1`、`long-zh` 和 `long-all` 使用评测集给定的语言，长音频按原清单拼接并作为单条请求提交。两种配置都让音频编码和 Target 使用 HTP，其中一种还让 HTP 运行 Q4 草稿。每个服务先转录一次中文短句，再轮换样本，每条测三次。首次请求和模型启动单独报告。用于主表的请求关闭逐算子 DSP profiling，同一配置还用开关 profiling 的热短句核对采样成本与输出。另以 Q4 草稿在两条长音频上对照 512 和 1024 的物理预填充批次。所有模式逐条对照完整 token 和文本。

报告列出端到端 tok/s、请求耗时与音频时长之比（RTF）以及原始混合错误率（编辑数除以参考单位数，汉字逐字、英语按词、忽略标点与大小写，保留口头语）。该口径与 31 条基准的数字和口头语归一化口径不同。输入准备包括 WAV 解码、特征和提示构造；剩余 prompt 耗时是 slot 的 prompt 总耗时减编码，包含调度。Draft、验证、草稿上下文是生成阶段内的计时。DSP 热点百分比以已记录算子的设备耗时之和为分母。逐次请求、转录、参考、token、阶段计时与计数保存在 `htp-suite.jsonl`，各配置另存 stderr。请拍最后的 **VOXT SNAPDRAGON REPORT**。

使用新版启动器选择 `-Route AudioEncoder` 可重新测音频编码占比。使用同一条 `zh-plain-1.wav`，以纯 OpenCL Target-only 为对照，分别在 HTP Target-only 和 HTP Target + HTP Q4 草稿上切换 Adreno / HTP 音频编码。五种配置各测三次，报告取请求 TPS 中位数对应的同一次测量，打印编码器毫秒数、占请求耗时的百分比、编码期间 HTP 算子数和端到端 TPS。服务在完成转录的响应中返回编码微秒数和编码窗口内 HTP0 的非零周期算子计数。编码计时覆盖音频编码器与投影，单独排除特征预处理与语言模型 prefill。原始逐次结果在日志目录的 `placement.csv`。请拍最后的 **VOXT SNAPDRAGON REPORT**。

更新本地启动器后，可用 `-Route All` 重新测完整 Target/Draft 组合及 QNN 八位置验证。QNN 当前只接入满八位置的验证，完整 QNN Target-only 尚无实测。

## GPU + QNN HTP 转录

脚本先采集一批全 GPU 的八位置验证张量，为短上下文下的 28 层量化图确定形状与激活范围。采集和构建会话在计时前完成。先测混合转录，取得实际 HTP 执行记录后才测一次全 GPU DFlash 对照。两条测速请求均使用相同的模型、音频和 Q4 草稿配置。需要已有实机回放创建的 ARM64 QNN Python 环境。

混合路径用 GPU 执行音频预填充、Target prefill、草稿和不足八位置的批次。满八位置时，现有解码器把实际位置、token 和活动历史 KV 交给 QNN worker。worker 把 28 层按顺序分成四个七层 QNN 会话，逐组初始化并报告进度。每组的隐藏状态传给下一组，报告逐组核对 HTP 执行次数。worker 用 HTP 执行 28 层，主机处理 token embedding 和词表输出层。K/V、三处 Draft 辅助状态和 logits 写回原解码器，原接受、拒绝与回滚逻辑继续负责提交顺序。ASR 服务逐轮通过带本次运行随机令牌的本机 TCP 连接传输张量，全部等待、搬运、主机输出层和 QNN 执行时间计入请求 TPS。会话的固定历史容量按报告显示，超出容量会报对应错误。

报告只有在完整 token 序列和转录文本一致、服务与 worker 的满批轮数一致且有 QAIRT 执行记录时给出吞吐倍率。日志目录保存两个请求的计时、转录及 profiler 报告。

## GGML Hexagon 音频转录

脚本先查找现有 Hexagon SDK。找不到时下载 llama.cpp 指南列出的 Windows ARM64 Hexagon SDK Community Edition 6.7.0.0（约 900 MB），校验发布包的 SHA-256，解压到 `build/win-arm64-native/sdk/hexagon`，并在这次构建中传入 SDK 路径。下次会复用该目录。在线下载总预算为 8 分钟。遇到 Schannel 无法查询吊销状态的错误，会在剩余预算内用 `--ssl-revoke-best-effort` 重试一次。其他网络错误可在剩余预算内用 PowerShell 重试。默认 Downloads 或 SDK 缓存目录里的同名发布包可直接校验和解压。[上游 SDK 发行页](https://github.com/snapdragon-toolchain/hexagon-sdk/releases/tag/v6.7.0.0)

官网 ZIP 解压后可把 `HEXAGON_SDK_ROOT` 指向包含 `build/cmake/hexagon_fun.cmake` 的版本目录。该 SDK 缺少 Windows 可选扩展时，GGML 会在构建目录应用与 Community Edition Windows 发行包相同的兼容设置，也会识别 ZIP 中 `WinNT` 目录的 IDL 编译器。兼容处理保留原 SDK 文件。[上游 Windows SDK 补丁](https://github.com/snapdragon-toolchain/hexagon-sdk/blob/v6.7.0.0/patches/wos-patch)

普通 PowerShell 在仓库根目录运行 `.\scripts\win-arm64\update_and_verify.ps1 -Route GgmlHexagon`。默认由本项目服务运行转录，DSP 使用 Qualcomm GenieX 官方原版 v73 库和配套签名目录。脚本核对两个文件的 SHA-256，从 GenieX CLI 安装目录或构建缓存取用；未找到时读取 Downloads 内的官方 SDK ZIP，或自动下载并校验 v0.12.0 ZIP。无需导入自签证书。报告列出选用目录、Windows 验签、HTP0 会话、请求内 DSP 算子事件和请求 TPS。[官方发布包](https://github.com/qualcomm/GenieX/releases/tag/v0.12.0)

自定义 DSP kernel 实验可在当前终端设 `$env:VOXT_HTP_PACKAGE='native'`，再跑相同命令。清除该变量即可恢复官方库。以下签名流程用于自编库模式。该模式从同一份固定 llama.cpp 源码构建 Windows 服务和 v73 DSP 算子库。已有 catalog 时复用。缺少 catalog 时，脚本检查 Windows 的 `CurrentUser\My` 和 `LocalMachine\My`，优先选有效且带私钥的当前用户代码签名证书。可用 `VOXT_HTP_SIGNING_THUMBPRINT` 指定证书指纹。找到可用证书后，使用 WDK 的 `Inf2Cat` 生成 catalog，用 `SignTool` 签名并验证 v73 算子库和 INF 的目录成员关系，然后尝试 HTP0 转录。最终以设备加载结果和实际请求的 DSP profiler 为准。[Inf2Cat](https://learn.microsoft.com/en-us/windows-hardware/drivers/devtest/inf2cat) · [SignTool](https://learn.microsoft.com/en-us/windows/win32/seccrypto/signtool)

两个证书库都找不到合适的证书时，脚本使用当前用户的临时自签名证书试跑。自签包保存在该轮日志目录，签名后清理临时证书和私钥。下次优先复用同一份有效自签包，核对库和 INF 的哈希及原运行记录的签名指纹。新生成的测试证书有效期为七天。即使通用签名验证返回错误，也会用正常 HTP 加载路径实测，并保留原始错误。[PowerShell 测试证书文档](https://learn.microsoft.com/en-us/powershell/module/pki/new-selfsignedcertificate)

缺少 `Inf2Cat` 或 `SignTool` 时，脚本查找 Downloads 和构建缓存里的同名 NuGet 包，或从微软 NuGet 下载相应工具包。每个包的 90 秒预算包含与 Hexagon SDK 共用的 Schannel 重试。若 curl 传输超时（退出码 28），脚本在剩余预算内用 Windows PowerShell 再取一次。脚本核对 SHA-256 并在本轮日志目录解包工具及依赖。[微软 WDK NuGet 说明](https://learn.microsoft.com/windows-hardware/drivers/install-the-wdk-using-nuget) · [curl 的吊销检查参数](https://curl.se/docs/manpage.html#--ssl-revoke-best-effort)

工具或签名失败时，报告会打印原因和待签的 `v73 package` 目录。可以把匹配的 `libggml-htp.cat` 放回该目录，也可将 `GGML_HEXAGON_LIBHTP_DIR` 指向包含同一 SHA-256 算子库及其签名 catalog 的目录。已有 PFX 环境仍可设置 `HEXAGON_HTP_CERT` 使用上游构建签名路径。[固定版本的上游 Windows 说明](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/docs/backend/snapdragon/windows.md)

对同一条 `zh-plain-1.wav`，单独选择 `-Route GgmlHexagon` 时测 HTP0 Target-only 和 HTP0 Target 配 Q4 DFlash。音频投影及可选草稿都在 Adreno。每个测试启动独立服务，比对两个 HTP 请求的完整 token 序列和转录文本。同轮有 GPU 校准转录时也复用其 token 和文本进行对照。GGML Hexagon 还要求请求开始后出现有非零周期的 DSP 算子记录。GGML 调度器可能将部分计算放在主机上。每个测试的 `.txt` 保存原始日志，`.metrics.json` 保存文本、token 和计时。摘要中的 request tok/s 使用生成 token 数（排除 EOS）除以 HTTP 请求时间，包括音频预填充和解码，排除启动加载时间。HTP 测试打开了设备 profiling。

对自签信任做前后对照时，用同一条命令跑两次。第一次报告给出公钥证书 `htp-signer.cer`、签名指纹、有效期、本机证书库和可读取的 BCD 测试签名设置。设备管理员核对原始指纹，通过设备适用的测试签名流程配置该公钥证书。在 Windows 测试设备上，上游使用本地计算机的 Trusted Root Certification Authorities 和 Trusted Publishers。在允许设备测试签名的机器上，可在仓库根目录的管理员 PowerShell 运行报告中带完整指纹的 `Elevated setup from repo root` 命令。脚本只接受本项目导出且指纹匹配、有效的代码签名公钥证书，导入后为当前启动项设置 TESTSIGNING。若启动配置写入失败，脚本回滚本次新增的证书。手动重启后，普通 PowerShell 的 GGML 报告中 `Active kernel test signing: True` 表示当前运行的内核允许测试签名。该模式影响整机。使用相同命令复测，报告在服务、库和目录文件哈希均匹配时并列列出最近一次结果及当前 HTP0 Target-only 结果。证书过期或包变更时重新建立基线。[llama.cpp Windows 测试签名说明](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/docs/backend/snapdragon/windows.md)

## 完整 Target 回放

内部工作脚本 `current_handoff.ps1` 的 `-FullReplay` 模式仍可运行完整回放。流程从公开 `zh-plain-1.wav` 捕获真实八位置验证批次，串起 28 个独立 HTP 层会话，把上一层的隐藏输出传给下一层。每层复用 Adreno 采集的历史 K/V，计算当前八位置的 K/V 与隐藏输出。CPU 运行小批次 QDQ 数值对照。HTP 禁用 CPU fallback，各层都检查 QAIRT 执行记录。最后用主机原 Q8_0 词表投影比较 logits、top-1 和 DFlash 三处辅助输入。

每层需要 CPU 对独立参考的相对 L2 ≤0.25%，HTP 对同输入 CPU 的相对 L2 ≤0.5%，最大误差分别 ≤参考峰值的 1% 和 2%。整批次还需要八个 top-1 全部匹配。第 27 层保存 attention 残差相加前后的状态和 FFN 各阶段。原生重建采用 5% 相对 L2 门槛，在有完整采集时逐阶段以原生输入检查，同时报告累计误差。若原生重建超出门槛，脚本继续采集 HTP 和 logits 结果，并列出超限项。若仅末层 ffn_down 超过 5% 且数值有限，允许在完整链八位置 top-1 一致时通过；缺层、超时、无执行证据和非有限数值仍失败。

先用原生输入单测第 27 层，再运行串联回放。每层 HTP 使用独立进程，最多等待 45 秒。若一层无法执行，后续层用下一份原生激活继续诊断，同时保留已有结果。串联验证的启动预算为 900 秒，整段回放由 1050 秒保护。报告在超时时标出最后记录的阶段及已保存的层数，日志保留单层 QNN 初始化、执行、profiling 和清理阶段。

各层中位数之和由每层三次热态运行得出。端到端时间、原生 KV 跨轮提交和连续转录属于下一阶段。每层数据和完整结果留在 `Logs` 指向的 `target-replay` 目录。

## Hexagon HTP 依赖

固定脚本从现有项目环境、PATH、Windows 注册信息和 `py` 启动器中查找标准版 Windows ARM64 CPython 3.11–3.14。屏幕摘要会列出已检查的解释器路径、平台和版本。若显示 `No compatible Python found`，请安装公司允许使用的 Windows ARM64 CPython 3.14，再运行同一条验证命令。[Python 3.14.10 官方下载页](https://www.python.org/downloads/release/python-31410/)

脚本会创建或复用 `.local` 下的隔离环境，从本机配置的 pip 软件源安装 `tools/qnn-probe/requirements-win-arm64.txt` 中锁定的包。依赖安装失败时，原始输出在 `qnn-dependencies.stdout.log` 和 `qnn-dependencies.stderr.log`。[QNN EP v2.8.0 安装说明](https://github.com/onnxruntime/onnxruntime-qnn/tree/v2.8.0#install)

新加的 `gguf` 包仅用于读取本地原始权重。模型、捕获数据、临时 ONNX 和日志都留在本机。

## 骁龙本从源码构建与验收

在骁龙本的 PowerShell 中打开源码仓库根目录。脚本会使用已有的 Visual Studio ARM64 环境、CMake、Ninja 和 Python。需要公司批准的 Clang，可使用 Visual Studio 的 **C++ Clang Compiler for Windows** 组件。锁定的 Windows ARM64 OpenCL 后端要求 Clang，Visual Studio 提供 Windows 链接所需的头文件和库。[llama.cpp 构建要求](https://github.com/ggml-org/llama.cpp/blob/e412c6f468b7b9e0f16f2540244236f8ad68e9ae/docs/backend/OPENCL.md#L196)

```powershell
.\scripts\win-arm64\build_native.ps1 -BackendOnly
.\scripts\win-arm64\probe_opencl_startup.ps1 -NativeBuildDirectory .\build\win-arm64-native -Transcribe
```

只检查工具时运行 `build_native.ps1 -BackendOnly -ToolchainCheck`。后端快测复用已有 Veri 1 模型和 `zh-plain-1.wav`，不用 Go。成功会记录 `Transcription probe: PASS`，回传 `Report saved to:` 指向的文本文件即可。

安装公司批准的 Go 1.27.1+ 后，从同一源码标签执行完整快测：

```powershell
.\scripts\win-arm64\build_native.ps1
.\scripts\win-arm64\run_verify.ps1 -NativeBuildDirectory .\build\win-arm64-native -OpenCLOnly -Quick
```

构建在骁龙本生成后端、OpenCL loader 和评测器。继续使用 `dist\voxt-snapdragon-veri-1` 的现有模型、评测集和资产清单。若资产在其他目录，用 `-InstallDirectory` 指向该目录。复验通过条件为两组 OpenCL 快测 PASS，DFlash 有候选被接收并与 Target-only 逐 token 一致。需要复测 CPU 时，可单独调用 `run_verify.ps1` 并省略 `-OpenCLOnly`。

回传 `Results:` 目录内的 `verify_report.md` 和 `verify_stats.json`。若构建失败，回传第一条工具错误及其上下文。若公司策略拦截本机构建的程序，按 IT 的软件审批流程处理。

## OpenCL 启动修复复验

在已安装 Veri 1 的骁龙本上，从源码仓库根目录运行：

```powershell
git fetch origin tag veri-1-opencl-fix
git switch --detach veri-1-opencl-fix
.\scripts\win-arm64\fetch_veri1.ps1 -OpenCLFixOnly
.\scripts\win-arm64\run_verify.ps1 -OpenCLFix -Quick
```

只下载约 6 MB 的 ARM64 运行时更新，复用已安装的模型、依赖和评测集。脚本独立校验新 EXE 的 SHA-256，将它和 Veri 1 原版 EXE 并排放置。可通过 `-Destination` 和 `-InstallDirectory` 分别指定自定义的 Veri 1 安装目录。

通过条件为四组快测都显示 PASS，两个 OpenCL 模式完成转录，OpenCL DFlash 有候选被接收且与 OpenCL Target-only 逐 token 一致。先回传 `Results:` 目录里的 `verify_report.md` 和 `verify_stats.json`。失败时一并回传该组 `.log`。

## 排查 OpenCL 启动崩溃

如果 CPU 快测通过，但 OpenCL 在读取 `target.gguf` 后以 `0xC0000005` 退出，在源码仓库根目录运行：

```powershell
.\scripts\win-arm64\probe_opencl_startup.ps1
```

探针复用 `dist\voxt-snapdragon-veri-1` 中已安装的运行时和模型，可用 `-InstallDirectory` 指定其他位置。它仅启动一次 OpenCL Target，记录完整 stderr、退出码和过去两天相关的 Windows 应用崩溃事件。把 `Report saved to:` 指向的文本文件发回即可。整个探针无需下载文件或跑评测集。

## 运行验收

在 Windows 11 ARM64 的骁龙 X Elite 笔记本上验证 Voxt 本地转录后端。整个交接目录含原生 EXE、OpenCL loader、模型和公开评测集。需要系统已有 Qualcomm Adreno OpenCL 驱动。目录中的 `verify_manifest.json` 记录准确源码版本和各文件的 SHA-256。

1. 将整个 Veri 1 目录复制到骁龙本并在其根目录打开 PowerShell。
2. 运行 `.\scripts\win-arm64\run_verify.ps1`。如需先做快速探针，加 `-Quick`。
3. 将脚本输出路径下的 **verify_report.md** 和 **verify_stats.json** 带回 Mac。失败时也回传这两个文件。

完整验收会分别在 Oryon CPU、Adreno OpenCL 上跑 Target-only 与固定 Q4 Draft，共四组 31 条。每组识别错误率需 ≤3.4%，词典命中 ≥7/10。Draft 全集平均接受 ≥3.0，三个干净句的平均接受 ≥5.3。同一设备逐 token 对齐 Target-only。耗时用于比较与定位，报表分开记录 Draft、Target 验证和 Context。实机使用阶段仍是通过公开 WAV 驱动的 Voxt 协议后端。


通过 GitHub 获取 Veri 1 时，请在源码仓库根目录运行新版 `.\scripts\win-arm64\run_verify.ps1 -Quick`。它会直接使用已组装的官方安装目录，也可以用 `-InstallDirectory` 指向自定义安装目录。

## Target 和 Draft 设备组合实测

在 Windows ARM64 仓库根目录使用新版启动器运行 `.\scripts\win-arm64\update_and_verify.ps1 -Route All`。GGML 先在同一份 Hexagon + OpenCL 主机上轮换测试 GPU/HTP 两种 Target-only 和四种 Target/Draft 组合。音频投影始终使用 GPU。每种运行三次，每次重启服务，使用同一条 zh-plain-1 和相同模型。按请求吞吐中位数报告，模型初始化不计入 TPS。脚本检查模型加载的设备名、输出文本和完整 token，含 HTP 的路线还检查请求内 DSP 算子事件。一种组合失败会记录日志并继续其他组合。每轮指标保存在 placement.csv，原始日志保留模型、KV、计算缓冲区分配和每个阶段的请求指标。

随后测试 GPU prefill、GPU 草稿和 QNN 满八位置 Target 验证。QNN worker 初始化一次，三次请求各自重启 ASR 服务；通过累计设备事件和逐次完整 token 对照验收。报告记录本机连接收发的张量字节数及准备、等待 worker、读回应用的耗时，等待包含推理。GGML 的跨设备数字仅覆盖可识别的同步 tensor copy，不包含所有驱动搬运或排队。内存为请求期间按 50 ms 间隔采样的进程私有提交量和工作集峰值，混合路线计入同一时刻的 ASR 服务和 QNN worker；工作集之和可能重复计算共享页。设备驱动驻留和初始化峰值不在该指标内。
