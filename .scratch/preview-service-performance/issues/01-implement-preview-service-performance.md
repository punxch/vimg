Status: in-progress

# Implement preview service performance and cache correctness

Implement the accepted design in `../spec.md`, preserving the two linked ADRs and the project glossary.

## 当前执行范围：运行效率

本轮只优化 VCS 与本地服务的运行效率：提取/编码的数据流、CPU 与内存占用、并发上限、缓存发布，以及可重复的性能测量。保持现有 TCP 请求协议和现有 Yazi 调用方式，不将协议迁移作为本轮验收条件。

## 暂不执行：Ya / DDS 集成

以下工作已记录，但明确延后，不能阻塞运行效率优化：

- 将服务接收端从本地 TCP JSON 协议迁移到 `ya` / DDS；
- 用 DDS 传递 queued、shared、completed、failed、busy 等完整生命周期结果；
- 根据 DDS 请求者断开状态清理 orphaned queued job；
- 为 `ya pub-to` 完成通知补齐端到端 DDS 集成测试。

恢复这部分工作时，应单独建立协议迁移任务，并重新确认 Yazi API 版本与兼容策略。

## 原型结论：单 FFmpeg 网格提取

问题：把九个采样 seek 合并到一个 FFmpeg 进程，用 `xstack` 生成完整 RGB 网格后再由 Rust 绘制标签并编码，能否稳定快于当前 lockstep 提取路径并进入 1 秒以内？

结论：否。当前正式路径三次对照为 1.30s、1.20s、1.20s；单 FFmpeg 原型为 1.55s、1.54s、1.45s，慢约 20–25%。原型仍保持 852×480、20fps、1.5s、30 帧结构；标签约 3ms，主要差距来自单进程 `xstack` 提取等待（约 1.27–1.37s）。显式设置 9 个复杂滤镜线程没有改善。

原型作为 primary source 保存在本地 Jujutsu bookmark `prototype-monolithic-ffmpeg`，提交 `1b34ab02`。该方向不应合入正式实现；若继续追求稳定低于 1 秒，应评估进程内 libavcodec/libavformat 解码或已验证缓存直接返回。
