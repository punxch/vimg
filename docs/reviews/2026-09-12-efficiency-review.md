# 当前代码效率复核（2026-09-12）

本轮审查上轮未提交修改，并继续阅读现有解码、调度、拼图、编码及服务路径。
固定点为 `3dcf808d3f8693c8807c8e4da260016f96c1bd5a`；差异使用
`git diff 3dcf808 -- src/command/libav.rs report.md`，另读取
`scripts/bench-startup.ps1`。本轮没有修改生产代码，也没有把下列候选宣称为已实现收益。

## Standards

未发现上轮修改引入的硬标准违反、FFI 所有权错误或并发回归。

- `libav.rs:867` 的 `av_frame_ref` 使用有效且不同的 AVFrame，目标为空；
  保留帧独立持有 buffer 引用，错误路径由 RAII 清理。
- `libav.rs:921` 转移 CPU 帧后只使用原结构体的标量字段。
  已读取本地 ffmpeg-next 8.1.0：`Video::clone` 确为深拷贝，
  `Source::add` 确实调用 `av_buffersrc_add_frame`，没有新增重复释放。
- `libav.rs:1013` 限制缩放线程的路径已有固定 Preview profile 检查，
  不会把任意大尺寸输出都强制为单线程。
- 独立重算上一轮 CSV，中位数 1.783596 → 1.4112622s、
  P95 1.9356531 → 1.6331616s，与报告一致。

## Spec

未发现上轮新增的帧选择、编码参数或默认后端缺陷。输出保持的证据为四组输入
共 1080 张 RGB、1080 个 PTS 及最终 AVIF 一致；默认 Windows `auto` 是既有实现。

验证覆盖仍有边界：新进程、热文件缓存的测试不能证明真正磁盘冷缓存收益，
也不能代表常驻 serve 连续任务和十任务满载。上一轮已披露这些边界，属于
待补测项目，不是伪造收益。既有 ADR 的 1.3s P95 目标也没有被宣布达成。

两轴结论：Standards 0 项新增阻断问题；Spec 0 项新增功能缺陷，仍需补充
冷文件缓存和服务热任务的性能证据。

## 本轮补充测量

使用上轮 release 二进制，Windows `CreateProcessW` 启动进程，
`GetThreadTimes` 读取初始主线程 CPU 时间，`GetProcessTimes` 读取进程 CPU。
进程结束后读取仍然有效的句柄；没有修改二进制或采样器注入。

| 运行 | 完整命令 wall | 主线程 CPU | 进程总 CPU |
|---|---:|---:|---:|
| 1 | 1.275s | 0.875s | 11.719s |
| 2 | 1.269s | 0.844s | 11.578s |
| 3 | 1.396s | 0.844s | 12.625s |

主线程 CPU 包含初始化、拼图等工作，不能全部归因于轮询，更不能将
0.84s CPU 直接换算为 0.84s wall 收益。结合 `recv` 的忙循环，它足以支持
优先测试事件唤醒。多核 CPU 时间不能与 wall 相加。

另运行三次现有 `VIMG_PROTO_PROBE=1`。最慢 cap7 的中间一次分解：
open 26.8ms、seek 28.8ms、decoder/filter setup 3.2ms、send_packet 923.5ms、
receive 1.1ms、emit 66.5ms，总计 1.0968s。该次 profile：
first_grid 0.916s、首 grid 前接收 241 帧、join 32ms、encoder_write 14ms、
encoder_tail 214ms、total 1.328s。三次 cap7 的 send_packet 为 924–1041ms，
说明解码提交仍是主要关键路径；此计时也包含等待解码线程的时间，并非纯解析 CPU。

`--version` 三次 wall 为 172/85/78ms，后两次反映热文件缓存下的进程加载及
最小 CLI 路径量级，不包含 VCS 初始化，也不是真正冷磁盘启动。

原始证据：`.scratch/startup/review_cpu.py`、`review-cpu.json`、
`review-profile-{1,2,3}.log`。本轮输出仍为
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。

## 下一步候选

### 1. 事件唤醒代替忙轮询：优先做独立原型

位置：`src/command/libav.rs:324`，尤其 `325–353` 的
`try_recv` 九路扫描与 `yield_now`。

先保留现有九路容量为 2 的队列和就绪扫描策略，只在没有消息时用
Condvar/通知序号休眠，生产者入队及退出时唤醒消费者。这样可以单独测量
等待策略的影响。必须处理“扫描完成与进入等待之间收到通知”的丢失唤醒竞态，
以及 worker 错误、取消、panic 和所有发送端断开后的唤醒。

不要同时修改窗口许可、接收公平性和预取深度，也不要直接改成逐路 `recv()`。
旧报告已经显示后者可能改善首 grid，却恶化总耗时和 RSS。当前任务的主要
预期是减少等待 CPU、改善并发服务的争抢；单次 wall/P95 收益尚未验证。

验收：输出门槛不变，交错比较 wall/P95、CPU、首 grid、峰值 WS；再测试
生产者失败与取消不会挂住。当前帧数已固定，缓冲不是无限增长，但首 grid 前
241 帧约有 31.5MiB RGB 在通道或拼图阶段流转，后续可独立测预取窗口。

