# Performance Optimization Report

## Test Command
```
vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif
```

## Baseline (original vimg.exe)
| Run | Time |
|-----|------|
| 1 | 2.957s |
| 2 | 2.888s |
| 3 | 2.721s |
| 4 | 2.712s |
| 5 | 2.697s |
| **Average** | **~2.80s** |

## Optimized (current build)
| Run | Time |
|-----|------|
| 1 | 2.153s |
| 2 | 2.097s |
| 3 | 2.082s |
| 4 | 2.061s |
| 5 | 2.078s |
| **Average** | **~2.09s** |

## Results
- **~26% faster** (2.80s → 2.09s, saved ~0.71s)
- Output file size unchanged (79KB AVIF)
- FFmpeg output suppressed

## Key Optimizations

### 1. Disabled CUDA Decoding
CUDA (`-hwaccel cuda`) was **adding overhead** for short captures:
- Single capture: 0.51s (CUDA) vs 0.28s (CPU)
- Reason: CUDA initialization overhead outweighs benefits for 30-frame captures
- Disabled by default; can be re-enabled if needed

### 2. SVT-AV1 Preset 6 → 8
- Faster encoding with negligible quality loss for contact sheets
- ~0.2s improvement per run

### 3. Thread Count 3 → 8
- Better utilization of 24-core system
- Each ffmpeg process uses ~1-2 cores internally
- 8 parallel ffmpeg calls = ~16 cores utilized

## Phase Breakdown
| Phase | Baseline | Optimized |
|-------|----------|-----------|
| Extraction | ~1.8s | ~1.5s |
| Join | ~0.3s | ~0.2s |
| Encoding | ~0.5s | ~0.3s |
| **Total** | **~2.8s** | **~2.1s** |

## Files Modified
- `src/command/extract.rs` - Disabled CUDA by default, thread count 3→8
- `src/command/vcs.rs` - SVT-AV1 preset 6→8, stderr suppression
- `src/command/join.rs` - Direct buffer copy optimization
- `src/command/join/label.rs` - Direct buffer access for label drawing

## Ordered Streaming Pipeline Verification (2026-07-30, macOS)

The release build was warmed once, then measured five times with the representative fixture:

```sh
./target/release/vimg vcs -c3 -H160 -n9 ./sample/input.mkv --output /tmp/vimg-final-benchmark.avif
```

| Warm run | Wall time |
|---|---:|
| 1 | 1.18s |
| 2 | 1.28s |
| 3 | 1.26s |
| 4 | 1.18s |
| 5 | 1.17s |
| **Average** | **1.214s** |

Profiling is available without changing the output profile:

```sh
./target/release/vimg vcs -c3 -H160 -n9 ./sample/input.mkv \
  --output /tmp/vimg-profile.avif --profile
```

Representative phase timing:

| Phase | Time |
|---|---:|
| Probe and pipeline setup | 0.021s |
| First complete grid available | 0.981s |
| Grid composition | 0.026s |
| Encoder input backpressure | 0.162s |
| Encoder tail | 0.088s |
| **Total** | **1.280s** |

The original bounded channel allowed each sampling process to enqueue its full 30-frame capture. The encoder therefore received 241 frames before it could assemble frame zero. A cancellable frame barrier now keeps all nine sampling processes on the same frame index: only nine frames are received before the first grid, and the channel remains bounded to two frames per sampling point.

Each sampling process uses three ffmpeg threads. One thread produced approximately 1.60–1.66s totals and two threads approximately 1.25–1.29s; three threads produced a warmed 1.16–1.28s range on this host.

`/usr/bin/time -lp` reported a maximum resident set size of approximately 298 MB. Summing the resident sets of the vimg process and all direct ffmpeg children peaked near 879 MiB, but that value double-counts shared mappings. Both figures are recorded because the ADR's memory accounting boundary needs to be made explicit before treating 512 MB as a hard process-tree gate.

The generated AVIF retains its animation stream: AV1, 852×480, 20 fps, 1.5 seconds, and 30 frames.

## FFmpeg Authority Regression Guard (2026-07-30, macOS)

Ticket 01 adds an explicit validation-only command without enabling instrumentation
on the production `vcs` path:

```sh
./target/release/vimg authority record \
  --manifest /tmp/vimg-authority/authority.json \
  -c3 -H160 -n9 ./sample/input.mkv \
  --output /tmp/vimg-authority/output.avif
```

The authority run records the exact 270 FFmpeg-selected integer source PTS values
and their original time bases, 30 lossless pre-encoder RGB grids, and 30 decoded
AVIF reference frames. Repeating the same run produced byte-identical JSON and
AVIF artifacts. The authority AVIF was also byte-identical to the existing
production output.

Authority publication serializes concurrent writers for the same manifest or
output. Reference frames live in immutable content-addressed generations; AVIF
and manifest replacement have rollback guards, and stale owned generations are
removed after a successful publish.

The normal production command remained within its established warm range:

| Warm run | Wall time |
|---|---:|
| 1 | 1.23s |
| 2 | 1.19s |
| 3 | 1.30s |
| 4 | 1.22s |
| 5 | 1.21s |
| **Average** | **1.230s** |

The validation-only authority run took 2.24 seconds because it also writes and
decodes 60 PNG references. `/usr/bin/time -lp` reported a maximum resident set
size of approximately 299 MB. Its additional work is absent from normal `vcs`
invocations.

## VideoToolbox 性能测试（2026-07-30，macOS）

使用启用 `in-process-decode` 特性的 release 构建，对固定 Preview 配置执行了
VideoToolbox 强制后端测试：

```sh
./target/release/vimg vcs -c3 -H160 -n9 \
  --capture-backend videotoolbox --profile ./sample/input.mkv \
  --output /tmp/vimg-videotoolbox-perf.avif
```

本次尚无可用于比较的 VideoToolbox 完整性能数据，但原因分为两个独立层面：

1. 在受限沙盒中，VideoToolbox 无法创建硬件解码会话，FFmpeg 会在初始化阶段报
   `VideoToolbox malfunction` 并回退到软件像素格式 `YUV420P`。
2. 在非沙盒的本机环境中，原生 FFmpeg CLI 已成功输出 `videotoolbox_vld`/`nv12`
   硬件帧，证明系统、FFmpeg 构建和测试视频均可用；但 Vimg 在下载硬件帧时调用
   `av_hwframe_transfer_data` 返回 `Invalid argument`，因此 Capture attempt 仍失败。

Vimg 会将软件回退和硬件帧传输失败均视为失败，以避免把软件解码错误地报告为
VideoToolbox 性能。

| 项目 | 结果 |
|---|---:|
| 受限沙盒中强制后端总耗时（失败前） | 1.296s |
| 已解码硬件帧数 | 0 |
| 硬件帧传输次数 | 0 |
| 受限沙盒失败原因 | VideoToolbox 初始化失败并回退至 `YUV420P` |
| 非沙盒 Vimg 失败原因 | `av_hwframe_transfer_data` 返回 `Invalid argument` |

作为对照，软件 libav 后端在相同输入和配置下成功完成：

| 项目 | 结果 |
|---|---:|
| 总耗时 | 0.938s |
| 解码耗时 | 0.832s |
| 已解码帧数 | 622 |
| 预滚动帧数 | 310 |
| 首个完整网格可用时间 | 0.544s |

项目自带的完整 promotion-gate 脚本也无法在当前受限环境中完成：
`/usr/bin/time -lp` 读取最大常驻内存所需的 `sysctl` 权限被拒绝，使其即使在
libav 基线成功后仍返回非零状态。该环境限制不改变上述结论：Vimg 的
VideoToolbox 硬件帧传输路径修复前，不应基于本次测试推广或评估其性能。

## VideoToolbox 修复后性能测试（2026-07-31，macOS，Apple M4）

已定位并修复 `av_hwframe_transfer_data` 返回 `Invalid argument` 的根因：

1. **移除自定义 `get_format` 回调**：让 FFmpeg 默认 `get_format` 路径调用 hwaccel
   初始化，正确创建携带真实 CVPixelBuffer 表面的 `hw_frames_ctx`。
2. **修复硬件帧克隆**：`Video::clone()` 使用 `av_frame_copy` + `av_frame_copy_props`，
   两者都不会复制 `hw_frames_ctx`，硬件帧因此丢失 CVPixelBuffer 引用导致传输失败。
   改为 `av_frame_ref`（新增 `hw_ref_frame` 辅助函数）后引用计数正确。

修复后强制 VideoToolbox 后端在代表输入上成功完成，输出与 FFmpeg 后端**逐字节一致**
（SHA-256 `406db119…`），帧选择契约完全保留。`auto` 现在首选 VideoToolbox。

### 30 轮交错热运行基准（VT → libav → FFmpeg 轮换顺序）

| 指标 | VideoToolbox | 软件 libav | FFmpeg |
|---|---:|---:|---:|
| 墙钟平均 | **0.759s** | 0.966s | 1.197s |
| 墙钟 P95 | **0.770s** | 1.010s | 1.280s |
| 用户 CPU 平均 | **1.042s** | 6.121s | 8.921s |
| 峰值 RSS | **~406 MiB** | ~598 MiB | ~289 MiB |

### 推广门槛（ticket #11）

| 门槛 | 目标 | 实测 | 结果 |
|---|---:|---:|---|
| VT 墙钟 P95 | ≤ 1.0s | 0.770s | ✅ |
| VT 墙钟优于 libav | ≥ 15% | 21.4% | ✅ |
| VT 用户 CPU 低于 libav | ≥ 70% | 83.0% | ✅ |
| 峰值 RSS | ≤ 512 MB | ~406 MiB | ✅ |
| 通用 P95 | ≤ 1.3s | 全部满足 | ✅ |

所有推广门槛现已通过。软件 libav 的 RSS（~598 MiB）仍超出 512 MB 预算，但这只
影响 `libav`/`auto` 回退路径，不影响首选 VideoToolbox 路径。

## AVIF 编码优化空间调研（2026-07-31，macOS，Apple M4）

### 背景

固定 Preview profile 使用 `libsvtav1`、preset 8、CRF 30、`yuv420p10le`，
输出 852×480、20fps、30 帧动画。调研目标是确认编码参数（preset/CRF/位深/
低功耗模式）以及硬件帧传输/缩放是否存在可落地的优化空间。

### 编码器不是瓶颈

profile 实测：`encoder_tail`（编码收尾）约 0.08s，占总耗时约 7–11%
（VT 0.74s 中的 0.083s；ffmpeg 1.18s 中的 0.081s）。解码/提取是真正的大头。

### 独立编码器基准（真实 contact sheet 30 帧内容）

