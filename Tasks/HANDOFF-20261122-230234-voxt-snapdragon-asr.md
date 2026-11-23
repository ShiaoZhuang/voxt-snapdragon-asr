# 骁龙本 Clang 检查已通过，已复现并修复 Windows 补丁换行错误

所属任务：[TASK-20261121-voxt-snapdragon-asr.md](TASK-20261121-voxt-snapdragon-asr.md)。时间：2026-11-22 23:02:34 US/Pacific。

当前项目提交 `88f26eacfd78917d1b5baa87fe136b3d97f29661`。写入本轮检查点前的 Git 状态：

```text
## veri/native-win-arm64...origin/veri/native-win-arm64
 M Tasks/INDEX.md
 M Tasks/TASK-20261121-voxt-snapdragon-asr.md
 M scripts/prepare_benchmark.py
 M scripts/win-arm64/build_native.ps1
?? .gitattributes
?? Tasks/HANDOFF-20261122-222542-voxt-snapdragon-asr.md
?? Tasks/HANDOFF-20261122-224303-voxt-snapdragon-asr.md
```

- 骁龙本 2026-11-23 14:57 +08:00 的第二次报告由固定入口运行 88f26ea，已越过 Clang 检查并拉取固定 llama.cpp。构建被 git apply 拦在 tools/server/CMakeLists.txt:76、tools/mtmd/mtmd-helper.h:121 等处，尚未进入 CMake 编译。
- 报告缓存目录补丁哈希 d075654c7c39 与原补丁 CRLF 转换结果精确匹配；库中 LF 版本是 10a9b7c26148。在固定上游 LF 源码上复现 CRLF git apply --check 返回 1，LF 原版返回 0。
- 增加补丁 Git eol=lf 属性，原生构建在运行时规范化补丁并使用一致的缓存哈希，已有 CRLF 工作树也适用。存在同一上游提交的旧本地 llama.cpp 缓存时从该 Git 源取固定提交，避免再次请求网络。Go runner 准备同样使用 LF 补丁和禁用 autocrlf 的 git archive。
- Mac 模拟 core.autocrlf=true 下的后端和完整脚本都通过，验证上游不可达时仍可用旧缓存，本地重复构建入口可重跑、Go ARM64 构建和全量数据哈希通过。Windows 风格旧工作树可以快进，新工作树保持补丁 LF。实机 CMake/Clang 和 Adreno 尚待复跑。

下一步：重跑固定 update_and_verify.ps1，让骁龙本继续 CMake/Clang 构建并回传单条 OpenCL 报告