### 2. 减少重复 probe：同时覆盖 CLI 初始化与服务热路径

位置：`capture.rs:764`、`libav.rs:451`、`serve.rs:126`、
`capture.rs:841`、`gridthumb.yazi/main.lua:187`。

已确认本地 `ffmpeg::format::input` 每次都调用 `avformat_find_stream_info`。
普通 CLI 在 plan 做一次 probe，九个 worker 又各做一次完整 open/probe。
可让 plan 生成已验证的 stream/codec 参数描述，worker 独立保留 demux/seek
上下文，但对容器头信息足够的输入跳过重复 stream-info。信息不完整、
stream/time-base 不一致时恢复完整探测。不能无条件删掉 probe，也不能在
多个 worker 之间共享可变的 `AVFormatContext`。

更窄的服务优化：请求的 `MediaDescriptor.codec` 在 `serve.rs:126` 被固定为
`None`，插件也未传该字段，所以即便有 duration、尺寸和 time base，仍必定
再次 probe。补齐插件提取、DDS 字段和 Rust 解析全链路，才会触发已有的
免探测路径。需要匹配实际选择的视频流并随源文件身份失效。

收益边界：当前 plan 约 9–12ms，关键 worker 的完整 open/probe 约 25–31ms，
其中仅部分可消除；九路并行，不能把九次 open 相加当成 wall 可省时间。

### 3. 编码传递所有权与小型 buffer pool

位置：`encode.rs:57` 的 `send(grid.clone())`、`encode.rs:239` 的
RGB AVFrame 分配和逐行拷贝、`encode.rs:247` 的 YUV AVFrame 分配；调用方
`vcs.rs:899–911` 在写入编码器后不再使用 grid。

优先将 `write_grid` 改为接收拥有所有权的 `RgbImage`，让刚生成的 grid 直接
进入编码线程；authority 在转移前记录。随后复用 RGB 输入 buffer。
若复用 YUV frame，必须尊重编码器可能保留的引用，使用可写检查或有界池，
不能覆盖仍被异步编码器使用的像素。

样本每张 grid 856×480×3，30 帧的一次额外复制约 35.3MiB。
主线程已测 encoder_write 约 14–16ms，其中包含通道等待，不能全部算成
复制；这项属于小收益、减少分配压力的候选，不应承诺再省几百毫秒。

### 4. 缓存标签覆盖率，并关闭未请求的诊断记录

位置：`join.rs:99`、`join/label.rs:164,200`、`libav.rs:948`。

同一任务九个时间标签在 30 张网格中不变，却重复进行 270 次 glyph 布局与
光栅化。预计算九份布局、背景区域与逐像素 coverage，保留原整数混合顺序，
每帧只执行合成。不要将背景提前混到黑图再覆盖，否则会改变视频背景像素。
本次 join 总共仅 32–37ms，标签只是其中一部分，收益上限很小。

普通非 authority 模式也会收集 270 条 `SourceSelection` 并格式化 time-base
字符串，最后被丢弃。按 `records.is_some()` 条件记录即可减少分配；对
prototype dump 独立保留其 PTS 输出。此项代码小，优先级低于轮询和 probe。

### 5. 服务端缓存复查与全局资源预算

位置：`serve.rs:177` 仅合并未完成任务，`serve.rs:376` 无条件执行 capture；
`serve.rs:240` 建立十个 worker，`libav.rs:257` 明确未使用 plan concurrency。

插件已在发送请求前检查 AVIF 缓存。服务端仍可在取出任务时再验证源文件身份、
缓存/manifest 和 profile；匹配时直接复用结果并通知等待者，可处理跨实例、
延迟到达或排队期间已完成的重复请求。收益仅针对重复请求，不能加到单次
CLI 的性能数字里，也不能只依据“目标文件存在”就跳过。

十个服务任务会进一步展开九路采样和每路解码线程。建议保持最多十个受理任务，
按独立的 CPU/内存预算限制活跃重任务，测 1/2/4/10 请求下的吞吐和响应尾延迟。
预算不能简单变成整 worker 持有许可后阻塞发帧，否则可能重现历史死锁。
历史连续任务内存增长尚未用本轮引用优化版本重测，不应宣称已修复或仍必然
以旧报告的每任务增量发生。

## 测量与推进顺序

先单独做事件唤醒原型，再测试 metadata/probe 复用，之后做 grid 所有权传递。
每项与当前 release 交错对照，不改变帧数、CRF、preset、预滚丢帧策略。
CUDA/D3D12VA、BIDIR discard、盲增 decoder/SVT 线程已有反证，不重复作为
当前固定样本的首选路线。

冷文件缓存测试需要受控重启后的可比首轮，或隔离机器的明确缓存条件；
服务热路径需要同一进程内连续任务及不同输入队列。两者与当前“新进程、热文件
缓存”单列报告。扩大测试是为了验证相应候选，不能用不同批次的最快值替代对照。