| 配置 | 编码耗时 | 文件大小 |
|---|---:|---:|
| preset 8, crf 30（当前） | 0.11s | 79.7 KB |
| preset 10 | 0.07s | 90.7 KB |
| preset 12 | 0.06s | 93.5 KB |
| preset 8, crf 34 | 0.10s | 66.4 KB |
| preset 8, crf 36 | 0.11s | 59.7 KB |
| preset 8, keyint=1（全关键帧） | 0.07s | 323 KB（4×） |
| preset 8, 8-bit yuv420p | 0.10s | 79.7 KB（与 10-bit 相同） |
| preset 8, threads 4/8 | 0.11s | 79.7 KB（无差异） |

### SVT-AV1 低功耗模式（lp=1）——不可用

| 模式 | 编码耗时 | 文件大小 |
|---|---:|---:|
| lp=0（默认） | **0.11s** | 79.7 KB |
| lp=1（低功耗） | **0.26s（慢 2.4×）** | 79.7 KB |

`lp=1` 是为特定 x86 架构设计的高速路径，在 Apple Silicon 上编码被串行化，
严重变慢。**结论：M4 上禁用，无优化价值。**

### 端到端实测（ffmpeg 后端，真实输入）

| 配置 | 总耗时 | 输出大小 |
|---|---:|---:|
| 默认 preset 8, crf 30 | 1.21s | 85.9 KB |
| preset 12 | 1.23s（更慢） | 102.8 KB（+20%） |
| crf 34 | 1.17s（≈噪声） | 69.8 KB（−19%） |

提高 preset 端到端反而更慢：编码只占 0.08s，省下的时间被提取主导的总耗时
淹没，还带来 +20% 文件体积。屏幕内容调优（`enable-overlays=1`、`tune=1`）
对 contact sheet 内容无任何收益（SVT-AV1 已自动处理）。

### 硬件帧传输/缩放成本（VT 路径逐帧插桩）

1920×1080 → 284×160 每帧分解：

| 阶段 | 每帧耗时 | 占比 |
|---|---:|---:|
| av_hwframe_transfer_data（GPU→CPU） | ~0.3ms | 20% |
| swscale bicubic 缩放 | **~1.2ms** | **80%** |
| copy_rgb | ~0ms | 0% |

**关键结论：传输/缩放不在墙钟关键路径上。** profile 指标 `transfer` 是 9 个
worker 的**总和**（0.339s），而 `decode` 是**最大值**（0.636s）；每个 worker
的传输+缩放仅约 0.04s，完全被解码管线覆盖。验证实验：

- **bilinear 替代 bicubic**：transfer 总和 0.339→0.229s（CPU 省 32%），
  但总墙钟不变（0.72s vs 0.72s），且质量下降（此前原型实测 SSIM 0.9951）。
- **DECODER_THREADS 1→2**：无改善（0.72s），硬件解码器已充分利用。

### 结论

| 方向 | 结果 | 原因 |
|---|---|---|
| SVT-AV1 lp=1 | ❌ 慢 2.4× | 该模式面向 x86，M4 上串行化 |
| preset 8→12 | ❌ 更慢 + 文件更大 | 编码不在关键路径 |
| CRF 30→34 | ⚠️ 文件 −19%、耗时不变 | 唯一有效杠杆，但改 profile 需产品决策（ADR-0001 锁定 crf 30） |
| 8-bit vs 10-bit | ❌ 无差异 | 此尺寸下 I/O 受限 |
| bilinear 缩放 | ❌ 墙钟无收益 | 传输/缩放被解码覆盖 |
| 解码线程 1→2 | ❌ 无收益 | 硬件解码器饱和 |

**真正瓶颈是 VT 解码（0.636s，占 88%）**，由 seek + 0.5s nonref 预滚策略
主导。进一步加速应研究预滚策略（受正确性契约约束），而非编码或传输/缩放。

## 解码预滚策略调研（2026-07-31，macOS，Apple M4）

### 背景

VT 路径总耗时 0.74s 中解码占 0.636s（88%），由 seek + 0.5s nonref 预滚策略
主导。调研预滚恢复余量（NONREF_RECOVERY_MARGIN_S）与 seek 是否有优化空间。

### 当前策略

每个采样点独立打开输入 → `seek(target, ..target)` 定位到目标前最近关键帧 →
以 `AVDISCARD_NONREF`（跳过非参考帧）解码预滚段 → 到达 `start_s − 0.5s` 时
切回 `AVDISCARD_DEFAULT` 完整解码，保证窗口起点时参考帧/B 帧就绪。

### 阶段耗时分解（9 个 worker，margin 0.5s）

| 阶段 | 耗时 | 说明 |
|---|---:|---|
| setup（打开+seek） | ~0.02s | 可忽略 |
| 预滚（nonref） | 0.09–0.36s | 取决于 seek 落点距窗口起点多远（关键帧间隔） |
| 窗口（完整解码） | 0.25–0.52s | 1.5s 窗口 + 恢复余量的完整解码 |
| 每 worker 合计 | **~0.61s 恒定** | 解码器吞吐受限 |

预滚帧数 15–70 帧不等：落点在短 GOP 区域（capture 0/1/4/8）约 15–19 帧，
长 GOP 区域（capture 6/7，关键帧间隔约 2.4s）达 62–70 帧。

### 恢复余量实验（VT，DECODER_THREADS=1）

| 余量 | 总耗时 | 输出 SHA-256 | 结论 |
|---|---:|---|---|
| 0.5s（当前） | 0.72s | `406db119…` | 基线 |
| 0.25s | 0.70s | `406db119…` ✅ 逐字节一致 | 安全，省 ~0.02s |
| 0.125s | 0.69–0.71s | `406db119…` ✅ 逐字节一致 | 本样本安全，需语料验证 |
| 0.0s | 0.68–0.73s | `3bed2195…` ❌ 画面差异 | 破坏正确性 |

结论：VT 只有 1 个 frame thread，帧重排序窗口远小于 libav 的 3 线程，余量
可保守降至 0.25s；0.125s 在代表样本逐字节一致但需跨语料验证。节省仅 ~0.02s
（2–4%），因为 nonref 预滚段本身已廉价（只解参考帧），余量只影响窗口前最后
0.25–0.5s 的完整解码帧数（约 4–8 帧/采样点）。

### seek 优化

`seek(target, ..target)` 已定位到目标前**最近关键帧**，这是标准最优行为。
预滚长度由源文件 GOP 结构决定（本样本关键帧间隔 0.5–2.4s），无 seek 标志
可进一步改善。`AVSEEK_FLAG_ANY` 会落在 GOP 中间导致参考链损坏，不可用。

### 结论

| 方向 | 结果 |
|---|---|
| 余量 0.5→0.25s | ⚠️ 省 ~0.02s（2–4%），输出逐字节一致；libav（3 线程）维持 0.5s |
| 余量 0.125s | ⚠️ 代表样本一致，需 11 语料验证后再定 |
| seek 优化 | ❌ 已是最优（最近关键帧），预滚长度由源 GOP 决定 |
| 解码本身 | ❌ 1.5s 窗口 × 9 采样点的固定 profile 成本，GPU 吞吐受限，为硬下限 |

真正瓶颈是固定 Preview profile（1.5s 窗口）的解码吞吐，预滚优化空间约
2–4%。若需更大幅度提速，只能降低 profile（改 ADR-0001 契约）或减少采样点
并发（-T 调优，但此前实测无墙钟收益）。

## Windows 性能测试（2026-07-31，Windows + RTX 3090）

### 环境

- 系统：Windows，NVIDIA GeForce RTX 3090（24 GB，CUDA 13.3，WDDM），多核 CPU
- FFmpeg：8.0-full_build-www.gyan.dev（CPU 解码路径）
- 输入：`sample/input.mkv`（3.2 GB，3295s，55 分钟）
- 测试命令（固定 Preview profile）：

```sh
./target/release/vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif
```

### Baseline（原始 vimg.exe，D:\Apps\ffmpeg\vimg.exe，2026-05-14 构建）

| Run | Time |
|-----|------|
| 1（冷缓存） | 3.539s |
| 2 | 2.478s |
| 3 | 2.494s |
| **热平均** | **~2.49s** |

### 最新代码（含 macOS streaming pipeline 优化，2026-07-31 构建）

| Run | Time |
|-----|------|
| 1（冷缓存） | 3.192s |
| 2 | 2.427s |
| 3 | 2.535s |
| 4 | 2.438s |
| 5 | 2.403s |
| 6 | 2.558s |
| **热平均** | **~2.47s** |

### 参数实验（最新代码）

| 配置 | 耗时 |
|------|------|
| 默认 -T4 | ~2.47s |
| -T2 | ~2.43s |
| -T8 | ~2.93–3.11s（资源竞争，更慢） |
| --capture-backend auto | ~3.06s（含 libav 尝试失败回退） |

### Profile 阶段分解（最新代码，默认 -T4）

| 阶段 | 耗时 |
|------|------|
| plan_setup（探测+规划） | 0.138s |
| first_grid（首个完整网格可用） | 1.681s |
| receive_wait（9 采样点同步等待，最慢 worker） | 1.740s |
| join（网格合成） | 0.049s |
| encoder_write（编码输入） | 0.256s |
| encoder_tail（编码收尾） | 0.298s |
| **total** | **2.509s** |

### 结果

- **最新代码 ≈ baseline**（2.47s vs 2.49s，+0.6%），mac 优化（bounded channel +
  frame barrier 同步）在 Windows 上无显著收益，瓶颈同样是解码/提取
  （receive_wait 1.74s 占总耗时 69%）。
- 输出与 baseline **逐字节一致**（SHA-256
  `0e0e34e99006231097fa1678752f880bf7f4928eaaa5136e795da5a86991e70b`，85 KB AVIF），
  正确性保持。
- **CUDA 硬件加速保持禁用**（`CUDA_AVAILABLE=false`）：与早期 Windows 结论一致，
  短视频捕获中 CUDA 初始化开销大于收益；RTX 3090 上启用未见加速。
- **-T8 更慢**：9 个采样点并发 8 个 ffmpeg 进程导致资源竞争；-T2/-T4 相当，
  默认 -T4 合理。
- **auto 更慢**（3.06s）：Windows 上先尝试进程内 libav 失败后再回退 ffmpeg，
  白耗约 0.5s。

### 与 macOS 对比

| 平台/后端 | 平均耗时 |
|---|---:|
| macOS Apple M4 / VideoToolbox | **0.759s** |
| macOS Apple M4 / 软件 libav | 0.966s |
| macOS Apple M4 / ffmpeg | 1.197s |
| **Windows / ffmpeg（最新代码）** | **2.472s** |
| Windows / ffmpeg（baseline） | 2.486s |

