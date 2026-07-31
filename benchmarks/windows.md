# Windows 性能优化记录（vimg vcs Preview profile）

> 归档于 2026-07-31。所有测试使用固定 Preview profile：
> `vimg vcs -c3 -H160 -n9 <input> --output output.avif`

## 测试环境

| 项 | 值 |
|---|---|
| 系统 | Windows（NTFS，Defender 已禁用） |
| CPU | Intel i9-12900K（16C / 24T，8P+8E） |
| GPU | NVIDIA GeForce RTX 3090 24GB（CUDA 13.3） |
| 存储 | Samsung 980 PRO 2TB NVMe |
| FFmpeg（ffmpeg 后端） | 8.0 gyan full build |
| FFmpeg（libav 后端） | 8.1.2 GyanD/codexffmpeg full_build-shared（dev 库） |
| 输入 | `sample/input.mkv`：3.2GB，3295s，h264 1080p 23.976fps，55 流（1 视频 + 2 音频 + 52 字幕） |

## 测试命令

```powershell
# ffmpeg 后端（默认）
.\target\release\vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output output.avif

# libav 进程内后端（需 in-process-decode feature + FFmpeg 8.1 dev 库 + PATH 含 bin）
.\target\release\vimg.exe vcs -c3 -H160 -n9 --capture-backend libav .\sample\input.mkv --output output.avif

# profile 分解
.\target\release\vimg.exe vcs -c3 -H160 -n9 --capture-backend libav --profile .\sample\input.mkv --output output.avif
```

## 优化时间线（wall 耗时，热运行）

| 阶段 | 提交 | 改动 | 耗时 |
|---|---|---|---|
| 原始基线 | — | 初始 exe | ~2.80s |
| 早期 Windows 优化 | — | 禁 CUDA、preset 8、线程 8 | ~2.09s |
| mac streaming 合并后 | `bc8039f` | 9 进程并发流式 | 2.18s（低负载）/ 2.47s（高负载） |
| libav 可用 | `1863551` | margin 0.5→0.25、Windows 1.3s 调研 | 2.08-2.4s |
| 整 worker 门控 | `32888cb` | semaphore=-T + try_recv 轮询 | 1.88s（profile，后被复测否定） |
| 预滚测量 | `a87fcfe` | setup/preroll/window 阶段分解 | — |
| no-clone + margin 0.125 | `71343ac` | 预滚帧零拷贝、margin 0.25→0.125 | 1.94s（profile） |
| **移除门控** | `56fc1e4` | 门控是负优化，恢复全并发 | **1.74s（profile）/ 1.90s（wall）** |

## 最终对比（2026-07-31，低负载，交错测试）

| 指标 | ffmpeg 后端 | libav（无门控） | 差异 |
|---|---:|---:|---:|
| wall 平均 | 2.11s | **1.90s** | −10% |
| profile total | — | **1.74s** | — |
| first_grid | 1.75s | **1.11s** | **−37%** |
| 输出 SHA-256 | `3f0fa2be…` | `3f0fa2be…` | 逐字节一致 |

## 调研后最终配置（2026-08-01：SVT lp=4 + DT2）

调研文档：`docs/research/2026-08-01-windows-runtime-optimization-options.md`。
端到端 ABBA（warm 6 次/配置）确认：

| 配置 | wall 平均 | profile total | 输出 |
|---|---:|---:|---|
| DT2 + SVT 自动 lp（原） | ~2.04s | 1.96s | 3f0fa2be… |
| **DT2 + lp=4（采用）** | **~1.90s** | **1.67s** | 3f0fa2be… |
| DT3 + auto lp | ~2.02s | —（RSS 超预算） | — |
| DT3 + lp=4 | ~1.99s | —（RSS 超预算） | — |

SVT-AV1 `lp`（Level of Parallelism）4：30 帧短编码 auto lp=6 过度并行
（PPCS 305→107），编码 write+tail 0.36→0.27s。lp4 在 DT2 下有效
（−15% profile total），DT3 下被解码竞争淹没。DT3 两格仅作正交量化，
RSS 超 512MB 预算未采纳。

**最终 libav 配置**：无门控 + frame threading DT=2 + margin 0.125 +
预滚零拷贝 + previous 缩放 RGB + SVT `lp=4`。wall ~1.90s、profile total
1.67s、peak RSS 445MB（预算内）、输出与 ffmpeg 后端逐字节一致
（`3f0fa2be…`）。

## 关键发现（调研结论）

1. **mkv 并发 seek 串行化**（ffmpeg 后端最大瓶颈）：3.2GB/55 流 mkv 的 9 个采样点
   seek 完全串行（~0.1-0.2s/点，总 ~1.9s）。同文件并发访问串行化（不同文件仅 1.22s）。
2. **硬件解码在 Windows 无价值**：CUDA 单点 1.6s（CPU 0.38s 的 4 倍）、dxva2 9 并发
   2.64s——GPU→CPU 帧传输开销 > 收益。
3. **整 worker 并发门控是负优化**：3 波排队（5 个 worker 空闲）> 9 路竞争。
   -T9 在低负载和高负载（2 实例）下均优于 -T4。
4. **预滚受 GOP 结构限制**：慢点（长 GOP）预滚 0.5-0.6s / 66 帧是物理下限；
   margin 0.125 已验证逐字节一致（0.0 会破坏正确性）。
5. **first_grid 下限 = 最慢采样点的帧 0**（长 GOP 预滚），调度无法消除。

## 权衡：门控 vs 无门控（ADR-0001 512MB 预算）

| 配置 | profile total | vimg 峰值 RSS | 预算 |
|---|---:|---:|---|
| 整 worker 门控（-T4） | 1.88s | ~286 MB | ✅ 内 |
| 无门控 + DT=3 | **1.74s** | ~514 MB | ⚠️ 超 ~2MB |
| **无门控 + DT=2（最终）** | 1.96s | **~443 MB** | ✅ 余 69MB |
| 无门控 + slice threading | 2.17s | ~364 MB | ✅ 余 148MB |

复测报告（report.md「libav 并发门控复测」）警告：在 512MB 契约下不应直接回退，
无门控的 RSS 优势是**延迟**，代价是**内存超预算**。最终采纳无门控 + 减少每
decoder 常驻内存（previous 帧改存缩放 RGB + DECODER_THREADS 3→2）使 RSS 回到
443MB 预算内，性能代价 ~0.22s。

## 正确性保证

所有 libav 变体（门控值、margin、threads）输出与 ffmpeg 后端**逐字节一致**：
SHA-256 `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
帧数保持 30，帧选择契约（authority）未改变。

## 复现方法

1. 编译：`cargo build --release --features in-process-decode`
   （需 FFmpeg 8.1 dev 库，见 report.md「libav 后端集成（Windows）」）
2. 运行：PATH 需包含 FFmpeg 8.1.2 shared 的 bin 目录（avcodec-62.dll 等）
3. 基准：先预热 1 次，再记录 5+ 次热运行取范围；避免系统负载波动（dota2/rustdesk 等）
