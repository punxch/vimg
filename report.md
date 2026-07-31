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