Windows 比 mac 慢约 2 倍，差距来自解码/提取阶段（Windows 上无 VT 硬件解码路径，
9 采样点 × 1.5s 窗口的 CPU 解码是硬成本），而非 vimg 自身处理逻辑
（join 0.049s + encode 0.55s 仅占总耗时 ~24%）。

## Windows 1.3s 优化调研（2026-07-31，Windows + RTX 3090）

目标：将 Windows 版本从 ~2.5s 优化到 1.3s 以内。Profile 显示瓶颈是解码/提取
阶段（receive_wait 1.74s 占 69%），系统性调研了所有可行路径。

### 瓶颈根因（ffmpeg CLI 后端）

1. **mkv 并发 seek 串行化**（最大单一瓶颈）：3.2 GB mkv（55 流，含 52 字幕）的
   9 个采样点 seek 完全串行，每点 ~0.1-0.2s，总 ~1.9s。
   - 单点 seek+解码：0.26-0.31s
   - 9 并发 seek+1帧：1.89s（同位置 0.998s vs 不同位置 1.89s）
   - 9 并发**无 seek** 解码：仅 1.075s（有并行）→ seek 是串行化元凶
   - 同文件并发访问串行化（9 个不同文件并发 seek 仅 1.22s）
   - mp4 faststart / 硬链接 / 页缓存预热均无改善
2. **ffmpeg 进程启动 0.137s/进程**（Windows DLL 加载）
3. **CPU 解码吞吐饱和**：~340-400 fps，9 点 × 65 帧（含预滚）需要并发解码

### 已尝试的优化及结果

| 方案 | 结果 |
|---|---|
| -T8（更高并发） | 2.93-3.11s，更慢（资源竞争） |
| FFMPEG_THREADS_PER_CAPTURE=2 | 3.15s，更慢（barrier 同步放大） |
| 3 worker × 3 点串行 | 1.80-2.40s（不稳定，受负载影响） |
| 单进程多输入（9 输入） | 2.95s，更慢（交错调度） |
| -probesize 100K | 无改善 |
| -map 0:v -sn（忽略字幕） | 无改善 |
| CUDA 硬件解码 | 单点 1.6s（CPU 0.38s 的 4 倍），9 并发 2.75s，更慢 |
| dxva2 硬件解码 | 9 并发 2.64s，比 CPU 慢 |
| mkv→mp4 faststart 转码 | 9 并发 seek 1.93s vs 2.06s，无改善 |
| **libav 进程内后端** | **2.35s（比 ffmpeg 后端快 9%），输出逐字节一致** |

### libav 后端集成（Windows）

在 Windows 上编译 `in-process-decode` feature 需要 FFmpeg 开发库：

1. 下载 GyanD/codexffmpeg 8.1.2 full_build-shared（GitHub，101 MB，含 include/lib）
2. 手动创建 pkgconfig .pc 文件指向其 lib 目录
3. 设置 `PKG_CONFIG_PATH` 编译；运行时 `PATH` 需含其 bin 目录（avcodec-62.dll 等）

ffmpeg-sys-next 8.1.0 仅匹配到 FFmpeg 8.1（lavc 62）；BtbN master（lavc 63）
API 不兼容（AV_CODEC_ID_V308 等被移除，AVCodec 字段改为 avcodec_get_supported_config）。

### 结论

**Windows 上 1.3s 不可达**。两个后端的瓶颈都是 Windows CPU 解码吞吐
（~340-400 fps），与进程启动/seek 策略无关：

- ffmpeg CLI 后端：~2.57s（mkv seek 串行化 1.9s + 解码竞争）
- libav 进程内后端：~2.35s（decode 1.75s 是最大 worker，9 路并发 CPU 竞争）
- macOS M4 的 1.197s（ffmpeg）/ 0.759s（VideoToolbox）依赖硬件解码路径，
  Windows 上 CUDA/dxva2 的 GPU→CPU 帧传输开销使其更慢（与早期结论一致）

附带改动：`NONREF_RECOVERY_MARGIN_S` 0.5→0.25（mac 已验证安全），Windows 上
libav 输出与 ffmpeg 后端逐字节一致（SHA-256 3f0fa2be…），预滚帧 310→272。

若需真正达到 1.3s，需要 Windows 硬件解码路径（CUDA 帧传输优化）或降低
固定 Preview profile 的窗口/帧数契约（ADR-0001）。

### libav 并发门控（semaphore）优化（2026-07-31 追加）

libav 后端 9 个解码 worker 全并发时 CPU 饱和（decode 1.68s）。添加并发门控：
worker 开始前 acquire semaphore（permit 数 = -T，默认 4），`recv` 改为轮询
所有 channel（try_recv + yield，跳过已完成的 worker），避免有界 channel
死锁。

| 配置 | decode（max worker） | first_grid | total（profile） |
|---|---|---|---|
| libav 无门控（9 并发） | 1.68s | 0.89s | 2.08s |
| libav -T4 门控 | 0.95s | 1.32s（241 帧才齐集，后 5 worker 排队） | **1.87s** |
| 每 5 帧时间片轮转 | 1.57s（解码器切换开销） | 1.26s | 1.88s（更差） |

高负载（CPU 被 dota2/rustdesk 占用）下 libav -T4 门控 1.87s vs ffmpeg 后端
2.60s（快 28%）；清理负载后两者均 ~2.1-2.2s（CPU 解码吞吐是共同硬下限）。
输出与 ffmpeg 后端逐字节一致（SHA-256 3f0fa2be…）。尝试了每帧/每 5 帧
时间片门控（解码器频繁切换，吞吐下降），最终保留整 worker 门控。

### first_grid 并发调度调研与门控移除（2026-07-31）

整 worker 门控（permit=-T，默认 4）让 9 个 worker 分 3 波排队：worker 0-3
解完全部 30 帧才释放 permit，grid 0 要等最后一波 worker 的帧 0
（frames_before_first_grid 膨胖到 241）。系统性实验：

| 配置 | first_grid | decode | total(profile) | wall |
|---|---|---|---|---|
| 整 worker 门控（-T4） | 1.32s | 0.95s | 1.88s | 2.35s |
| 帧 0 后释放+重 acquire | 1.39s | — | 2.20s（重新排队停顿） | 2.3-3.3s |
| 每 5 帧时间片 | 1.26s | 1.57s（切换开销） | 1.88s | 2.0-3.0s |
| -T9 无门控 | 1.11s | 1.43s | **1.74s** | **1.90s** |

**结论：整 worker 门控是负优化**。3 波排队（后 5 个 worker 空闲等 permit）的
开销大于 9 路并发竞争（27 线程 vs 24 核）。低负载、高负载（2 实例并行）
下 -T9 均优于 -T4（2.85s vs 2.96s @ 2 实例）。已移除门控（保留 recv 轮询
与 margin 0.125/no-clone 优化）。

最终（libav，无门控 + margin 0.125 + no-clone）：first_grid 1.11s
（vs ffmpeg 后端 1.75s，快 37%），total 1.74s（vs 2.11s，快 12%），
输出逐字节一致（3f0fa2be…）。frames_before_first_grid=241 的残余是
慢采样点（长 GOP 预滚 0.6s）的物理下限：grid 0 必须等最慢采样点的帧 0，
期间 recv 已消费快采样点的帧 1-29。

### libav 预滚执行效率测量（2026-07-31，Windows + RTX 3090）

对 libav 后端的 9 个采样点逐 worker 计时（setup / nonref 预滚 / 窗口完整解码）：

| cap | start | setup | 预滚(nonref) | 窗口(完整) | total | 预滚帧 |
|---|---:|---:|---:|---:|---:|---:|
| 0 | 183s | 0.034s | 0.060s | 0.320s | 0.415s | 12 |
| 1 | 549s | 0.034s | 0.065s | 0.244s | 0.343s | 13 |
| 2 | 915s | 0.034s | 0.236s | 0.341s | 0.606s | 26 |
| 3 | 1282s | 0.034s | 0.387s | 0.365s | 0.791s | 29 |
| 4 | 1648s | 0.036s | 0.081s | 0.292s | 0.411s | 15 |
| 5 | 2014s | 0.035s | 0.212s | 0.243s | 0.495s | 33 |
| 6 | 2380s | 0.044s | 0.492s | 0.200s | 0.759s | 67 |
| 7 | 2746s | 0.042s | 0.629s | 0.297s | 0.962s | 66 |
| 8 | 3112s | 0.034s | 0.031s | 0.180s | 0.255s | 11 |

结论：

1. **setup 恒定 0.03-0.05s**（打开+seek，与采样点位置无关）。
2. **预滚成本完全由源 GOP 结构决定**：长 GOP 区域（cap 6/7，关键帧间隔
   2-3s）预滚 0.47-0.63s / 66-67 帧；短 GOP 区域（cap 8）仅 0.03s / 11 帧。
3. **nonref 预滚吞吐 ~105-137 fps**（只解参考帧，跳过 B 帧）；窗口完整
   解码阶段稳定 0.18-0.37s（1.5s 窗口 + 0.25s 余量）。
4. **慢采样点（cap 6/7）的 0.76-0.96s ≈ ffmpeg 后端同位置 0.7-0.9s**，
   但 libav 预滚跳过 B 帧（AVDISCARD_NONREF），ffmpeg CLI `-ss` 丢弃段
   是全解码——这是 libav 高负载下快 20% 的结构性原因。
5. 预滚占慢点总耗时 52-65%，是 Windows 上剩余可优化空间（受 GOP 结构和
   nonref 正确性约束，仅能通过 margin 微调，已从 0.5s 降至 0.25s）。

### 预滚优化实施（2026-07-31）

两项改动（提交于 libav backend）：

1. **预滚帧跳过克隆**：原 `receive_frames` 对每个解码帧（含预滚帧）先
   `decoded.clone()`（~3MB/帧）再判定 `pts < source_pts_offset()` 丢弃。
   预滚 272 帧 × 3MB ≈ 800MB 无效内存分配 + 拷贝。改为先判定后克隆，
   预滚帧零拷贝。
2. **margin 0.25 → 0.125**：预滚帧 272 → 254（−6.6%），输出仍逐字节一致
   （SHA-256 3f0fa2be…，本样本验证；mac 上 0.125 亦一致但需语料验证）。

效果（profile total）：1.944s → 1.881-1.95s（−0.06s，~3%），收益在系统
负载噪声内。结构性限制：预滚段必须解出窗口起点前的全部参考帧（参考链
正确性），GOP 由源决定，margin 只能微调 nonref/完整解码切换点。剩余大头
是 first_grid 等待（semaphore=4 下 241 帧才齐集，后 5 个 worker 排队）和
encode 0.35s。

