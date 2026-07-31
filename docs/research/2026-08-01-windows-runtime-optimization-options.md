# Windows 固定 Preview profile 的进一步运行时优化调研

日期：2026-08-01  
范围：`vimg vcs -c3 -H160 -n9 sample/input.mkv --output output.avif`，Windows、i9-12900K、RTX 3090  
目标：在不放宽 3×3、160 px、30 帧、CRF 30 等 Preview profile 契约的前提下，寻找 libav 方案的后续优化点。

## 结论摘要

下一轮最值得先做的不是重试已经失败的“整 worker 门控”或命令行 CUDA/DXVA2，而是组合验证：

1. **将 SVT-AV1 `lp` 从自动值 6 显式降到 4，并独立测试只给关键慢窗口使用 decoder threads=3。** 本机编码端 pilot 中 `lp=4` 比自动 `lp=6` 快约 25%，同时 Picture Parallel Coding Structures（PPCS）从 305 降到 107。`lp4` 本身是当前最高优先级的低风险实验；但编码器在子进程中，它不能降低报告中 vimg 自身的 DT3 内存，应以“少数慢窗口 DT3、其余 DT2”另行探索解码收益/内存平衡。
2. **只在权威帧真正被选中后再缩放。** 代表性调度 fixture 中，当前窗口会缩放 394 个源帧，但最终只有 268 个不同源帧被采用，理论上可少做 126 次、约 32% 的缩放；这是低风险、保持选帧语义的 CPU 优化。
3. **消除 `recv()` 的忙轮询。** 提交 `32888cb` 为整 worker 门控引入 `try_recv + yield_now` 是为了避免门控死锁；若不再保留整 worker 门控，可恢复阻塞式轮询。若以后仍需门控，应使用 ready queue/条件变量通知，而不是全 channel 自旋扫描。
4. **中期收益上限最高的是共享设备上下文的进程内硬件管线。** 新的单窗口探针显示，即使先在 GPU 缩小再回传，CUDA/D3D11/QSV CLI 仍都慢于 CPU，已经排除“只调 FFmpeg CLI 滤镜”的速赢。若继续硬件方向，只值得测试 9 decoder 共享最少 device/context、按需映射选中小 surface 的进程内架构。
5. **进程内编码/封装值得做，但不是先手。** 它可去掉子进程、DLL 启动和 raw RGB 管道，并允许缩放直接写入编码器帧；非解码尾段当前约 0.4–0.5 s，但可回收部分预计小于 0.2 s。

这些判断区分了三类证据：仓库或本机实测、官方 API 能力、以及基于前两者的工程推断。文中所有收益预测均是上限或实验假设，不是端到端承诺。

## 对提交 `32888cb` 结论的解读

提交 `32888cb` 的结论是有适用条件的：在当时的高系统负载下，将 9 个 libav worker 以 `-T4` 整 worker 门控，decode 从 1.68 s 降到 0.95 s、总时间从 2.08 s 降到 1.87 s；清理外部负载后，门控与无门控都约为 2.1–2.2 s。这个结果证明了**高负载时限制 CPU 过度并发有效**，但没有证明整 worker 门控是干净系统上的稳定最优方案。[提交记录](../../report.md)还显示它把 `first_grid` 推迟到 1.32 s，并迫使接收端忙轮询。

当前进一步测量还表明，忙轮询本身增加约 3% CPU、总耗时约 1.4%，且接收端会先排空快 worker，第一张 grid 前累计约 241 帧。因此更准确的结论是：

- 高外部负载下，限制解码并发能改善吞吐；
- 干净系统上，整 worker 门控没有稳定端到端优势，且损害首帧延迟；
- `try_recv + yield_now` 是整 worker 门控的防死锁附带成本，不应脱离门控长期保留；
- 每帧/每 5 帧时间片门控已因解码器切换成本变差，不建议重复。

本轮完整重测应以新的暖机 ABBA 数据最终确认以上边界，而不是用单次 wall time 覆盖提交中“高负载”和“干净系统”两组条件。

