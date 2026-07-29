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

## 原型结论：进程内 VideoToolbox 硬件解码

问题：在九路进程内 libavformat/libavcodec 管线中共享一个 VideoToolbox 设备、为每个采样点建立独立硬解上下文，并且只把命中的 270 个采样帧传回系统内存，能否显著降低端到端时间和 CPU 占用并稳定进入 1 秒以内？

结论：方向成立，但仍未进入 1 秒。最终每个硬解上下文使用 1 个 codec worker；五次暖态墙钟为 1.16s、1.17s、1.15s、1.15s、1.15s，平均 1.156s、中位数 1.15s。同期正式路径为 1.22s、1.19s、1.31s、1.32s、1.20s，平均 1.248s、中位数 1.22s；VideoToolbox 平均快约 7.4%、中位数快约 5.7%。首个完整网格约 0.82–0.84s，270 帧硬件到系统内存的传输总计约 0.05–0.09s。

主要收益是 CPU：原型用户态 CPU 约 1.09–1.25s，正式路径约 8.85–9.09s，降低约 86%。每个硬解上下文 1 线程略优于 3 线程；增加 codec worker 对硬件吞吐没有帮助。暖态峰值 RSS 约 348MB，高于正式路径约 298MB；首次动态库冷装载曾测到 1.98s。日志确认全部 270 帧均来自 VideoToolbox，没有软件回退；输出保持 852×480，抽查画面与标签一致。

原型作为 primary source 保存在本地 Jujutsu bookmark `prototype-videotoolbox`，提交 `fe0276c9`。若优先级包含 CPU、功耗和 macOS 连续预览吞吐，建议将它继续产品化为有软件回退的 macOS 可选路径；若只看单次命令墙钟和跨平台分发，当前 5–8% 收益还不足以直接替换默认实现。

## 原型结论：Bilinear 缩放

问题：将 VCS 提取缩放从 bicubic 改为 bilinear，能否在允许缩放质量变化的前提下带来至少 3% 的稳定端到端收益？

结论：否。通过同一 release 二进制交错切换 scaler，排除第一组动态装载后的五组热态配对中，bicubic 与 bilinear 的 profile total 平均分别为 1.255s 和 1.223s，bilinear 只快约 2.6%；中位数只快约 2.2%，用户态 CPU 只降低约 2.9%。两边都输出 852×480、20fps、30 帧，但编码后 SSIM 为 0.9951，画面不是像素等价。

原型作为 primary source 保存在本地 Jujutsu bookmark `prototype-mtn-bilinear`，提交 `cefff0a8`。该方向未达到 3% 阈值，不应改变默认 bicubic；只有未来明确提供快速/低质量缩放档时才考虑复用。

## 原型结论：预滚阶段丢弃非参考帧

问题：进程内软件解码 seek 后先使用 `AVDISCARD_NONREF`，在采样起点前恢复 `AVDISCARD_DEFAULT`，能否降低长 GOP 预滚成本，同时完整保留 9×30 个目标帧？

结论：当前样本上成立，并稳定进入 1 秒以内。采用 0.5 秒完整解码余量的六组交错配对中，进程内完整预滚与 nonref 预滚的实际墙钟平均分别为 1.208s 和 0.928s，降低约 23.2%；profile total 从 1.195s 降到 0.916s，首个完整网格从 0.815s 降到 0.553s，用户态 CPU 从 8.525s 降到 5.782s。六次 nonref 实际墙钟均为 0.91–0.97s，9 路解码器都成功恢复完整解码且补帧数为 0。

正确性验证在 encoder 前导出了全部 270 个 RGB tile。基线与 nonref 的 36,806,400 字节逐字节相同，SHA-256 都是 `88d9b4594cfe86f9aa7e6c34ce88009f0e3714016b5f04c7dcb4fa221650fa64`；最终动画 AVIF 也逐字节相同。0.25 秒和 0.125 秒余量在本样本仍相同，但 0 秒余量已经产生画面差异，证明必须为 frame threading 和帧重排序保留恢复窗口。

原型作为 primary source 保存在本地 Jujutsu bookmark `prototype-mtn-preroll-nonref`，提交 `982bae84`。这一结果足以重新评估此前暂不合入的进程内 libav 路径；跨语料门槛已在下一节完成。

## 原型结论：Nonref 预滚跨语料验证

问题：0.5 秒恢复完整解码余量能否在 H.264/H.265、不同 GOP/B-frame、VFR、短片和远离关键帧的文件尾部采样中，保持全部 270 个目标 tile 及其源 PTS 与完整预滚严格一致？

结论：本轮预定门槛全部通过。语料包含真实 1080p H.264 MKV，以及 H.264/H.265 的 GOP 240+B-frame、GOP 12+无 B-frame、VFR、1.627 秒短片、GOP 360+8 B-frame+整个文件只有一个关键帧的尾部压力样本，共 11 个。每个样本都分别运行完整预滚和 0.5 秒 nonref 预滚。

所有 11 个样本均满足：

- encoder 前的 270 个 RGB tile 逐字节一致；
- 270 条“动画帧、采样点、源 PTS”记录逐字节一致；
- 最终动画 AVIF 逐字节一致，动画流均为 30 帧；
- 9 路解码器均恢复 `AVDISCARD_DEFAULT`，补帧数均为 0。

真实样本本次从 1.246s 降到 0.886s。小型 640×360 正确性语料只有一次计时且经常由 encoder tail 主导，不作为性能结论；其中 H.264 long-GOP 样本出现 0.271s→0.297s 的小幅反向波动，不影响严格等价结果，也不能说明该类媒体必然变慢。

可复现原型保存在本地 Jujutsu bookmark `prototype-mtn-preroll-corpus`，提交 `3eb3ea8f`；单命令为：

```sh
bash src/bin/prototype_preroll_corpus.sh ./sample/input.mkv
```

这一结果将进程内 libav + nonref 预滚从“继续调研”提升为“可产品化候选”。正式实现应先作为可选软件后端，保留 0.5 秒余量，并在不支持的 codec、无时间戳、seek/解码失败或输出异常时回退现有 FFmpeg 子进程路径；Ya/DDS 仍不在本轮范围内。