## libav 并发门控复测（2026-07-31，Windows + RTX 3090）

### 目的与方法

本轮重新验证 jj 提交 `32888cb2`（整 worker semaphore + `try_recv/yield_now`
轮询）相对父提交 `1863551e` 的结论。两个提交均使用 FFmpeg 8.1.2 shared
开发库重新执行 release + LTO 构建，固定输入和 Preview profile：

```powershell
.\vimg.exe vcs -c3 -H160 -n9 -T4 --capture-backend libav --profile `
  .\sample\input.mkv --output .\output.avif
```

先各预热一次，再按 ABBA 顺序交错运行，避免把文件缓存和随时间变化的系统负载
归到某一个提交。空闲态每个版本记录 6 轮；受控高负载使用 8 个限时 CPU job，
每个版本记录 4 轮。墙钟、vimg CPU 时间、profile 阶段和 vimg 自身工作集分别采集。

### 严格父/子提交 A/B（空闲态）

| 指标 | 父提交 `1863551e` | `32888cb` `-T4` | 变化 |
|---|---:|---:|---:|
| 外部墙钟平均 | **2.031s** | 2.086s | +2.7% |
| profile total 平均 | **1.955s** | 2.012s | +2.9% |
| profile decode（最大 worker） | 1.634s | **1.073s** | -34.3% |
| first_grid | **0.830s** | 1.445s | +74.1% |
| 首个网格前接收帧数 | **9** | 240–241 | 约 27 倍 |
| vimg CPU 时间 | 15.878s | **12.781s** | -19.5% |

复测确认门控显著降低单 worker 活跃解码耗时和 CPU 消耗，但**没有转化为端到端
延迟收益**；空闲态总耗时反而约慢 3%。原因是只有前 4 个 worker 能工作，后 5 个
必须等待前一批完整产生 30 帧并释放 permit，导致编码器很晚才得到第一个完整网格。

### 受控高负载复测

| 指标 | 父提交 `1863551e` | `32888cb` `-T4` | 变化 |
|---|---:|---:|---:|
| profile total 平均 | **3.393s** | 4.148s | +22.3% |
| profile decode | 2.667s | **2.071s** | -22.4% |
| first_grid | **1.482s** | 2.793s | +88.5% |

受控负载下仍未复现原报告的 `2.08s → 1.87s`，而是得到相反结果。原实验使用
dota2/rustdesk 形成不可重复的背景负载，本轮的 ABBA + 固定 CPU job 结果表明，
不能以单次 `decode` 降幅推导总吞吐提高。

这里还有一个计时盲点：semaphore 在调用 `decode_capture` 之前获取，而
`decode_capture` 内部才启动计时；`CaptureMetrics::include_worker` 又只保留最大
worker 活跃时间。因此 profile `decode` 完全不含 permit 排队时间。`32888cb`
显示的 `decode` 下降是真实的单 worker 吞吐改善，但不是 Capture attempt makespan。

### CPU/RSS 收益

独立的 3 轮交错工作集采样得到：

| 指标 | 父提交 `1863551e` | `32888cb` `-T4` |
|---|---:|---:|
| vimg 自身峰值 RSS | ~603 MB | **~286 MB** |
| vimg CPU 时间 | ~15.8s | **~13.3s** |

RSS 不包含 ffmpeg 编码子进程，因此不能直接当作进程树总 RSS；但父提交仅 vimg
自身就已超过 ADR-0001 的 512 MB 预算，而 `-T4` 留有明显余量。由此，`32888cb`
应被评价为**资源稳定性优化，而不是延迟优化**。简单回退会恢复早首屏，但违反现有
内存约束。

### 接收策略隔离实验

将 `32888cb` 设为 `-T9` 后 9 个 worker 都能立即获得 permit，此时与父提交的
主要差异只剩新的轮询接收策略：

| 指标 | 父提交阻塞 round-robin | `32888cb -T9` 轮询 |
|---|---:|---:|
| profile total（4 轮平均） | **1.895s** | 1.922s |
| vimg CPU 时间 | **16.332s** | 16.816s |
| first_grid | **0.830s** | 1.328s |
| 首个网格前接收帧数 | **9** | 约 240 |

`try_recv + yield_now` 本身使 CPU 增约 3%、总耗时增约 1.4%，并让快速 worker
反复被抽干，破坏 capture index 之间的公平性。它解决了 whole-worker 门控与有界
channel 的死锁，却不应作为最终调度方案。

### `-T` 与 decoder threads 扫描

当前门控实现执行两轮 `-T2…-T9` 扫描：

| `-T` | profile total 平均 | vimg 峰值 RSS（单轮） |
|---:|---:|---:|
| 2 | 2.370s | 未记录 |
| 3 | 2.013s | 未记录 |
| 4 | 2.083s | ~286 MB |
| 5 | 2.016s | ~330 MB |
| 6 | 1.899s | ~403 MB |
| 7 | 1.865s | ~412 MB |
| 8 | 1.860s | ~475 MB |
| 9 | 1.858s | ~499 MB |

本机空闲态的速度峰值在 `T7–T9`，而非默认 `T4`；但 T8/T9 的 vimg 自身 RSS
已经接近 512 MB，尚未计入编码子进程，也没有输入语料余量，因此不能直接提升
全局默认值。T7 可作为这台机器的后续候选配置，但需要采集进程树 P95 RSS。

另构建了父提交公平 round-robin 的实验二进制，将每 decoder frame threads 从
1 扫到 8。1/2/3 threads 的三轮 total 分别约为 2.315s、2.076s、2.065s；
4–8 threads 落在约 1.93–2.08s，没有稳定单调收益。单轮 RSS 为：

| decoder threads | first_grid 前帧数 | vimg 峰值 RSS |
|---:|---:|---:|
| 1 | 9 | ~449 MB |
| 2 | 9 | ~519 MB |
| 3 | 9 | ~609 MB |
| 4 | 9 | ~664 MB |

降到 1 thread 能保留公平首屏且把 vimg RSS 压到 512 MB 内，但总耗时约 2.3s，
并且加上编码子进程后仍可能越界；2 threads 已由 vimg 自身越界。单纯调整 decoder
threads 不是足够好的最终方案。

### 正确性

本轮所有门控值、父/子提交以及 decoder thread 变体都生成相同 SHA-256：
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`，
与 ffmpeg Capture backend 输出逐字节一致。帧数保持 30，帧选择契约未改变。

### 后续优化优先级

1. **先修 profile 计时边界**：新增 `gate_wait`、从 worker 创建到完成的
   `capture_makespan`，并记录进程树峰值 RSS。否则后续仍可能把排队隐藏成
   “decode 变快”。
2. **降低每个 decoder 的常驻帧内存，再恢复公平接收**：当前每个 worker 会保留
   `pending_decoded` 和 `previous_decoded` 的全分辨率 frame 引用，frame threading
   又扩大 decoder buffer pool。可原型验证把 previous source 缩放为小尺寸 RGB 后
   释放全分辨率引用，或评估 slice threading；目标是让 9 个公平 worker 在包含编码器
   的 512 MB 进程树预算内运行。若能做到，父提交的 9-frame 首屏可恢复。
3. **替换忙轮询**：使用带 ready 通知的公平调度器（共享 Condvar/ready queue +
   capture-index 优先级），避免 `yield_now` 占核。它必须和资源许可一起设计，不能
   只把 `try_recv` 换回阻塞调用，否则会重新引入有界 channel 死锁。
4. **尝试更粗的公平时间片**：此前 1 帧/5 帧轮转较慢，但 10/15 帧尚未验证；
   ticketed semaphore 可保证等待 worker 获得 permit，减少同一 worker 立即重抢。
   这属于低风险原型，但仍需同时验证 RSS、first_grid 与总耗时。
5. **Windows 编码路径**：本轮 libav 的 join + encoder write + tail 常占约
   0.4–0.5s。进程内 AVIF 编码可减少子进程启动、pipe backpressure 和重复 DLL
   工作集，是解码以外更现实的 0.1–0.2s 候选；必须保持固定 Preview profile。
6. **NVIDIA 路径只研究“GPU 上缩放后再下载选中帧”**：已有 CUDA CLI 路径逐点
   初始化且传输成本高，不值得重复。若继续，应使用进程内 D3D11VA/NVDEC、保持
   解码帧在 GPU，并在 284×160 缩放后才下载；否则大概率仍慢于软件 libav。
7. **预滚余量 0.25→0.125s**：代表样本已有逐字节一致证据，潜在收益约 2–4%，
   但只能在完整语料 authority 验证通过后采用，优先级低于调度和内存问题。

### 复测结论

- `32888cb` 的“降低 worker decode/CPU/RSS”结论成立。
- `32888cb` 的“提高端到端效率、高负载更快”结论本轮未验证，空闲和受控高负载
  均更慢；原结论应修正为资源稳定性收益。
- 当前最主要的结构性问题是以 240 个已接收帧换取内存门控，丢失了原有 9 帧即可
  组成首个网格的流水线性质。
- 在 512 MB 契约下不应直接回退；下一步最值得做的是减少每 decoder 常驻内存，
  使公平的 9-worker 接收重新可行，并同时修正指标。

### 最终决策与权衡（2026-07-31，提交 `56fc1e4`）

上表建议“在 512 MB 契约下不直接回退”，但后续 A/B 实测推翻了该保守结论：

| 配置 | profile total | first_grid | vimg 峰值 RSS |
|---|---:|---:|---:|
| 整 worker 门控（-T4） | 1.88s | 1.32s | ~286 MB |
| 无门控（`56fc1e4`） | **1.74s** | **1.11s** | ~523 MB |

门控的 3 波排队（5 个 worker 空闲等 permit）在低负载与受控高负载（2 实例
并行）下均劣于 9 路并发竞争：`-T9` 2.85s vs `-T4` 2.96s（2 实例）。
serve 模式为单活跃 job，门控无防御价值。

**决策：移除门控（延迟优先）**，接受 RSS ~523MB 超预算 ~11MB。残留风险与
后续方向：减少每 decoder 常驻内存（释放 `previous_decoded`/`pending_decoded`
全分辨率引用）使公平 9-worker 回到预算内，并修正 profile 计时边界
（新增 `gate_wait`/`capture_makespan`）。完整数据归档于
`benchmarks/windows.md`。

### 每 decoder 常驻内存优化实施（2026-07-31，提交 `实施`）

目标：移除门控后 RSS ~523MB 超 ADR-0001 的 512MB 预算，压缩每 decoder
常驻内存。

