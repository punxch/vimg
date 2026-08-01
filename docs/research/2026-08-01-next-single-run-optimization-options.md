# Windows 固定命令的下一轮单次运行优化选项

> 2026-08-01 更新：本文两个 P0 均已由原型验证闭合，结论见
> [report.md 原型验证节](../../report.md)：三级 discard 因 FFmpeg 8.1.2 的
> `AVDISCARD_BIDIR` 在含 reference-B 的稳态 mini-GOP 上永久损坏 P 帧链而被
> 否决（CLI `-skip_frame bidir` 独立复现，任何恢复区都不安全）；原生
> parser + 共享 D3D11VA/CUDA 功能上逐字节成立（270 PTS、270 raw RGB、
> AVIF SHA 全一致，parser-skip 先于硬件已证实），但强制单线程后比当前软件
> 慢 4–16%，不达 8% 推广门槛。剩余可操作空间回到下方 P1 小项。

日期：2026-08-01  
范围：`vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif`，Windows、i9-12900K、RTX 3090  
基线：当前默认 `auto -> libav`、进程内 probe、选择性 DT3、进程内 SVT-AV1/AVIF、`lp=2`

## 结论

当前实现已把外部进程、重复 probe、非视频流 packet、SVT 子进程和固定 DT2 的主要成本拿掉。现有报告的最终 warm 数据为 profile total 约 1.19–1.28 s，ABBA median 1.252 s、P95 1.295 s；decode max 约 1.13 s，encoder tail 约 0.135 s。下一轮不能再从 preset、CRF、普通 CUDA CLI、thread-map 扫描或 lazy scale 中期待大收益。

本轮临时分段探针进一步显示，关键 cap7 worker 的 1.128 s 中，`avcodec_send_packet` 同步路径占 0.878 s，而 `receive_frame` 只有 0.153 s。这不是永久 profile 功能，探针现已移除；但它把下一轮方向明确收敛到“减少送入软件 decoder 的 picture/NAL”或“让这段工作进入硬件”，而不是继续调整接收轮询、缩放或 CPU affinity。

还剩两条值得优先原型化的关键路径：

1. **重新打开“原生 FFmpeg H.264/HEVC + 硬件 surface”路径。** 之前关闭的是独立 `h264_cuvid` decoder；FFmpeg 原生 `h264`/`hevc` decoder 会在硬件回调之前执行 `skip_frame`，理论上可以同时保留 nonref preroll 和 NVDEC/D3D11VA。先做计数探针，不先集成。
2. **把 H.264 preroll 从两级 `NONREF -> DEFAULT` 改成三级 `BIDIR -> NONREF -> DEFAULT`。** 固定样本的长 GOP 中存在 reference B；`BIDIR` 能在早期 preroll 连这些帧也不解码，同时保留 I/P 链。它有本轮最大的纯 CPU 理论上限，但必须用 authority 证明恢复区足够。
其余方案降为 measurement-gated P1：先判断重复 stream-info probe 和 direct swscale 的真实上限；encoder 初始化只作为 RSS 错峰实验。实测 `EncoderState::new()` p50 约 43 ms，而且当前已与 capture worker 解码重叠，异步化几乎没有新的可隐藏区间，延后到首个 grid 反而可能增加延迟。

建议实现候选时重新加入编译期或环境变量控制的分段探针，至少保留 packet-read/scale/channel-wait 和 `encoder_setup` 计时。若前两项都不能稳定改善 P95，剩余 byte-identical 空间只适合做由实测上限触发的 probe、复制、缩放和 label 微优化；要再获得明显降幅，就需要接受新 SVT bitstream 或修改 Preview profile。

## 已实现或已有负结论：不要重复

本轮结论以 [`report.md`](../../report.md) 和[上一轮研究](2026-08-01-windows-runtime-optimization-options.md)为前提：