## 候选方案优先级

| 优先级 | 方案 | 可能收益/上限 | 风险与工作量 | 建议 |
|---|---|---:|---|---|
| P0 | SVT `lp=4` | 编码 pilot：0.59→0.44 s | 参数小改；需测 child 和进程树 RSS | 立即做端到端 ABBA |
| P0 | 仅关键慢窗口 DT3，其余 DT2 | 历史全 DT3 解码收益约 0.22 s，选择性方案会更小 | 需按窗口 profile；严格测 vimg RSS | 与 lp4 正交测试，不直接启用全 DT3 |
| P0 | 选中后再缩放 | fixture 中缩放调用最多减少 32% | 中低；必须保持 CFR/上一帧选择语义 | 做计数器，再实现 lazy scale |
| P0 | 阻塞轮询或 ready queue | 已知忙轮询约占总耗时 1.4% | 低；取决于是否保留门控 | 无门控用阻塞 RR，有门控用通知队列 |
| P1 | 进程内编码/封装 | 非解码段 0.4–0.5 s 中的一部分，预计 <0.2 s | 中；需复刻 AVIF 动画封装 | 在 P0 后做原型 |
| P1 | 共享上下文 NVDEC + 小图回传 | 粗略工程上限约 0.4–0.9 s | 高；PTS、surface 生命周期、像素一致性 | 两阶段原型 |
| P1 | D3D11/MF 解码、缩放、9 路合成 | 与 NVDEC 同量级，但未知 | 高；驱动质量和选帧语义风险 | 与 NVDEC 二选一原型 |
| P2 | UHD 770 oneVPL decode+VPP | CLI 单窗口 2.49 s，当前没有性能证据 | 高；共享 session/device 的收益未知 | 仅保留为架构备选 |
| P2 | `lookahead=0` / low-delay | pilot 仅约 0.03 s 或无收益 | 改变码流、文件体积、GOP | 不优先 |
| P2 | 跳过重复 `find_stream_info` | 当前 setup 上限仅几十毫秒 | 中；需验证 Matroska/H.264/HEVC corpus | 作为收尾微优化 |
| P2 | P-core CPU Sets | 只可能改善调度 | 低到中；可能与 SVT 抢核 | 仅在 ETW 证实迁核后测试 |

## P0：SVT `lp=4` 与选择性 decoder threads=3

### 参数语义需要先纠正