1. **previous 帧改存缩放后 RGB**：`emit_scheduled_frames` 原来把
   `previous_decoded`（全分辨率 YUV ~3MB/worker）保留给 CFR 补帧；改为
   每次无条件将当前帧缩放一次（`current_rgb`，284×160 RGB 136KB）并作为
   previous 保留，补帧直接复用 RGB（不再重新缩放）。省 ~9MB/进程，且缩放
   次数从“每 scheduled 帧”降到“每源帧一次”。
2. **DECODER_THREADS 3→2（frame threading）**：decoder 帧线程缓冲池是 RSS
   大头（DT=3 514.6MB → DT=2 443.3MB）。slice threading 虽降到 363.7MB
   但 h264 单帧 slice 少、无并行收益（total 2.17s，+25%），放弃。

| 配置 | profile total | 峰值 RSS | 512MB 预算 |
|---|---:|---:|---|
| frame threading DT=3 | **1.74s** | 514.6MB | ✗ 超 0.5% |
| **frame threading DT=2（采用）** | 1.96s | **443.3MB** | ✅ 余 69MB |
| slice threading DT=3 | 2.17s | 363.7MB | ✅ 余 148MB |

输出与 ffmpeg 后端逐字节一致（SHA-256 3f0fa2be…）。**最终采用 DT=2**：
预算内最快；性能代价 ~0.22s（相对 DT=3）换取 RSS 余量 69MB（含编码子进程
与输入语料的缓冲）。

### 调研执行与 SVT lp=4（2026-08-01）

执行调研文档 `docs/research/2026-08-01-windows-runtime-optimization-options.md`
的 P0 实验（端到端 ABBA，warm 6 次/配置）：

| 配置 | wall 平均 | profile total | 512MB 预算 |
|---|---:|---:|---|
| DT2 + SVT 自动 lp（原） | ~2.04s | 1.96s | ✅ |
| **DT2 + `lp=4`（采用）** | **~1.90s** | **1.67s** | ✅ |
| DT3 + 自动 lp | ~2.02s | — | ✗ |
| DT3 + `lp=4` | ~1.99s | — | ✗ |

SVT-AV1 `lp`（Level of Parallelism，0-6）不是 low-power：30 帧 852×480
短编码自动 lp=6 过度并行（PPCS 305→107），编码 write+tail 0.36→0.27s。
lp=4 在 DT2 下端到端 −15%（profile total），输出逐字节一致
（`3f0fa2be…`）；DT3 下收益被解码竞争淹没，且 RSS 超预算。

**最终 libav 配置**：无门控 + frame threading DT=2 + margin 0.125 +
预滚零拷贝 + previous 缩放 RGB + SVT `lp=4`。wall ~1.90s、profile total
1.67s、peak RSS 445MB。未做选择性 DT3（收益小于复杂度）与阻塞轮询
（当前收益上限 1-2%）；进程内编码/硬件后端为 P1 后续方向。

### 调研 P0 剩余项执行结果（2026-08-01）

按调研文档建议实验顺序执行剩余 P0，**两项均端到端实测失败并回退**：

| 步骤 | 方案 | 端到端实测 | 结论 |
|---|---|---|---|
| S1 | busy poll → 阻塞 round-robin | first_grid 0.73s（−39%✅）但 **total 1.94s（更慢）+ RSS 507MB（超预算）** | ❌ 回退 polling |
| S2 | lazy scale（只缩放被选帧） | 输出一致但 **wall 无收益 + RSS 510MB（Deferred 全分辨率保留）** | ❌ 回退无条件缩放 |
| S3 | 选择性 DT3（慢窗口） | 未实施：per-window 线程需 open 时配置 + 运行时慢窗口判定，复杂度 > 估计收益 <0.22s | 跳过 |

关键发现（与调研隔离数据矛盾处）：

- **阻塞 round-robin 的 channel 背压使快 worker 停顿**（解码吞吐下降，total
  反而变慢），且 worker 暂停时保留 decoder buffer（RSS +67MB 超预算）。
  调研隔离数据（blocking 1.895s vs polling 1.922s）未计入 RSS 与端到端
  背压交互，本机端到端 ABBA 结论相反。
- **lazy scale 的 Deferred 全分辨率保留**使 RSS 超预算；本 sample 缩放不占
  profile 大头（无 wall 收益）。

**最终保留配置 = 调研前状态**（DT2 + lp4 + polling + previous RGB +
no-clone + margin 0.125）：profile total ~1.8s、wall ~2.0s、peak RSS
~440MB、输出逐字节一致（`3f0fa2be…`）。剩余有价值方向为 P1：
进程内编码（非解码尾段 0.4-0.5s）与共享上下文硬件解码。

### P1 进程内编码原型（2026-08-01）

用 ffmpeg-next 实现进程内 libsvtav1 编码 + AVIF mux 的独立探针
（临时 `enc_probe` bin，已删除）：

- **编码收益确认**：30 帧 852×480 libsvtav1（preset 8 / crf 30 / lp=4 /
  yuv420p10le）进程内 **0.08-0.11s**，packets=30。外部 ffmpeg 的
  encoder_write+tail 约 0.32s → **可回收 ~0.2s**。
- **关键坑**：`encoder::find(Id::AV1)` 选到 **libaom-av1**（4.4s 极慢），
  必须 `find_by_name("libsvtav1")`；SVT 全缓冲（send_eof 后才出包）。
- **封装障碍**：packet pts 以编码器 time_base（1/20）输出，avif muxer 的
  track timescale 为 1/10240（CLI 自动 rescale，ffmpeg-next 需手动
  pts×512 + duration=512）；track duration_ts 对齐后（15360=1.5s），
  **mvhd 仍不匹配**（stream time_base 1/90000 vs CLI 1/10240，
  format duration 0.17s vs 1.5s）——非字节一致。
- **结论**：编码端收益 ~0.2s 可行，但 AVIF 封装 timescale 对齐需深入
  movenc 内部；按 ADR 字节一致门槛**暂不集成**。后续若做，先解决
  stream time_base 与 packet pts 单位对齐，再用 raw grid hash + 解码帧数
  + duration + 文件大小验收。

### P1 硬件解码探针（2026-08-01，进程内共享 CUDA）

ffmpeg-next 无 hwaccel API，用 ffmpeg-sys ffi 写临时 `cuda_probe` bin
（已删除）：共享 CUDA device context + 9 窗口 h264_cuvid 并发解码 +
av_hwframe_transfer_data 回传 + sws 缩放。

| 发现 | 数据 |
|---|---|
| 像素一致性 | CLI 验证 CUDA 硬解 = CPU 软解逐字节一致（h264 确定性） |
| 共享上下文吞吐 | 9 窗口 30 帧/窗口 makespan **0.53-0.59s**（~460-510fps 含 transfer+sws） |
| seek | `avformat_seek_file(-1)` 无效（packet pts 全 0）；`av_seek_frame(流索引)` 有效 |
| **nonref 预滚** | **`skip_frame(AVDISCARD_NONREF)` 对 h264_cuvid 无效**（packets 全解） |
| 帧 pts | cuvid 输出帧无 pts（需 packet time_base + 权威追踪） |

**收益评估为负**：cuvid 无 nonref 预滚 → 预滚段全解码（含 B 帧），
每窗口 ~95 帧（vs CPU nonref 的 ~65 帧，+50%）。9 窗口 855 帧 @ 460fps
≈ 1.86s，劣于 CPU libav 的 1.5s（nonref 预滚）。

**结论：硬件解码方向关闭**。NVDEC 13.1 的按 PTS 跳过输出不承诺跳过参考帧
解码（调研文档已警示），无法复刻 `AVDISCARD_NONREF` preroll；预滚段全解码
抵消 GPU 吞吐优势。若要继续，需先验证驱动层跳过 B 帧解码，或改预滚策略
（但会破坏选帧权威）。

### 首帧延迟（first_grid）专项调研（2026-08-01）

目标：默认 ffmpeg 后端的 `first_grid`（首个完整 3×3 网格）约 1.5s，占 total
~2.24s 的 67%。定位其构成，寻找不破坏选帧权威的 CLI 级优化。

实测基线（默认 ffmpeg 后端，warm，3 次）：`first_grid` 1.50–1.63s、
`receive_wait` 1.53–1.64s、`total` 2.08–2.31s。

构成分解（本机实测）：

1. **9 路 ffmpeg 子进程启动约 270ms/进程，并发重叠后约 350ms 总量**。
   `ffmpeg -version` 稳定 236–313ms（Windows 进程 + FFmpeg DLL 装载）；
   9 个原生并发启动（Rust `std::process` / CreateProcess）makespan 约
   310–370ms，说明 DLL 装载高度重叠，不是主要瓶颈。
2. **H.264 预滚解码是主导**。`-ss` 前置于 `-i` 为 fast-seek，落到起点前的
   关键帧再顺序解码到采样点。本样本关键帧间隔 4–8s（探测：窗口 1281.56s
   前关键帧 1276.11s → 预滚 5.45s；窗口 2746.21s 前关键帧 2738.19s →
   预滚 8.02s）。孤立单窗口解码耗时与预滚长度正相关：2746s 窗口 928–1103ms，
   3112s 窗口（近文件尾、预滚短）296–335ms。
3. **每进程线程数已最优**。原生并发 9 窗口测 makespan：
   threads=1/2/3 → 2373/1863/1659ms，当前 `FFMPEG_THREADS_PER_CAPTURE=3`
   为最佳。
4. **缩放不是预滚瓶颈**。预滚帧会经过 scale 但开销可忽略
   （`select='gte(t,start)'` 前置拦截无收益；不缩放输出 1080p 反而更慢）。

已排除的 CLI 方案（会破坏选帧权威，不可用）：

- `-noaccurate_seek`：速度提升 3×（2746s 窗口 1103→412ms）但输出从关键帧
  开始（showinfo 首帧 type=I、pts=-8.016s），帧内容整体前移，违背 ADR-0003。
- `-skip_frame nonref`：预滚期跳 B 帧可行，但会对目标窗口同样丢弃非参考帧，
  CFR 取帧得到错误内容。

结论：默认 ffmpeg 后端 `first_grid` 对本样本已接近下限。唯一能实质降低
`first_grid` 的是进程内 libav 后端的 nonref 预滚（仅预滚期丢弃非参考帧、
目标窗口恢复完整解码）。该后端 feature-gated、本机原先无 FFmpeg dev 库无法
构建、且未晋级默认。服务端重复请求已通过 Media descriptor 跳过 plan_setup
探测（约 0.2s），无需额外改动。构建解锁与实测见下节。

### 进程内 libav 构建解锁与实测（2026-08-01）