- 已实现：进程内 libav probe/decode、非视频流 `AVDISCARD_ALL`、nonref preroll、0.125 s recovery margin、预滚零拷贝、previous RGB、小范围 DT3、进程内 SVT/AVIF、`lp=2`。
- 已回退：阻塞 round-robin（总耗时变慢且 RSS 超预算）、lazy scale（wall 无收益且保留全分辨率 frame 使 RSS 超预算）。
- 已关闭的具体实现：9 个外部 FFmpeg CUDA/DXVA2 进程，以及独立 `h264_cuvid` 共享设备探针。后者不能代表下文的“原生 parser + hwaccel”路径。
- decoder thread 已完成更细 sweep：长窗口 DT2/DT3/DT4/DT5 的 p50 分别为 1.490/1.394/1.387/1.586 s；短/长组合扫描后，当前 2/3 thread map 仍最佳。DT4 相对 DT3 仅 7 ms，不能补偿内存和复杂度，DT5 明显回退。
- nonref recovery margin 的 50/75/125 ms、各 12 轮 p50 分别为 1.397/1.432/1.387 s，输出 SHA 均一致但没有稳定收益；保留 125 ms，不再扫固定 margin。
- all-core 与 P-core-only 的 p50 分别为 1.312/1.324 s；CPU Sets 方向在本机已关闭，除非未来 ETW 明确发现新的迁核回归。
- SVT 4.1 `lp=1/2/3/4` 的 wall p50 分别为 1.484/1.329/1.311/1.295 s，RSS 分别约 524–536/553–561/604–619/665–674 MB，输出均为权威 SHA。单独提高 LP 的速度上限很小且内存代价过高，不再重复扫描。
- 其他不再扫描项：全局 decoder thread count、`-T`、preset、CRF、8/10 bit、普通 seek flags、`lookahead=0`、low-delay、CLI GPU filter 顺序。
- 不用 RTX 3090 NVENC 编 AV1，也不用 still-picture `avif=1` 编 30 帧动画。

## 当前关键路径与测量缺口

[`libav.rs`](../../src/command/libav.rs) 的顶层 `decode` 指标把打开输入、seek、packet demux、`send_packet`、`receive_frame`、scale、RGB copy 和 channel 背压合并为一个 worker wall time。本轮曾临时拆出 `open`、`seek`、`decoder_setup`、`send_packet`、`receive` 和剩余 `other`；得到关键 cap7 的 1.128/0.878/0.153 s 证据后已移除，不应把它描述成现有产品功能。后续候选应按需重新加入 gated profiling，并继续补齐：

- 每 worker：把 `other` 再拆为 `packet_read`、`scale_copy`、`channel_send_wait`，并记录 packet 数/字节数、实际 decoder threads；
- 全局：从 worker spawn 起算的 `capture_makespan`、`encoder_setup`、encoder 第一次 send/第一次 packet、SVT drain、分阶段 peak working set；
- 硬解探针：送入原生 decoder 的 NAL/packet 数、真正触发 hardware callback 的 picture 数、hardware output 数和 `av_hwframe_transfer_data` 次数。

当前 [`encode.rs`](../../src/command/encode.rs) 在 `InProcessAvifEncoder::start()` 中同步完成 `EncoderState::new()`，而 [`vcs.rs`](../../src/command/vcs.rs) 的 `first_grid` 从 encoder 已创建之后才开始计时；所以 `encoder_setup` 是现有指标中最重要的盲区。

一次当前二进制的诊断性 warm smoke（不是统计基准）记录到 566 个 decoded frame、254 个 preroll frame、首个 grid 前接收 241 帧。这说明：一方面 preroll 仍占约 45% 的 decoder 输出工作；另一方面当前接收策略会让大多数快 worker 在最慢 worker 给出第 1 帧前接近完成。后者正是“延后 SVT 大内存阶段”可能成立的本地依据。

## 候选方案排序