当前 SVT-AV1 的 `--lp` 是 **Level of Parallelism**，范围 0–6；它同时控制线程和 picture buffer 数量，`0` 表示按核心数自动决定。它不是 “low power”，也已不再表示逻辑处理器数量。[SVT-AV1 v3.1 参数文档](https://gitlab.com/AOMediaCodec/SVT-AV1/-/raw/v3.1.0/Docs/Parameters.md)和[变更日志](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/CHANGELOG.md)明确记录了这次语义变化。SVT 的[系统要求](https://gitlab.com/AOMediaCodec/SVT-AV1/-/blob/master/Docs/System-Requirements.md)也说明内存主要受 `lp`、输入分辨率/位深、lookahead 和层级结构影响。

本机 FFmpeg 8.0 / SVT-AV1 3.1.0 的启动日志显示：

| 设置 | SVT 实际 level | PPCS |
|---|---:|---:|
| 自动 | 6 | 305 |
| `lp=5` | 5 | 140 |
| `lp=4` | 4 | 107 |
| `lp=1..3` | 对应 level | 74 |

编码端局部 pilot 从现有 `output.avif` 的动画流解出同 30 帧，再用相同 `libsvtav1 preset=8 / CRF=30 / yuv420p10le` 重编码，15 轮交错、每项 5 轮：

| 设置 | 平均 | 范围 | 输出 |
|---|---:|---:|---|
| 自动 `lp=6` | 0.59 s | 0.57–0.65 s | 78,780 B |
| `lp=5` | 0.52 s | 0.49–0.55 s | 78,780 B |
| `lp=4` | **0.44 s** | 0.41–0.48 s | 78,780 B |

三个输出 SHA-256 相同。这是有价值的本机证据：对于 30 帧、852×480 的短序列，自动 level 6 存在过度并行开销；但输入来自已有 AVIF 解码帧、计时包含共同解码成本，不替代真实 vimg 端到端验证。

历史端到端数据中 libav DT2 约 1.96 s、vimg peak RSS 443.3 MiB；全 DT3 约 1.74 s、vimg peak RSS 514.6 MiB。编码器运行在 FFmpeg 子进程，因此降低 SVT PPCS **不能**降低这项 vimg 自身内存，也不能让全 DT3 自动满足 512 MiB。最小实验应把编码和解码两个变量分开比较：

- DT2 + 自动 lp（控制组）；
- DT2 + lp4；
- DT3 + 自动 lp；
- DT3 + lp4。

全 DT3 两组用于量化正交效应，不代表可以推广。更现实的解码实验是从 profile 中找出关键慢窗口，仅这些窗口用 DT3，其余维持 DT2，从而只增加部分 decoder pool。必须同时记录 vimg peak RSS、FFmpeg child peak RSS 和 process-tree P95 RSS。ADR 的 512 MiB 是 active-job 预算，而既有报告只记录了 vimg 自身；推广前应先补齐进程树统计。若未来把编码器移入进程内，SVT 和 decoder 才会在同一进程预算内统一调度。

### `lookahead` 和 low-delay 不应抢跑

SVT 文档说明 `pred-struct=2` 是默认 random access，`pred-struct=1` 是 low delay；`lookahead=-1` 是自动，`0` 禁用 lookahead。旧 FFmpeg `la_depth` 已被移除，应通过 `svtav1-params=lookahead=...` 传递；参见[上游兼容性讨论](https://gitlab.com/AOMediaCodec/SVT-AV1/-/issues/1829)。

同一 pilot 在 `lp=4` 下测得：默认 0.45 s；`lookahead=0` 0.42 s，但文件增大 1.4%、hash 改变；`lookahead=0:pred-struct=1` 0.44 s，文件增大 8.5%。本地证据不支持把 low-delay 作为优先方案，`lookahead=0` 的约 0.03 s 也接近噪声边缘，且会改变码流。

## P0：延迟缩放，避免处理最终未入选的帧

当前 [`libav.rs`](../../src/command/libav.rs) 在 preroll 后将每个解码源帧先经过 `scale=-1:H:flags=bicubic,format=rgb24`，再由 CFR 选择逻辑判断它是否成为一个或多个输出帧。对 [`representative.json`](../../tests/fixtures/frame-selection/representative.json) 统计：

- 9 个窗口共进入缩放阶段 394 个源帧；
- 权威输出实际引用 268 个不同源帧；
- 最多可省 126 次缩放，即 32.0%。

这是 fixture 的理论上限；实际 sample 的单窗口通常约 37 个 post-offset 源帧选 30 个，直接调用数下降约 19%。两者都不等于总耗时会同比下降，因为解码、demux、grid 合成和编码都不变；实际收益取决于 scale/copy 在 profile 中的占比。建议先增加 `decoded_post_preroll`、`scaled_unique`、`scale_ns`、`copy_ns` 四个诊断计数，再做改动。

实现时可把 previous 表示为 `Scaled(Rgb)` 或 `Deferred(Video)`：本帧被 schedule 选中才 scale；未选中则保留 full-resolution frame 到下一次 push，仅在它作为 previous 补帧被实际引用时 scale。同一源帧供多个输出帧时只缩放一次。代价是每 worker 峰值最多多保留一个 full-resolution frame；所有 270 个 source PTS 必须与现有 authority 完全一致。

第二步可以绕过 AVFilter 的中间 `Video` frame 和 `copy_rgb`，优先使用 FFmpeg 官方推荐的 [`sws_scale_frame`](https://www.ffmpeg.org/doxygen/8.0/group__libsws.html) 写入预分配的输出 frame/目标 plane。要保持字节一致，必须固定与现有 filter 等价的输入色彩元数据、bicubic flags、stride 和 rounding；在没有 raw grid hash 对比前不能假定等价。这应作为与 lazy scale 分离的 A/B，便于归因。

## P0：去掉接收端忙轮询

当前 whole-worker gate 已移除，但 `recv()` 仍扫描 9 个 channel，空时 `yield_now()`。该结构原本是为“后五个 worker 被 semaphore 阻塞、前四个 channel 又可能填满”的死锁而引入，不是当前 libav 管线的必要条件。隔离测量中 polling total 1.922 s，阻塞 round-robin 1.895 s，polling 还多约 3% CPU；所以无 gate 现状下恢复阻塞 round-robin 是明确的最小实验，收益上限约 1–2%。

- 当前无 gate：按 capture index 阻塞 round-robin 接收即可，第一张 grid 只需每个 worker 各收到一帧。
- 未来若引入 per-frame/dynamic gate：worker 发送 frame 后，再向一个共享 ready queue 发送 capture index；接收端阻塞等通知并从对应 channel 取帧。条件变量/通知 channel 都可以避免全 channel 自旋。

这项实现小，也会减少抢占解码线程和 SVT 的机会。隔离数据支持方向，但仍需纳入同一端到端 ABBA 后才能作为最终结果。

## P1：进程内 SVT-AV1 编码与 AVIF 封装

当前 [`vcs.rs`](../../src/command/vcs.rs) 启动外部 FFmpeg，把 30 张 852×480 RGB grid 经 stdin 送入，再等待编码和 trailer。现有 profile 中 join + encoder write + tail 常为 0.4–0.5 s。进程内实现能去掉：

- 子进程和动态库冷启动；
- raw RGB pipe 的内核复制与背压；
- 最后一帧后额外的进程同步；
- 若同步重构缩放，还可直接生成编码器期望的 YUV frame。

FFmpeg 官方的[编码 API](https://www.ffmpeg.org/doxygen/8.0/group__libavc.html)提供 `avcodec_send_frame` / `avcodec_receive_packet`，其[封装 API](https://www.ffmpeg.org/doxygen/8.0/group__lavf__encoding.html)提供 header、packet 和 trailer 写入。另一条路径是 libavif；其[官方头文件](https://raw.githubusercontent.com/AOMediaCodec/libavif/v1.4.1/include/avif/avif.h)支持选择 SVT codec、设置 timescale、逐帧 `avifEncoderAddImage` 和 `avifEncoderFinish`。

风险是必须复刻当前 FFmpeg 的动画 AVIF timescale、duration、track/metadata 和 SVT 参数映射。libavif 的输出容器布局或默认参数可能不同，即使视觉等价也未必字节一致。建议先做独立原型，用相同 30 张 raw grid 输入，比较 decoded RGB hash、帧数、PTS/duration、文件大小和编码阶段 wall time。

`svtav1-params=avif=1` 只适用于 still-picture 优化，不适用于 30 帧动画，不能拿来替代动画编码。

## P1：共享上下文 NVDEC，而不是重复命令行 CUDA 试验

既有 CUDA/DXVA2 命令行方案较慢，最初只能说明“9 个外部进程/硬件上下文、全分辨率 surface 回传 CPU、再缩放”的实现没有收益。新增的单窗口 cap7 sanity 进一步采用“GPU 先缩到 284×160，再 hwdownload，再小尺寸 NV12→RGB”：CPU 路径约 0.43–0.50 s，CUDA 约 0.72 s，D3D11VA + `scale_d3d11` 约 0.81 s。两个 GPU 命令都能正确完成，但仍受每进程设备/decoder 初始化影响。

因此可以明确排除“仅调整 CLI 滤镜顺序/下载尺寸”的速赢；它仍不能排除共享上下文的进程内实现。

NVIDIA 的 [NVDEC 编程指南](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.0/nvdec-video-decoder-api-prog-guide/index.html)说明：

- 解码器在有效 CUDA context 中创建和使用；
- `ulTargetWidth/ulTargetHeight` 可设置输出 surface 分辨率；
- `cuvidMapVideoFrame` 映射输出，并可包含格式转换、缩放、裁剪；
- 多解码 session 推荐共享尽量少的 CUDA contexts，以节省 context memory。

建议分两阶段，先控制精确性风险：

1. 共享一个 CUDA primary context，9 个 parser/decoder session；仍将“最终被选中的全分辨率帧”回传，继续用现有 CPU bicubic/RGB。先确认选帧、颜色和稳定性。
2. 在 decoder output 或 NPP 中缩到约 284×160 后再回传，只让 CPU 做 3×3 join 和 label。

按 1920×1080 NV12 约 3.11 MiB、284×160 NV12 约 68 KiB 计算，小图回传的数据量约小 45.6 倍；270 张 tile 总计约 18.4 MiB。这只是数据量推算，不含 reference decode、map 同步和 RGB 转换。

NVIDIA 的 [Ampere 吞吐表](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvdec-application-note/index.html)给出的 H.264 1080p 指示值约 748 fps。按当前约 600 个 preroll/窗口帧粗算，纯硬解下限约 0.8 s；这不是本机端到端预测，因为还未计 demux、seek、session 初始化、surface map、scale、join 和 SVT 编码。因此把潜在净收益写成约 0.4–0.9 s 更合理，但仍需原型证明。

NVDEC 13.1 新增的按 PTS 跳过输出可避免部分后处理和复制，但文档没有承诺跳过参考帧解码，不能等同于当前 `AVDISCARD_NONREF` preroll。要谨慎使用 direct/unsafe surface；FFmpeg 的[硬件加速 API](https://ffmpeg.org/doxygen/8.0/group__lavc__hwaccel.html)也说明 direct surface 会带来 surface pool 生命周期风险。

RTX 3090 属于 Ampere。NVIDIA [NVENC 支持表](https://docs.nvidia.com/video-technologies/video-codec-sdk/13.1/nvenc-application-note/index.html)显示 Ampere/Turing 没有 AV1 编码器，AV1 编码从 Ada 才有，因此 RTX 3090 不能通过 NVENC 生成此 AVIF；GPU 优化应集中在 decode/scale/compose。

## P1：D3D11 / Media Foundation 路径

Windows 原生替代方案是让 9 个 decoder 共享一个 D3D11 device/DXGI manager，解码输出保留为 texture，再用 Video Processor 一次合成 3×3 grid。

微软文档说明：

- Media Foundation Source Reader 场景可由应用创建一个 D3D11 device，并通过 DXGI device manager 与 decoder 共享，[解码结果保持为 D3D texture](https://learn.microsoft.com/en-us/windows/win32/medfound/supporting-direct3d-11-video-decoding-in-media-foundation)；
- [`VideoProcessorBlt`](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videocontext-videoprocessorblt)可把一个或多个输入 sample 写到输出 surface；
- 每一路可用 [`VideoProcessorSetStreamDestRect`](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/nf-d3d11-id3d11videocontext-videoprocessorsetstreamdestrect)设置目标矩形；能力结构中的 [`MaxInputStreams`](https://learn.microsoft.com/en-us/windows/win32/api/d3d11/ns-d3d11-d3d11_video_processor_caps)必须先确认至少为 9；
- Video Processor MFT 支持 resize/color conversion 及 D3D11/D3D12 GPU acceleration，[能力见官方文档](https://learn.microsoft.com/en-us/windows/win32/medfound/video-processor-mft)。

理想管线是 9 张被选 surface 一次 blit 到 852×480 texture，只回传一张 grid，再由 CPU 画 timestamp label。它比逐 tile 回传进一步减少传输，但 scaler、chroma siting 和颜色矩阵由驱动实现，未必与 FFmpeg bicubic/RGB 字节一致。

Media Foundation 的 `MF_SOURCE_READER_ENABLE_VIDEO_PROCESSING` 是有限的软件处理，[官方明确如此说明](https://learn.microsoft.com/en-us/windows/win32/medfound/mf-source-reader-enable-video-processing)，不应启用它冒充硬件缩放。`MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS` 也不会自行启用 DXVA；仍需配置 D3D manager。MF Source Reader 还没有与 `AVDISCARD_NONREF` 等价的公共语义，preroll 和 PTS authority 是主要验证风险。

## P2：利用 i9-12900K 的 UHD 770 / oneVPL

[Intel 官方规格](https://www.intel.com/content/www/us/en/products/sku/134599/intel-core-i912900k-processor-30m-cache-up-to-5-20-ghz/specifications.html)显示 i9-12900K 带 UHD 770、Quick Sync 和两个 Multi-Format Codec Engines，前提是主板 BIOS 与驱动没有禁用 iGPU。

oneVPL 有两个与本任务高度匹配的固定功能：

- [`mfxExtDecVideoProcessing`](https://intel.github.io/libvpl/latest/API_ref/VPL_structs_vpp.html)可让 decoder 直接输出 resize/crop 后的 NV12，绕过中间全分辨率内存；
- `mfxExtVPPComposite` 可把多个输入 surface 合成到一个输出，适合 video wall。文档注明每个 tile 最多 8 个 surface，3×3 可以按 6+3 个不相交 tiles 分两批，但必须先 Query 实际实现能力。

oneVPL 的[组合 decode+VPP API](https://intel.github.io/libvpl/latest/API_ref/VPL_func_vid_decode_vpp.html)是异步 surface 管线；demux 仍可沿用 libavformat，因为 oneVPL decoder 接收 elementary stream。最小探针应先测单 capture 的 H.264/HEVC 解码、固定功能缩放和 PTS 对齐，再测 9 session 与 composite，避免一开始重写完整后端。

本机 cap7 CLI sanity 使用 `scale_qsv` 先缩小再 download，单窗口约 2.49 s，远慢于 CPU 的 0.43–0.50 s。这说明 iGPU 和 QSV 路径可用，却没有近期性能证据。只有在共享 session/device 的单窗口原型先做到不慢于 CPU 后，才值得扩到 9 窗口。

这一方向仍有服务模式的潜在价值：未来若并行处理多个文件，可以让 RTX 3090 和 UHD 770 分担设备负载。不过当前 ADR 是单活跃 job，不应把多 job 吞吐当成本次单命令 wall time 的收益。

## P2：小收益或高不确定性方案

### 跳过 9 次重复 stream probing

每个 capture worker 当前各自调用一次 `ffmpeg::format::input()`，其底层通常会执行 `avformat_open_input` 和 `avformat_find_stream_info`。FFmpeg 官方头文件说明，后者会继续读 packets 来补全 stream 信息；参见 [`avformat.h`](https://ffmpeg.org/doxygen/8.0/avformat_8h.html)。

对 Matroska/H.264/HEVC，可以原型化“主线程只 probe 一次，把 codec parameters/time base/index 计划传给 worker；worker 只读 header 后开始 demux”。但这依赖容器头信息完整，必须覆盖 11 个 corpus 和异常文件。当前观测的 setup 总量仅约 0.03–0.05 s，所以优先级低。不要为这几十毫秒先做复杂的自定义 mmap/AVIO。

### Windows hybrid CPU 的 CPU Sets

Windows 可通过 [`SYSTEM_CPU_SET_INFORMATION`](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information)读取 `EfficiencyClass`，较大值代表更快、较不节能的核；[`SetThreadSelectedCpuSets`](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setthreadselectedcpusets)可给线程选择 CPU sets。

可在 ETW 证实 decoder worker 频繁落到 E-core 或迁核后，测试把 decoder threads 放到动态发现的 P-core sets。不要硬编码 CPU 编号；也要避免把所有 P-core 占满，导致 SVT 子进程反而变慢。这是调度优化，不减少工作量，置信度低。

### SVT tiles

当前 SVT 的 `tile-rows` / `tile-columns` 表示 log2 tile 数量，不是直接 tile 个数。852×480 的画面很小，额外 tiles 更可能增加边界和调度开销；最多做一次编码端 0/1 小 sweep，不应列为主方案。

## 明确不重复的方向

- 不再重复整 worker `-T4` 门控、每帧/每 5 帧时间片门控；只在新的联合变量或真实高负载场景下复核。
- 不再重复 9 个外部 FFmpeg 进程的 CUDA/DXVA2 全分辨率下载方案。
- 不再扫描 seek 策略、decoder thread 全范围、preset/CRF；已有数据已覆盖。
- 不把 `lp` 当 low power，也不使用已移除的 `la_depth` 选项。
- 不尝试 RTX 3090 NVENC AV1；硬件不支持。
- 不使用 SVT still-image `avif=1` 编码 30 帧动画。
- 暂不做 YUV-native grid + YUV label；它可能减少 RGB 往返，但会改变文字抗锯齿、颜色转换和像素契约。

## 建议实验顺序与验收门槛

1. **重建稳定基线。** 干净系统、固定电源/温度，warm ABBA 每配置至少 6–10 次；另记一组 cold 数据。
2. **编码参数实验。** 先对 DT2 比较 SVT auto/lp4；再用全 DT3 两格量化正交效应，但不因 lp4 自动放宽 vimg 512 MiB 门槛。
3. **选择性 DT3。** 依据每窗口 profile，只给关键慢窗口 DT3，与全 DT2 比较收益和 vimg RSS。
4. **接收策略。** 当前直接比较 busy poll 与阻塞 round-robin；只有未来重新加 gate 才做 ready queue。
5. **lazy scale。** 先加计数和 phase timing，再实现只缩放被选源帧；随后独立评估 direct swscale。
6. **进程内编码原型。** 只接固定 raw-grid fixture，隔离编码收益。
7. **硬件后端二选一。** 优先 NVDEC 两阶段原型；若 D3D11 集成成本更低则用 D3D11。oneVPL 只在共享 session 的单窗口先追平 CPU 后继续。

每轮至少记录：

- `total`、`first_grid`、decode max worker、receive wait、scale、join、encoder init/write/tail；
- vimg peak RSS、FFmpeg child peak RSS、process-tree P95 RSS；
- CPU total、GPU video decode/compute、PCIe copy（硬件原型）；
- 270 个 source PTS authority、30 个输出帧、尺寸、fps、duration；
- 进入编码器前的 30 张 raw RGB grid hash。

低风险 CPU/调度改动应要求 raw grid hash 完全相同，当前命令最终输出也应尽量 byte-identical。硬件 scaler、low-delay 或新封装器若无法 byte-identical，必须单独经过 ADR 的视觉容差、结构、duration 和文件大小门槛，不能把“能播放”视作正确。

最终推广到默认路径前，应在 11 个 corpus 上验证 avg/P95、内存余量和 fallback；1.3 s warm P95、512 MiB 上限仍按现有 ADR 解释，不能用单个 `sample/input.mkv` 的最佳值替代。

## 相关仓库材料

- [`report.md`](../../report.md)：历史基线、提交 `32888cb`、decoder threads、seek 与硬解试验。
- [`libav.rs`](../../src/command/libav.rs)：当前 demux/decode、preroll、scale、channel 和 authority 实现。
- [`vcs.rs`](../../src/command/vcs.rs)：grid 生成与外部 FFmpeg/SVT 管线。
- [`frame_schedule.rs`](../../src/command/frame_schedule.rs)：CFR 选择权威。
- [`join.rs`](../../src/command/join.rs)：RGB grid 合成。
- [`ADR-0001`](../adr/0001-preview-service-performance-contract.md)：固定 Preview profile 与性能门槛。
- [`ADR-0002`](../adr/0002-stream-contact-sheet-frames-with-bounded-buffering.md)：有界流与内存预算。
- [`ADR-0003`](../adr/0003-preserve-frame-selection-across-capture-backends.md)：跨后端保持帧选择权威。
- [`ADR-0004`](../adr/0004-fallback-by-whole-capture-attempt.md)：whole-attempt fallback。