构建环境：本机原先 `--features in-process-decode` 因缺少 FFmpeg dev 库无法
链接（`ffmpeg-sys-next` 需要 `libavutil.pc`）。从 BtbN 下载与
`ffmpeg-next 8.1.0` 版本匹配的 `ffmpeg-n8.1-latest-win64-gpl-shared-8.1.zip`
（含 `include/`、`lib/pkgconfig/*.pc`、共享 DLL），设置 `PKG_CONFIG_PATH`
指向其 `lib/pkgconfig` 后 `cargo build --release --features in-process-decode`
成功。运行需把该包 `bin/` 置于 PATH（进程内解码器 DLL 与编码器子进程共用 8.1）。

同编码器（ffmpeg 8.1）下 warm 3 次实测：

| 指标 | libav 后端 | ffmpeg 后端 | 差异 |
|---|---:|---:|---:|
| first_grid | 0.95–1.02s | 1.20–1.22s | −19% |
| receive_wait | 1.05–1.11s | 1.23–1.25s | −15% |
| total | 1.40–1.47s | 1.74–1.76s | −18% |
| 峰值 RSS（vimg 进程，采样） | 348 MiB | — | 512MB 预算内 |

输出与 ffmpeg 后端在相同编码器下逐字节一致（SHA-256 `7e3e22df…`），满足
ADR-0003 选帧权威。`--capture-backend auto` 在 Windows 上实测会选中 libav。

附带发现：编码器子进程从 ffmpeg 8.0 升到 8.1 本身就让 ffmpeg 后端 total
从 ~2.24s 降到 ~1.75s（SVT-AV1 编码端差异），是独立于解码后端的部署级收益。

结论：进程内 libav 后端在可构建机器上收益明确（first_grid −19%、total −18%、
RSS 预算内、输出逐字节一致）。**已实施：非 macOS 默认后端改为 `auto`**。

### 默认后端改为 auto（Windows 使用 libav）（2026-08-01）

变更：`capture.rs` 新增平台条件默认常量
`DEFAULT_CAPTURE_BACKEND`（非 macOS = `auto`，macOS 保留 `ffmpeg` 以维持
VideoToolbox 晋级决策）；`vcs.rs` 与 `serve.rs` 的 `--capture-backend`
默认值改为该常量。`auto` 在 Windows（带 `in-process-decode` feature）解析为
`[Libav, Ffmpeg]`：libav 仅当满足固定 Preview profile（3×3、160px、30 帧、
CRF 30、libsvtav1、无自定义 vfilter）时可用，否则以 `Unavailable` 回退到
ffmpeg 子进程，不会 fail-fast。无 feature 构建下 `auto` 等价于 `ffmpeg`。