| 排名 | 方案 | 已知上限/依据 | Byte identity | RSS 风险 | 决策 |
|---:|---|---:|---|---|---|
| 1 | 原生 `h264`/`hevc` + 共享 D3D11VA/NVDEC，保留动态 `skip_frame` | 未知；直接作用于占 0.878/1.128 s 的关键段 | 中：硬解像素、PTS、下载路径需实证 | 中高：hardware surface pools | 立即做独立计数探针 |
| 2 | `BIDIR -> NONREF -> DEFAULT` 三级 preroll | 固定样本理论少解约 127/566 帧；wall 必须实测 | 高风险：reference-B 恢复 | 低，预期下降 | 先做软件 CPU A/B，再与硬解组合 |
| 3 | 避免 9 次重复 `avformat_find_stream_info()` | 未知；先用临时 `open` 分段定上限 | 低到中：流参数完整性 | 低 | 做低复杂度 Matroska 探针 |
| 4 | direct `sws_scale_frame` + move-only grid + label mask cache | 未知；由 `scale_copy`/join 分段定上限 | 低到中：色彩/stride/rounding | 低，预期下降 | probe 后做 |
| 5 | encoder setup 错峰 + `lp=2/3/4` | setup p50 43 ms 且已大多与 decode 重叠；wall 余量接近零 | 低：参数不变时应相同，但仍须 SHA gate | 延迟 setup 可试降重叠峰值；高 LP 会增 RSS | 仅作 RSS 调度诊断 |
| 6 | 单 demuxer 预取并分发 ref-counted packets | 未知；仅在 demux 达晋级门槛时继续 | 中 | 中：压缩 GOP staging | 由新计时触发，不抢跑 |
| 7 | SVT-AV1 4.2.0 / startup mini-GOP | 上限受约 0.135 s tail 限制 | 高：版本/GOP 会改码流 | 4.2 可能下降；需实测 | 作为允许新码流的独立轨道 |

上表只列已测 phase 上限、工作量上限或“未知”，不是收益承诺。高复杂度硬解只有在 warm P95 至少改善 8% 且保持回退可靠时才值得合入；微优化至少应稳定改善 2% 或 20 ms，否则不应用增加的复杂度换噪声内收益。

## P0：原生 H.264/HEVC parser 加共享硬件设备

### 为什么旧 `h264_cuvid` 负结论不充分

