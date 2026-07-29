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

## 原型结论：进程内 libavformat / libavcodec 提取

问题：用九个进程内 libavformat/libavcodec 上下文取代九个 FFmpeg 子进程，同时保留每路容量 2 的有界流、并行 seek、bicubic 缩放、逐帧拼图和现有 SVT-AV1 编码，能否带来足以合入正式路径的端到端收益并稳定进入 1 秒以内？

结论：暂不合入。相同热启动条件下，正式路径五次墙钟为 1.21s、1.21s、1.19s、1.34s、1.21s，平均 1.232s、中位数 1.21s；进程内原型为 1.17s、1.15s、1.20s、1.28s、1.19s，平均 1.198s、中位数 1.19s。平均只快约 2.8%，中位数只快约 1.7%，没有稳定低于 1 秒。原型首个完整网格约 0.77–0.85s，优于正式路径约 0.90–0.99s，但编码回压和尾部耗时吸收了大部分收益。

线程对照显示每个解码上下文 1 线程约 1.72s、2 线程约 1.28s、3–4 线程约 1.23s，继续增加线程没有稳定收益。原型用户态 CPU 时间约 8.4–8.6s，正式路径约 8.8–9.3s，但首次动态库冷装载曾测到约 1.9s 墙钟，且原型峰值 RSS 约 455MB，高于正式命令约 298MB。输出保持 852×480、20fps 输入参数和 30 帧写入，抽查画面与标签一致。

原型作为 primary source 保存在本地 Jujutsu bookmark `prototype-libavcodec`，提交 `5230b1c8`。除非可以接受 FFmpeg 开发库的构建/分发依赖来换取几个百分点的热启动收益，否则不应替换当前子进程实现。若目标仍是稳定低于 1 秒，下一步应单独验证 VideoToolbox 等硬件解码路径，或优先命中已验证缓存。