部署：libav 版 `vimg.exe` 运行时需 FFmpeg 8.1 共享 DLL（avcodec-62.dll 等）。
已搭建可独立运行的目录 `D:\ffmpeg-dev\libav-deploy\`（vimg.exe + 8 个 DLL），
PATH 中保留 scoop ffmpeg 8.1.2 作为编码器子进程。默认命令实测（warm）：

| 指标 | 值 |
|---|---:|
| 默认选中后端 | libav |
| first_grid | ~0.96–1.00s |
| total | ~1.42–1.63s |
| 输出 | `3f0fa2be…`（与 ffmpeg 后端逐字节一致） |

相比改前默认 ffmpeg 后端（total ~2.1–2.3s），默认命令提速约 30%，
first_grid 提速约 40%，峰值 RSS ~348 MiB 仍远低于 512MB 预算。

## Windows 单次运行优化第三轮（2026-08-01，RTX 3090 + gyan FFmpeg 8.1.2 shared）

目标：在 libav 后端 ~1.45s 的基础上继续压缩单次运行时间。所有改动保持输出
SHA-256 `3f0fa2be…` 逐字节一致。

### 改动一：进程内探测（plan_setup 0.098-0.135s → 0.008s）

`capture.rs` 新增 `probe_video()`：启用 `in-process-decode` 时先用 libavformat
进程内探测（`format::input`，读容器头 + find_stream_info），失败或缺字段时
回退 ffprobe 子进程。duration 用 `"{:.6}"` 格式化与 ffprobe 输出完全一致，
保证 CapturePlan 逐位相同。ffprobe 子进程（Windows 进程 + DLL 装载 ~0.1s）
从单次运行关键路径消失。serve 模式本已缓存 Media descriptor，此改动只影响
CLI 单次运行。

### 改动二：libav worker 丢弃非视频流

`decode_capture` 在 seek 前对除选中视频流外的所有流设置
`AVStream.discard = AVDISCARD_ALL`（通过 ffi）。55 流 mkv（52 字幕轨）的
非视频 packet 在 `av_read_frame` 内部被丢弃，不再分配、投递、逐个跳过。
ffmpeg 8.x 的 seek 文档明确把 `discard < AVDISCARD_ALL` 的流视为 active，
因此 seek 行为不受影响。

### 改动三：预滚自适应 decoder 线程（选择性 DT3）

`decode_capture` 的 decoder 改为在 seek 后、读到第一个视频 packet 时惰性
打开：该 packet 的 pts 即预滚起点，据此选择帧线程数——预滚 > 1.5s（长 GOP
慢窗口，本样本 cap 6/7）用 DT3，其余 DT2。makespan 由最慢窗口主导，只给
它们加线程回收了全 DT3 的大部分收益（decode max 1.29→1.13s），而 RSS 只
增加 ~20MB（2 个 worker）。ABBA 复测 t=1.0 与 t=1.5 性能相同，取 t=1.5
（RSS 更小）。

### 改动四：进程内 SVT-AV1 编码 + AVIF 封装（ABBA total 1.265→1.252s，P95 1.376→1.295s）

新增 `src/command/encode.rs`（feature-gated）：独立编码线程 + channel 喂帧，
替换外部 ffmpeg 子进程。encoder_write 0.07→0.012s，encoder_tail
0.15→0.135s；干净环境下 ABBA 差额约 0.10s。输出与 CLI 管线**逐字节一致**，
复刻配方：

1. 输出流 time_base 设为编码器 time_base（1/20），movenc 自动推导 track
   timescale 10240（20→×2 至 ≥10000）并重写流 time_base——与 CLI 相同。
2. packet 显式 `rescale_ts(1/20 → 1/10240)` 后写盘（此路径 muxer 不隐式
   重缩放；packet 的 pts 域与 CLI 的 ost mux_timebase 缩放等价）。
3. packet duration 显式置 1 tick/帧（libsvtav1 不输出 duration，CLI 在编码
   层用帧 duration 补丁——缺了它 track duration 只有 1.45s）。
4. 编码器设 `GLOBAL_HEADER`（mov/avif muxer 请求时 CLI 会设）：SVT 把
   sequence header 放入 extradata → av1C box 12B、每 packet −4B in-band。
5. 编码器 ctx `field_order = PROGRESSIVE`：CLI 的 codecpar 经滤镜链得到
   PROGRESSIVE，movenc 据此写 av01 的 `fiel` box。
6. 输出流 metadata `encoder = "Lavc{maj}.{min}.{micro} libsvtav1"`：
   movenc 的 compressor name 来自该 metadata（否则 32 字节全零）。
7. RGB→yuv420p10le 用 swscale bicubic（与 CLI auto_scale_0 flags 0x4
   相同），帧 range=MPEG；实测与 CLI 转换逐字节一致（mdat 完全相等）。

关键坑：**SVT-AV1 构建版本决定 bitstream**。进程内 DLL 若用 BtbN n8.1
（SVT-AV1 v4.1.0-279），输出与 CLI（gyan 8.1.2，SVT-AV1 v4.1.0-259）
不同（mdat 各包 ±2-62B，总 +120B）。已切换到 **gyan 8.1.2 full_build-shared**
DLL（新部署目录 `D:\ffmpeg-dev\libav-deploy` 已更新），SVT 版本对齐后
mdat 逐字节一致。

`lp` 实验：lp=4/2/1 输出全部逐字节一致（lp 不影响 bitstream，只影响并行度
与内存）。lp=4 峰值 WS 660MB → lp=2 553MB（PPCS 59→42）→ lp=1 528MB 但
编码串行化（total 1.39-1.48s，+0.2s）。**采用 lp=2**（字节一致 + 内存与
耗时平衡）。

逃生门：`VIMG_SUBPROCESS_ENCODER=1` 强制回退外部 ffmpeg 编码（输出仍
3f0fa2be…）。

### RSS 精确测量（GetProcessMemoryInfo PeakWorkingSetSize）

此前 4ms WorkingSet 采样严重低估峰值（短生命周期进程）。改用 OS 维护的
`PeakWorkingSetSize` 轮询（`benchmarks/peak_ws.py`）：

| 配置 | vimg 峰值 WS | 说明 |
|---|---:|---|
| 子进程编码（当前基线） | ~490MB | 另有 ffmpeg 子进程 ~150MB |
| 进程内编码 lp=4 | ~660MB | SVT 线程池 + PPCS |
| 进程内编码 lp=2（采用） | **~553MB** | 超 512 预算 41MB |

预算口径：ADR-0001 的 512MB 是 active-job 峰值 RSS。vimg 自身口径下 lp=2
超 41MB；但**进程树口径**下 lp=2（553MB，无子进程）反而比子进程编码
（490+150≈640MB）小 87MB。按本仓库"延迟优先、接受小幅度超预算"的先例
（移除门控时接受 523MB 超 11MB），采用 lp=2 并记录此口径问题供 ADR 修订。

### 最终 warm 指标（gyan 8.1.2 shared，默认 auto→libav）

| 阶段 | 优化前 | 优化后 |
|---|---:|---:|
| plan_setup | 0.098-0.135s | **0.008s** |
| decode（max worker） | ~1.29s | **~1.13s** |
| first_grid | ~1.00s | **~0.85-0.95s** |
| encoder_write | ~0.07s | **~0.012s** |
| encoder_tail | ~0.15s | **~0.135s** |
| profile total | ~1.45-1.59s | **~1.19-1.28s** |
| 峰值 WS | ~490MB | ~553MB |

ABBA（交错 12 轮/臂）：进程内编码 med 1.252s / P95 1.295s vs 子进程编码
med 1.265s / P95 1.376s；输出全部 SHA-256 `3f0fa2be…`，跨 capture backend
（libav/ffmpeg）一致。cargo test 49 通过。mp4 冒烟（探测回退路径）通过。

### 构建与部署变更

- 构建依赖从 BtbN n8.1 改为 **gyan 8.1.2 full_build-shared**
  （`D:\ffmpeg-dev\ffmpeg-8.1.2-full_build-shared`，含 include/lib/`lib/pkgconfig`
  手建 .pc 文件，SVT-AV1 v4.1.0-259 与 CLI 子进程同版）。
- 部署目录 `D:\ffmpeg-dev\libav-deploy\` 已更新为 gyan 8.1.2 的 8 个 DLL +
  新 vimg.exe；运行时 PATH 需要该目录，编码器子进程仍是 scoop ffmpeg 8.1.2
  （静态，与 DLL 同版同 SVT）。
- 注意：若部署回 BtbN DLL，进程内编码将因 SVT 版本不同产生非字节一致输出
  （容器/时长正确，仅 bitstream 不同），设置 `VIMG_SUBPROCESS_ENCODER=1`
  可强制一致。

## Yazi DDS 预览服务实装与往返验证（2026-08-01）

此前 `serve.rs` 的请求链路实际为 `gridthumb → vimg send → TCP → serve`，仅完成
通知使用 `ya pub-to`；调度器也只有一个 worker，`MAX_JOBS=10` 只是队列容量，
并不满足 AGENTS.md 所述的 DDS 接收和最多同时处理 10 个文件。

本轮改为完整 DDS 链路：

1. `vimg serve` 启动 `ya sub vimg-gridthumb-request` 并逐行读取
   `kind,receiver,sender,JSON-body`。解析使用 `splitn(4, ',')`，所以 Windows 路径
   或文件名中的逗号不会截断 JSON；DDS sender 自动成为完成通知的 Yazi ID。
2. `gridthumb.yazi` 在顶层创建 `ya.sync` 发布桥，通过
   `ps.pub_to(0, "vimg-gridthumb-request", request)` 直接发送文件路径、cache AVIF
   路径、源文件 identity 和已探测的媒体描述，不再为每次预览启动 `vimg send`
   子进程。
3. 服务完成后通过
   `ya pub-to <sender> gridthumb-avif-ready --json <payload>` 返回文件与 cache 路径；
   插件收到后触发 `peek`，命中当前 AVIF/manifest 后执行
   `ya.image_show(cache_avif)` 和 `ya.preview_widget`。
4. `vimg send` 保留为兼容/诊断命令，但内部也改为 `ya pub-to`，不再使用固定
   TCP 端口；`socket2` 直接依赖随之移除。
5. 服务启动 10 个 worker，调度状态用 `HashSet` 记录所有 active cache；active +
   queued 总数最多 10。相同 cache 的请求合并并收集所有订阅者；容量满且没有可
   淘汰的未启动任务时返回 busy，从结构上保证不会同时执行第 11 个文件。

依据 Yazi DDS 官方文档（https://yazi-rs.github.io/docs/dds/）和本机
Yazi/Ya 26.1.22 实测确认 `ya sub` 协议格式。验证结果：

| 验证项 | 结果 |
|---|---|
| `cargo check` | 通过 |
| `cargo test --features in-process-decode` | **56 passed / 3 ignored / 0 failed** |
| Lua DDS 契约（发布 request、订阅 ready、触发 peek） | 通过 |
| release 构建 | `cargo build --release --features in-process-decode` 通过 |
| 真实进程链路 | 隔离配置加载仓库 `gridthumb.yazi` → `ps.pub_to` → `ya sub` → 直接 `Vcs::run` → `ya pub-to` → 插件 ready 回调成功 |
| 服务实时状态 | 打印 subscribed、queued、worker processing、done；单任务实测 1.5–1.7s |
| 输出 | 86,080 bytes；SHA-256 `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2` |
| cache identity | AVIF 与 `<cache>.3210297211-1744354554.json` manifest 均生成 |

三条真实 DDS 路径（直接 `ya pub-to`、`vimg send` 兼容入口、仓库插件
`ps.pub_to`）均得到与性能基准逐字节相同的 AVIF。插件层验证使用隔离的
`YAZI_CONFIG_HOME` 和源视频硬链接，不修改用户现有 Yazi 配置；ready 事件已由
插件订阅，回调重新触发 `peek`。验证使用的临时 AVIF/manifest/config/硬链接均
已删除，测试 Yazi/serve/ya 进程已正常停止。

资源说明：单个固定 Preview job 的精确峰值 WS 约 553MB；10 是功能上的并发
上限而非推荐持续满载值，极端满载可能需要约 5.5GB 以上内存，部署时应结合
机器资源和 ADR-0001 的单 job 预算继续评估默认并发度。

## Windows 单次运行优化第四轮：剩余瓶颈与下一步（2026-08-01）

本轮只做诊断和候选方案筛选，没有把实验开关留在生产代码中。固定样本所有
有效 arm 的输出均校验 SHA-256；除明确写出的 0ms recovery arm 外，结果都是
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
当前机器有明显的后台负载波动，因此绝对 wall 不替换上一轮受控 ABBA 的
1.252s 基准；本轮决策以同一批次交错 arm 和 phase 分解为主。

### 当前关键路径分解

12 次 warm 诊断的中位数为 wall 1.48s、profile total 1.36s、decode 1.15s、
first_grid 0.97s、receive_wait 1.05s、join 0.033s、encoder_write 0.014s、
encoder_tail 0.19s。wall 与 profile total 约 0.12s 的差额主要是进程/DLL 启动
及 profile 边界外工作；对 Yazi 的常驻 `serve` 路径可避免重复启动，对真正的
一次性 CLI 则不能靠 capture 微优化消除。

一次逐 worker 计时进一步确定最慢 cap7：total 1.128s，其中 open 0.0245s、
seek 0.0207s、decoder setup 0.0078s、`send_packet` 0.8783s、receive/scale/copy
0.1534s、other 0.0437s。九个 worker 合计 decoded 566 帧、preroll 254 帧；
cap7 decoded 98 / preroll 64。**长预滚的软件 H.264 解码是剩余主瓶颈**，
而重复 open/probe、scale/copy、join、写盘各自只有几十毫秒量级的上限。

SVT 初始化也单独测量了 8 次：`EncoderState::new` 中位数 0.0432s（0.0340–
0.0511s）。capture worker 已在它之前启动，所以这 43ms 大部分已经与解码重叠；
把初始化移到 worker 的纯延迟上限很小，延迟到首个 grid 反而可能把它串到
关键路径上。它更适合作为 RSS 错峰实验，而不是首要提速方案。

### 已完成的窄范围反证

#### SVT `lp`：可用内存换 18–34ms，但不适合作为默认值

每 arm 6 次交错 warm，全部输出逐字节一致；RSS 用 Windows
`PeakWorkingSetSize` 精确读取（每 arm 2 次）：

| lp | wall p50 | encoder tail p50 | 峰值 WS |
|---:|---:|---:|---:|
| 1 | 1.4843s | 0.3410s | 524–536MB |
| **2（当前）** | **1.3292s** | **0.1635s** | **553–561MB** |
| 3 | 1.3107s | 0.1320s | 604–619MB |
| 4 | 1.2954s | 0.1430s | 665–674MB |

`lp=3` 相对当前只省约 18ms，却再增加约 50–65MB；`lp=4` 省约 34ms，增加
约 110MB。保留 `lp=2`。若将来提供明确的“latency-first/忽略内存预算”模式，
`lp=4` 可以成为可选项，但不应静默改变默认资源契约。

#### decoder threads：DT3 已处在拐点

只改变长预滚 worker 的线程数，每 arm 6 次交错 warm：

| 长预滚 DT | wall p50 | decode p50 | CPU time p50 | 结论 |
|---:|---:|---:|---:|---|
| 2 | 1.4901s | 1.1810s | 14.219s | 慢 |
| **3（当前）** | **1.3937s** | **1.1105s** | **14.148s** | 采用 |
| 4 | 1.3872s | 1.1010s | 15.117s | 仅约 6ms，CPU +约 1s |
| 5 | 1.5858s | 1.2450s | 15.555s | 明显变慢 |

随后又测试短窗口 DT1/DT2 与长窗口 DT3/DT4 的组合。当前 DT2/DT3 的 wall
p50 1.3617s；DT1/DT3、DT1/DT4、DT2/DT4 分别为 1.4771s、1.4169s、
1.4554s。DT4 的微弱单臂信号没有复现，短窗口降到 DT1 会产生新的 straggler，
因此不修改当前选择性 DT3。

#### recovery margin：缩短后的初始信号没有复现

第一组 6 次测试中 50ms 曾比当前 125ms 快约 43ms，故追加每 arm 12 次轮转
复测：

| `NONREF -> DEFAULT` 余量 | wall p50 | wall P95 | 输出 SHA |
|---:|---:|---:|---|
| **125ms（当前）** | **1.3870s** | **1.5062s** | 3f0fa2be… |
| 75ms | 1.4320s | 1.5149s | 3f0fa2be… |
| 50ms | 1.3966s | 1.6294s | 3f0fa2be… |

50/75ms 没有稳定收益，50ms 的 P95 反而更差，保留 125ms。0ms arm 虽略快，
但输出变为 `7a92c5c…`，直接违反权威输出约束。

#### P-core affinity：中位延迟无收益

全 24 logical CPU 与固定 0xFFFF P-core mask 各 8 次交错：wall p50
1.3118s vs 1.3240s，profile total 1.218s vs 1.220s，decode 均约 1.047–
1.048s；P-core mask 的 CPU time 从 13.719s 降至 12.672s，但没有降低单次
中位延迟。硬编码 affinity 不合入；只有 ETW 证明关键线程频繁迁到 E-core 时，
才值得用 Windows CPU Sets 做 P95/能效实验。

### 下一步优化优先级

详细原理、上游主来源和验收门槛记录在
[`docs/research/2026-08-01-next-single-run-optimization-options.md`](docs/research/2026-08-01-next-single-run-optimization-options.md)。
按当前 phase 上限重新排序：

1. **原生 FFmpeg H.264/HEVC decoder + 共享 D3D11VA/NVDEC context 探针。**
   旧负结果是独立 `h264_cuvid` 路径；原生 decoder 会在 hardware callback 前
   执行 `skip_frame`，可能同时保留 nonref preroll 跳过与硬解。先只做回调/
   surface/transfer 计数探针；若 P95 不能改善至少 8%，不集成。
2. **三级 preroll discard：`BIDIR -> NONREF -> DEFAULT`。** 固定样本的长 GOP
   含 reference-B，早期 `BIDIR` 理论上可再少解最多约 127 个 preroll frame，
   是纯 CPU 路径最大的剩余上限；但恢复 reference-B 链风险高，必须用 270 个
   source PTS、30 个 raw grid hash 和多 codec/GOP corpus 晋级。
3. **低风险小项：跳过重复 `avformat_find_stream_info`、direct libswscale。**
   当前关键 worker open+seek 约 45ms，其中可省的重复 stream-info 约 20–25ms
   上限；receive/scale/copy 总共约 153ms，direct swscale 的实际可省部分预计仅
   10–40ms。两者都应先加细分计时，再做 Matroska-only/逐帧 hash 探针。
4. **encoder 初始化/RSS 错峰。** setup 实测只有约 43ms且已与 capture 重叠；
   只在目标是把 553MB 拉回 512MB 或为 `lp=3` 腾空间时继续，不预期显著降低
   wall。
5. **允许新码流时升级 SVT-AV1 4.2.0。** 上游包含短任务相关的 worker 与分配
   优化，并可测试 `startup-mg-size`；但版本/GOP 会改变 AV1 bitstream，必须建
   新 cache generation，不能作为当前 byte-identical 默认优化。

结论：现状下继续调线程、affinity、`lp` 或 recovery margin 已进入噪声/内存
换微秒区。若目标仍是单次再降 0.1s 以上，应优先验证“原生 parser + hwaccel”
和三级 discard；若不接受高复杂度或新码流，现实可期待的剩余空间约为若干个
10–40ms 小项，而不是再次获得上一轮 20–30% 的降幅。

## 原型验证：原生 parser + hwaccel 与三级 discard（2026-08-01，RTX 3090 + gyan FFmpeg 8.1.2 shared）

按上一轮结论对两项 P0 候选做独立原型验证。原型层以 `VIMG_PROTO_*` 环境变量
临时加在 `libav.rs`，验证完成后已从源码还原；脚本与全部运行产物保留在
`.scratch/proto/`（`sweep.sh`、各 config 的 stdout/日志/dump）。固定样本所有
输出均做三重 gate：270 个 source PTS、270 张 raw RGB dump 逐字节 hash、
最终 AVIF SHA-256 `3f0fa2be…`。本机仍有后台负载波动，绝对 wall 只与同批次
交错测量对比。

### 三级 discard（BIDIR → NONREF → DEFAULT）：否决

按建议做二维 sweep：BIDIR 恢复区 {0.25, 0.375, 0.5}s × 最终 margin
{0.125, 0.25, 0.5}s，共 9 个 config，全部通过 PTS gate（270/270 一致）但
**RGB 与 AVIF SHA 全部不一致**。错误 SHA 由较晚的转换点决定（margin 大于
BIDIR 区时两级转换合并，行为等价于更晚的 BIDIR 区）；把 BIDIR 区放大到
0.75/1.0/1.5/2.0s 仍然失败。不是恢复区不够，而是
**`AVDISCARD_BIDIR` 在这条流的稳态 mini-GOP（P、reference-B、B×4）上会永久
破坏 DPB**：一旦跳过 reference-B，后续 P 帧就对着错误参考重建。

用官方 CLI 独立复现（与原型实现无关）：`ffmpeg -skip_frame bidir` 从 0 帧
稳态解码 186s，在 183.08s 窗口内输出的 4/4 个 P 帧（pts 4398/4404/4410/
4424）与完整解码逐帧 md5 不一致；`-threads 1` 同样复现，说明与帧线程无关；
文件前 2s 干净（起始 GOP 结构不同），所以是“稳态 mini-GOP 含 reference-B”
本身触发。文档中“BIDIR 只用于早期长 preroll、维护 I/P 链”的假设被这条流
证伪：跳过 reference-B 的代价是 I/P 链本身损坏。

允许输出改变时（仅作上限数据）：bidir_0.375 与当前两级的同批次交错
median 1.658s vs 1.793s，约 -7.5%（实测少解约 107/566 帧，理论估计约
127 帧），但输出不是权威 SHA，不可用。结论：三级 discard 在 FFmpeg
8.1.2 原生 h264 上对含 reference-B 的样本无条件失败，整条路线关闭。

### 原生 parser + 共享 hwaccel（D3D11VA / CUDA）：功能全通，性能为负，不推广

新探针按研究文档实现：`avcodec_find_decoder(H264)` 原生 decoder + 每 worker
持有共享 `hw_device_ctx` 的 `av_buffer_ref` + `get_format` 强制硬件格式
（拒绝静默软件回退），preroll 帧不下载，仅对需要缩放的帧做
`av_hwframe_transfer_data`，计数探针记录 demux packet、NAL、hardware
decoded、transfer。**两个后端都完整通过三重 gate**：270 PTS、270 raw RGB、
AVIF SHA `3f0fa2be…` 全部逐字节一致，且 capture 选择的就是进程内 libav
backend（无 fallback）。这同时证明 NV12→bicubic RGB 与 yuv420p→bicubic RGB
的 swscale 输出逐字节相同，以及 GPU 解码像素与软件解码逐字节相同。

**parser-skip 先于硬件的证据**（研究文档的关键假设，已证实）：cap7 在
discard=none 下 hardware decoded=227，两级 NONREF 下=98，即 129 帧在进入
NVDEC 前就被原生 parser 跳过；计数与软件路径完全一致（sw none=227、
sw two=98），且 send 耗时随 decoded 数缩放（none 1.56s vs two 0.88s），
说明跳过发生在硬件回调之前。transfer 每 worker 仅 33–34 次（offset 后的
帧），preroll surface 全部留在 GPU。

探针中排除的实现坑（均已解决，记录供后续参考）：(1) hwaccel + 帧线程可
打开但解码损坏（"Missing reference picture"、"mmco: unref short failure"），
必须 threads=1；(2) ffmpeg-next 的 `Video::clone` 是 `av_frame_copy` +
`copy_props`，对硬件帧会复制纹理句柄字节且丢失 `hw_frames_ctx`，必须用
`av_frame_ref`；(3) D3D11VA 的 `av_hwframe_transfer_data` 要求 dst 已按
hw frames ctx 的 sw_format 预分配（否则 EINVAL），CUDA 会自己分配；(4)
D3D11VA surface 高度 16 对齐（1080→1088），dst 按编码尺寸分配即可在传输
时裁掉 padding。

性能（同批次交错 warm，输出均校验为权威 SHA）：

| 路径 | wall median | 相对当前 | 峰值 WS | 峰值 commit |
|---|---:|---:|---:|---:|
| 当前软件（dt 2/3） | 1.711s | — | 563.6MB | 701.4MB |
| cuda dt1 | 1.784s | +4.2% | 616.4MB | 1520.1MB |
| d3d11va dt1 | 1.990s | +16.3% | 588.8MB | 785.6MB |

两个硬件后端都达不到“P95 至少快 8%”的推广门槛。原因明确：硬件只加速重建，
h264 的解析/提交路径（每 worker 约 0.6–0.9s）仍是 CPU 主导且不随后端变快；
hwaccel 又强制单线程，失去当前 DT2/DT3 的 CPU 并行；每帧 PCIe 下载再增加
约 0.06–0.13s/worker。CUDA 的 1520MB peak commit 也直接违反 512MB 内存
契约方向。结论：原生 parser + hwaccel 功能上完全成立（可随时作为独立
cache generation 的非 byte-identical 轨道），但对当前固定命令没有性能价值，
默认路径不采用。

### 本轮收敛

两项 P0 均已用原型闭合：三级 discard 因 FFmpeg 的 BIDIR skip 本身损坏
reference-B 流而不可用；hwaccel 因强制单线程且提交路径仍占 CPU 而比软件
更慢。剩余可期待的真实空间回到研究文档的 P1 小项（跳过重复 stream-info
probe 约 20–25ms、direct swscale 约 10–40ms），以及接受新码流的独立轨道
（SVT 4.2.0 / startup mini-GOP）。若未来换更快的提交路径（如 D3D12VA、
多 decoder context 分片）或接受非 byte-identical 输出，hwaccel 的探针
代码与 .scratch/proto 证据可直接复用。

## hwaccel-dt 分支：D3D12VA 与多 decoder context 分片验证（2026-08-02）

承接上一轮"hwaccel 强制单线程"的瓶颈，在 `hwaccel-dt` 分支验证两个候选
解决方向。原型层与上轮相同的 `VIMG_PROTO_*` 门控（新增 d3d12va 后端与
`VIMG_PROTO_THREAD_KIND=frame|slice|none` 线程类型控制），三重 gate 不变
（270 PTS、270 raw RGB、AVIF SHA `3f0fa2be…`）。

### D3D12VA：正确但最慢，且同样不支持帧线程

| 后端 | 单线程 | slice 线程 | 帧线程 |
|---|---:|---:|---:|
| cuda | 正确，cap7 send 0.92s | 正确，1.06s（不加速） | **损坏**（Missing reference/mmco） |
| d3d11va | 正确，cap7 send 1.21s | 正确，1.26s（不加速） | **损坏** |
| d3d12va | 正确，cap7 send 1.38s | 正确，1.60s（不加速） | **损坏** |

- 三种后端的帧线程全部损坏（与上轮结论一致：hwaccel + `FF_THREAD_FRAME`
  在 FFmpeg 8.1.2 下打开成功但 DPB 参考链断裂，decoded 只剩 2–4 帧，
  SHA 均为 `931fce70…`）。
- slice 线程全部正确（这是新结论：slice threading 不触发损坏），但
  hwaccel 下 slice 线程不真正并行 MB 解码（MB 重建在 GPU），send 反而
  增加约 0.1–0.2s 开销。
- D3D12VA 单线程是三者中最慢的（cap7 send 1.38s vs cuda 0.92s），
  transfer 也不占优。D3D12VA 出局。

### 多 decoder context 分片：样本 GOP 太长，并行度 ≈ 1

按 IDR 分片的前提是单窗口内存在多个可并行的 GOP。对固定样本 9 个窗口
逐一检查（ffmpeg `select='eq(pict_type,I)'` 解码计数）：稳态 IDR 间隔约
**8–12s**（全片 272 个 IDR / 3295s），而单窗口跨度（预滚 2.7s + 窗口
1.5s + reorder）约 4.2s——绝大多数窗口的预滚+窗口完整落在 **1 个 GOP
内**，按 IDR 切分只有 1 段，无并行度。唯一例外是 cap4（1640s 附近有
1640.06/1642.85/1646.27/1647.98 一串 IDR），但其预滚只有 12 帧，本来
就不需要分片。非 IDR 处切分会破坏 H.264 参考链，不可行。

### 结论

两个候选方向均验证为不可行：D3D12VA 不解决单线程（更慢且帧线程同样
损坏）；GOP 分片在本样本上无并行度。hwaccel 单线程的 CPU 解析/提交路径
（cap7 约 0.9s）是 FFmpeg 8.1.2 hwaccel 架构的硬成本，与后端选择无关。
Windows 固定命令维持软件路径（cap7 1.09s，wall 1.25s 量级），硬件解码
仅作为未来接受非 byte-identical 输出时的独立轨道候选。原型层代码保留在
`hwaccel-dt` 分支（libav.rs 的 `VIMG_PROTO_*` 探针），主分支不受影响。