FFmpeg 8.0 原生 H.264 decoder 的 `decode_nal_units()` 先检查 `skip_frame >= AVDISCARD_NONREF && nal_ref_idc == 0` 并跳过 NAL，之后才调用 hardware `start_frame`/`decode_slice`；同一个原生 `ff_h264_decoder` 注册了 D3D11VA、D3D12VA、NVDEC 等 hardware configs。[FFmpeg H.264 decoder source](https://www.ffmpeg.org/doxygen/8.0/libavcodec_2h264dec_8c_source.html)

HEVC 原生 decoder 也先以 `ff_hevc_nal_is_nonref()` 处理 `skip_frame`，之后才进入 hardware frame callback，并注册 D3D11VA/D3D12VA/NVDEC configs。[FFmpeg HEVC decoder source](https://www.ffmpeg.org/doxygen/8.0/libavcodec_2hevc_2hevcdec_8c_source.html)

这与之前显式选择 `h264_cuvid` 是不同架构：让 `avcodec_find_decoder(AV_CODEC_ID_H264)` 返回原生 parser/decoder，再用 `avcodec_get_hw_config`、`get_format` 和共享 `hw_device_ctx` 选择 CUDA 或 D3D11 surface。FFmpeg 官方硬解示例正是这个 public API 流程，并在需要 CPU 数据时才调用 `av_hwframe_transfer_data`。[FFmpeg `hw_decode.c` example](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/doc/examples/hw_decode.c)

因此新探针应是：

1. 创建一个 CUDA 或 D3D11 `AVHWDeviceContext`，9 个原生 decoder context 各持有一个 `av_buffer_ref`；先测 D3D11VA，再测 CUDA/NVDEC。
2. 保留当前 seek 和动态 `NONREF -> DEFAULT`；为每个窗口记录 demux packet、parser 跳过、hardware submitted/output 三层计数，证明 nonref frame 没进入硬件解码。
3. preroll hardware frame 不下载；仅对达到 schedule offset 且可能入选的 frame 做 `av_hwframe_transfer_data`，继续沿用 CPU bicubic/RGB、现有 join 和 SVT，先争取 raw grid 与最终 AVIF SHA 完全一致。
4. PTS 必须来自原生 decoder 的 frame timestamp；不能沿用旧 cuvid 探针中“输出帧无 PTS”的临时推算。
5. CUDA 与 D3D11VA 分开测单 device/9 decoder，禁止每 worker 创建设备 context。

旧探针的 0.53–0.59 s 只是 9 窗口各 30 个目标 frame（共 270 帧）的 makespan，不含真实 preroll；旧 1.86 s 负估算则是假设 `h264_cuvid` 把约 855 帧全部解码。新路径若 skip 生效，应按真实 hardware-submitted picture 数重新估算，不能把任何一个旧数字直接当端到端预测。

### 推广门槛

- 强制硬件后端不能静默软件 fallback；profile 必须打印 device、pixel format、hardware submitted/output/transfer。
- 固定样本 270 source PTS、30 raw RGB grid hash、最终 AVIF SHA 全部一致；H.264 与 HEVC corpus 分开晋级。
- warm ABBA 至少 12 轮/臂，hardware total P95 比当前 libav 至少快 8%，且 P95 不超过 1.3 s。
- 峰值按 vimg、driver shared memory/专用显存、进程树分别记录；任何 surface 泄漏或第二次运行增长都直接否决。
- 强制 hardware failure 后 whole-attempt fallback 仍从 frame 0 重新开始，符合 ADR-0004。

## P0：三级 preroll discard

FFmpeg 的 H.264 实现对 `AVDISCARD_NONREF` 跳过 `nal_ref_idc == 0` 的 NAL；更高一级的 `AVDISCARD_BIDIR` 还会跳过所有 B slice，包括 reference B。[FFmpeg H.264 NAL skip](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/libavcodec/h264dec.c#L578-L584)、[FFmpeg H.264 B-slice skip](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.0/libavcodec/h264_slice.c#L1980-L1987)

对固定样本长 GOP 的 `trace_headers` 局部检查显示，稳态 mini-GOP 重复出现“一张 reference P、一张 reference B、四张 non-reference B”。当前 `NONREF` 会解 P 和 reference B；早期换成 `BIDIR` 后只需解 I/P。以本次 smoke 的 254 个 preroll decoded frame 粗算，最多可少解约 127 帧，即当前 566 个 decoded frame 的约 22%。这是样本和 GOP 结构给出的理论上限；packet parser、目标 1.5 s 窗口、scale/join/encode 均不会同比减少。

不能从 keyframe 一直 `BIDIR` 到窗口边界后立即恢复 `DEFAULT`。更保守的状态机是：

```text
seek keyframe ── BIDIR ──> mini-GOP recovery ── NONREF ──> reorder/thread recovery ── DEFAULT ──> window
```

- `BIDIR` 只用于早期长 preroll，维护 I/P reference chain。
- 到窗口前至少一个实测安全的 mini-GOP 恢复区切回 `NONREF`，先恢复 reference-B 层。
- 再按 decoder reorder + frame-thread delay 切回 `DEFAULT`，恢复窗口所需的所有 B frame。

FFmpeg 文档说明 `has_b_frames` 是 decoder 的 frame reordering buffer 大小，而 `FF_THREAD_FRAME` 会按每个 frame thread 增加一帧 decode delay；这两个量比固定秒数更适合定义最后一级恢复门槛。[FFmpeg `AVCodecContext::has_b_frames` and `thread_type`](https://www.ffmpeg.org/doxygen/8.0/structAVCodecContext.html)

建议先只改固定 H.264 样本，以 0.25/0.375/0.5 s 的 `BIDIR -> NONREF` 恢复区和按 frame 数计算的 `NONREF -> DEFAULT` 恢复区做二维 sweep。任何单帧 raw RGB hash 差异都否决该配置；不能用最终 AVIF 大小或肉眼观看代替。之后必须覆盖有/无 reference-B、开放 GOP、不同 fps、HEVC CRA/BLA 的完整 corpus。

## P1：encoder 初始化只作为 RSS 错峰诊断

当前 `InProcessAvifEncoder::start()` 在调用线程构造完整 `EncoderState` 后才创建 worker；capture worker 此时已经运行。本轮 8 次 warm setup 的 p50/min/max 为 0.043163/0.0340/0.0511 s，输出 SHA 一致。因为这段初始化已经与 decoder worker 重叠，43 ms 只是理论总量，不是可回收 wall；延迟到首个 grid 更可能把初始化移到关键路径上。只有为了错开 RSS 峰值时，才值得比较下面四格：

| 变体 | 初始化时点 | `lp` | 目的 |
|---|---|---:|---|
| A | 当前：主线程同步 | 2 | 控制组 |
| B | encoder worker 启动后立即异步初始化 | 2 | 验证 wall 是否基本不变 |
| C | encoder worker 收到首个 grid 后初始化 | 2 | 测 RSS 错峰代价；预期可能增加 wall |
| D | 同 C | 3 / 4 | 只有 C 降 RSS 且 wall 可接受时，才用余量缩短 encode tail |

SVT-AV1 4.1 的官方参数文档说明 `lp` 同时控制线程数和 picture buffer 数；更高 level 增加并行 picture、速度和内存，CRF 下 level 4 还会并行更多 mini-GOP。[SVT-AV1 4.1 Parameters, thread management](https://gitlab.com/AOMediaCodec/SVT-AV1/-/raw/v4.1.0/Docs/Parameters.md)

本轮完整 sweep 与这个模型一致：`lp=1/2/3/4` 的 wall p50 为 1.484/1.329/1.311/1.295 s，RSS 约 524–536/553–561/604–619/665–674 MB，且输出全为权威 SHA。`lp=4` 相对 `lp=2` 只快约 34 ms，却多占约 104–121 MB；在 512 MB ADR 尚未收口时不能直接采用。当前首个 grid 前已经接收约 241/270 帧，使“先释放大多数 decoder，再分配 SVT”仍是可检验假设；只有 C/D 真正把峰值降回门槛内，才考虑用高 LP 换这 34 ms 量级的已知上限。

实现 B 时，`EncoderState` 在同一个 worker 内创建和使用，还可以移除当前为跨线程移动 swscale raw pointer 所需的 `unsafe impl Send`。实现 C/D 时错误会延迟到第一次写 grid 后报告，temporary-output cleanup 与 whole-attempt failure 必须继续正确。

验收除统一 gate 外还应要求：

- 新增 `encoder_setup`，不能把 setup 隐藏进 `receive_wait` 或 `tail`；
- 绘制随时间变化的 vimg working set，确认是“错峰”而非采样漏峰；
- `lp=2/3/4` 已有权威 SHA 结果；调度实现改变后仍各重复 20 次，因为 SVT 官方没有承诺不同并行 level 一定产生相同 bitstream；
- ADR-0001 仍写 512 MB active-job 上限，而现状 `lp=2` 精确 PeakWorkingSetSize 约 553 MB。新优化不得继续扩大这个未决偏差：要么回到 512 MB 内，要么先修订 ADR 的进程/进程树口径。

## P1：去掉 filter graph、复制和重复 label 工作

当前每个入选后的 source frame 走 `buffer -> scale -> format -> buffersink -> copy_rgb`。FFmpeg 的 `scale` filter 本身最终调用 `sws_scale_frame()`；libswscale 官方也把直接对已设置 frame 属性调用 `sws_scale_frame()` 列为推荐 API，并允许 caller 提供预分配 destination frame。[FFmpeg `vf_scale.c`](https://www.ffmpeg.org/doxygen/8.0/vf__scale_8c_source.html#l00878)、[FFmpeg libswscale API](https://www.ffmpeg.org/doxygen/8.0/group__libsws.html)

可拆成三个可归因的小实验：

1. 用 direct `sws_scale_frame` 写预分配 RGB `AVFrame`，保持 BICUBIC、source color metadata、range、stride 与当前 filter 完全一致。
2. 让 destination plane 直接指向 owned packed RGB buffer，去掉 `copy_rgb`；若 stride 与 `RgbImage` 不兼容则保留一次 row copy，不做 unsafe 强行别名。
3. `write_grid` 接收 `RgbImage` 所有权而不是 `grid.clone()`；缓存 9 个固定 timestamp label 的 glyph layout/coverage mask，30 个 animation frame 仅 blend。

当前 profile 的 join 约 0.035 s、encoder_write 约 0.014 s，因此后两项的可观测上限本来就很小；direct scale 的占比尚未单独测量。所有三项必须分开 A/B，并要求 30 个 raw grid 和最终 AVIF SHA 完全一致。

## P1：先去掉重复 stream-info probe，再条件性集中 demux

当前每个 capture worker 都调用一次 `ffmpeg_next::format::input()`；本仓库锁定的 `ffmpeg-next 8.1.0` 实现会在每次 `avformat_open_input()` 后无条件调用 `avformat_find_stream_info()`。[`ffmpeg-next` 8.1.0 format source](https://github.com/zmwangx/rust-ffmpeg/blob/v8.1.0/src/format/mod.rs#L151-L168) FFmpeg 说明 `avformat_find_stream_info()` 会读取 packet，并可能尝试解码帧来补全缺失的流信息。[FFmpeg demuxing API](https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html)

因此应在集中 demux 之前做一个更小的探针：第一次 authority/probe 仍完整执行 stream discovery；后续 9 个 worker 用 raw `avformat_open_input()` 打开 Matroska，并且只有在 video stream 的 codec id、extradata、尺寸、time base、start time 等所有必需字段已完整时才跳过 `avformat_find_stream_info()`。字段缺失或容器不是已验证的 Matroska 路径时，立即使用现有封装流程。先临时恢复 `open` 分段判断上限；如果 9 路并行 probe 没有推高 makespan，就不值得为此扩展 unsafe FFI。

这个探针必须比较每 worker 的 stream index/time base/codec parameters、seek landing、首 packet PTS/DTS、270 个 source PTS、30 个 raw grid hash 和最终 AVIF SHA。不要把第一次 probe 得到的 `AVStream*` 或 codecpar 指针跨 `AVFormatContext` 复用；只复制需要验证的拥有型元数据。

9 个 worker 当前各自打开同一 MKV、seek、读取并跳过非视频 packet。若新增计时显示 `open_seek + av_read_frame` 是关键 worker 的显著部分，可用一个 demux stage 依次 seek 9 个窗口，把每个窗口从 landing keyframe 到安全 drain 边界的压缩 video packet 放入独立有界队列，再让 decoder 并行消费。

FFmpeg 的 `av_read_frame()` 返回 reference-counted packet，packet 的 PTS/DTS/duration 使用 stream time base；这使 packet staging 不需要复制 payload，但每个队列仍须正确持有/释放引用。[FFmpeg demuxing API](https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html)

这个方案只在以下条件同时满足时继续：

- 新计时中关键 worker 的 demux/open/seek 占 total 至少 8% 或 0.10 s；
- 中央 seek/预取没有把 9 路现有重叠变成更长的串行前置阶段；
- 压缩 GOP staging 峰值可控，不超过 active-job RSS 门槛；
- packet side data、PTS/DTS/duration、flush 边界与现有逐 context 路径完全一致。

否则保留 9 个 format context。不要直接上 3.2 GB 全文件 mmap：热路径只触碰 9 个 GOP，映射整个文件不会减少 H.264 重建工作，还会使 working-set 口径更难解释。

## P2：允许改变码流时的 SVT 轨道

当前 DLL 的 SVT 是 `v4.1.0-259-gec17f8382`。4.2.0 上游随后合入了减少空闲 worker、合并对象 backing allocation、减少 resource-manager 分配和缩小初始 bitstream buffer 等初始化/内存改动；这些改动与 30 帧短任务相关，但上游没有给出本场景的 wall 百分比。[SVT 4.2.0 changelog](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.2.0/CHANGELOG.md)、[idle-worker change](https://gitlab.com/AOMediaCodec/SVT-AV1/-/commit/aca2d89875cee3694e64fac1134466a59d56f59a)、[pooled allocation](https://gitlab.com/AOMediaCodec/SVT-AV1/-/commit/a8cb86964a16b5f42c1abe8d0d16dc02b4abdebf)、[bitstream buffer change](https://gitlab.com/AOMediaCodec/SVT-AV1/-/commit/a5b12b3d5b3a261948380113c3e6c17834ed9203)

升级 encoder library 极可能改变 AV1 bitstream；本仓库又已经验证即使都是 SVT 4.1.0，不同构建提交也会改变 `mdat`。因此它不是 byte-identical 优化。若产品允许建立新 cache generation，可独立测试：

1. 4.2.0 + 当前参数 + `lp=2`；
2. 同版本 `lp=2/3/4`；`lp=1` 仅用于确认 4.2 的初始化改动是否改变结论，因为当前 4.1 的 p50 已比 `lp=2` 慢约 0.155 s；
3. 再测试 `startup-mg-size=2/3/4`。该参数专门缩小 keyframe 后第一个 mini-GOP，可能减少 30 帧短序列的 EOF 集中工作，但会改变 GOP/码流。[SVT startup mini-GOP design](https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/1945)、[SVT Parameters](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.0.0/Docs/Parameters.md)

SVT public API 只有 init/send/receive/deinit/destroy 生命周期，没有跨独立 bitstream 的 reset/restart API，因此服务模式不应复用一个活动 encoder handle 生成多个 AVIF 文件。[SVT public encoder API](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/v4.2.0/Source/API/EbSvtAv1Enc.h)

这条轨道仍要求 decoded 30-frame RGB golden、20 fps、1.5 s、尺寸、文件大小门槛和 20 次自身确定性；但不能要求与 4.1 的文件 SHA 相同。若 cache key 没有编码器配方/版本，升级前必须先解决旧新 cache 碰撞。

## 统一实验与验收方法

1. 固定 FFmpeg/SVT DLL、Windows 电源状态、温度和后台负载；每个 arm 先 warm，再做至少 12 轮 ABBA。另记录 cold 但不混入 warm P95。
2. 每轮记录 wall、profile total、capture makespan、每 worker 分段、first grid、encoder setup/write/first packet/tail、CPU time、vimg PeakWorkingSetSize、process-tree peak、GPU video decode/PCIe copy。
3. byte-preserving 轨道必须通过：270 source PTS、30 raw RGB grid SHA、最终 AVIF SHA `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2` 全相同。
4. 先固定样本定位，再跑现有 11-file frame-selection corpus；H.264、HEVC、reference-B、开放 GOP、不同 fps/时基和异常 fallback 都要覆盖。
5. 性能推广同时要求 warm P95 ≤ 1.3 s。ADR-0001 的 512 MB active-job RSS 与当前约 553 MB 精确峰值冲突，应在本轮一并收口，不能继续只比较相对内存。
6. 高复杂度 backend（硬解、集中 demux）至少改善 P95 8%；低复杂度改动至少改善 2% 或 20 ms。否则保留更简单的现状。

## 推荐执行顺序

1. **按候选恢复诊断。** 临时探针已证明 `send_packet` 是关键段；实现候选时补 packet-read/scale/channel-wait、capture makespan 和分阶段 RSS，输出必须完全不变。encoder setup 已测得 p50 43 ms，无需重复基线。
2. **修正硬解结论。** 原生 H.264 + D3D11VA/NVDEC 共享 context 计数探针；先确认 nonref 在 hardware callback 前被跳过，再测 wall。
3. **三级 discard。** 先在软件 libav 上 sweep recovery；通过 authority 后与原生硬解组合。
4. **先测重复 stream-info probe。** 仅在临时 `open` 分段有可见上限时做 Matroska-only 跳过探针；不成立就停止。
5. **CPU 微优化。** direct swscale、move-only grid、label mask cache 各自 A/B。
6. **只在 RSS 需要时测 encoder phase 调度。** 当前/B/C/D 四格；若延迟 setup 增加 wall 且没有解决内存门槛，立即停止。
7. **由计时决定集中 demux。** demux 不到门槛就停止。
8. **另开非 byte-identical 轨道。** SVT 4.2.0、startup mini-GOP；不得与默认 cache 静默混用。

## 相关仓库材料

- [`report.md`](../../report.md)：所有历史 A/B、当前 P95/RSS、硬解与 encoder 探针。
- [`libav.rs`](../../src/command/libav.rs)：当前 seek、discard、thread、scale 和接收路径。
- [`encode.rs`](../../src/command/encode.rs)：当前同步 encoder state 初始化、RGB→YUV 与 SVT drain。
- [`vcs.rs`](../../src/command/vcs.rs)：capture/encoder 启动顺序、pending grids 和 profile 边界。
- [`ADR-0001`](../adr/0001-preview-service-performance-contract.md)：1.3 s P95、512 MB active-job 契约。
- [`ADR-0003`](../adr/0003-preserve-frame-selection-across-capture-backends.md)：FFmpeg CFR frame-selection authority。
- [`ADR-0004`](../adr/0004-fallback-by-whole-capture-attempt.md)：whole-attempt fallback。
