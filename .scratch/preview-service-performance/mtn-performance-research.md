# mtn 实现对动画 VCS 性能的适用性调研

调研日期：2026-07-30  
上游版本：`movie_thumbnailer/mtn` commit [`4e1ec98d`](https://gitlab.com/movie_thumbnailer/mtn/-/commit/4e1ec98d315f24708b5d18e24fca7b2a537d7cd7)  
目标负载：`vimg vcs -c3 -H160 -n9 sample/input.mkv --output output.avif`，即 9 个采样点、每点 1.5 秒内取 30 帧，合成为 30 个 852×480 网格帧并编码为动画 AVIF。

## 结论

**mtn 的整体实现不适合替换当前动画 VCS 管线，预计不会改善端到端墙钟时间。** 它针对的是“每个时间点取一张静态图，最后保存一张静态网格”：单个 demux/decoder 上下文串行执行 9 次 seek，每次只解出一张图，所有图完成后才保存网格。当前 vimg 则让 9 个采样点并行解码各自连续的 30 帧，并通过有界 lockstep 流与 AVIF 编码重叠。把 mtn 的串行模型扩展到本负载会把九路解码放回关键路径，且 mtn 没有动画输出、硬件解码或跨阶段流水线。

mtn 只有两个值得单独做微型基准的细节；两项原型已经完成：

1. **仅在 seek 后的预滚阶段使用 `AVDISCARD_NONREF`，接近采样起点前恢复完整解码。** 0.5 秒恢复余量的六组配对测量把进程内 libav 原型平均墙钟从 1.208s 降至 0.928s，约 23.2%；用户态 CPU 从 8.525s 降至 5.782s，约 32.2%。全部 270 个原始 tile 与基线逐字节一致。这一结果足以把该方向提升为下一轮跨媒体语料验证的首选。
2. **将缩放从 bicubic 改为 bilinear，作为显式的速度/质量选项。** 同一二进制的热态配对结果仅快约 2.6%，未达到 3% 阈值；输出 SSIM 为 0.9951，并非等价画面，因此否决默认替换。

不建议原型化 mtn 的单上下文串行 seek、GD 像素拷贝或静态 AVIF 保存路径。若主要目标是 CPU/功耗，进程内 VideoToolbox 仍最有效；若主要目标是单次墙钟，`AVDISCARD_NONREF` 预滚原型已经在当前样本上稳定进入 1 秒以内，但尚需跨 codec、GOP、B-frame 和 VFR 语料验证后才能进入正式路径。

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

1. **跨语料验证软件解码预滚丢非参考帧。** 保持 0.5 秒保守恢复余量，覆盖 H.264/H.265、不同 GOP/B-frame、VFR、短片和临近文件尾部的采样点；逐个比较 270 个原始 tile、选中 PTS 和补帧数。
2. **验证通过后重新评估进程内 libav 路径。** 单独的进程内迁移原本只有约 2.8% 墙钟收益；叠加预滚优化后已达到约 23.2%，足以改变此前“暂不合入”的结论。

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

余量扫描中，0.25 秒和 0.125 秒仍与基线逐字节一致；0 秒已经不同，编码后 SSIM 降至 0.9966。这确认“目标前恢复完整解码”是正确性条件，不应为了样本内的少量收益把余量压到 0。当前结论：**保留 0.5 秒作为保守候选，并立即扩大语料验证；尚不直接合入正式路径。**
