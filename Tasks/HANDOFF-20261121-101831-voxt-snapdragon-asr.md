# Hugging Face 音频塔在骁龙本安装时转换为原 Veri 1 FP16

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-21 10:18:31 US/Pacific。

当前项目提交 `72dad6314942ab57e1bc46fc63fbe5bca2dc0726`。写入本轮检查点前的 Git 状态：

```text
## main
 M README.md
 M scripts/win-arm64/fetch_veri1.ps1
 M scripts/win-arm64/veri1-release-sha256.json
?? scripts/win-arm64/make_projector_layout.py
?? tools/
```

- 用户明确要保留 Veri 1 F16/FP16 精度，只改分发和本地处理。-ProjectorSource HuggingFace 现下载锁定上游 BF16，再调用约 2 MiB 的原生 ARM64 工具一次性转为原版 FP16。文件通过原验收 SHA-256 才替换；已装 BF16 或缓存 BF16 可直接复用，旧清单恢复原 F16 哈希与标签。已装 FP16 按原逻辑复用。
- Windows 工具在 Mac 交叉构建，file 确认为 ARM64 PE32+。GitHub Release 新增 veri1-projector-fp16-arm64.exe，SHA256 4ad453bab0e8b403ca7ce0c185688a4e217e436790dda372e55ef5d3d2ef96f1，匿名重下载逐字节比对通过。验收服务与原权重附件不变。
- Mac 执行同源码转换 641773984 字节 BF16 投影器，输出与原 Veri 1 FP16 cmp 一致，哈希 d4b5d02d6560745e18d74e84b1cceadf6736bc9b923293aebe14eb43a761c513。PowerShell 真实输入重放通过，验证 BF16 直接复用、转换、旧清单恢复及再次运行无重复下载。非匹配源被拒绝且不产出文件。Windows 工具尚待实机运行。

下一步：在骁龙上运行更新后的下载脚本与快速验收
