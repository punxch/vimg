# mtn 实现对动画 VCS 性能的适用性调研

调研日期：2026-07-30  
上游版本：`movie_thumbnailer/mtn` commit [`4e1ec98d`](https://gitlab.com/movie_thumbnailer/mtn/-/commit/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7)  
目标负载：`vimg vcs -c3 -H160 -n9 sample/input.mkv --output output.avif`，即 9 个采样点、每点 1.5 秒内取 30 帧，合成为 30 个 852×480 网格帧并编码为动画 AVIF。

## 结论

**mtn 的整体实现不适合替换当前动画 VCS 管线，预计不会改善端到端墙钟时间。** 它针对的是“每个时间点取一张静态图，最后保存一张静态网格”：单个 demux/decoder 上下文串行执行 9 次 seek，每次只解出一张图，所有图完成后才保存网格。当前 vimg 则让 9 个采样点并行解码各自连续的 30 帧，并通过有界 lockstep 流与 AVIF 编码重叠。把 mtn 的串行模型扩展到本负载会把九路解码放回关键路径，且 mtn 没有动画输出、硬件解码或跨阶段流水线。

mtn 只有两个值得单独做微型基准的细节；两项原型以及后续与 VideoToolbox 的组合验证已经完成：

1. **仅在 seek 后的预滚阶段使用 `AVDISCARD_NONREF`，接近采样起点前恢复完整解码。** 0.5 秒恢复余量的六组配对测量把进程内 libav 原型平均墙钟从 1.208s 降至 0.928s，约 23.2%；用户态 CPU 从 8.525s 降至 5.782s，约 32.2%。全部 270 个原始 tile 与基线逐字节一致。这一结果足以把该方向提升为下一轮跨媒体语料验证的首选。
2. **将缩放从 bicubic 改为 bilinear，作为显式的速度/质量选项。** 同一二进制的热态配对结果仅快约 2.6%，未达到 3% 阈值；输出 SSIM 为 0.9951，并非等价画面，因此否决默认替换。
3. **将 0.5 秒 nonref 预滚与 VideoToolbox 组合。** 相对已经低于 1 秒的进程内软件 nonref 基线，六组交错测量把实际墙钟从 0.932s 进一步降至 0.743s，约 20.2%；用户态 CPU 从 5.798s 降至 1.073s，约 81.5%。270 个原始 tile、源 PTS 和最终 AVIF 均逐字节一致。

不建议原型化 mtn 的单上下文串行 seek、GD 像素拷贝或静态 AVIF 保存路径。当前 macOS 上同时优化墙钟、CPU 和功耗的首选候选是 **VideoToolbox + 0.5 秒 nonref 预滚**；跨平台软件候选仍是进程内 libav + nonref。软件路径已经通过 11 个 H.264/H.265、GOP/B-frame、VFR、短片和文件尾部样本的逐帧等价验证；硬件组合目前只在目标样本上严格验证，产品化前仍需复跑同一跨媒体语料。

## 1. mtn 的实际数据流

### 1.1 一次打开、一次探测、一个解码器

mtn 对每个输入文件只调用一次 `avformat_open_input` 和 `avformat_find_stream_info`，选择视频流后创建一个 `AVCodecContext`，再调用 `avcodec_open2`。它不是 FFmpeg CLI 子进程封装，而是直接链接 libavformat/libavcodec/libswscale；README 也列出了这些开发库依赖。[mtn README](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/README.md#L4-15) [输入与解码器初始化](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L2687-2758)

它还会在任何 seek 之前额外解码第一帧，用于兼容某些旧格式并确认尺寸。[首次解码](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L2863-2878)

这能避免九次独立 open/probe，但该节省已经被本项目的“九路进程内 libavformat/libavcodec”原型部分覆盖：热态端到端平均只从 1.232s 降至 1.198s，约 2.8%，详见[现有原型结论](issues/01-implement-preview-service-performance.md)。mtn 更进一步只保留一个上下文，代价是采样点之间失去并行性。

### 1.2 逐点串行 seek，不是并行提取

mtn 在一个普通 `for` 循环中递增目标时间。每个采样点调用 `really_seek`，seek 成功后 `avcodec_flush_buffers`，然后读取视频包直到解出一帧；如果 seek 偏差过大，它可能退化为从头连续解码到各目标点。[串行采样循环](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L3142-3255) [seek 回退策略](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L2205-2252)

`really_seek` 的回退顺序是：

1. 普通 `av_seek_frame`；
2. 加 `AVSEEK_FLAG_ANY`，允许定位到非关键帧；
3. 按文件大小和总时长估算字节位置，再用 `AVSEEK_FLAG_BYTE`。

FFmpeg 官方定义 `AVSEEK_FLAG_ANY` 为“可 seek 到非关键帧”，`AVSEEK_FLAG_BYTE` 为“按字节位置 seek”；seek 后调用 `avcodec_flush_buffers` 是官方建议的状态重置方式。[FFmpeg seek flags](https://www.ffmpeg.org/doxygen/4.0/avformat_8h.html#l02480) [FFmpeg `avcodec_flush_buffers`](https://ffmpeg.org/doxygen/7.1/group__lavc__misc.html)

mtn 自己的文档承认：seek 模式较快，但时间步很小或短片段时不准确；此时非 seek 模式更准确但更慢。[mtn changelog](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/changelog.txt#L76-92)

### 1.3 每个目标只保留一帧

`video_decode_next_frame` 串行调用 `av_read_frame`，跳过非视频包，把包送入 `avcodec_send_packet`，收到一张解码帧便返回。它没有为一个采样点继续产出 30 帧，也没有 producer/consumer channel。[读包与单帧解码](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L1947-2113)

FFmpeg 官方说明 `av_read_frame` 每次返回下一个 demux packet；因此 mtn 的循环是在同一个 format context 上向前读，采样点之间靠 seek 改变位置。[FFmpeg demuxing API](https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html)

### 1.4 缩放、RGB 转换和网格组成

mtn 创建一个可复用的 `SwsContext`，把命中的解码帧用 `SWS_BILINEAR` 缩放并转换为 RGB24。[缩放上下文](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L3048-3084) [逐帧 `sws_scale`](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L3316-3323)

随后它逐像素调用 `gdImageSetPixel`/`gdImageColorResolve`，把 RGB AVFrame 转为 GD 图像；再用 `gdImageCopy` 把 tile 放进完整网格。时间戳也绘制在每个临时 tile 上。[逐像素 RGB→GD](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L939-952) [网格 copy](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L1215-1233) [标签与入网格](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L3369-3445)

这一逐像素 GD 转换对仅 9 张静态 tile 尚可，但若扩展到 270 张 tile，会增加不必要的函数调用和颜色解析；vimg 当前直接持有连续 RGB buffer，更适合动画数据流。

### 1.5 输出是单张图片，不是动画编码管线

mtn 等所有 tile 完成后才调用一次 `save_image`。`.avif` 分支只是把最终 GD image 交给 `gdImageAvif`，源码没有动画帧循环、AVIF muxer 或 encoder producer。[保存单张网格](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L3466-3521) [静态图片格式分派](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c#L886-929)

因此 `mtn -c3 -r3` 与本项目命令只在“9 个时间点”这一层相似；前者输出 1 个网格帧，后者输出 30 个网格帧。不能用 mtn 的静态运行时间直接推断动画 VCS 性能。

## 2. 并发、硬件和 I/O

### 并发

mtn 的采样循环没有外层线程池或每采样点 worker；仓库的 TODO 仍把“use multiple threads”列为未来计划。[mtn TODO](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/doc/todo.txt#L15-20)

它没有显式设置 `AVCodecContext.thread_count`，因此只可能获得所选 decoder 的 libavcodec 默认内部并行，不能并发执行九个 seek。FFmpeg 文档说明 frame threading 会引入每线程一帧的解码延迟；这也解释了为什么本项目短 clip 原型中盲目增加每路 codec worker 没有持续收益。[FFmpeg `AVCodecContext` threading](https://ffmpeg.org/doxygen/trunk/structAVCodecContext.html)

当前 vimg 已经为 9 个采样点各启动一个 worker，并用 frame barrier 让第 N 个动画网格的九张 tile 同步到达；channel 总容量为每路两帧。[当前 `stream_pipe`](../../src/command/extract.rs#L230-L310) [当前 worker/FFmpeg 命令](../../src/command/extract.rs#L351-L447)

### 硬件解码

在本次审查的 `mtn.c` 中，解码器通过通用 `avcodec_find_decoder`/`avcodec_open2` 打开，没有 `AVHWDeviceContext`、hardware pixel format negotiation、VideoToolbox、VAAPI、CUDA 或硬件帧下载路径。[mtn 完整核心源码](https://gitlab.com/movie_thumbnailer/mtn/-/blob/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7/src/mtn.c)

因此 mtn 不包含比已验证 VideoToolbox 原型更好的 CPU 优化。现有测量中 VideoToolbox 已把用户态 CPU 从约 8.85–9.09s 降到约 1.09–1.25s；mtn 仍是软件解码，详见[现有原型结论](issues/01-implement-preview-service-performance.md)。

### I/O 与生命周期

mtn 的优势是单进程、单次 open/probe、没有 rawvideo 子进程 pipe；但它没有把解码、网格组成和编码重叠。当前 vimg 的九路子进程确有重复 open/probe 和 pipe 成本，但它们并行工作，且第一张完整网格一到就开始向 SVT-AV1 编码器写入。此前进程内 libavformat/libavcodec 原型已表明，移除子进程和 pipe 只带来约 2.8% 热态平均墙钟收益，并伴随更高 RSS；mtn 没有新的 I/O 技巧可改变该结论。

## 3. 可借鉴点逐项判断

| mtn 技巧 | 对静态网格的作用 | 对 9×30 动画 VCS 的判断 |
|---|---|---|
| 单次 open/probe、复用一个 demux/decoder | 减少初始化和上下文内存 | 不建议照搬。九个采样区间将串行进入关键路径；只可能降低部分 CPU/RSS，不利于低于 1 秒的墙钟目标 |
| 每个目标 `av_seek_frame` + flush | 快速跳到稀疏静态帧 | 当前 FFmpeg `-ss` 路径已采用同类输入 seek；不是新增方向 |
| seek 失败后 `ANY`/byte fallback | 提升古怪容器的兼容性 | 可用于健壮性，但不是常见 MKV/H.264 的性能优化；byte seek 还是按时长/大小估算 |
| `skip_frame=AVDISCARD_NONREF` | 稀疏截图时少解非参考帧 | 不能全程使用。FFmpeg 定义它会丢弃全部非参考帧，动画会缺帧并依赖 CFR 复制；仅可研究“预滚时开启、起点前关闭” |
| `SWS_BILINEAR` | 比更高质量 scaler 更偏速度 | 值得作为可选质量档做 A/B；当前要求是 bicubic，直接替换不等价 |
| 复用一个 `SwsContext`/RGB buffer | 避免每张静态图重新分配 scaler | 当前每个持续 worker 本身已复用 FFmpeg filter context；进程内原型也能复用，不是 mtn 独有收益 |
| 一次只保留一个 tile + 完整静态网格 | 静态输出内存小 | 当前 vimg 已用每路容量 2 的有界流，且必须同步九张 tile；没有可观的新节省 |
| GD 逐像素 RGB 转换和 `gdImageCopy` | 实现简单 | 对 270 tile 是退步；不应移植 |
| `gdImageAvif` 保存最终网格 | 可输出静态 AVIF | 不支持 30 帧动画，不能替代当前 SVT-AV1 管线 |

FFmpeg 对 `AVDISCARD_NONREF` 的定义就是“discard all non-reference frames”；这不是保持所有展示帧、只跳过无用计算的无损开关。[FFmpeg `AVDiscard`](https://ffmpeg.org/doxygen/7.0/group__lavc__decoding.html)  
FFmpeg 将 bilinear 与 bicubic 定义为不同的 scaler 算法，当前文档默认是 bicubic，因此改用 bilinear 应当被视为显式质量策略，而非内部等价重构。[FFmpeg scaler documentation](https://www.ffmpeg.org/ffmpeg-scaler.html)

## 4. 原型后的优先级

### 继续推进

1. **将进程内 libav + nonref 预滚产品化为可选后端。** 先保持 0.5 秒恢复余量，运行时遇到不支持的 codec、无时间戳、seek/解码失败或输出校验失败时回退现有 FFmpeg 子进程路径。
2. **保留逐帧等价回归。** 将代表性的 H.264/H.265、VFR、短片和单关键帧尾部样本缩减为可维护的测试夹具，比较选中 PTS、补帧数和原始 tile，而不只检查最终文件能否打开。

### 不建议

1. **不要把 bilinear 设为默认。** 热态配对收益低于 3% 阈值，且画面发生变化。
2. **不要实现 mtn 式单上下文串行采样。** 它更可能减少总 CPU 和内存，而不是减少端到端墙钟；与当前“优先运行效率、冲击 1 秒”的目标不一致。
3. **不要移植 GD 合成或静态 AVIF 保存路径。** 前者引入逐像素转换，后者不能表达 30 帧动画。
4. **继续保留 VideoToolbox 为主要 CPU 方向。** mtn 没有硬解机制；预滚优化降低约 32% 用户态 CPU，仍不及 VideoToolbox 的约 86%。

## 5. 证据边界

本调研是源码架构比较，不是 mtn 与 vimg 的直接计时对比。mtn 当前不支持目标动画输出，因而不存在保持相同 9×30 帧、852×480、动画 AVIF 语义的公平命令行基准。若只测 mtn 的 3×3 静态 JPG/AVIF，结果主要回答“生成一张静态 contact sheet 多快”，不能回答本项目的动画 VCS 问题。

本地样本经 `ffprobe` 读得 H.264、1920×1080、24000/1001 fps、总时长 3295.446s；这些数据只用于确认目标负载特征，没有据此宣称 mtn 的实测速度。可复现命令：

```sh
ffprobe -v error -select_streams v:0 \
  -show_entries stream=codec_name,width,height,avg_frame_rate,r_frame_rate \
  -show_entries format=duration -of json ./sample/input.mkv
```

## 6. 两项原型结果

### 6.1 Bilinear 缩放

原型在同一 release 二进制中通过 `VIMG_PROTOTYPE_SCALE_FLAGS=bicubic|bilinear` 切换 scaler，避免重新编译影响配对结果。书签为 `prototype-mtn-bilinear`，提交 `cefff0a8`。

六组交错配对中，排除第一组动态装载后：

| 指标 | Bicubic | Bilinear | 变化 |
|---|---:|---:|---:|
| profile total 平均 | 1.255s | 1.223s | -2.6% |
| profile total 中位数 | 1.257s | 1.229s | -2.2% |
| 用户态 CPU 平均 | 8.932s | 8.672s | -2.9% |

两边都输出 852×480、20fps、30 帧。编码后画面 SSIM 为 0.9951，说明差异可见于像素层；收益未达到预设 3% 阈值。结论：**关闭默认替换方向**，只有未来明确提供“快速/较低缩放质量”选项时才考虑复用。

### 6.2 预滚阶段 `AVDISCARD_NONREF`

原型基于九路进程内 libavcodec 解码器：seek 后先设置 `AVDISCARD_NONREF`，当 packet DTS/PTS 到达采样起点前 0.5 秒时恢复 `AVDISCARD_DEFAULT`，不 flush 已建立的参考帧状态。书签为 `prototype-mtn-preroll-nonref`，提交 `982bae84`。

六组交错配对结果：

| 指标 | 完整预滚基线 | Nonref 预滚 | 变化 |
|---|---:|---:|---:|
| 实际墙钟平均 | 1.208s | 0.928s | -23.2% |
| profile total 平均 | 1.195s | 0.916s | -23.3% |
| 首个完整网格平均 | 0.815s | 0.553s | -32.1% |
| 用户态 CPU 平均 | 8.525s | 5.782s | -32.2% |
| 峰值 RSS 平均 | 453.3MB | 449.7MB | -0.8% |

六次 nonref 墙钟均为 0.91–0.97s；每次都完成 9 次恢复正常解码，补帧数为 0。

验证运行在 encoder 前按“30 个动画时刻 × 9 个采样点”的顺序写出全部 270 个 RGB tile：

- 基线与 0.5 秒余量都是 36,806,400 字节；
- 两者 SHA-256 都是 `88d9b4594cfe86f9aa7e6c34ce88009f0e3714016b5f04c7dcb4fa221650fa64`；
- 两个动画 AVIF 也逐字节相同，SHA-256 都是 `1646e7f4e42f2261f785dc5e6d466dcac85b326f7ed96a7a06ae15c649973985`。

余量扫描中，0.25 秒和 0.125 秒仍与基线逐字节一致；0 秒已经不同，编码后 SSIM 降至 0.9966。这确认“目标前恢复完整解码”是正确性条件，不应为了样本内的少量收益把余量压到 0。当前结论：**保留 0.5 秒作为产品化候选；跨语料结果见下一节。**

### 6.3 跨 codec/GOP/VFR/短片验证

可复现脚本保存在 Jujutsu bookmark `prototype-mtn-preroll-corpus`，提交 `3eb3ea8f`。单命令运行：

```sh
bash src/bin/prototype_preroll_corpus.sh ./sample/input.mkv
```

脚本从真实输入截取并转码小型语料，随后对每个样本分别运行完整预滚和 0.5 秒 nonref 预滚。每次都比较：

- encoder 前按顺序写出的 270 个 RGB tile；
- 270 条“动画帧索引、采样点索引、源 PTS”记录；
- 最终动画 AVIF 的完整字节；
- 9 路恢复完整解码次数、补帧数和动画流帧数。

完整复现结果：

| 样本 | 特征 | 完整预滚 | Nonref 预滚 | 正确性 |
|---|---|---:|---:|---|
| original | 真实 1080p H.264 MKV | 1.246s | 0.886s | 全部一致 |
| h264-longgop-b3 | GOP 240、B-frame | 0.271s | 0.297s | 全部一致 |
| h264-shortgop-nob | GOP 12、无 B-frame | 0.236s | 0.196s | 全部一致 |
| h264-vfr-b3 | VFR、B-frame | 0.261s | 0.235s | 全部一致 |
| h264-short-b3 | 1.627s 短片 | 0.213s | 0.213s | 全部一致 |
| h264-tail-g360-b8 | 单关键帧、GOP 360、8 B-frame | 0.258s | 0.254s | 全部一致 |
| hevc-longgop-b4 | GOP 240、B-frame | 0.271s | 0.238s | 全部一致 |
| hevc-shortgop-nob | GOP 12、无 B-frame | 0.197s | 0.195s | 全部一致 |
| hevc-vfr-b4 | VFR、B-frame | 0.247s | 0.220s | 全部一致 |
| hevc-short-b4 | 1.627s 短片 | 0.213s | 0.213s | 全部一致 |
| hevc-tail-g360-b8 | 单关键帧、GOP 360、8 B-frame | 0.266s | 0.227s | 全部一致 |

11 个样本全部满足：raw tile、选中 PTS 和 AVIF 逐字节一致，PTS 记录为 270 条，动画流为 30 帧，9 路都完成恢复完整解码且补帧数为 0。VFR 样本实际包含约 41/42ms 与 83/84ms 两组相邻 PTS 间隔；尾部样本在整个 12 秒文件内只有一个关键帧。

小型 640×360 样本只有一次计时且常由 AVIF encoder tail 主导，不能据此评价几个百分点的性能差异；它们只用于正确性覆盖。真实样本仍从 1.246s 降到 0.886s。结论：**0.5 秒策略通过本轮预定语料门槛，可进入带回退的可选软件后端实现。**

### 6.4 VideoToolbox 与 Nonref 预滚组合

在 `prototype-videotoolbox` 上加入与软件原型相同的 0.5 秒策略：seek 后设置 `AVDISCARD_NONREF`，当 packet DTS/PTS 到达采样起点前 0.5 秒时恢复 `AVDISCARD_DEFAULT`，不 flush 参考帧状态。VideoToolbox 只替换 H.264/H.265 解码；容器仍由 libavformat 读取，缩放/RGB 转换仍使用 libswscale，最终动画 AVIF 仍由 `libsvtav1` 编码。原型保存在 Jujutsu bookmark `prototype-videotoolbox-nonref`，提交 `210fcda9`。

同一 release 构建的三种路径以轮换顺序交错运行六次：

| 指标 | 软件 Nonref | VideoToolbox 完整预滚 | VideoToolbox Nonref | VT Nonref 相对软件 |
|---|---:|---:|---:|---:|
| 实际墙钟平均 | 0.932s | 1.158s | 0.743s | -20.2% |
| profile total 平均 | 0.916s | 1.147s | 0.735s | -19.8% |
| 首个完整网格平均 | 0.549s | 0.832s | 0.417s | -24.1% |
| 用户态 CPU 平均 | 5.798s | 1.182s | 1.073s | -81.5% |
| 峰值 RSS 平均 | 450.1MB | 359.0MB | 376.3MB | -16.4% |

六次 VideoToolbox nonref 墙钟均为 0.74–0.75s。与 VideoToolbox 完整预滚相比，组合策略将墙钟降低 35.8%、首个完整网格降低 49.9%；解码帧数从 1092 降至 632，预滚帧数从 822 降至 362，最终下载到系统内存的硬件帧仍为 270，软件回退为 0。说明 VideoToolbox 本身主要节省 CPU，稳定低于 1 秒依赖 nonref 预滚减少送入硬件解码器的无用帧。

严格等价验证以进程内软件 nonref 作为当前方案基线：

- 两种 VideoToolbox 模式和软件 nonref 均输出 270 条相同的源 PTS；
- 三者的 36,806,400 字节 RGB tile 流逐字节相同，SHA-256 均为 `88d9b4594cfe86f9aa7e6c34ce88009f0e3714016b5f04c7dcb4fa221650fa64`；
- 三者的最终动画 AVIF 逐字节相同，SHA-256 均为 `1646e7f4e42f2261f785dc5e6d466dcac85b326f7ed96a7a06ae15c649973985`。

另做了六组正式 FFmpeg 子进程路径与组合原型的交错运行，作为部署层面的参考：

| 指标 | 正式 FFmpeg 路径 | VT Nonref 原型 | 变化 |
|---|---:|---:|---:|
| 实际墙钟平均 | 1.207s | 0.747s | -38.1% |
| profile total 平均 | 1.209s | 0.735s | -39.2% |
| 首个完整网格平均 | 0.913s | 0.418s | -54.3% |
| 用户态 CPU 平均 | 8.927s | 1.047s | -88.3% |
| 峰值 RSS 平均 | 297.8MB | 366.7MB | +23.1% |

这组正式路径对照不能当作严格的“只替换 decoder”收益：两边虽都输出 852×480、20fps、1.5 秒、30 帧动画，但正式 FFmpeg CLI 的 CFR 取帧与原型的显式 PTS 选择并非逐像素等价，动画 SSIM 为 0.9685。可用于评估实际耗时和资源量级的可靠基线，是逐字节等价的“软件 nonref → VideoToolbox nonref”对照，即约 20% 墙钟收益和 81.5% 用户态 CPU 降幅。

当前建议：先把组合方案作为 macOS 可选后端候选，保留 0.5 秒恢复余量；运行时按 **VideoToolbox nonref → 软件 libav nonref → 现有 FFmpeg 子进程** 回退。合入前必须把 6.3 的 11 个样本在硬件组合上复跑，并验证不支持的 codec、无时间戳、硬件设备创建失败、硬件帧传输失败和解码输出异常都能可靠回退。
