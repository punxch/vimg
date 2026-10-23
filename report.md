# Performance Optimization Report

## 2026-10-24：H.264 冷启动 4.2% 差值复核与 CPU 负载控制

**未确认稳定的 H.264 代码回退，因此没有修改解码策略或回滚 HEVC 优化。**
同一组二进制复测，低负载冷态中位数仅差 +0.15%，热态 +0.48%。
本轮改进测量工具，加入负载门槛、整组补测和失败上限。上轮 +4.2% 的历史记录保留；
不能将本轮复核写成“代码修复后加速 4.2%”。

### 主要对照与结论

基线仍为 `db471de` 的 `.scratch/startup/phase24/baseline/vimg.exe`，候选仍为 `bb4e1d0` 的
`target/preview-runtime-phase24-wpp/vimg.exe`。两端 EXE SHA-256 与上轮记录一致，所有相邻 DLL 逐个校验相同。
没有重新构建、换库、修改优先级/亲和性/电源计划或停止用户应用。机器仍为 Windows / i9-12900K。
命令为 `preview --skip 0 --max-width 600 --max-height 900 --quality 75`，每次启动新进程、使用独立输出，主要对照不启用 timings。

门槛在测量前固定：启动前连续四个 250ms 窗口的系统 CPU 均≤8%，测量期间系统 CPU≤12%。
系统 CPU 包含被测进程，不代表全机零负载。任一次超限，整组四次 ABBA/BAAB 均保留但不计入低负载汇总，补测整组；
没有按耗时快慢选点。冷态沿用 RAMMap `-Es` / `-Et`，以普通令牌启动；紧接热态另按完整组判定。

| 状态 / 样本数 | 中位数 基线→候选（ms） | P95 基线→候选（ms） | 中位数变化（正数为变慢） |
| --- | ---: | ---: | ---: |
| 上轮冷态，各 8 次 | 119.08→124.12 | 147.32→143.14 | +4.23% |
| 本轮低负载冷态，各 16 次 | 116.12→116.29 | 155.43→124.91 | +0.15% |
| 本轮全部冷态，各 50 次 | 116.68→116.85 | 149.50→128.62 | +0.15% |
| 本轮低负载热态，各 24 次 | 100.78→101.26 | 109.90→111.31 | +0.48% |
| 本轮全部热态，各 60 次 | 100.92→101.93 | 113.12→117.77 | +1.00% |
| 紧接冷测的低负载热态，各 12 次 | 100.20→101.17 | 108.15→119.14 | +0.97% |

热态共 30 个对照组，12 组合格；冷态共 25 组，8 组合格。全部超限组和慢轮次保留。
包括超限组的全部 50 次/版本冷测也仅差约 0.15%，不是通过去掉超限组才得到接近的结果。
低负载基线仍有一次约 155ms 的冷启动，按既定条件保留；16 次的 nearest-rank P95 恰好为最大值。

按完整组重采样 10,000 次（固定种子 25），中位数相对差的探索性 95% 区间为：
上轮冷态 -7.11%～+10.02%，本轮低负载冷态 -3.45%～+2.53%，
热态 -0.56%～+2.61%。区间包含零；它们描述当次小样本，不保证其他环境或长期 P95。

### 对原差值的归因

旧记录每版本仅 8 次，难以可靠区分约 5ms 的差值和运行波动。加载状态也有可观察变化：

| 进程硬缺页中位数 | 基线 | 候选 |
| --- | ---: | ---: |
| 上轮 | 6.0 | 71.0 |
| 本轮低负载冷态 | 6.5 | 7.0 |

候选 EXE/DLL 字节未变，硬缺页却从 71 降到 7，这不是本轮修改解码代码的结果。
硬缺页表示需要从磁盘取回内存页，见 [Microsoft Hard Faults 说明](https://learn.microsoft.com/en-us/previous-versions/windows/desktop/xperf/hard-faults)。
**据此推断，原差值更符合冷加载状态差异和小样本波动，而非稳定的 H.264 解码回退。**
CPU 不是已证明的唯一原因；负载、采样数量和运行历史同时影响观察结果，现有证据不能把原约 5ms
精确拆分为 CPU 争用、预读和缺页等待，也不能归因到某个具体 Windows 服务。

代码核对：H.264 不进入 HEVC PPS/WPP 检查，仍使用 1 个 Frame 线程并保留环路滤波。
采集到的候选阶段记录均为 `decoder_threads=1`、`skip_loop_filter=false`；两端读包数均为 1，选帧时间戳和 JPEG 哈希一致。

### 冷态证据与补充诊断限制

主要冷测的 100 个 ETW 会话均无丢失事件，每次都实际读取素材、EXE 和运行库，紧接热态这些路径的读取均为零。
按执行窗口和具体路径统计，包含系统代发读取，不以逻辑读取量代替磁盘读取。低负载冷态读取量中位数：

| 路径 | 基线 MiB | 候选 MiB |
| --- | ---: | ---: |
| 素材 | 1.344 | 1.344 |
| EXE | 11.391 | 11.108 |
| 运行库 | 19.834 | 20.200 |

仍是 Windows 文件缓存冷态，未清理 SSD 控制器缓存或 Windows 预取文件。
另外两组带 timings 的补充诊断，因后续持续负载波动，在无活动追踪的边界安全停止：

- `stages` 保留 71 次冷/紧接热态试验：17 个完整组仅 1 个低负载冷态组合格（每版本 2 次），另有 3 次未完成组样本。
- `settled` 在清缓存后增加相同的低负载等待，保留 15 次试验：3 个完整组均未合格，另有 3 次未完成组样本。

两组未达到预定的每版本 8 次，**不作为性能验收或修复依据**。这 86 个已完成启动的 ETW 会话均无丢失事件、均实际读到目标文件；
`settled` 的等待期间没有目标路径读取，未观察到等待阶段重新预热这些文件。所有原始记录和中断尾部保留。
完整组（含超限组）的 read_decode 中位数分别为 30.70→30.83ms、30.62→30.67ms，decoder_init 为
0.121→0.116ms、0.109→0.111ms，仅作线索，不能据此声称已用低负载阶段测量排除所有细小回退。
所有控制器及专用 ETW 会话均已停止；主动停止后测量器报告控制器退出，不是 vimg 功能失败，也未标记为成功完成。

### 测量工具改动与验证

`scripts/bench-static-preview.py` 新增可选 `--max-system-cpu`、`--idle-system-cpu`、`--idle-timeout`、`--max-blocks`。
默认仍采用原有预热和 ABBA/BAAB 次数。启用门槛后同时输出低负载 `summary` 和保留超限组的 `all_samples_summary`；
`run.json` 固定记录参数与 EXE 哈希，`rows.json` 保留逐次数据与整组判定。等待超时或重试耗尽会失败，不发布伪成功汇总。

新增 `scripts/test-preview-benchmark.py` 使用真实 vimg/JPEG 流程并注入 CPU 计数，验证单次超限会使整组保留并补测、
两端样本平衡、重试耗尽不生成成功汇总、持续高负载等待有上限。这些逻辑测试不纳入性能表。
默认与启用门槛的真实 CLI 各 4 次/版本通过，非法参数在创建输出目录前拒绝；所有实际预览完整解码、图像哈希一致。
原生源码和运行包未修改，未重新构建。本轮不为 H.264 声称加速。

```powershell
python -B -X utf8 scripts/bench-static-preview.py --baseline .scratch/startup/phase24/baseline/vimg.exe --candidate target/preview-runtime-phase24-wpp/vimg.exe --video sample/input.mkv --output-dir <new-directory> --runs 24 --max-system-cpu 12 --idle-system-cpu 8
python -B -X utf8 scripts/test-preview-benchmark.py --vimg target/preview-runtime-phase24-wpp/vimg.exe --video sample/input.mkv --output-dir <new-test-directory>
```

完整证据在 `.scratch/startup/phase25/`：`warm-original`、`original` 是已完成的主要对照；`stages`、`settled` 是未达到样本目标的补充诊断。
`prepare.py` 创建新目录和会话，启动对应 `admin.py` 后以普通令牌运行 `measure.py --cold`，结束后由 `analyze.py` 验证读盘。
`summary.json` / `summarize.py` 保存区间及归因统计；`benchmark-tests`、`benchmark-default`、`benchmark-gated`、`validation.json` 保存工具验证。
提交测量脚本、测试、README 和本报告；实验二进制/素材/ETL 不入库，`.serena/project.yml` 的用户改动不纳入提交。

## 2026-10-24：静态预览环路滤波与 HEVC slice 线程对照

本轮基线为 Git `db471de` 的原生 release，继续使用相同的精简 FFmpeg 8.1.2 DLL。
测试了关闭环路滤波、HEVC 2/4 个 slice 线程，以及两者组合。最终只默认启用
**已探测画面面积≥2,073,600 像素且所有 hvcC PPS 都明确启用 WPP、未启用 tiles 的 HEVC 组合策略**。
H.264、小图、无 WPP、未知配置保留原滤波和单线程；这些输入未证明有稳定的端到端收益。
本轮不修改 VCS 解码、JPEG 质量/尺寸参数、选帧规则、stdout 元数据或插件协议。

### 最终版本：新进程冷热耗时

测试机仍为 Windows / i9-12900K。参数为 `preview --skip 0 --max-width 600 --max-height 900 --quality 75`。
两端均用实际名称 `vimg.exe` 和独立输出文件。热态先各预热两次，再按 ABBA/BAAB 交替每臂测 24 次；
冷态各 8 次，每次 RAMMap 清理后启动普通权限进程，并立即追加一次热态调用。
下表为最终运行包的默认模式（没有 `--timings`），单位 ms；P95 使用 nearest-rank。

| 素材 | 热态中位数 基线→最终 | 热态 P95 基线→最终 | 冷态中位数 基线→最终 | 冷态 P95 基线→最终 | 冷/热中位数改善 |
| --- | ---: | ---: | ---: | ---: | ---: |
| 主素材 H.264 1080p | 110.0→109.2 | 124.2→123.7 | 119.1→124.1 | 147.3→143.1 | -4.2% / 0.7% |
| HEVC 1080p / WPP | 59.7→57.4 | 70.6→65.3 | 82.0→75.9 | 107.8→84.2 | 7.4% / 3.9% |
| HEVC 4K / WPP | 76.4→64.4 | 90.2→71.8 | 92.4→88.3 | 117.0→100.2 | 4.4% / 15.8% |
| 真实画面 HEVC 4K / WPP（1080p 放大） | 76.8→66.7 | 96.1→75.1 | 91.4→77.1 | 104.8→80.1 | 15.7% / 13.2% |

H.264 最终策略和图像保持原样，但本轮冷态仍为 119.1→124.1ms（慢约 4.2%），
未达到主素材加速目标。保留该结果，不将 HEVC 的改善外推到 H.264。8 次冷测的 P95 等于本组最大值，
不能解释成长期延迟保证；不同批次中位数不拼接相减。真实画面取自现有主素材 1500 秒位置，
4K 用例由 1080p 放大后编码，用于内容复杂度对照，不冒充原生 4K 摄影素材。

| 最终运行包资源（基线→最终） | 热态进程 CPU ms | 冷态进程 CPU ms | 热态系统 CPU % | 冷态系统 CPU % | 冷态素材 / EXE / DLL MiB（最终） |
| --- | ---: | ---: | ---: | ---: | ---: |
| 主素材 H.264 1080p | 78.1→78.1 | 78.1→78.1 | 20.0→21.7 | 9.8→10.7 | 1.395 / 11.108 / 19.507 |
| HEVC 1080p / WPP | 31.2→31.2 | 31.2→31.2 | 11.4→10.7 | 17.1→15.5 | 0.313 / 11.101 / 18.618 |
| HEVC 4K / WPP | 46.9→54.7 | 46.9→70.3 | 10.4→13.0 | 15.7→29.3 | 0.627 / 11.108 / 18.866 |
| 真实画面 HEVC 4K / WPP（1080p 放大） | 46.9→31.2 | 46.9→39.1 | 19.8→21.6 | 10.3→10.0 | 0.065 / 11.126 / 18.866 |

进程 CPU 使用 GetProcessTimes，受 Windows 计时粒度限制；系统 CPU 包含本进程。
主素材和 HEVC 1080p/4K 在 skip=0 的阶段诊断中，取帧循环仍只读 1 个包，收益来自单帧处理。

### 单项、线程数及组合的消融结果

所有实验臂使用同一个原型 EXE、同一套 DLL，仅切换两个临时实验开关。原型不进入默认运行包。
先各测 12 次热态，再各测 24 次复测；下表采用 24 次复测和对应各 8 次冷态对照。

| 素材 / 改动 | 热态中位数 基线→候选 | 热态 P95 基线→候选 | 冷态中位数 基线→候选 | 冷态 P95 基线→候选 |
| --- | ---: | ---: | ---: | ---: |
| H.264 / 仅关闭滤波 | 103.7→102.4 | 118.2→115.5 | 125.5→119.9 | 181.4→138.4 |
| HEVC 1080p / 仅关闭滤波 | 62.8→61.9 | 75.9→82.2 | 73.6→74.1 | 85.9→85.2 |
| HEVC 1080p / 仅 4 slice 线程 | 62.0→60.2 | 73.9→72.8 | 83.0→77.3 | 96.9→93.6 |
| HEVC 1080p / 组合 | 59.3→57.5 | 69.8→80.2 | 75.9→70.4 | 105.6→76.5 |
| HEVC 4K / 仅关闭滤波 | 77.6→73.8 | 90.1→89.2 | 93.7→89.6 | 123.9→95.2 |
| HEVC 4K / 仅 4 slice 线程 | 95.6→81.0 | 129.1→115.5 | 89.5→81.9 | 96.8→110.1 |
| HEVC 4K / 组合 | 82.3→68.3 | 90.4→84.9 | 89.6→83.9 | 102.6→96.0 |

另有 2 线程和 4 线程的独立对照。阶段诊断中，4K HEVC 的 read_decode 为
22.5→14.5ms（2 线程）、22.9→11.4ms（4 线程）；4 线程初始化约 0.9ms。
1080p 对应约 6.4→4.3/3.8ms。320×180 的解码没有并行收益，却增加约 0.5–0.7ms 初始化，故排除小图。
无 WPP 的真实画面没有获得 slice 解码加速，4 线程整进程初测退化约 8.5%，故必须检查 PPS。
只读 hvcC parallelismType 不足够：FFmpeg 在未指定 min_spatial_segmentation_idc 时会将该字段设为 0，
即使 PPS 启用了 WPP。本实现用有边界检查的 RBSP/Exp-Golomb 读取 PPS 前缀，未知结构保持单线程。
参考固定本地 FFmpeg 8.1.2 的 `libavformat/hevc.c` 和 `libavcodec/hevc/hevcdec.c`，
以及 [FFmpeg PPS / parallelismType 源码说明](https://www.ffmpeg.org/doxygen/trunk/hevc_8c_source.html)。

在已经使用 4 个 slice 线程的相同原型上，再加关闭滤波，各 48 次 ABBA 对照：
1080p 56.4→56.1ms、4K 68.0→65.5ms、真实画面 1080p 57.0→56.6ms、真实画面 4K 63.4→62.4ms。
因此大尺寸 WPP HEVC 保留组合策略；没有把不同组的差值相加当作组合收益。

### 没有进入默认策略的实验与负结果

- H.264 关闭滤波虽然单帧解码约 30.8→29.6ms，64 次热态也有 103.6→102.1ms 的小幅改善，
  但含该改动的中间运行包各 16 次冷态为 116.0→122.1ms；第一轮同 EXE 冷态却为 125.5→119.9ms。
  冷态方向未稳定复现，不能把热态约 1–2ms 的收益推广到冷启动，最终恢复原 H.264 策略。
  中间包的硬缺页中位数 6.5→57.0，不能据此将全部变化归因为解码开关。该轮原始结果完整保留。
- 320×180 单独关闭滤波仅省不到 0.1ms 解码，墙钟结果不稳定，最终保留滤波。
- 无 WPP 的 1080p 单独关闭滤波整进程复测约为 +1.9%、+0.2%、−3.8%，不足以进入默认策略。
  最终恢复原策略后，无 WPP 热态为 57.5→58.2ms，320×180 为 51.3→50.9ms；均不声明加速。
- 中间包同时包含 H.264/无 WPP 关闭滤波的所有测量均保留在 `warm-final-*`、`warm-accepted`、
  `warm-hevc-only`、`cold-final`；最终数据只取 `warm-wpp` 和 `cold-accepted`。

### 冷态证据与负载处理

总计 256 个 ETW 会话：单项/组合 112 个，中间包 80 个，最终包 64 个。
每个会话均 `EventsLost=0`；每次冷态都读到素材、EXE 和 libav DLL，紧接热态这些路径均为 0 字节。
WPR 读取按路径与进程墙钟窗口归类，包含系统代发的读取/预读，不把进程逻辑读取量当成磁盘读取。
RAMMap `-Es`/`-Et` 均成功，控制器只用管理员令牌清缓存和管理本次专用会话，被测程序为普通令牌。
这是 Windows 文件缓存冷态，不等同于断电或 SSD 控制器缓存清空；所有控制器和会话均已停止。

最终清缓存到启动间隔 3.49–24.96ms；
清理后 standby 0.207–0.344MiB。
全部高负载样本保留，没有为了结果好看而删点。初筛及真实画面对照出现高负载轮次，已追加复测；
最终默认热态系统 CPU≥45% 样本 2 个，
最终冷/紧接热态同阈值样本 0 个。所有轮次的逐次 CPU、耗时和图像哈希均保留。

最终热态的两个高负载样本均位于真实画面 4K 组，仍完整保留在主表。该组随后独立追加每臂 24 次 ABBA/BAAB：中位数 74.6→61.2ms，P95 100.1→71.8ms，中位数改善 17.9%；CPU≥45% 样本 0 个。追加结果保存在 `warm-wpp-natural-repeat`，不替换或合并原批次。

### 功能、图像和兼容性验证

- 原生 Rust 测试 92 passed / 7 ignored；标准构建 68 passed / 4 ignored。新增测试覆盖 WPP/tiles、
  多 PPS、截断长度、错误 NAL 头、多层 PPS、emulation-prevention 和过长/截断 Exp-Golomb。
- 既有 46 组静态预览/回退和 24 组快速 seek/IRAP 用例通过；元数据、方向、尺寸、完整 JPEG 解码、
  损坏输入不覆盖旧缓存的要求保持。17 项协议检查和 4 组 Lua 插件测试通过。
- 新增 33 组与基线同帧对照：选中 PTS、seek 路径/次数、元数据和尺寸一致；真实画面、WPP、
  无 WPP、多 slice、320×180 和 1920×1078 门槛下输入均覆盖，实际线程数符合限制。
  18 组 RGB 有差异；变化图像 PSNR 最低 41.95dB，
  RGB 单通道平均绝对误差最大 0.515/255。这些数值只记录，未将像素相同当成通用验收条件。
  对真实画面、4K 图像及差异较大的测试图作目视检查，没有发现明显损坏。H.264、无 WPP 和门槛下用例图像保持基线。
- 原始 `vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output <unique>.avif` 通过，
  AVIF 动画流 `v:1` 仍为 30 帧、852×480、20fps、time base 1/10240、PTS 0..14848 步长 512。
  严格解码通过，输出 SHA-256 仍为 `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
  本轮没有修改 VCS 或声明其加速。

### 构建、复现与提交范围

```powershell
$env:PKG_CONFIG_PATH='D:/ffmpeg-dev/ffmpeg-8.1.2-full_build-shared/lib/pkgconfig'
cargo build --release --features in-process-decode
python -B -X utf8 scripts/build-preview-runtime.py --exe target/release/vimg.exe --runtime-dir D:/ffmpeg-dev/libav-deploy --output-dir target/preview-runtime-phase24-wpp --filter-dll target/preview-runtime-repro/avfilter-11.dll
python -B -X utf8 scripts/test-preview-decode.py --baseline <baseline/vimg.exe> --candidate target/preview-runtime-phase24-wpp/vimg.exe --fixtures <new-fixture-dir> --output-dir <new-check-dir> sample/input.mkv
python -B -X utf8 scripts/bench-static-preview.py --baseline <baseline/vimg.exe> --candidate target/preview-runtime-phase24-wpp/vimg.exe --video <video> --output-dir <new-bench-dir> --runs 24
```

运行包位于 `target/preview-runtime-phase24-wpp/`，没有覆盖全局安装。DLL 全部与上一轮原样一致，
本轮只重编译 vimg；`--timings` 增加 `decoder_threads` 和 `skip_loop_filter`，默认 stdout 协议不变。
最终 EXE SHA-256：`1f9955090a7423dbdd979ca08ba11c622ade932d20806b6fa52ef79196423d47`。
基线 EXE SHA-256：`2fa1e409ff996056c1dfa17f37615a6b55cd4e1d4976c011c9a9ffffc4c3ca7b`。

完整证据在 `.scratch/startup/phase24/`：`warm-first`、`warm-repeat`、`warm-diagnostic`、
`warm-natural`、`warm-loop-on-slice` 保存消融；`cold`、`cold-final`、`cold-accepted` 保存
受限控制器、WPR 配置、普通令牌测量器、每次缓存清理状态、ETL、逐事件 JSON 及分析结果。
复测时先启动对应 `admin.py`，再以普通令牌运行 `matrix.py`，测量结束后运行 `analyze.py`；
必须使用新目录和专用会话名。`prototype.patch` 与 `bench.py` 记录临时开关及实验构建逻辑，
这些开关已从正式源码移除。`quality-wpp`、`test-fixtures`、`fast-wpp`、`static-wpp`、
`wpp-validation` 保存最终包的图像、协议与 VCS 证据；生成素材的命令和哈希位于各自 manifest。
提交包含实现、测试脚本、README 和本报告；实验二进制、ETL、素材不入库，`.serena/project.yml` 保留并排除。

## 2026-10-23：首次静态预览四项优化落地与冷/热验收

本轮以 Git `2bdff6c` 的原生 release 为基线，采用用户确认的新验收口径：
保持预览尺寸约束、JPEG 质量参数、方向和元数据；允许选帧与像素变化。
快速策略默认启用，失败仍复用已探测元数据走原插件 FFmpeg 回退。
最终独立运行包位于 `target/preview-runtime-repro/`，没有覆盖全局安装。

### 最终结果

主素材为 `sample/input.mkv`，参数为
`preview --skip 0 --max-width 600 --max-height 900 --quality 75`。
两端均以实际名称 `vimg.exe` 启动新进程，每次使用独立 JPEG 输出；
墙钟包含进程创建、原生探测/解码/缩放/编码/发布、stdout/stderr 读取和进程退出。
下表默认模式不启用 `--timings`。

| 状态 | 每版本样本 | 基线中位数 / P95 | 最终中位数 / P95 | 中位数改善 |
| --- | ---: | ---: | ---: | ---: |
| Windows 文件缓存冷态 | 8 | 165.9 / 187.3ms | 115.1 / 147.7ms | 30.6% |
| 独立预热后的热态 | 12 | 142.8 / 158.9ms | 99.3 / 128.5ms | 30.4% |
| 每次冷测后立即热测 | 8 | 141.2 / 159.9ms | 98.7 / 116.7ms | 30.1% |

冷热中位数均超过至少改善 10% 的目标。P95 使用 nearest-rank；
8/12 个样本时它就是本组最大值，不将其解释成长期延迟保证。
测试机器为 Windows、Intel Core i9-12900K；没有修改系统电源/调度策略。
这里的冷态是清理 Windows 文件缓存后的实际读盘，不等同于断电启动或清空 SSD 内部缓存。
测量覆盖直接 CLI 首次静态预览，插件协议另测，不包含 Yazi DDS 传输或屏幕显示耗时。

### 实现与保护

- **减少前置解码**：目标之前且 PTS 已知的包仍发送给解码器处理参数，
  使用 `AVDISCARD_ALL` 抑制图像重建；其他包恢复 `AVDISCARD_NONKEY`。
  缺失 PTS 使用保守解码，不授权跳过重建或提前排空。
- **快速定位**：优先 `input.seek(target, target..)` 前向索引定位。
  失败或没有有效输出时，在同一个已探测 input 上创建新解码器，执行一次
  `input.seek(target, ..target)`，允许返回目标之前的索引关键帧。
  第二次仍失败才返回原有回退协议，不重复探测。
- **HEVC 排空**：在既有 H.264 IDR 校验之外，增加 hvcC 长度前缀、全部 NAL
  边界、单层/temporal-layer-zero、首 slice 和同一 IRAP 图像类型检查，
  覆盖 IDR/BLA/CRA。截断、混合图像、多层、未知结构和配置变化不授权提前排空。
  正常解码仍可处理不满足快速路径的结构；损坏/非关键帧不发布，排空结果
  的时间戳必须匹配候选包。解码启用 bitstream/buffer/explode 错误检查。
- **启动依赖**：固定官方 FFmpeg 8.1.2，仅重建 avfilter，保留 `buffer`、
  `buffersink`、`scale`、`format` 和构建系统总会带入的 `abuffer`/`abuffersink`。
  其余 DLL 全部原样复制，avcodec、avformat、avutil、swscale 校验版本及 SHA-256。
  SVT-AV1、编码器和封装能力不裁剪。avfilter 从 **124,344,320 字节缩至
  281,932 字节（118.58MiB→275.32KiB）**。

CLI/stdout 协议及插件调用不变。仅 `--timings` 增加 `target_pts`、
`seek_mode`、`attempts`、`pre_target_packets`、`drain_kind`；时间戳使用视频流 time base。
重试后的同名阶段应累加，计数覆盖两次尝试。主素材目标 PTS 164000，
仍选 PTS 169378；最终只需读取 1 包，旧版为 199 包。

### 热态分项归因

每种模式先各预热 2 次，再按 ABBA/BAAB 各测 12 次，release、新进程、新输出。
默认耗时与诊断阶段计时分开运行；不同组的绝对时间不能拼接相减。
A=旧版，B=仅减少前置重建的原型，C=再加前向定位/重试及解码校验，D=再加 HEVC 排空，
E=再加精简 DLL。B 仅用于同素材拆分收益，不作为交付版本。
D 的正式版本还把包策略提取成函数以直接测试缺失 PTS 和配置变化。

| 变更 / 素材 | 首轮中位数 基线/候选 | 复测中位数 基线/候选 | 复测 P95 基线/候选 | 复测系统 CPU 基线/候选 |
| --- | ---: | ---: | ---: | ---: |
| A→B 前置解码 / 主素材 | 160.7 / 131.9ms | 144.8 / 119.5ms | 156.9 / 148.5ms | 7.7% / 12.6% |
| B→C 快速定位 / 主素材 | 121.7 / 115.8ms | 118.3 / 110.0ms | 125.3 / 137.3ms | 9.0% / 8.7% |
| C→D HEVC 开关 / H.264 主素材 | 110.4 / 117.8ms | 107.9 / 114.9ms | 155.3 / 127.3ms | 10.0% / 11.8% |
| C→D HEVC 排空 / 1080p | 78.4 / 64.2ms | 78.6 / 64.5ms | 91.4 / 80.5ms | 14.5% / 16.0% |
| C→D HEVC 排空 / 4K | 123.5 / 82.7ms | 未重复 | 首轮 139.7 / 90.3ms | 首轮 10.1% / 14.5% |
| D→E 精简 DLL / 主素材 | 108.9 / 105.0ms | 109.5 / 104.4ms | 127.1 / 117.9ms | 14.7% / 11.8% |
| A→E 组合 / 主素材 | 140.4 / 100.2ms | 151.7 / 108.5ms | 169.1 / 127.6ms | 19.4% / 18.4% |

首轮及补测全部保留，没有剔除高负载样本。系统 CPU≥45% 的默认测量样本为：
首轮 decode 3 次、HEVC 1080p 1 次；诊断测量首轮 decode 8 次、seek 1 次，
补测 decode 9 次、combined 1 次。已分别补测；第三次 decode 诊断及最终组合
默认/诊断组均无此类高负载样本。所有 cold/cold-final 样本也均低于 45%。

H.264 控制组初测出现数毫秒增加，不能作为 HEVC 的收益。
进一步以只差 HEVC 分支的原型各测 24 次，得到

**123.3→121.3ms**，P95 139.9→136.5ms，方向与前两轮相反；
包策略函数提取的独立对照为 106.4→104.8ms。未观察到稳定的 H.264 回退，
也不为 HEVC 改动声明 H.264 收益。HEVC 1080p 的两轮热态结果稳定，4K 收益更大。

| 诊断对照 | read_decode 中位数 | 读包数 |
| --- | ---: | ---: |
| 前置解码（第三轮） | 65.5→40.7ms | [199]→[199] |
| 快速定位（复测） | 41.1→30.7ms | [199]→[1] |
| HEVC 1080p（复测） | 17.5→6.3ms | [94]→[1] |
| HEVC 4K | 59.3→21.3ms | [46]→[1] |
| 最终组合 | 65.7→30.6ms | [199]→[1] |

### 冷态分项与实际读盘

先完成五组各 8 次/版本的冷测（共 80 个独立 ETW 会话），随后对确定性
链接的最终运行包再做 8 次/版本（16 个会话）。每个冷进程结束后立即启动
同版本热进程。A/B 排序同样交错；冷/热输出各自独立。

| 冷态变更 / 素材 | 基线中位数 / P95 | 候选中位数 / P95 | 改善 | 系统 CPU 基线/候选 |
| --- | ---: | ---: | ---: | ---: |
| 前置解码 / 主素材 | 163.2 / 182.4ms | 147.0 / 171.7ms | 9.9% | 13.7% / 15.9% |
| 快速定位 / 主素材 | 142.6 / 161.1ms | 124.6 / 144.8ms | 12.6% | 16.6% / 13.6% |
| HEVC 排空 / 1080p | 98.7 / 132.1ms | 83.9 / 102.2ms | 15.1% | 10.8% / 9.8% |
| 精简 DLL / 主素材 | 130.7 / 145.5ms | 121.2 / 137.3ms | 7.3% | 23.9% / 12.6% |
| 首轮组合 / 主素材 | 169.8 / 173.4ms | 119.5 / 150.8ms | 29.6% | 14.5% / 13.6% |

| 分项冷态磁盘读取中位数 | 素材（基线→候选） | libav DLL（基线→候选） |
| --- | ---: | ---: |
| decode | 17.203→17.203MiB | 30.803→30.742MiB |
| seek | 17.203→1.344MiB | 31.019→30.879MiB |
| hevc | 3.157→1.657MiB | 31.194→31.194MiB |
| dll | 1.344→1.344MiB | 31.450→19.834MiB |
| combined | 17.203→1.344MiB | 31.456→19.834MiB |

控制器仅以管理员令牌启停本次专用 WPR 会话和调用 RAMMap `-Es`、`-Et`；
被测 vimg 使用普通用户令牌。会话名为 `VimgColdPhase23` 和
`VimgColdPhase23Final`，均已停止，两个控制器均已退出。
全部 96 条 ETW 日志 `EventsLost=0`；每一次冷测都观察到素材、EXE 和 libav
DLL 的 DiskIORead，紧接的热测在这三类路径上全部为 0 字节。
读取量按文件路径和进程墙钟区间统计，包含系统代为发起的读取/预读；
没有把进程逻辑读取字节数当作磁盘读取。

最终组 RAMMap 完成到启动间隔为 3.47–23.71ms；standby 从 GiB/MiB 级
清到 0.207–0.246MiB，每次清理命令退出码均为 0。结果如下：

| 最终组冷态资源中位数 | 基线 | 最终包 |
| --- | ---: | ---: |
| 系统 CPU | 13.2% | 11.1% |
| vimg 进程 CPU 时间 | 125.0ms | 78.1ms |
| 进程硬缺页 | 40.0 | 18.5 |
| 素材读盘 | 17.203MiB | 1.395MiB |
| EXE 读盘 | 11.250MiB | 11.445MiB |
| libav 读盘 | 30.773MiB | 19.497MiB |

进程 CPU 时间来自 GetProcessTimes，受 Windows 计时粒度限制。最终冷态样本（按执行顺序，ms）：

- baseline：165.6、169.8、187.3、163.2、163.4、176.1、160.2、166.2。

- candidate：147.7、138.6、116.0、114.2、117.9、113.5、110.6、112.8。

### 功能验收与选帧变化

- 既有 139 组预览/回退对照，加新增 24 组，共 163 组通过：141 次原生输出，
  22 次保留回退协议（其中 1 次双方都无图）。实际输出使用 FFmpeg 严格解码为
  RGB 并验证数据长度、尺寸、方向及元数据。JPEG/RGB 哈希差异只记录；
  `--exact` 可额外启用历史图像对照。
- 22 组输出与原 FFmpeg 图像不同：包括稀疏 Cues、部分开放 GOP、动态分辨率，
  以及原路径在结尾没有后续关键帧而新路径可回到前一关键帧的情况。
  稀疏 Cues 删除 10 秒索引后，目标 2 秒会选 20 秒帧，符合新规则。
  主素材全部已测位置仍与原图一致。
- 新增 HEVC IDR/BLA/CRA、长 GOP、1080p/4K、损坏输入与动态配置素材。
  BLA 为 CRA 素材修改相容的 NAL 类型并重算容器 CRC 的确定性合成用例；
  不能替代所有真实多层/复杂 HEVC 的覆盖。未知结构保持正常解码/回退。
  4K 和动态分辨率输出另做了目视检查，无明显损坏。
- Rust 原生测试 **89 passed / 7 ignored**，默认构建 **68 passed / 4 ignored**。
  新测试覆盖 NAL 截断、混合图像、多 slice、多层、异常/缺失 PTS、损坏标记，
  以及真实 AVPacket 的 NEW_EXTRADATA 侧数据禁用提前排空。
- 17 项协议检查通过：无外部 ffmpeg/ffprobe 仍可原生预览、上界响应、参数错误、
  同源输出拒绝、坏文件、发布失败和旧缓存保护。4 组 Lua 插件测试通过，
  覆盖元数据复用、能力缓存、刷新、取消和陈旧结果处理。
- 最终确定性 DLL 再次通过全部 89 项原生单测和 24 个新增图像用例。
  精简库初测曾因测试专用 `null` 滤镜被裁掉而失败；测试改为生产库已有的
  透传 `format=rgb24`，保留原帧缓冲引用计数/释放断言，不为测试增加运行库依赖。
  动态分辨率素材另用显式测试选项验证当前帧尺寸边界与显示比例；固定分辨率
  素材仍要求与原 FFmpeg 的尺寸相同。

原始 VCS 命令也已验证：

```powershell
vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output <unique>.avif
```

基线与最终包先各预热一次，再交错各测 4 次，中位数 **981.9→982.7ms**，
没有声明 VCS 加速。默认无原生 feature 的 release 也完成同一命令和 capability
响应检查（单次 1815.4ms，仅作功能检查）。所有输出 SHA-256 均为
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
AVIF 动画流 `v:1` 为 30 帧、852×480、20fps、time base 1/10240，PTS 为
0、512、…、14848，帧 duration 全部一致；全动画严格解码通过。
初次检查误选 `v:0` 的主静态图得到 1 帧，改为明确检查动画流后通过。

### 构建与复现

```powershell
$env:PKG_CONFIG_PATH='D:/ffmpeg-dev/ffmpeg-8.1.2-full_build-shared/lib/pkgconfig'
cargo build --release --features in-process-decode
python -B -X utf8 scripts/build-preview-runtime.py --exe target/release/vimg.exe --runtime-dir D:/ffmpeg-dev/libav-deploy --output-dir target/preview-runtime --build-root target/preview-ffmpeg-clean
```

输出目录必须不存在；旧实验目录不会被覆盖。需要 Python 3.12+、Git Bash、
MinGW GCC/make、NASM，可用参数覆盖路径。实际工具链为 GCC 15.2.0，
编译器/NASM 版本及配置参数记录在 manifest；固定工具链重建，跨工具链哈希
不作相同承诺。`--filter-dll` 可独立打包已构建的 DLL，仍做 ABI/滤镜检查。
未通过检查的包保留 `INCOMPLETE`，不能被标为成功。

脚本固定 [FFmpeg 8.1.2 官方源码](https://ffmpeg.org/releases/ffmpeg-8.1.2.tar.xz)，
SHA-256 `464beb5e7bf0c311e68b45ae2f04e9cc2af88851abb4082231742a74d97b524c`。
配置使用 `--disable-everything --disable-autodetect --enable-shared --disable-static`，
仅启用所需滤镜/依赖，不构建 FFmpeg 命令行程序；`-static-libgcc` 避免增加编译器
运行时 DLL，`--no-insert-timestamp` 消除 PE 构建时间戳。
最终 avfilter 两次独立重新链接的 SHA-256 完全相同：

`29fe462b228ce8e1c6f3293bc243a2ecb4e59d96440fe00987946b3046e38f31`。

保留库版本为 avcodec 62.28.102、avformat 62.12.102、avutil 60.26.102、
swscale 9.5.102；新 avfilter 11.14.102。版本/滤镜集合用独立子进程加载检查，
避免 Windows 复用已加载 DLL 而检错运行包。四个保留核心库的 SHA-256 不变。

主要二进制身份（均只留本地，不入 Git）：

| 版本 | SHA-256 |
| --- | --- |
| 基线 2bdff6c | `9597000837733f9e828339cbe610776720e596cd711541fb08a4886ec66d990e` |
| 仅减少前置解码 | `055eab31a5746b9d0f0748cf71820425526ccb59e5197dd55af0e52a476d61f8` |
| 快速定位、无 HEVC 排空 | `f44175f4a67908b9ee07b149a67677196ba0de63d79cb5f3d4f49d815d9bc42a` |
| 最终原生 EXE | `2fa1e409ff996056c1dfa17f37615a6b55cd4e1d4976c011c9a9ffffc4c3ca7b` |

复现热测与新增素材验证：

```powershell
python -B -X utf8 scripts/bench-static-preview.py --baseline <baseline/vimg.exe> --candidate target/preview-runtime-repro/vimg.exe --video sample/input.mkv --output-dir <new-result-dir>
python -B -X utf8 scripts/test-preview-fast.py --vimg target/preview-runtime-repro/vimg.exe --fixtures <fixture-dir> --output-dir <new-test-dir>
```

性能/验证证据位于 `.scratch/startup/phase23/`：`warm-*`、`repeat-warm-*`、
`third-decode-timings`、`control-*` 保存每次耗时/系统 CPU/进程 CPU/哈希/阶段计数；
`cold/` 与 `cold-final/` 保存受限管理员控制器、WPR profile、普通权限测量器、
RAMMap 结果、96 份 ETL、逐事件 JSON 和 `analysis.json`。冷测运行前通过
`Start-Process ... -Verb RunAs -WindowStyle Hidden` 启动对应 `admin.py`，
普通权限运行 `matrix.py`，完成后 `analyze.py` 校验读盘及无丢失事件；
分析器沿用 `phase19/analyzer`。每次复现使用新目录及独立 ETW 会话名。
`verified-*`、`boundary-*`、`final-fast`、`repro-fast`、`protocol-results.json`、
`vcs-verified/results.json` 保存功能结果。独立构建源和日志位于
`target/preview-ffmpeg-repro/`，最终包 manifest 记录所有文件的大小及哈希。

四项优化均有对应收益证据并通过功能验收，进入本地独立运行包；没有修改
全局 FFmpeg/vimg 或 Yazi 安装。实验二进制、临时素材、ETL、构建产物均不入库。
提交仅包含实现、测试、构建/测量脚本、README 和本报告；保留并排除现有
`.serena/project.yml` 修改。

## 2026-10-23：进一步性能调查——先减少目标之前的解码

基线为 `2bdff6c`，本轮围绕首次静态预览开展测量和可撤销原型实验，
没有把实验逻辑合入正式代码。`src/command/preview.rs` 已恢复原始字节，
`target/release/vimg.exe` 已恢复本轮基线；实验保存在 `.scratch/startup/phase22/`。
当前原生 release 的 SHA-256 为
`9597000837733f9e828339cbe610776720e596cd711541fb08a4886ec66d990e`。

### 结论和建议顺序

1. **优先减少目标之前的图像重建。** 保留原 seek、顺序读包及参数处理，
   目标之前暂时使用 `AVDISCARD_ALL`，到目标附近恢复 `AVDISCARD_NONKEY`。
   release 原型在较低后台负载的交错复测中，首次预览热态中位数
   **149.3→125.8ms（−15.8%，减少 23.5ms）**；读包仍为 199 个，
   读包与解码阶段 **65.4→40.9ms**。收益主要来自省去前一个关键帧的重建。
   正式实现应先限定到能验证完整 IDR 的 H.264 路径；缺失/异常 PTS、
   开放 GOP、配置变化、交错图像及无法确认安全性的输入应重走原路径。
   当前原型按包 PTS 切换 discard，尚未实现这些上线保护，不能把有限素材
   对照通过当作对所有视频的正确性证明。
2. **再调查启动侧和 libav 构建裁剪，尤其面向磁盘冷启动。** 当前
   `--version` 的 12 次热态中位数也有 55.4ms；预览内部计时之外约 57ms。
   PE 导入表确认 EXE 直接依赖 avcodec、avformat、avfilter、swscale、avutil。
   本机 avcodec/avfilter DLL 文件约 92.9/118.6MiB；上一轮 ETW 已观察到
   冷态 libav 实际磁盘读取中位数约 27.6MiB。可对照构建仅保留所需能力的
   libav，或评估独立精简静态预览助手。DLL 文件大小不是启动时实际读盘量，
   57ms 也包含进程创建、参数解析、输出和退出，不能全部归因为 DLL。
   裁剪必须兼顾现有 Capture 后端需要的滤镜/编解码器。
3. **HEVC 提前排空作为后续方向。** 当前提前排空只覆盖 H.264；既有
   HEVC 素材仍可能读 94/195 个包才返回所选帧。但现有 HEVC 测试素材很小，
   先前读包/解码仅约 2–3ms，不能据此推断真实 4K HEVC 的收益。
   应先收集有代表性的长 GOP HEVC，再区分 IDR、CRA、leading pictures
   等情况验证，不直接复用 H.264 的判断。
4. **不采用无条件向后 seek，也不优先缩短探测。** 向后 seek 已有可复现
   的选帧错误；当前完整流信息探测仅约 6ms，缩放与 JPEG 编码合计约 1–2ms，
   均小于前置解码及进程启动开销。

### 基线及原型方法

基线反馈命令：

```powershell
python -B -X utf8 .scratch/startup/phase22/profile.py baseline target/release/vimg.exe
```

每次启动新 CLI 进程、输出到新 JPEG 文件；主素材 `sample/input.mkv`，
参数保持 `preview --skip 0 --max-width 600 --max-height 900 --quality 75`。
首次诊断为 2 次预热加 8 次测量：墙钟 150.4ms，native prepare 89.7ms，
stream_info 5.9ms，seek 9.7ms，read_decode 64.7ms；全部选中 PTS 169378，
读包 199 个，与既有 JPEG golden 相同。

随后逐项改变一个变量：

- `forward-prototype.rs`：仅把 `input.seek(target, ..target)` 改为
  `input.seek(target, target..)`。主素材只读 1 个包、仍选中同一 JPEG，
  但兼容性反例使其不能作为通用替换。
- `discard-prototype.rs`：保持原 seek，在发送每个包前，根据包 PTS 是否
  小于目标切换 `All/NonKey`。包仍送入解码器，不直接丢弃整个包。
  FFmpeg 8.1.2 的 [H.264 NAL 处理](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/h264dec.c)
  和 [slice 跳过逻辑](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/h264_slice.c)
  支持这一候选方向，但其他编解码器及动态状态不能仅靠类推确认。

开发构建仅用于筛选、计数和图像对照；下面正式耗时比较均使用 release。
原型 release SHA-256 为
`055eab31a5746b9d0f0748cf71820425526ccb59e5197dd55af0e52a476d61f8`。

### Release 热态交错比较

每轮、每种计时模式先各预热 2 次，再按 ABBA/BAAB 顺序各测 12 次。
默认模式不启用 `--timings`；阶段计时另测，不能跨轮拼接成同一次测量。
计时从启动子进程前到 stdout/stderr 读取及进程退出完成；系统 CPU 含测试自身。

| 轮次 / 指标 | 基线 | 减少前置解码原型 |
| --- | ---: | ---: |
| 第一轮，默认 CLI 中位数 | 199.1ms | 160.2ms（−19.5%） |
| 第一轮，默认 CLI 范围 | 169.7–278.9ms | 143.8–237.0ms |
| 第一轮，默认模式系统 CPU 中位数 | 63.25% | 56.26% |
| 复测，默认 CLI 中位数 | 149.3ms | 125.8ms（−15.8%） |
| 复测，默认 CLI 范围 | 145.2–157.6ms | 120.7–149.2ms |
| 复测，默认模式系统 CPU 中位数 | 22.99% | 24.40% |
| 复测，启用阶段计时的 CLI 中位数 | 149.1ms | 124.3ms |
| 复测，native prepare 中位数 | 91.4ms | 66.9ms |
| 复测，read_decode 中位数 | 65.4ms | 40.9ms |
| 复测，stream_info 中位数 | 6.3ms | 6.1ms |
| 复测，seek 中位数 | 9.9ms | 9.7ms |
| 复测，prepare 之外耗时中位数 | 57.6ms | 57.2ms |

第一轮后台负载明显偏高，全部数据保留；复测前 5 个两秒 CPU 窗口为
20.1%–31.5%。两轮结果均支持减少前置解码有收益，不能用不同负载轮次
的绝对耗时直接比较。两轮共 112 张输出（含预热、默认/诊断模式、两版本）
全部匹配既有主素材 JPEG SHA-256：
`ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。

这些是 **OS 文件缓存热态、新 CLI 进程的首次预览**，不含 Yazi DDS 或显示。
本轮没有清理 Windows 文件缓存，也没有重做 ETW 磁盘冷态测量。
减少 CPU 工作可能帮助冷态，但没有据此声称具体的冷启动改善幅度；
读包数没有下降，不能声称减少了素材磁盘读取。

### 向后 seek 的反例及正确性验证

既有 139 组对照中，向后 seek 原型的 114 个原生输出仍与 golden 相同，
但开放 GOP MP4 在 skip=79、80 时从原生成功变成了 seek 失败后回退。
进一步构造稀疏 Cues 素材：复制既有 24 秒 closed-long.mkv，把 10 秒
CuePoint 改为同尺寸 Void 并重算 Cues CRC32；视频包、文件长度及其他
偏移不变，剩余索引时间为 0、20 秒，实际关键帧仍为 0、10、20 秒。

目标为 1 秒时：

- FFmpeg 和当前正式代码选中 10 秒帧；
- 向后 seek 原型只读 1 包，错误选中 20 秒帧，JPEG 与 RGB 哈希均不同；
- 减少前置解码原型仍选中 10 秒帧，与 FFmpeg 的 JPEG/RGB 完全一致。

这与 [Matroska seek 使用 Cues 索引条目定位](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavformat/matroskadec.c)
的实现相符。找到“一个有效 IDR”不足以证明它就是应选的第一个关键帧；
只检查最终帧非损坏和 PTS 大于目标，无法发现这个错误。

减少前置解码的 release 原型复用了上一轮已由 FFmpeg 验证的 139 组 golden：
116 个原生 JPEG 字节一致，已记录的原生 PTS 均一致；23 组回退的元数据和
能力状态不变，本轮未重复执行这些回退的 FFmpeg 图片生成。
另对新增稀疏索引案例直接运行 FFmpeg/JPEG/RGB 对照，通过。
这是可行性验证，不替代正式实现后的异常配置、时间戳、回退和磁盘冷态测试。

### 本地证据

`.scratch/startup/phase22/` 内保留：
`profile.py` / `baseline.json`、`paired.py` / `paired.json` / `paired-repeat.json`、
`compare.py` / `discard-release-compare.json`、`sparse_cues.py` / `sparse-cues.mkv`、
`sparse-forward/results.json`（预期失败反例）、`sparse-current/results.json`、
`sparse-discard-release/results.json`、`imports.json`、`version-timing.json`，
以及两个实验源码和独立二进制。实验目录已被既有 scratch 规则忽略。

## 2026-10-14：提前取出已到达的 H.264 IDR，减少额外 GOP 读取

基线为 `2569fdb`。在确认目标 H.264 IDR 已送入解码器后，提前排空其
重排序队列，减少为等待目标帧输出而继续读取后续 GOP 的工作。主素材
读取包数 **499→199（−60.1%）**，JPEG 保持逐字节一致。
**直接启动 CLI 生成首次静态预览**，各 8 次冷缓存中位数
**247.3→210.8ms（−14.7%）**，紧接的热缓存中位数
**217.2→183.9ms（−15.3%）**。包含进程创建、探测、取帧、写图、元数据
输出及进程退出；本节没有完成 Yazi/DDS/显示调用的端到端复测。

### 定位与实现

原路径从目标 164.000s 前的关键帧开始解码，跟踪结果如下：

| 读到的包编号 | 关键包 PTS | 此时原解码器返回的关键帧 PTS |
|---:|---:|---:|
| 1 | 161.119s | 无 |
| 199 | 169.378s | 无 |
| 308 | 173.924s | 161.119s，早于目标，丢弃 |
| 499 | 181.890s | 169.378s，最终选中 |

目标画面在第 199 包已经到达，额外 300 包并不是为了找到画面。
包内容检查确认这些关键包含普通 SEI 和 H.264 IDR NAL。FFmpeg 的
[H.264 输出队列源码](https://raw.githubusercontent.com/FFmpeg/FFmpeg/n8.1/libavcodec/h264_slice.c)
保留解码后画面以满足重排序；其
[send/receive API](https://ffmpeg.org/doxygen/8.0/group__lavc__encdec.html)
允许发送空输入排空已缓存的帧。本次采用公开 API，不修改解码器的
重排序参数，也不前跳容器索引。

- 保留原 seek 方向、完整探测、时间戳换算及 `NonKey` 解码策略。原 seek
  到目标之前这一段仍会读取，以维持原有参数/SEI 和选帧行为。
- 仅检查目标处及之后的第一个关键包；要求 AVC 长度前缀已知、关键包
  无其他标志，逐个验证完整 NAL 边界，所有 VCL 均为 IDR。允许普通
  SPS/PPS、SEI、AUD、filler；混合非 IDR、扩展 NAL、未知类型、畸形或
  截断长度继续原路径。遇到新的 extradata 后停用本次提前排空。
- 先接收已有输出，只有仍未得到目标画面时才发送 EOF 排空，避免
  `send_eof` 的 EAGAIN。排空所得帧必须为非损坏关键帧，PTS 与候选包
  一致，并通过原有隔行、旋转和像素格式检查；不满足则复用元数据回退
  FFmpeg，不发布未经检查的原生图像。
- HEVC、恢复点/开放 GOP 的非 IDR、未知 framing 保持原路径。
  无 B 帧素材若立即有输出，就直接返回，不需要排空。没有引入常驻
  worker，也没有修改 `vcs`、`serve` 或生产插件。
- `--timings` 增加 `key_packets`、`early_drain`、`selected_pts`
  （视频流 time_base 单位）。对照脚本增加可重复的 `--skip` 参数，
  便于验证关键帧前后的位置。

最终 release 二进制各预热一次，再交错测量各 4 次 `--timings`：

| 指标，中位数 | 基线 | 优化后 |
|---|---:|---:|
| 打开容器头 | 2.379ms | 2.607ms |
| 完整 stream_info | 7.835ms | 7.789ms |
| seek | 13.068ms | 12.894ms |
| 读包与解码 | 108.884ms | 73.101ms |
| 原生准备 total_ms | 143.469ms | 104.612ms |
| 包数（每次相同） | 499 | 199 |
| 提交的关键包数 | 4（原路径跟踪） | 2 |

优化后均报告 `early_drain=true`、`selected_pts=169378`，time_base=1/1000。
上述阶段计时不含进程启动，不能拿来代替以下 CLI 整段耗时；各阶段
中位数也不能相加当作整段中位数。

### 冷缓存方法与结果

环境沿用 Windows 11、Samsung SSD 980 PRO 2TB NVMe、FFmpeg/libav 8.1.2，
素材 `sample/input.mkv`，静态图参数 600×900、质量 75、skip=0。两臂
分别使用隔离目录中的基线/候选 EXE，每次启动新进程，不传 `--timings`。
每轮用一次性 UAC 助手运行 RAMMap `-Es`、`-Et`，清理系统文件工作集
和待机页，再生成冷态图；随即生成另一张热态图。vimg 始终为普通用户
进程。顺序为旧/新/新/旧/新/旧/旧/新，两遍，共 16 轮、32 张图。

清理前待机页 49.02–2201.05MiB，清理后 0.23–0.66MiB；正式冷态调用在
清理后 9.0–21.6ms 内开始。全部 RAMMap 调用成功。WPR 记录 DiskIORead、
文件名、进程和硬缺页等事件，通过 TraceEvent/ETLX 解析路径，正式
**16 份 ETL 均 EventsLost=0**。计时期间未并行构建、正确性测试或 ETL
分析，其他桌面程序仍在运行。

| 指标，各 8 次 | 基线 | 优化后 |
|---|---:|---:|
| 冷态 CLI 中位数 | 247.3ms | 210.8ms（−14.7%，减少 36.5ms） |
| 冷态范围 | 236.0–614.4ms | 199.6–231.7ms |
| 紧接热态 CLI 中位数 | 217.2ms | 183.9ms（−15.3%，减少 33.3ms） |
| 热态范围 | 212.0–236.7ms | 178.3–194.8ms |
| 冷态系统 CPU 中位数，含测试自身 | 23.18% | 27.60% |
| 热态系统 CPU 中位数，含测试自身 | 25.11% | 27.50% |

按 Popen 前至进程退出窗口、按文件路径合计实际存储读取，包含系统预读。
每轮冷态都读到了素材、对应 EXE 和 libav DLL；中位数如下，单位 MiB：

| 读取对象 | 基线冷态 | 优化后冷态 | 基线热态 | 优化后热态 |
|---|---:|---:|---:|---:|
| 主素材 | 31.00 | 17.20 | 0 | 0 |
| vimg EXE | 11.17 | 11.30 | 0 | 0 |
| libav DLL 合计 | 27.21 | 27.63 | 0 | 0 |

素材读取中位数减少约 **44.5%**，实际范围为旧版 31.00–31.43MiB、
新版 17.20–18.55MiB；所有热态对这三类文件均无磁盘读取。包数降幅
与字节降幅不同，包大小、缓冲和预读均会影响结果。这里验证的是 Windows
文件缓存冷态，未重启整机或清空 SSD 控制器缓存；不声称每次落到 NAND。

全部有效样本如下。首轮旧版 614.4ms 保留，没有剔除异常慢启动。第 5 轮
控制响应文件出现短暂 PermissionError，尚未开始取图；停止其跟踪，
为控制文件读取加入有界重试后，重新清缓存完成该轮，前 4 轮有效样本
继续计入。未取图的尝试保留在 `cli-4-candidate/`，正式重试为
`cli-4-candidate-retry/`。

| 顺序 | 版本 | 冷态 ms | 紧接热态 ms | 系统 CPU 冷/热 % |
|---:|---|---:|---:|---:|
| 1 | 旧版 | 614.4 | 215.5 | 27.65 / 33.83 |
| 2 | 新版 | 221.9 | 181.1 | 29.26 / 32.24 |
| 3 | 新版 | 231.7 | 194.8 | 23.06 / 28.21 |
| 4 | 旧版 | 253.9 | 236.7 | 22.86 / 29.72 |
| 5 | 新版 | 205.1 | 178.3 | 20.05 / 21.46 |
| 6 | 旧版 | 236.0 | 213.1 | 23.00 / 13.38 |
| 7 | 旧版 | 242.8 | 212.0 | 15.83 / 22.52 |
| 8 | 新版 | 199.6 | 179.3 | 28.16 / 16.11 |
| 9 | 旧版 | 242.4 | 220.5 | 21.45 / 18.34 |
| 10 | 新版 | 204.6 | 194.2 | 28.69 / 21.92 |
| 11 | 新版 | 212.8 | 191.0 | 31.29 / 31.18 |
| 12 | 旧版 | 255.0 | 216.9 | 36.13 / 21.47 |
| 13 | 新版 | 208.8 | 181.3 | 20.92 / 26.79 |
| 14 | 旧版 | 240.4 | 221.0 | 30.84 / 27.70 |
| 15 | 旧版 | 251.7 | 217.6 | 23.36 / 30.19 |
| 16 | 新版 | 215.1 | 186.5 | 27.03 / 31.21 |

在冷态测量前，另做无 ETW 的 OS 热缓存 CLI 交错对照，各 8 次，中位数
**190.0→154.8ms（−18.5%）**；系统 CPU 中位数 10.86%→10.39%。
范围分别 179.4–315.8ms、144.7–312.5ms，慢样本全部保留。外部负载
与 ETW 测量批次不同，只对比同批两臂，不跨批相减或混为一组。

### 图像与协议验证

- `cargo test --features in-process-decode`：82 通过、7 忽略；
  `cargo test`：68 通过、4 忽略。新增 4 项检查覆盖 AVC 长度前缀、
  多切片 IDR、恢复点/混合/扩展 NAL，以及截断/畸形输入。
- 最终 release 共 **139 组**图像对照：116 次原生成功、17 次回退有图，
  **133 对 JPEG 和解码 RGB 哈希全部一致**；另 6 组双方都无图。
  元数据继续与完整 ffprobe 对照，覆盖原有 23 素材、尺寸/质量边界，
  新增闭合长 GOP、开放长 GOP、4 切片、无 B 帧素材及 18 个 offset，
  主素材另测 7 个位置。默认无计时的主素材也验证通过。
- 新增素材中，开放 GOP 全 18 组维持正常读取，没有提前排空；无 B 帧
  全 18 组直接返回已有帧。闭合长 GOP 的最后 2 个位置双方都无图，
  没有强行制造一个较早画面。旧有 HEVC 继续原路径并保持一致。
- 17 项协议/错误检查通过，含参数边界、损坏/缺失输入、源目标相同、
  缓存原子替换、失败保留旧图和无外部 FFmpeg 助手的原生执行。
  本次修改的 Rust 文件格式、Python 语法及限定文件的空白检查通过。
  原有 `capture.rs` 全库格式差异和既存编译警告不在此次修改范围。
- 用户原始命令 `vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output <独立输出>.avif`
  旧/新/新/旧各 2 次，中位数 **1.016→1.019s**，4 张 AVIF 哈希均为
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
  该路径未修改，小幅波动不作为优化收益。

32 张冷/热图、16 张热态 CLI 图、10 张阶段计时图的主素材 JPEG 均匹配
`ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
最终 EXE SHA-256 为
`9597000837733f9e828339cbe610776720e596cd711541fb08a4886ec66d990e`；
基线为 `37dc534f899669458ad84d2cd2b21342b3ebbeb949f9ca4ebf77684034359018`。

### 测量边界与留存

最初尝试真实 Yazi 基准时，它无法在沙箱内访问共享状态目录
`AppData\Roaming\yazi\state`，尚未生成预览；自动审批随后拒绝放宽该
访问，原因是隔离配置未能证明同时隔离持久状态。本轮没有绕过拒绝，
也没有修改共享状态来完成基准，改为仅在工程目录写入结果的 CLI 对照。
因此 **上述百分比不代表 Yazi 的 DDS 或显示延迟改善**。失败尝试
`formal-0-baseline/` 未纳入有效样本。未完成 Yazi 端到端验证是本轮限制。

本机忽略目录 `.scratch/startup/phase21/` 保存：`trace.log`、
`drain.log`、`key-nals.json`、`trace-drain-prototype.rs`（定位原型），
`profile.json`、`final-bench.json`、`cold-analysis.json`、`cli-*/result.json`、
`purge.json`、`disk.etl`、`io.json`；脚本 `pilot.py`、`validate.py`、
`cold_cli.py`、`analyze_cli.py`、`profile.py`、`final_bench.py`、`admin.py`、
`control.py`、`cold.wprp`，以及测试日志和比对图像。ETL 解析复用
`.scratch/startup/phase19/analyzer/`。这些原始实验产物不加入 Git。
正式实现、测试脚本、README 和本节报告随提交保存；历史报告原始字节保留。
管理员助手已确认退出、所有独立跟踪已停止。用户安装的 EXE/插件未覆盖，
原有 `.serena/project.yml` 修改未纳入此次提交。


## 2026-10-14：静态预览分阶段诊断与常驻原型评估

基线为 `d14afdc`（生产代码同 `f110496`）。本轮新增可选
`vimg preview --timings`，并完成常驻静态 worker 原型的进程内、真实 DDS
及磁盘冷缓存对照。**最终只保留诊断能力，不将常驻原型接入默认服务。**
默认 PATH 下，原型重复空缓存预览仅改善约 3.3%；直接调用实际 `ya.exe`
时改善约 19.3%，但将 worker 自身启动计入后，未证明磁盘冷启动收益。
不能将预先启动的 worker 请求耗时写成整个服务首次启动耗时。

### 分阶段计时与实现范围

`--timings` 在 stderr 输出一行 `vimg-preview-timing {JSON}`；stdout
仍为原有元数据。记录阶段毫秒数、总准备时间、读包数和 PID。默认不开启
时不读取计时器、不分配阶段数组、不输出诊断，仍使用原有 libav 打开函数。
显式开启时拆分 `avformat_open_input` / `avformat_find_stream_info` 两步，
保留完整探测及 `scan_all_pmts`，打开后的输入通过 RAII 管理，失败会释放。
错误及不支持的素材可输出部分阶段。标准构建接受参数，但只返回原有能力
缺失响应，不输出原生计时。

`total_ms` 从原生准备函数进入到输入清理结束，**不含**进程启动、命令行
解析、stdout JSON 序列化、诊断输出及进程退出。`read_decode` 合计读包和
解码；`decoder_release` 包含最后的 JPEG 数据复制及解码器/滤镜/编码器
清理，并非纯解码器析构。阶段中位数不能相加冒充总耗时中位数。

沿用本机 Windows 11、FFmpeg/libav 8.1.2、Yazi/Ya 26.1.22，主素材
`sample/input.mkv`，600×900 上限、质量 75、skip=0。OS 缓存已热时，
12 次新 CLI 进程与两个常驻进程交错测量；每个常驻进程执行 30 次请求，
重复请求统计排除各自首个，共 58 次。以下为阶段中位数：

| 阶段 | 新 CLI 进程 ms | 常驻重复请求 ms |
|---|---:|---:|
| libav 初始化 | 0.011 | 0.004 |
| 打开容器头 | 2.401 | 1.207 |
| 完整 stream_info | 7.596 | 5.706 |
| 元数据处理 | 0.358 | 0.366 |
| 解码器初始化 | 0.128 | 0.102 |
| seek | 13.453 | 11.909 |
| 读包和解码 | 111.602 | 112.454 |
| 滤镜准备 / 缩放 | 0.521 / 0.585 | 0.302 / 0.556 |
| JPEG 准备 / 编码 | 0.101 / 0.682 | 0.091 / 0.570 |
| 编码后清理 | 1.039 | 1.172 |
| 发布缓存 | 3.450 | 3.010 |
| 输入释放 | 2.795 | 2.893 |
| 原生准备 total_ms | 144.981 | 140.624 |
| 外部计时：CLI 启动至退出 / 常驻请求至响应 | 220.838 | 141.367 |

每次读取 499 个包。当前主要成本是读包/解码，探测仅约 6–8ms，滤镜和
JPEG 各阶段约 0.1–0.7ms。常驻的优势主要在复用进程，而非减少这些阶段。
上述常驻请求通过 stdin/stdout，不含 DDS，不等于用户实际等待时间。
两个 worker 从创建到 ready 分别为 **818.3ms、88.9ms**，首请求本身为
147.2ms、151.4ms；保留首个异常慢启动，不能因 OS 已热就保证启动很快。

30 次请求后，两进程工作集由 25.64/25.02MiB 到 42.85/27.06MiB，
峰值 52.32/51.91MiB，PrivateUsage 由 22.39/22.54MiB 到
39.95/24.89MiB。这只是短期观察，不足以证明长期无泄漏或内存稳定。

### 真实 Yazi / DDS 对照

实验插件通过 `ps.pub_to` 发请求，原型复用同一 `Preview::prepare()`，
用持久 `ya sub` 接收、每请求一次 `ya pub-to` 回传。插件每 5ms 检查
响应。原型未实现生产所需的容量限制、最新兴趣取消和可靠就绪握手；没有
替换当前 `serve`。每组使用 8 个隔离 Yazi，旧/原型/原型/旧/原型/旧/旧/原型，
每个首次加 5 次重复，共 48 张图；每次仅清理隔离的图片缓存。worker 在
测量前启动，收到订阅日志后另等 300ms，**启动及等待均不计入下表**。
Yazi 的图像延迟为 30ms，关闭测试配置的预加载和动画服务。

第一组沿用默认 PATH 的 Scoop `ya` shim；第二组仅给 worker 的 PATH
前置 `D:\Scoop\apps\yazi\current`，直接调用实际 `ya.exe`。各组同期对照：

| 指标 | 默认 PATH：旧版→原型 | 实际 ya.exe：旧版→原型 |
|---|---:|---:|
| 首次 peek→显示调用，中位数，各 4 次 | 220.9→211.5ms | 217.6→184.8ms |
| 重复空缓存 peek→显示调用，中位数，各 20 次 | 217.0→209.9ms（−3.3%） | 223.3→180.1ms（−19.3%） |
| 重复 P95 | 240.7→230.5ms | 234.8→192.6ms |
| 重复 reveal 启动前→显示调用，中位数 | 250.5→244.3ms | 258.2→213.3ms |
| 重复期间系统 CPU 中位数（含测试自身） | 30.19→30.83% | 31.06→24.90% |

原型处理时间中位数分别为 145.0ms、139.6ms；启动通知子进程到其退出的
中位数分别为 73.6ms、39.7ms。UI 可以在 `ya` 退出前收到通知，因此
该时间并非全部位于显示关键路径，也不能直接与其他中位数相加。第二组
两臂 CPU 存在差别；两组外部负载也不同，不把跨组时间差全归因于 shim。
默认 PATH 旧版首次最高 410.0ms，原型最高 242.6ms，全部样本保留。
终端仍缺少 chafa，终点是 `ya.image_show` 调用，未计屏幕像素绘制。

### 将 worker 创建计入的磁盘冷启动

本节两臂均用同一原型 EXE（开启 `--timings`），分别走 CLI 与常驻
stdin/stdout 模式，以隔离复用进程这一因素。每轮用 RAMMap `-Es -Et`
清理系统文件工作集及待机页，随后开始计时并创建进程；冷态 worker 包含
创建、ready、首请求到响应的全部时间，CLI 包含创建到退出。每轮随后
再请求一次相同视频生成新的图片。**这里不含 Yazi/DDS，只是组件对照；
不能当作常驻服务的端到端冷态成绩。**

| 顺序 | 模式 | 冷态 ms | 随后热态 ms | 系统 CPU 冷/热 % |
|---|---|---:|---:|---:|
| 1 | CLI | 291.2 | 252.4 | 36.15 / 35.63 |
| 2 | worker | 280.2 | 145.5 | 27.79 / 25.24 |
| 3 | worker | 280.9 | 155.8 | 29.10 / 37.75 |
| 4 | CLI | 269.5 | 228.8 | 23.87 / 38.65 |
| 5 | worker | 277.0 | 149.7 | 28.98 / 40.12 |
| 6 | CLI | 261.3 | 231.9 | 27.59 / 33.61 |
| 7 | CLI | 246.1 | 209.8 | 26.40 / 22.83 |
| 8 | worker | 247.5 | 144.9 | 37.93 / 16.62 |

各 4 次冷态中位数 **CLI 265.4ms，worker 278.6ms**；样本少且负载波动，
结论是本轮未证明冷启动收益。worker 自身启动到 ready 为 103.3–135.1ms，
并未消失。随后热态中位数 CLI 230.4ms、worker 147.6ms；后者复用已经
运行的进程，且未支付 DDS 通知成本。

清理后待机页 0.23–0.65MiB，全部 RAMMap 调用成功。沿用上节 WPR 内核
磁盘跟踪与 TraceEvent/ETLX 文件名解析，8 份 ETL 的 EventsLost 均为 0。
统计窗口是调用 Popen 前至响应/退出，按目标路径合计真实 DiskIORead，
包含系统预读取。每轮冷态都实际读取主素材 **31.00MiB**、原型 EXE
**11.37–11.40MiB**、libav DLL **30.72–31.26MiB**；紧接的热态对这三类
文件均为 0。这是 Windows 文件缓存冷态，未重启、未清空 SSD 控制器缓存，
不能据此声称每次都读取 NAND。没有在计时期间并行编译、解析 ETL 或跑测试。

### 最终提交与验证

最终保留 `--timings`、README 说明，以及静态对照脚本的 `--timings`
断言和结果留存。原型命令及实验插件不进入生产代码；默认插件、服务和
回退策略保持原实现。下一轮应先记录包的关键帧标记及目标/实际帧时间戳，
检查 499 次读包中的可省工作，再对 seek/解码路径作受限实验；继续验证
长 GOP、HEVC、起始偏移和输出逐字节一致性。当前数据不支持优先砍掉
完整探测，也不支持为约 2ms 的缩放/编码引入新的兼容性风险。

- 原生 Rust 测试 78 通过、7 忽略；标准构建 68 通过、4 忽略，均无失败。
- 23 个素材 × 2 个位置，启用计时共 46 组：31 次原生、13 次成功回退，
  44 对 JPEG/RGB 全一致；另 2 组双方均无图。默认不启用计时的主素材
  2 组也一致且无计时日志。尺寸/质量边界另 12 组，8 次原生、4 次回退，
  全部 JPEG/RGB 一致；元数据继续与完整 ffprobe 对照。
- 17 项协议/错误场景通过，包括参数边界、源/目标相同、缺失及损坏输入、
  不可写目标、原缓存保留、替换及临时文件清理。启用计时时成功/回退/错误
  路径均能读取有效诊断 JSON。标准构建在无外部助手的 PATH 下，带/不带
  计时参数均只返回能力响应，没有计时日志或输出图片。
- 本次修改的两个 Rust 文件 `rustfmt --check --edition 2024` 通过，
  Python 语法及限定到本次文件的 `git diff --check` 通过。全库
  `cargo fmt --check` 仍报原有 `capture.rs` 三处格式差异，本次未修改
  该文件；现有 `encode.rs` 的 unused_mut 与标准构建的 dead_code 警告
  未扩大到此次改动。

最终默认路径不传 `--timings`，在构建和正确性测试结束后独立执行
旧/新/新/旧/新/旧/旧/新两遍，各 8 次，图片缓存每次为空、OS 缓存已热。
新旧均每次启动进程。旧版→最终版中位数为
**224.7→217.1ms**，范围分别
204.9–407.9ms、
211.0–220.0ms，系统 CPU 中位数
31.20%→26.13%。
这是新增可选诊断后的默认路径检查，不将这组短测波动宣称为性能优化。
16 张主素材 JPEG 全部匹配黄金哈希，默认 stderr 无计时输出。

用户原始命令 `vimg vcs -c3 -H160 -n9 .\sample\input.mkv --output <独立输出>.avif`
再做旧/新/新/旧对照，各 2 次，中位数
**1.167→1.181s**，
系统 CPU 中位数 57.36%→60.46%。
4 张 AVIF 的 SHA-256 均为
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
该路径未修改，这组小样本仅检查兼容性，不用于宣称吞吐提升。

原型阶段共 184 张主素材 JPEG（72 次阶段测试、96 次真实 Yazi、16 次
冷/热对照），全部为 10,749 字节，SHA-256 匹配
`ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
原型 EXE SHA-256：
`67db3105cc0a5d1e6b93499fade8ccf6cd410c0444c950aad7003472b1710dfa`。
最终 EXE SHA-256：
`37dc534f899669458ad84d2cd2b21342b3ebbeb949f9ca4ebf77684034359018`。
基线 EXE SHA-256：
`00035953ebee904b5cefa8d00d5efecd929bf08495c4e9d3e1187cd503804f63`。

本机忽略目录 `.scratch/startup/phase20/` 保留原始数据及复测脚本：
`stages.json`、`warm-analysis.json`、`direct-analysis.json`、
`cold-analysis.json`，各轮 `result.json`、`events.log`、`worker.log`、
`purge.json`、`disk.etl`、`io.json`；脚本 `stages.py`、`prepare.py`、
`bench_yazi.py`、`run_bench.ps1`、`cold_first.py`、`analyze_cold.py`、
`admin.py`、`control.py`、`cold.wprp`。`prototype-tracked.patch` 与
`prototype-worker.rs` 配套保存原型源码，EXE 为 `prototype.exe`；
最终检查记录见 `validate.py`、`validation.log`、`verified-timings/`、
`protocol-results.json`、`final_bench.py`、`final-bench.json`。
这些本机实验文件未加入 Git；正式诊断功能和报告随本次提交保存。
管理员助手、测试 worker 和独立 WPR 会话均已结束。未覆盖用户安装的
EXE/插件，未修改全局电源、亲和性或预取设置。


## 2026-10-13：验证 Windows 磁盘冷缓存下的首次静态预览

对照旧版 `f07d9ed` 与新版 `f110496`，本轮只验证，不修改生产代码。
每轮清空 Windows 系统文件工作集和待机页后，真实 Yazi 首次静态预览
`peek→ya.image_show` 中位数 **330.6→204.1ms（−38.3%，减少 126.5ms）**。
包括外部 `ya reveal` 启动、DDS 传递和 Yazi 选中文件的整段中位数
**411.2→289.0ms（−29.7%）**。磁盘 ETW 证实每轮素材、vimg EXE、
libav DLL 均发生实际存储读取，旧版还读取独立 FFmpeg EXE。

### 冷态方法与证据

环境为 Windows 11、D 盘 NTFS / Samsung SSD 980 PRO 2TB NVMe。
素材、EXE、libav DLL 均在 D 盘；沿用上节 Yazi/Ya 26.1.22、FFmpeg/
libav 8.1.2、600×900、质量 75、图像延迟 30ms，关闭测试配置中的预加载
和动画服务。旧版仍通过 Scoop shim 调用原 FFmpeg，新版使用原生 preview。

1. 为每轮启动独立 Yazi，隔离配置、图片缓存和临时目录，初始不选中视频。
   在访问素材之前，用单独的 UAC 管理员助手依次运行微软签名有效的
   [RAMMap](https://learn.microsoft.com/en-us/sysinternals/downloads/rammap)
   `-Es` 和 `-Et`；所有调用退出码为 0。助手仅控制本轮缓存清理和跟踪，
   Yazi/预览进程保持普通用户权限。不会把管理员权限给生产服务。
2. 记录清理前后待机页：正式 16 轮由每轮清理前 140.0–2463.0MiB，降至
   清理后 0.23–10.63MiB；随后 82.3–127.1ms 内进入首次 peek。这个间隔
   包含 `ya reveal` 和 Yazi 自身处理，不在其间预运行 probe 或 preview。
3. 清理前启动独立 WPR 会话，内存模式记录 ProcessThread、Loader、
   DiskIO、DiskIOInit、FileIO、FileIOInit、Filename、HardFaults。
   [WPR 内核关键字说明](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/keyword--in-systemprovider-)
   区分了文件操作与磁盘 I/O。本轮以 **DiskIORead 的路径和传输字节**
   验证读盘，不使用进程逻辑读字节数冒充磁盘读。TraceEvent 3.2.8 经
   ETLX 解析回填文件名；16 份 ETL 全部 **EventsLost=0**。
4. 冷态图生成后切走，仅删除隔离目录内该图片，再次访问同一视频取得
   紧随其后的热态对照。每次仍启动新的助手进程；共 16 个 Yazi 进程、
   32 次生成，顺序为旧/新/新/旧/新/旧/旧/新，重复两遍，全部样本保留。

磁盘读统计窗口为调用 `ya reveal` 前至 `ya.image_show`，按目标文件路径
汇总，包含正常的系统预读取及 Yazi 在 peek 前的文件访问；不是仅统计
vimg 进程，也不是物理读取时间。以下为各 8 次中位数，单位 MiB：

| 实际读取对象 | 旧版冷态 | 新版冷态 | 旧版热态 | 新版热态 |
|---|---:|---:|---:|---:|
| sample/input.mkv | 55.98 | 52.10 | 0.44 | 0 |
| vimg.exe | 10.00 | 10.93 | 0 | 0 |
| libav DLL 合计 | 27.75 | 30.72 | 0 | 0 |
| FFmpeg 主 EXE | 88.97 | 0 | 0 | 0 |
| FFmpeg Scoop shim | 0.23 | 0 | 0 | 0 |

每轮以上目标文件合计的中位数为 **182.93→93.75MiB**。减少独立 FFmpeg
加载是本轮读盘下降的主要来源，但不能把全部时间差归因于磁盘 I/O。
新版热态 8 次对上述文件均无磁盘读；旧版热态仍有 0.31–1.69MiB 素材读，
不能宣称其完全零读盘。冷态助手硬缺页数中位数 129.5→12，热态 0.5→0；
此计数包含正常预取与缺页机制的差别，不等同于读取次数或延迟。

### 同期耗时对照

| 指标（各 8 次） | 旧版 | 新版 |
|---|---:|---:|
| 冷态：peek→静态显示调用中位数 | 330.6ms | 204.1ms（−38.3%） |
| 冷态：上述范围 | 320.2–404.5ms | 193.0–249.6ms |
| 冷态：探测及取帧合计中位数 | 327.9ms | 200.1ms |
| 冷态：ya reveal 启动前→静态显示调用中位数 | 411.2ms | 289.0ms（−29.7%） |
| 热态：peek→静态显示调用中位数 | 252.2ms | 184.8ms（−26.7%） |
| 热态：上述范围 | 241.0–288.3ms | 170.8–214.0ms |
| 冷态：测试期间系统 CPU 中位数，含测试自身 | 7.60% | 11.94% |
| 热态：测试期间系统 CPU 中位数，含测试自身 | 7.44% | 16.19% |

全部原始耗时如下；CPU 是从调用 reveal 前到收到本轮完成事件的系统利用率，
不代表 vimg 单进程 CPU。第 10、11 轮负载较高，未剔除或替换。测量期间
没有并发构建、ETL 分析、正确性测试或主动施加负载；其他桌面程序继续运行。

| 顺序 | 版本 | 冷态 ms | 紧接的热态 ms | 系统 CPU 冷/热 % |
|---|---|---:|---:|---:|
| 1 | 旧版 | 355.3 | 267.1 | 7.99 / 9.95 |
| 2 | 新版 | 205.6 | 184.6 | 12.29 / 11.68 |
| 3 | 新版 | 210.2 | 184.9 | 17.47 / 13.92 |
| 4 | 旧版 | 404.5 | 255.3 | 10.58 / 6.48 |
| 5 | 新版 | 197.4 | 175.3 | 7.81 / 7.56 |
| 6 | 旧版 | 332.6 | 256.2 | 7.39 / 6.06 |
| 7 | 旧版 | 322.1 | 244.9 | 5.91 / 11.08 |
| 8 | 新版 | 193.0 | 170.8 | 7.14 / 7.36 |
| 9 | 旧版 | 353.1 | 249.1 | 7.80 / 6.84 |
| 10 | 新版 | 249.6 | 214.0 | 33.45 / 42.41 |
| 11 | 新版 | 221.5 | 211.0 | 18.22 / 32.89 |
| 12 | 旧版 | 325.2 | 288.3 | 13.78 / 13.76 |
| 13 | 新版 | 194.0 | 185.6 | 7.51 / 22.52 |
| 14 | 旧版 | 320.2 | 241.0 | 6.99 / 7.90 |
| 15 | 旧版 | 328.6 | 241.2 | 7.37 / 6.97 |
| 16 | 新版 | 202.6 | 177.5 | 11.58 / 18.46 |

### 验证结论与边界

- 32 次 JPEG 均为 10,749 字节，SHA-256 全部匹配
  `ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
  事件及进程轨迹确认：旧版 16 次 probe、16 次 FFmpeg（另有对应 shim）；
  新版 16 次 preview，没有额外 probe、ffprobe 或 FFmpeg 回退。
- 新版 EXE SHA-256 仍为
  `00035953ebee904b5cefa8d00d5efecd929bf08495c4e9d3e1187cd503804f63`；
  基线为 `eac5c5c5b8d6d60e29f1bac17050a19b2eda07804bb8f57601372730898a3302`。
  未重建或修改 EXE/插件，因此沿用上节完整兼容性测试，本轮补充冷态验证。
- 这是 **Windows 文件缓存冷态的首次预览**。Yazi 在访问前已经启动，
  共用的系统 DLL 仍可驻留；Yazi 在 peek 前的正常访问也会预热部分素材。
  因而同时报告 reveal→显示调用整段，不能将 peek 单项当作整个应用启动。
  没有整机重启/断电，没有清除 SSD 控制器缓存，也未禁用 SysMain、预取或
  杀毒软件。ETW 证明请求到达 Windows 存储栈，不能证明落到 NAND 的读取。
- 终端缺少 chafa，终点仍是 `ya.image_show` 调用，未测屏幕像素绘制完成。
  数据仅代表本机本素材；CPU 存在波动，不能承诺所有机器或尾延迟的收益。
  仅对比本节同期数据，不与前节无 ETW、负载不同的绝对耗时直接相减。

管理员助手及测试进程已退出，独立 WPR 会话已停止。未覆盖用户安装的
EXE/插件，也未修改全局电源、亲和性或预取设置。原始证据保留在本机忽略
目录 `.scratch/startup/phase19/`：`formal-*/result.json`、`events.log`、
`purge.json`、`disk.etl`、`io.json`，总汇 `analysis.json`；复测脚本为
`prepare.py`、`bench_yazi.py`、`run_bench.ps1`、`admin.py`、`control.py`、
`cold.wprp`、`analyzer/Program.cs`、`analyze.py`。正式测试前的方法试测保留在
`pilot/`（新版冷/热 244.4/187.3ms），不混入上述正式 16 轮统计。

## 2026-10-13：在同一原生进程内完成静态预览探测和取帧

基线为 Git `f07d9ed`。新增 `vimg preview`，在一次原生进程、一个输入上下文
内完成完整探测、关键帧定位、缩放和 JPEG 编码，返回供 DDS 使用的元数据。
插件空静态缓存时优先使用该命令，支持范围之外复用元数据并回退 FFmpeg。
最终真实 Yazi 对照中，新进程首次预览中位数 **278.0→180.2ms（−35.2%）**，
重复空缓存预览 **260.0→175.8ms（−32.4%）**。这里的首次是新 Yazi 进程的
首次 peek，系统文件缓存已经预热；不代表重启机器后的真实冷启动收益。

### 实现和兼容范围

- 复用 `probe` 的输入打开和 JSON 元数据提取函数，仍执行完整
  `avformat_find_stream_info`，保留 `scan_all_pmts` 和全部视频流/封面信息。
  成功路径不再分别启动 `vimg probe` 和 `ffmpeg`，不重新打开输入文件。
- 原生路径覆盖 Matroska 和 MP4/MOV 中单个、逐行、8-bit YUV420 的
  H.264/HEVC 视频流。解码、滤镜、JPEG 编码均限制为单线程；取帧百分比、
  秒数取整、`nokey`、fast_bilinear 缩放、尺寸上限和 JPEG 质量保持原行为。
  seek 加上容器起始时间，丢弃目标时间之前的解码帧。
- 封面、多视频流、旋转矩阵、隔行、10-bit、其他编码/容器和不连续时间轴
  使用原 FFmpeg 路径；已成功探测的元数据直接返回给插件，不再启动第二个
  探测助手。原型中 MPEG-TS 出现选帧不一致，因此明确回退这类时间轴。
  1×1 等尺寸可能使缩放后的 SAR 无效，原型虽 RGB 相同但 JPEG 头不同；
  最终增加 SAR 检查，让这些边界情况也回退。
- JPEG 先在内存中编码完成，只写一次同目录临时文件再重命名发布，避免
  失败时留下部分缓存；失败会清理本次临时文件。拒绝输出路径等于输入。
  越界 skip 返回元数据和 `preview_upper_bound`，不生成错误位置的图片。
- `preview_written` 表示是否生成图片；`native_preview` 表示构建能力。
  标准构建直接返回缺少能力，不在内部启动 ffprobe。缺失/旧版命令及标准
  构建在 Yazi 会话内缓存能力判断；单个文件失败不会禁用其他文件。
  已有静态缓存仍跳过取帧。需要同步更新原生版 EXE 和插件，并重启 Yazi。

### 最终版本真实 Yazi 性能对照

本机 Yazi/Ya 26.1.22，FFmpeg/链接 libav 8.1.2，素材 `sample/input.mkv`。
使用隔离配置和缓存，尺寸上限 600×900、质量 75、图像延迟 30ms，禁用
预加载和动画服务。每次访问后切走并删除该次静态缓存，不命中图片缓存。
基线使用保存的旧 EXE/插件，新版使用最终 EXE/插件的埋点副本。

按旧→新→新→旧→新→旧→旧→新执行八个独立 Yazi 进程，各首次 1 次、
后续 5 次，共 48 次全部保留。测量期间没有并发构建、正确性测试或主动
CPU 负载。时间通过 Yazi 内 `ya.time()` 记录；P95 使用 nearest-rank。

| 指标 | 基线 | 新版 |
|---|---:|---:|
| 新进程首次：peek→静态显示调用中位数，各 4 次 | 278.0ms | 180.2ms（−35.2%） |
| 新进程首次：上述四次原始值 | 398.7 / 256.6 / 296.5 / 259.5ms | 256.7 / 171.1 / 178.3 / 182.1ms |
| 重复空缓存：整段中位数，各 20 次 | 260.0ms | 175.8ms（−32.4%） |
| 重复空缓存：整段 P95 | 265.6ms | 181.6ms |
| 重复空缓存：探测及取帧合计中位数 | 257.2ms | 172.9ms（−32.8%） |
| 重复预览期间系统 CPU 中位数，含测试自身 | 12.42% | 12.96% |
| 重复预览期间系统 CPU 范围 | 8.95–16.93% | 8.08–20.90% |
| 含首次、各 24 次：整段中位数 | 260.0ms | 176.1ms |
| 含首次：整段最大值 | 398.7ms | 256.7ms |

事件记录确认：基线 24 次 `probe` 加 24 次 FFmpeg 取帧；新版 24 次
`preview`，没有额外 `probe`、ffprobe 或 FFmpeg 取帧。新版合并阶段时间
包括元数据、解码、缩放、编码及缓存发布，不与基线的“单帧提取”单项混比。
48 次图像均为 10,749 字节，匹配既有 JPEG SHA-256：
`ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。

### 首用额外延迟及测量边界

加 SAR 边界检查前，独立命令按 ABBA 重复三次，各 6 次，中位数为
260.8→179.5ms。但该版新 EXE 第一个调用达 **719.5ms**，旧版第一个
探测+取帧调用为 398.2ms；这些样本未删除。最终 EXE 在首次独立调用中为
**294.7ms**，随后才完成上述 Yazi 对照。独立调用不是相同机器冷态下的
受控对照，不能据此量化真正冷启动收益，也没有精确归因首用额外耗时。

本轮没有重启机器、清空系统页缓存或修改全局电源/亲和性。所有重复预览
仍启动新的助手进程；“重复”仅指 Yazi 和系统缓存已热。首次样本各只有
4 次，结果代表本机本素材，不保证所有格式或机器的尾延迟。终端缺少
chafa，计时截至 `ya.image_show` 调用及文件校验，未测屏幕像素绘制完成。
只比较本节同期对照，不把上一轮背景负载下的绝对数值直接相减。

### 验证

- 最终 EXE 的 23 个素材 × skip 0/45，共 46 个默认配置场景：31 次原生
  输出、13 次回退输出，44 对 JPEG 字节及解码 RGB 哈希一致；另 2 次
  低帧率/MPEG-4 场景在基线也无法取图，新版保留相同回退失败行为。
  覆盖 H.264、HEVC、VFR、长 GOP、多视频流、音频先行、非零起始时间、
  MPEG-TS、分数/高低帧率、短片、色彩范围、非方形像素、隔行、封面、
  10-bit、90° 旋转矩阵及中文/空格/前导连字符路径。
- 额外 12 个尺寸/质量场景全部匹配：601×301/质量 100、320×179/质量 0、
  1×1/质量 50，各使用主素材和非方形像素材、两个 skip。前 8 次原生，
  后 4 次 SAR 无效回退。合计 56 对成功图片字节/RGB 一致。
- 17 项真实 CLI 协议检查通过：参数范围、极大/越界 skip、封面上界、
  同输入输出路径、缺失/损坏输入、输出目录错误、失败保留旧图、成功替换
  旧图、临时文件清理。移除 PATH 中的 ffmpeg/ffprobe 后，原生取帧仍成功。
- 四个 Lua 回归脚本通过，新增 `test-gridthumb-preview.lua` 覆盖一次调用
  完成取帧、DDS 元数据、已有缓存、回退元数据复用、旧/缺失/标准助手、
  坏 JSON/执行失败、会话能力缓存与 skip 上界。
- 真实 Yazi 兼容检查：旧 EXE 与标准 EXE 各 3 次空缓存预览均正确，只
  尝试一次新命令。旧版保留每次 `probe`，标准版直接 ffprobe，均执行
  FFmpeg 回退取帧。首次能力尝试仍有额外成本，不声称标准构建提速。
- 原生 release Rust 测试 **78 通过 / 7 忽略**；无默认 feature 测试
  **68 通过 / 4 忽略**。两种构建均成功，保留已有 `unused_mut` 与
  feature-off `dead_code` 警告。最终 SAR 修正后重跑原生测试通过。
- 最终真实 Yazi+服务烟测：静态准备 208.1ms，请求→ready 1.177s，
  ready→动画调用 33.0ms，再次访问动画缓存 32.3ms。只生成一次动画，
  切换取消、ready 强制刷新及缓存复用正常；此为单次功能验证。
- 原命令 `vimg vcs -c3 -H160 -n9 sample/input.mkv --output <测试目录>.avif`
  的旧/新/新/旧验证为 0.924 / 0.922 / 0.931 / 0.922s，四次及服务烟测
  均匹配 AVIF golden：
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
  本轮未改动画实现，不据这些用时波动宣称 VCS 加速。

最终原生 EXE SHA-256：
`00035953ebee904b5cefa8d00d5efecd929bf08495c4e9d3e1187cd503804f63`。
可复用图像对照命令为 `python scripts/test-static-preview.py --vimg
target/release/vimg.exe --output-dir <新测试目录> <video>...`，需配置 libav DLL
搜索路径。原始数据及脚本位于忽略目录 `.scratch/startup/phase18/`：
`final-*/result.json`、事件日志、`final-analysis.json`、`first-final.json`、
`diagnostic.json`（SAR 检查前原型）、`verified-corpus/results.json`、
`verified-options-*/results.json`、`options-tiny-fixed/results.json`、
`protocol-final-results.json`、`fallback-old/`、`fallback-standard/`、
`final-smoke/`、`cli-checks.json`。早期不一致样本也保留在该目录的
`corpus/` 与 `options-2/`，不混入最终通过结果。测试进程已退出，测试使用
独立配置和 PATH，没有覆盖用户安装。Git 仅提交实现、测试和相关文档。


## 2026-10-13：限制静态预览的滤镜与 JPEG 编码线程

基线为 Git `b026b6c`。本轮落实上一轮建议的第一步：在静态单帧 FFmpeg
命令中加入 `-filter_threads 1`，并在输入之后加入输出选项 `-threads:v 1`。
既有输入解码仍为单线程，限制滤镜和 JPEG 编码的工作线程启动开销。
取帧位置、关键帧筛选、封面选择、缩放算法和 JPEG 质量保持一致。
只需更新插件；本轮没有改动 Rust 或 EXE。

两轮真实 Yazi 对照共 96 次，全部保留。重复空缓存预览中位数
**297.3→291.1ms（−2.1%）**，P95 **429.1→410.3ms**。这是小幅收益，
背景负载波动明显。新 Yazi 进程首次预览的合并中位数
**290.1→296.9ms（+2.3%）**，本轮仍没有证实首次进程预览或磁盘冷启动
得到稳定改善，不将重复预览收益表述为冷启动收益。

### 参数筛选

同一主素材、相同完整单帧命令，六种配置各执行 10 次，每轮正反顺序交替。
每次均重新启动 FFmpeg，输出写到测试目录。计时包含进程启动和输出写入，
不含元数据助手。使用本机 PATH 中的 FFmpeg 8.1.2。

| 配置 | 单帧命令耗时中位数 |
|---|---:|
| 基线，自动滤镜及输出编码线程 | 220.6ms |
| 仅滤镜 1 线程 | 201.0ms |
| 仅滤镜 2 线程 | 200.8ms |
| 仅 JPEG 编码 1 线程 | 200.5ms |
| 滤镜和 JPEG 编码各 1 线程，本次采用 | 201.4ms（−8.7%） |
| 滤镜和 JPEG 编码各 2 线程 | 195.3ms |

六种配置的主素材 JPEG 和解码 RGB 哈希均相同。2 线程组合在此轮中位数
低约 6ms，尚不足以判断跨负载优势；本轮选择各 1 线程作为缩略图的保守
资源上限，没有把它描述为所有机器、分辨率和素材上的最快参数。
输入前的 `-threads 1` 和输入后的 `-threads:v 1` 分别控制解码与编码。
选项与 MJPEG 的线程支持通过本机 `ffmpeg -h full`、
`ffmpeg -h encoder=mjpeg` 核对。

### 真实 Yazi 对照与首次调用

Yazi/Ya 26.1.22，FFmpeg/链接 libav 8.1.2；使用相同原生 EXE，
`sample/input.mkv`、600×900 尺寸上限、质量 75、图像延迟 30ms。
禁用预加载，计时期间不运行动画服务。每次访问后切走并删除该次静态图
缓存；探测助手和 FFmpeg 每次都是新进程，没有命中图像缓存。

每轮按旧→新→新→旧→新→旧→旧→新运行八个独立 Yazi 进程，每个进程
首次 1 次、后续 5 次。首轮候选组出现较高 CPU 负载，因此完整重复一轮，
没有删除慢样本。以下合并两轮，各版本首次 8 次、重复 40 次。

| 指标 | 基线 | 新版 |
|---|---:|---:|
| 重复：peek→静态显示调用中位数 | 297.3ms | 291.1ms（−2.1%） |
| 重复：整段 P95 | 429.1ms | 410.3ms |
| 重复：单帧提取中位数 | 226.0ms | 217.3ms（−3.8%） |
| 重复：单帧提取 P95 | 328.0ms | 314.6ms |
| 重复：元数据中位数 | 67.4ms | 71.7ms |
| 重复：系统 CPU 中位数，含测试自身 | 17.53% | 20.11% |
| 重复：系统 CPU 范围 | 9.51–57.08% | 10.76–59.68% |
| 新进程首次：整段中位数 | 290.1ms | 296.9ms（+2.3%） |
| 新进程首次：单帧提取中位数 | 224.4ms | 224.0ms |
| 新进程首次：整段最大值 | 400.5ms | 425.5ms |
| 包含首次、各 48 次：整段中位数 | 296.1ms | 291.1ms |

P95 使用 nearest-rank。单独看两轮，重复整段中位数分别为
290.3→280.8ms、342.8→319.7ms；首次中位数分别为
287.1→299.0ms、347.1→296.9ms。首次原始值（ms）为：

| 轮次 | 基线首次四次 | 新版首次四次 |
|---|---|---|
| 第一轮 | 291.0 / 289.2 / 284.9 / 277.6 | 425.5 / 325.6 / 267.2 / 272.5 |
| 第二轮 | 273.9 / 362.9 / 400.5 / 331.3 | 261.6 / 319.6 / 386.1 / 274.2 |

未改动的元数据探测也随负载变慢，因此不将两轮差异完全归因于参数。
没有构建并发或主动施加负载；也未重启机器、清空系统页缓存、修改全局
电源或亲和性。本轮“首次”仅指新 Yazi 进程的第一次空缓存 peek，
不包含 Yazi 应用启动，系统文件缓存已经被前面的测试预热。
终端缺少 chafa，计时截至 `ya.image_show` 调用，未测屏幕像素绘制完成。
不跨轮直接用上一节的 399.4ms 与本节数值相减作为收益。

### 正确性与提交范围

- 11 个素材 × skip 0/45，共 22 对实际命令输出，JPEG 字节与解码 RGB
  哈希全部一致。涵盖主素材、H.264、HEVC、VFR、多视频流、非零起始时间、
  BT.709 全/限范围、非方形像素、短片和封面。96 次 Yazi 主素材静态图
  全部为 10,749 字节，SHA-256：
  `ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
- 三个既有 Lua 回归脚本全部通过：`test-gridthumb-metadata.lua`、
  `test-gridthumb-requests.lua`、`test-gridthumb-probe.lua`。
- 真实 Yazi+服务烟测通过：静态准备 331.9ms，请求→ready 0.970s，
  ready→动画调用 32.1ms，再次访问动画缓存 32.4ms；只请求和执行一次
  动画生成，切换取消与 ready 强制刷新正常。这一次烟测用于功能验证。
- 原命令 `vimg vcs -c3 -H160 -n9 sample/input.mkv --output <测试目录>/cli.avif`
  验证一次为 0.934s，输出与服务烟测均匹配 AVIF golden：
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
  EXE 没有变化，不据这一次用时宣称 CLI 加速。本轮没有重跑 Rust 全量
  测试；验证重点为实际修改的 Lua 取帧命令及其集成链路。

使用的原生 EXE SHA-256 仍为
`eac5c5c5b8d6d60e29f1bac17050a19b2eda07804bb8f57601372730898a3302`。
原始数据和复现脚本在忽略目录 `.scratch/startup/phase17/`：
`diagnose.py`/`diagnostic.json`、`prepare.py`、`bench_yazi.py`、
`run_bench.ps1`、`final-*/result.json`、`repeat-*/result.json`、事件日志、
`analysis.json`（第一轮）、`repeat-analysis.json`、`combined-analysis.json`、
`corpus/results.json`、`final-smoke/`、`cli-check.json`。
第一轮第 0 组已成功写出全部结果，驱动脚本曾因 PowerShell 的空 ExitCode
误报失败；随后改为校验结果文件及错误日志，从第 1 组继续，保留第 0 组。
测试实例均已退出，未覆盖用户安装。下一步若继续追求更大的首次收益，
应测量同一原生进程内完成探测和取帧，减少助手/FFmpeg 的重复启动与探测。


## 2026-10-13：用轻量原生探测减少静态预览的元数据等待

基线为 Git `19f3bb2`。新增 `vimg probe <video>`，原生构建通过 libavformat
返回预览所需的 JSON；插件优先调用该命令。最终真实 Yazi 对照中，重复
空图像缓存预览的元数据等待中位数 **138.4→98.4ms（−28.9%）**，整段静态
预览准备 **424.4→399.4ms（−5.9%）**。新进程首轮仍有额外启动延迟，
本轮没有证明首次进程调用或真正磁盘冷启动得到稳定改善。

### 定位与实现

先比较原始参数、单线程、只输出视频流、关闭流信息探测和缩短分析窗口，
每项 8 次，正反顺序交替。原始探测中位数 119.9ms；其余分别为
118.0、112.5、112.3、113.6ms，单线程加视频选择为 117.7ms。
仅执行 Scoop PATH 中的 `ffprobe -version` 已需 102.2ms；直接执行其实际
EXE 的同项测量为 74.3ms。由此判断，本机进程启动及程序加载占主要成本，
不是 JSON 字段太多。没有采用缩短分析窗口或跳过 `find_stream_info`。

新命令使用项目已有的可选 `ffmpeg-next` 依赖，仍执行完整
`avformat_find_stream_info`，并与 ffprobe 一样启用 MPEG-TS 的
`scan_all_pmts`。遍历全部视频流，保留封面 disposition；时长按 ffprobe
的六位小数字符串输出，不先转为 f32。原生探测缺少必要字段或失败时，
以及未启用 `in-process-decode` 时，使用 ffprobe 回退。
实现参考 [FFmpeg 8.1.2 ffprobe 源码](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/fftools/ffprobe.c)
的输入探测流程；本机静态 ffprobe EXE 约 242MB，vimg EXE 约 8MB，后者
另需共享库。文件大小只是实现差异，不单独作为耗时下降的因果证明。

插件只在预览元数据路径使用新命令，spot 信息展示沿用原路径。新命令仍是
一个子进程，并非消除了所有进程启动；需同时更新原生版 EXE 和插件才能
取得本轮收益。旧版/缺失的 vimg、无效 JSON 或缺少时长等情况保留原 ffprobe
回退。`native_probe` 能力字段和 `ya.sync` 状态使标准构建、旧版及缺失助手
在后续 peek 中被跳过；单个坏文件的执行错误不会禁用其他文件的原生探测。

### 最终版本真实 Yazi 对照

Yazi/Ya 26.1.22、FFmpeg/链接 libav 8.1.2，同一 `sample/input.mkv`。
旧→新→新→旧四个独立 Yazi 进程，每个首次 1 次、后续 10 次；44 次全部
保留。每次切走并删除该次测试的静态图缓存，动画服务在计时期间关闭。
相同环境、600×900 尺寸上限、质量 75、图像延迟 30ms，禁用预加载。
使用生产插件的埋点副本，在 Yazi 内以 `ya.time()` 测量。构建和性能测量
分开进行，没有主动施加 CPU 负载。系统 CPU 仍有背景波动。

| 指标 | 基线 | 最终版本 |
|---|---:|---:|
| 重复空缓存预览：元数据中位数，各 20 次 | 138.4ms | 98.4ms（−28.9%） |
| 上述元数据样本 P95 | 155.0ms | 109.3ms |
| 重复空缓存预览：peek→静态显示调用中位数 | 424.4ms | 399.4ms（−5.9%） |
| 上述整段样本 P95 | 454.1ms | 406.9ms |
| 重复预览：单帧提取中位数 | 281.9ms | 294.1ms |
| 重复预览期间系统 CPU 中位数，含测试自身 | 30.14% | 33.94% |
| 新进程首次元数据，两次原始值 | 165.5 / 143.3ms | 195.0 / 103.1ms |
| 新进程首次静态预览，两次原始值 | 453.4 / 440.1ms | 493.6 / 404.8ms |
| 包含首次、各 22 次的静态预览中位数 | 425.5ms | 400.0ms |
| 包含首次的最大静态预览耗时 | 458.0ms | 493.6ms |

P95 使用 nearest-rank。新版组单帧提取稍慢且 CPU 占用更高，故没有把
元数据节省的约 40ms 全部计为整段收益。首次观测中，新版一次比基线慢；
原型的首次独立命令还曾为 835ms，而重复中位数为 87.5ms。尚未精确归因
这类首用额外耗时，不把它当作错误样本剔除。首次样本量各只有 2 次，
不足以保证冷启动尾延迟。先前未加能力缓存的中间版本还测得
139.3→89.4ms、429.9→387.6ms，保留为诊断记录，不替代最终版本数据。

所有预览都重新启动元数据助手和静态 FFmpeg；“重复”只是 Yazi 进程及
操作系统缓存已热，不是图像或元数据缓存命中。本轮未重启机器或清空页
缓存，不包含 Yazi 应用启动。终端缺少 chafa，计时截至 `ya.image_show`
调用及图像文件校验，没有测量屏幕像素实际绘制完成时间。

### 回退成本与正确性

标准构建的直接命令对照曾测得 ffprobe 140.5ms、经 vimg 转调 191.1ms，
因此加入能力缓存。最终真实 Yazi 标准构建测试中，11 次预览仅尝试一次
助手；后续 10 次探测中位数 141.6ms、静态准备 425.1ms，直接走 ffprobe。
但首次能力判断仍有成本：该次探测 391.7ms、静态准备 680.4ms。
标准构建仅保证兼容，不声称首次性能获益；缺少原生能力的状态持续到
Yazi 重启，更新 EXE 后应重启 Yazi。

- 原生和标准构建各对照 18 个素材，时长、全部视频流顺序、codec、尺寸、
  时间基、封面标志与 ffprobe 一致。涵盖 H.264、HEVC、VFR、多视频流、
  音频先行、长 GOP、MPEG-TS、非零起始时间、不同帧率、色彩范围、非方形
  像素、隔行、短片和封面。移除 PATH 中的 ffprobe 后，18 个原生探测仍
  成功；最终原生 EXE 再次通过 18 项对照及能力字段检查。无效路径返回
  失败状态，stdout 不发布部分 JSON。
- 新旧元数据分别驱动实际静态取帧命令，11 个素材 × 两个 skip，22 对
  JPEG 字节和解码 RGB 哈希一致。最终 44 次 Yazi 静态图均匹配上一轮的
  10,749 字节 JPEG：
  `ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
- 三个 Lua 回归脚本通过，包含原生成功、旧版/缺失助手、坏 JSON、缺失
  时长/流、会话内能力缓存、单个文件失败不禁用原生能力，以及既有的
  元数据传递、取消和 ready 刷新行为。
- 原生 release 测试 78 通过/7 忽略；无默认 feature 测试 68 通过/4 忽略。
  能力标记补充后重新构建两种最终 EXE，并完成真实 Yazi 能力缓存与原生
  链路验证。保留既有 `unused_mut`/feature-off `dead_code` 警告。
- 最终真实 Yazi+服务烟测：静态准备 325.3ms，请求→ready 1.088s，
  ready→动画调用 32.9ms（含 30ms 配置延迟），再次访问缓存 30.8ms；只
  请求/执行一次动画生成，切换取消正常，AVIF 匹配既有 golden
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- 原命令 `vimg vcs -c3 -H160 -n9 sample/input.mkv --output <cache>.avif`
  在加能力字段前的基线/新版 ABBA 验证为 1.392/1.224/1.172/1.193s，
  四个输出均匹配 golden。未改动画实现，不据这四次波动宣称 CLI 加速。

最终原生 EXE SHA-256：
`eac5c5c5b8d6d60e29f1bac17050a19b2eda07804bb8f57601372730898a3302`。
可复用的元数据一致性检查为
`python scripts/test-preview-probe.py --vimg target/release/vimg.exe <video>...`，
需按本机配置 libav DLL 搜索路径。Lua 检查为 `scripts/test-gridthumb-probe.lua`、
`scripts/test-gridthumb-metadata.lua`、`scripts/test-gridthumb-requests.lua`。
原始数据、构建副本及复现脚本在忽略目录 `.scratch/startup/phase16/`：
`diagnostic.json`、`native-diagnostic.json`、`final-*/result.json` 和事件日志、
`final-analysis.json`、`final-corpus-metadata.json`、`feature-off-metadata.json`、
`corpus/results.json`、`fallback/`、`final-smoke/`、`cli-checks.json`。
正式比较对应 `final-0` 到 `final-3`，早期 `abba-*` 为中间版本。测试使用
隔离配置/缓存和临时 PATH，未覆盖用户安装；测试 Yazi 与服务均已退出。


## 2026-10-13：缩短首次静态预览的单帧提取耗时

基线为 Git `9699aad`。本轮仅修改 `gridthumb.yazi` 的静态单帧命令：
去掉 `-hwaccel auto`，使用既有的单线程软件解码，避免每次为一张缩略图
初始化硬件设备。取帧百分比、关键帧筛选、封面选择、缩放、JPEG 质量和
渐进预览顺序保持原样。动画仍由 `vimg serve` 的已选后端生成。

### 定位与真实 Yazi 对照

先按插件参数运行 12 次 ABBA 交叉诊断，各版本 6 次：`ffprobe` 中位耗时
118→111ms，单帧 `ffmpeg` 486→235ms；12 张 JPEG 的 SHA-256 相同。
这支持硬件初始化成本是本机此路径的主要可移除开销；未进一步细分驱动内部
阶段。[FFmpeg 官方说明](https://www.ffmpeg.org/ffmpeg.html#Advanced-Video-options)
也指出硬件解码不一定更快，回传系统内存还有额外成本。

正式对照使用已安装 Yazi/Ya **26.1.22**、FFmpeg **8.1.2**，输入
`sample/input.mkv`（1920×1080 H.264）。仅在生产插件的测试副本中加入
`ya.time()` 事件，记录 `peek`、探测、提取和 `ya.image_show` 调用边界。
测试配置明确设置默认尺寸上限 600×900、质量 75、`image_delay = 30`，
禁用预加载。每轮都切走再删除该轮自己的静态缓存，保证图像缓存未命中。

按 **旧→新→新→旧** 启动四个独立 Yazi 进程，各测首次 1 次及后续 10 次。
统计从进入 `peek` 到调用静态图 `ya.image_show`，不含 Yazi 应用启动时间。
静态对照期间不启动动画服务，不编译、不主动施加 CPU 负载，避免动画工作
干扰下一次静态测量；完整服务链路另外验证。共 44 次，未剔除慢样本。

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 新 Yazi 进程首次静态预览，两次原始值 | 645.7 / 585.7ms | 349.1 / 397.2ms |
| 上述首次观测中位数，仅各 2 次 | 615.7ms | 373.1ms（−39.4%） |
| 进程内重复、图像缓存未命中，各 20 次中位数 | 587.3ms | 379.1ms（−35.4%） |
| 上述 20 次样本 P95，nearest-rank | 652.0ms | 438.1ms |
| 重复预览中 `ffprobe` 中位数 | 117.4ms | 120.2ms |
| 重复预览中单帧提取中位数 | 461.9ms | 252.6ms（−45.3%） |
| 重复预览中显示 API 调用耗时中位数 | 5.10ms | 5.35ms |
| 重复预览期间系统 CPU 占用中位数 | 25.23% | 19.46% |

收益集中在单帧提取。两组旧版重复预览中位数为 589.3 / 582.8ms，
两组新版为 397.3 / 366.9ms。机器仍有背景负载，系统 CPU 范围旧版
18.93%～35.94%，新版 11.49%～41.78%；这里的系统占用包含测试自身，
不是“其他进程占用”。只看系统占用低于 30% 的辅助分组，旧版 15 次
中位数 577.7ms、新版 16 次 361.1ms；主结果仍包含全部样本。

“首次”是新 Yazi 进程第一次为无缓存文件准备静态图，“重复”仍会启动
新的 `ffprobe`/`ffmpeg` 子进程，均不是图像缓存命中。未重启机器或清空
操作系统页缓存，不能称为真正磁盘冷启动；两次首次观测也不足以估计稳定
尾延迟。测试终端缺少 chafa，结果截止到显示 API 调用及生成图像校验，
不代表屏幕像素已经绘制完成。收益数值限定于这台机器与该素材。

### 正确性与完整服务链路

- 正式 44 次静态输出均为同一个 10,749 字节 JPEG，SHA-256 为
  `ac3d666b3f640b22310630d58879a7807740ceb62467da7b120de3291d4e469d`。
- 通过 Lua 桩调用新旧插件真实 `preload`，取得各自构造的命令，再执行真实
  FFmpeg。11 个素材各测 `skip=0/45`：主样本、H.264 MP4、HEVC、VFR、
  多视频流、非零起始时间、BT.709 limited/full、非方形像素、短片、带封面
  MP4。**22 对 JPEG 字节及解码 RGB 哈希全部一致**；含默认封面及向后寻帧。
- `lua scripts/test-gridthumb-metadata.lua` 和
  `lua scripts/test-gridthumb-requests.lua` 均通过，覆盖元数据传递、当前预览
  兴趣、切换取消、过期完成与动画 ready 强制刷新。
- 真实 Yazi + 当前 release 服务烟测通过：首次静态准备 **338.5ms**，
  DDS 请求→ready **1.065s**，ready→动画显示调用 **33.2ms**（含配置的
  30ms 图像延迟）；首次 peek→动画调用合计 **1.441s**。切走会取消兴趣，
  返回后 **31.6ms** 调用已缓存动画，只有一次生成请求和一次服务执行。
  这是单次功能烟测，不与上轮不同配置的单次结果作性能对比。
- 动画输出仍匹配既有 golden AVIF：
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
  本轮未改 Rust/CLI，release EXE 仍为 SHA-256
  `09c4b10793e3f37ff6ca9a9a3ecc76bce86c3d8b81852565cf91fb74a1e92c97`，
  不宣称原始 `vimg vcs` 命令的运行时间有变化。

测试配置、脚本、原始数据保存在忽略目录 `.scratch/startup/phase15/`：
`diagnose.py`/`diagnostic.json`，`prepare.py`/`bench_yazi.py`，
`abba-*/result.json` 与事件日志，`analysis.json`，
`static-command.lua`/`check_corpus.py`/`corpus/results.json`，
`plugin_smoke.py`/`smoke/plugin-result.json`/`smoke/plugin-service.log`。
`baseline.lua` 保存 `9699aad` 的原始插件；计时副本的埋点未进入生产插件。
最初测试配置把 DDS 订阅写在 `init.lua`，Yazi 拒绝启动；修正为插件内订阅后
才开始上述正式测量，失败尝试无计时样本。所有配置、缓存均在项目内隔离，
没有覆盖用户安装或插件配置，本轮启动的 Yazi/服务/子进程已退出。


## 2026-10-13：移除过期 DDS 排队预览，并修复动画就绪后的刷新

基线为 `b9220ad4`。本轮优化实际 Yazi DDS 请求生命周期：插件声明当前
预览兴趣，服务移除已无人等待的未启动任务，正在执行的任务继续完成并填充
缓存。多个客户端共享同一缓存、普通批量请求、匿名请求和十任务容量上限
均保留。没有改动取帧、解码、编码参数或图像内容。

### 复现、原因与实现

原服务虽优先执行最新排队任务，但完成后仍会生成此前所有旧预览。真实 DDS
复现中，11 次请求生成 11 个动画，8 个已经过期；后续选中文件仍等待 1.742s，
整段消耗 86.719s 进程 CPU 时间。Rust 回归在旧实现上因孤立任务仍在队列中
失败，新实现通过。基线测量成功保存，但初次清理受到沙箱限制；随后核实
测试进程 PID 并清理其子进程，正式对照均正常结束，无遗留负载。

实现增加可选 `latest: true` 和 `vimg-gridthumb-cancel`（携带 `cache`）。
交互兴趣按 DDS sender 绑定，每个实例仅保留一个当前兴趣；取消必须同时
匹配 sender 和 cache。普通订阅单独保存，避免取消交互请求时误删批量工作。
重新选择已排队的共享预览会把它移至队尾，按最新请求优先执行。
插件监听 hover/tab，覆盖切到已缓存文件、非视频文件或空目录的情况；在同步
发布点核对当前悬停文件，阻止已过期的异步预加载重新入队。消息只解析一次。

另一个完整插件烟测在收到 ready 后等待 30s 仍未再次调用动画预览：旧回调
发送普通 `peek`，同一源文件的预览被 Yazi 复用。现在使用
`peek { only_if = hovered.url, force = true }`，并去掉固定的 0，保留当前预览
位置。行为与安装版本的 [Yazi v26.1.22 Peek 实现](https://github.com/sxyazi/yazi/blob/v26.1.22/yazi-actor/src/mgr/peek.rs)
及 [Peek 参数](https://github.com/sxyazi/yazi/blob/v26.1.22/yazi-parser/src/mgr/peek.rs)一致。

### 真实 DDS 快速切换对照

使用已安装的 Yazi/Ya 26.1.22、项目内测试配置、独立测试服务，保持默认一个
执行任务和自动 CPU 策略。测试插件通过 `ps.pub_to` 发出请求，真实 `ya sub`
接收，真实 `ya pub-to` 回传，Yazi Lua ready 回调用 `ya.time()` 记录接收时间。
控制命令在请求计时之前运行；DDS 请求和回调均在真实 Yazi 进程内。
这里使用同一视频、不同缓存键模拟文件切换，以排除不同素材解码成本。

每轮先启动一个任务，在它执行期间连续发出 8 个过期预览及一个最终选中预览；
后者 ready 后等 150ms，再选中下一个预览，并等队列完全排空。先 ABBA、
再 BAAB，基线和新版各 4 轮。计时期间没有编译或附加 CPU 负载。

| 指标 | 基线 | 新版 |
|---|---:|---:|
| 每轮生成动画数 | 11 | 3 |
| 后续预览请求→ready 中位数 | 1.654662s | 0.950266s（−42.6%） |
| 第一批最终选中预览请求→ready 中位数 | 1.336584s | 1.344198s |
| 每轮总进程 CPU 时间中位数 | 82.375s | 23.8125s（−71.1%） |
| 整段排空耗时中位数，含控制与固定等待 | 10.198s | 3.140s |
| 四轮最大进程峰值工作集，十进制 MB | 444.416 | 424.305 |
| 其他进程 CPU 占用中位数 | 8.00% | 10.89% |

后续预览的分段中位数：接收日志相对插件发送均小于 1ms；排队约
736ms→低于 1ms；执行约 867→907ms；执行结束到 ready 回调约 44ms→43ms。
日志观察包含管道读取调度误差，执行结束标记之后还包含清单发布和通知进程，
因此最后一段不能全部算成 DDS 网络时间。主要收益来自不再启动过期任务，
不是单次解码变快。第一批最终选中预览仍需等待正在执行任务的剩余时间。
每组只有 4 轮，不把它们的最大值或 P95 当作稳定分布估计。

四轮基线 44 个、新版 12 个输出全部匹配既有 golden AVIF SHA-256：
`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
原始事件、服务日志、CPU/内存、哈希在 `.scratch/startup/phase14/abba-*`、
`reverse-*`；分段数据在 `analysis.json`。复现脚本为该目录的
`bench_dds.py`，参数 `baseline|candidate <新目录名> 11|3`，需先启动该目录
`yazi-config` 中的测试接收端（client ID 141414）并重定向本地
`vimg-bench-observed` 事件；正式数据使用 `yazi-events.log`。Windows 此版本
DDS 端口固定，测试时已确认没有用户服务/实例运行，未覆盖用户安装或配置。

### 完整 gridthumb 链路

使用生产插件的测试副本，只加计时事件。在新的测试缓存目录内，真实
`peek → 静态图调用 → DDS 请求 → ready → 强制 peek → 动画图调用` 通过。
修复后的单次记录为：静态图准备 467ms，请求→ready 906ms，ready→动画
`ya.image_show` 调用 2.1ms，首次 peek→动画调用合计 1.378s。再次访问已缓存
文件约 18ms 到动画调用，服务仅执行一次，没有再次发出生成请求。
切到 README 时实际发出取消事件，服务收到 cancelled。记录在
`plugin-result.json`、`plugin-service.log`；原失败记录保留在
`plugin-events-before-force.log`。

这些是烟测而非稳定性能分布。第一次未修复烟测静态图准备曾为 1.536s，
本轮没有修改静态图生成算法，不能把两次静态图耗时差算作收益。
测试终端缺少 chafa，故验证截止到显示 API 调用及 AVIF 内容一致性，
不声称量到屏幕像素实际显示完成时间。下一处值得测量的是首次静态图准备。

### 原始命令与常驻回归

`scripts/bench-startup.ps1 -Baseline .scratch/startup/phase14/baseline.exe
-Candidate target/release/vimg.exe -OutputDirectory .scratch/startup/phase14/cli-final
-Runs 10`，每种二进制首个观测单列，之后各 10 次新进程，顺序交替。
执行参数仍为 `vcs -c3 -H160 -n9 sample/input.mkv --output <output> --profile`。

| 新进程 CLI | 基线 | 最终新版 |
|---|---:|---:|
| 首个观测 | 1.066623s | 1.616270s |
| 重复新进程中位数 | 0.985715s | 0.980213s |
| 重复新进程样本 P95（n=10） | 1.041178s | 0.999309s |

22 个输出哈希一致。重复运行基本持平，不主张独立 CLI 提速。新版首个观测
较慢；两者内部 profile total 为 0.890/0.886s，额外差异在内部处理计时之外，
本轮未定位其原因。没有重启机器或清空系统文件缓存，不能称作真正冷启动，
也没有证据宣称冷启动改善。

另外运行原有常驻基准：`--rounds 1 --jobs-per-process 50
--max-p95-seconds 1.3 --max-peak-mb 512`，目录 `resident-final`。
立即执行与启动后空闲 10 秒各 50 次生成及缓存校验，首任务不计入 warm P95：

| 进程 | warm 样本数 | 中位数 | P95 | 峰值工作集 MB |
|---|---:|---:|---:|---:|
| fresh | 49 | 0.865430s | 0.924300s | 462.467 |
| aged | 49 | 0.873998s | 0.927995s | 463.954 |

返回 0，绝对预算和相对退化检查均通过。所有 warm 样本观测到的其他进程
CPU 占用均低于 30%；这只是本次较低负载下的回归结果，不代表任意负载保证。
此基准直接调用服务内部执行 seam，不包含 DDS 或静态图准备。

### 验证及边界

Rust 原生全套 78 passed / 7 ignored，无默认特性 68 passed / 4 ignored；
最终解析整理后再次验证服务测试。两个 Lua 回归脚本通过，覆盖 sender/cache
隔离、过期异步完成、共享与匿名批量请求、淘汰清理、重新选择优先级、
hover/tab 取消，以及 ready 强制刷新且不重置位置。格式和本轮文件的 diff
检查通过；保留原有 encode.rs unused_mut 警告和用户 .serena/project.yml 修改。

决策见 ADR-0008。旧客户端未发送 `latest` 时保持批量语义。客户端异常退出
尚未通过 DDS bye 自动撤销兴趣；正在执行的任务也不会中途取消。

正式对照二进制 SHA-256 为
`4e486457445ce49e4f29c6cb2d223e168b2d2a32e43361ce04a4bf5aa6dc1f13`；
之后仅整理 JSON 为单次解析并补充测试。最终 `target/release/vimg.exe` 为
`09c4b10793e3f37ff6ca9a9a3ecc76bce86c3d8b81852565cf91fb74a1e92c97`。
最终构建再跑真实 DDS：11 次请求仅生成 3 个动画，后续预览 0.910s，
整段 CPU 22.281s，峰值工作集 425.390 MB，输出全部匹配 golden；
记录在 `final-dds/result.json`。最终解析代码的 native 服务回归为
27 passed / 3 ignored。所有专用测试服务、ya 子进程和 Yazi 实例已结束。

## 2026-09-13：完成受控负载对照，保留解码实现并增加 CPU 分组诊断

基线为 `75697408`。**本轮没有生产解码提速改动**：完成四种条件的两轮
交替测量，验证外部 CPU 竞争对长回溯解码和编码尾段的影响；一个提前过滤
非参考包的测试原型未命中主样本，已撤回。保留的代码改动仅为基准脚本的
CPU 占用分组统计、对应测试和说明。所有原始任务仍进入绝对 P95/内存验收。

### 控制方式及复现

最小复测命令使用现有 `scripts/bench-service.py`，参数为 `--rounds 1
--jobs-per-process 4 --idle-seconds 0 --max-p95-seconds 1.3 --max-peak-mb 512`，
产物目录 `.scratch/startup/phase13/repro`。八次真实生成和缓存检查通过，任务
耗时 1.018–1.189 秒，返回 0。它可检测绝对超时，但此时自然负载下没有复现。

随后执行 `python -B .scratch/startup/phase13/load_matrix.py matrix 26`，并以
`matrix-repeat 26` 独立重复。每轮包含 CLI/常驻 × 有/无附加 CPU 负载四种
条件，每种 26 次；首轮次单列，两轮合计每种条件 **50 个有效样本**。
各轮次旋转四种条件顺序并交替反转，任何时刻只有一个预览任务执行。

四个专用 Python 负载进程仅在负载条件下循环计算，亲和性读取自服务实际的
`0xffff` 性能核心掩码。控制事件关闭后先留出 150ms，另用 150ms 观察运行前
系统 CPU；这些时间不计入任务耗时。进程在实验结束或异常路径统一停止并
回收。没有终止其他应用或改变系统电源、全局优先级设置。计时与编译、其他
基准串行执行；附加负载是本次明确控制的实验变量。

无附加负载条件仍包含用户电脑的自然负载，不能称为空闲机器或绝对低负载。
测试只覆盖这种有限的 CPU 竞争，不能代表任意程序的内存、磁盘或 GPU 压力。

### 两轮结果：主要增量与 CPU 竞争一致

| 轮次/模式 | 无附加负载中位数 / P95（秒） | 附加负载中位数 / P95（秒） | 配对耗时增量中位数 | 配对进程 CPU 时间增量中位数 |
|---|---:|---:|---:|---:|
| 第一轮 CLI | 1.334970 / 1.666884 | 1.454443 / 1.808885 | +117ms | +0.250s |
| 第一轮常驻 | 1.214382 / 1.971990 | 1.353847 / 1.516917 | +125ms | +0.015625s |
| 第二轮 CLI | 1.178127 / 1.308441 | 1.230746 / 1.328151 | +89ms | +0.093750s |
| 第二轮常驻 | 1.013732 / 1.156756 | 1.149371 / 1.283009 | +109ms | +0.031250s |

每行每个条件有 25 个有效样本，P95 为 nearest-rank。第一轮无附加负载的
常驻 P95 反而更差；其中自然负载尖峰的其他 CPU 达到约 67–73%，必须保留
这些样本，不能把这个现象解释为附加负载改善性能。

常驻任务的进程 CPU 时间配对增量仅约 16/31ms，但墙钟时间增加约 125/109ms。
首网格中位数两轮分别 0.915→0.996 秒、0.770→0.855 秒；接收等待
0.984→1.073 秒、0.818→0.916 秒；编码尾段 0.178→0.216 秒、
0.160→0.185 秒。数据支持外部竞争增加等待、长回溯解码是主要敏感段，
编码尾段也受影响；这些指标有重叠，不能直接相加为精确的阻塞时间。
没有 ETW 调度轨迹，不能进一步精确区分调度等待、频率或缓存竞争的贡献。

同样的负载条件下常驻中位数保持较低，没有发现常驻进程独有的额外劣化。
两种路径还存在媒体描述符复用、CPU 核心策略和初始化差异，不能把差值全部
归因于进程创建。CLI 均为原始命令加 `--profile`，没有重启或清除 OS 缓存，
因此本轮仍未测真正磁盘冷启动。

### 按实际外部 CPU 占用分组

以下合并两轮及两种负载条件，只用于解释观察结果；区间是描述性分组，
不是硬件通用阈值，也没有按分组剔除验收样本。

| 路径及其他 CPU 区间（%） | 样本数 | 中位数（秒） | P95（秒） |
|---|---:|---:|---:|
| cli-0-30 | 18 | 1.111561 | 1.247540 |
| cli-30-45 | 60 | 1.288167 | 1.422452 |
| cli-45-101 | 22 | 1.486571 | 1.808885 |
| service-0-30 | 25 | 1.013732 | 1.136178 |
| service-30-45 | 50 | 1.176076 | 1.314022 |
| service-45-101 | 25 | 1.379103 | 1.971990 |

其中常驻低于 30% 的 25 个样本 P95 为 **1.136178 秒**；30–45% 的 50 个
样本为 **1.314022 秒**；45% 以上的 25 个样本为 **1.971990 秒**。
这说明先前 1.3 秒门槛的通过/失败对背景负载敏感，不证明某个 CPU 阈值能
保证性能。小样本 P95 尤其不适合作为长期保证。

### 未采用的非参考包原型

原型仅在测试构建启用，只考虑逐行 H.264、已知 AVCC 长度格式、无包侧数据
更新、且所有 NAL 都是普通非参考切片的预滚包。保留 SEI、SPS/PPS、AUD、
参考图像、损坏/未知包以及 HEVC/硬件路径，恢复完整解码的时间点不变。

四次候选生成的诊断计数均为九路 **skipped=0**。进一步读取最慢窗口的
12 个数据包：非参考包都包含 `0x06` SEI NAL 和 `0x01` 非参考切片，而非
只含切片。标准输出哈希和缓存检查通过，但原型没有改变实际工作量；这不是
有效的性能候选，因此没有对其做大样本提速宣称，也没有扩大过滤范围。

FFmpeg n8.1.2 在 NONREF 策略下仍处理 SEI，相关信息不能简单当作整包无效
数据丢弃。这里依据的是实际包内容和
[FFmpeg H.264 解码实现](https://github.com/FFmpeg/FFmpeg/blob/n8.1.2/libavcodec/h264dec.c#L582)，
并不声称所有 SEI 都必须跨帧保留。进一步细分 SEI 需要额外语义证明，目前
没有足够收益证据支持增加这种复杂度。原型源码及测试程序只归档在忽略的
实验目录，生产源文件已逐字节恢复到本轮基线。

### 最终验收与交付

基准脚本现在按每个 fresh/aged 分组输出其他进程 CPU 为 `<30%`、`30–45%`
和 `>=45%` 的样本数、耗时、CPU 时间及首网格/接收等待/编码尾段统计。
缺失或无效的占用记录明确计入 unclassified。分组不会改变 P95 预算检查；
回归测试验证低负载组通过时，高负载组仍能让整个进程的绝对预算判为失败。

恢复后的基线程序再次执行现有门槛：一轮 fresh/aged，每进程 50 次，aged
开始前静置 10 秒，`--max-p95-seconds 1.3 --max-peak-mb 512`：

| 进程 | 热样本数 | 中位数（秒） | P95（秒） | 观测峰值 WS（MB） | 其他 CPU 中位数 |
|---|---:|---:|---:|---:|---:|
| fresh | 49 | 1.043217 | 1.151368 | 463.52 | 23.23% |
| aged | 49 | 1.057509 | 1.271824 | 467.55 | 24.13% |

绝对预算超限 `False`，相对变慢 `False`，
返回码 `0`。结果是本次环境观察，
不能替代外部负载较高时的失败记录。内存按 512,000,000 字节判定，DDS
传输仍不在计时范围内。

两轮矩阵共 104 个 CLI 输出匹配标准 SHA，104 个常驻输出及 104 次缓存
断言通过；恢复后最终基准另有 100 次生成及缓存断言。主程序及测试程序
哈希均恢复为 `75697408` 的原产物，既有 16 组像素/PTS/AVIF 验证不受改变。
Python 验收测试 **8 项通过**，其中新增两项在实现前失败、实现后通过。
`git diff --check` 通过，临时 `[DEBUG-p13-*]` 和过滤开关在源代码中均为零。

- 主程序 SHA-256：`3208446ba22ef953dfcd8a6eaa12a4280dd985fe6ea51df2500320f9ba005052`。
- 测试程序 SHA-256：`43470cf5a499c2f7eb9d2a3e943e34f12c5e1311a0c1ce6f88dc23af525c4a43`。
- 复现材料：`.scratch/startup/phase13/` 内 `load_matrix.py`、`matrix/`、
  `matrix-repeat/`、`matrix-analysis.json`、`packet-smoke/`、`packet-data.json`、
  `libav-rejected-prototype.rs`、`packet-prototype-test.exe`、`final-gate/`。

## 2026-09-12：优化长回溯解码，并补齐绝对耗时和内存验收

基线为 `c1627212`。只把回溯超过 6 秒的 libav 采样点从 3 个帧解码线程
增加到 4 个，其他采样点仍为 2 个。主样本只有索引 6、7 进入这一分支。
保留首网格延迟初始化编码器、默认一个服务任务、性能核心策略和输出参数。
该调整用少量额外 CPU 和内存换取更短的解码等待；**不能保证高外部负载下
P95 始终小于 1.3 秒，也没有证明真正磁盘冷启动的改善**。

### 先复现，再缩小瓶颈

未修改的基线连续 50 次：热任务 49 次中位数 1.104406 秒、P95 1.283063 秒，
峰值 WS 445.65 MiB，其他进程平均 CPU 28.83%。上一轮同代码记录的 P95
为 1.400892 秒。因此不能把跨轮绝对耗时差全部算作代码变化。
`python -B .scratch/startup/phase12/latency_gate.py .scratch/startup/phase11/final`
对真实慢任务记录输出 `LATENCY_GATE FAIL`；同命令检查本轮基线记录输出
`LATENCY_GATE PASS`。这是一条可回放的绝对 P95 反馈路径。

两轮各取中位数附近 5 个任务和最慢 5 个任务，慢组解码等待约增加 130ms，
编码尾段约增加 40ms。进一步 30 次逐采样点诊断全部由索引 7 最晚完成。
普通组/慢组该点总耗时中位数 1.0291 / 1.1637 秒；`send_packet` 路径占
0.8985 / 0.9648 秒，`receive_frame` 本身仅约 1ms。帧线程的等待也计入
send 路径，不能据此把它解释为纯 Rust 调用开销。
热任务与首网格、其他进程 CPU 占用的相关系数分别约 0.921、0.918；这支持
外部负载会放大尾部波动，但不是 OS 调度具体机制的因果证明。

初次启用既有 `VIMG_PROTO_PROBE` 时，原型缓存失效策略使缓存复用断言失败；
该轮不计入有效测量。随后用仅测试构建的临时开关收集诊断，30 次生成和
缓存断言通过。临时诊断及线程对照开关均已从源代码移除。

### 常驻交替对照：热任务改善，有 CPU 代价

使用同一个测试二进制，以仅测试开关切换长回溯 DT3/DT4；每组只执行一个
任务，AB/BA 交替顺序。两轮初筛每进程 25 次，另两轮独立确认每进程 50 次；
各进程首任务单列，不进入热统计。P95 使用 nearest-rank，各行单独计算。

| 对照轮次 | 每组热样本 | DT3 中位数 / P95（秒） | DT4 中位数 / P95（秒） | CPU 中位数（秒，前→后） | 其他 CPU 中位数（前→后） |
|---|---:|---:|---:|---:|---:|
| 初筛 1 | 24 | 1.293834 / 1.500840 | 1.215754 / 1.369451 | 10.633 → 10.734 | 38.66% → 36.67% |
| 初筛 2 | 24 | 1.237263 / 1.406297 | 1.227927 / 1.367030 | 10.266 → 10.625 | 34.36% → 36.68% |
| 确认 1 | 49 | 1.270855 / 1.715979 | 1.250088 / 1.657204 | 10.531 → 10.563 | 37.75% → 39.68% |
| 确认 2 | 49 | 1.106757 / 1.244571 | 1.079483 / 1.185871 | 9.375 → 9.563 | 24.13% → 24.94% |

独立确认的两轮中位数分别减少 **1.6%、2.5%**。合并 98 个热样本，中位数
1.181134 → 1.119304 秒、P95 1.608895 → 1.607372 秒、CPU 中位数
9.726563 → 9.851563 秒。两轮负载分布不同，合并中位数降幅不能当作稳定
5.2% 收益；合并 P95 也基本没有改善。高负载轮中两组都没有达到 1.3 秒。
确认轮的接收等待中位数分别 1.045 → 1.013 秒、0.897 → 0.872 秒，
编码尾段变化很小，收益与慢采样点的解码等待减少一致。

两轮 50 次常驻进程的峰值 WS：DT3 为 444.35 / 438.93 MiB，DT4 为
448.55 / 443.99 MiB。所有 300 次交替生成及 300 次缓存复用断言通过；
每个进程首 AVIF 外部核对标准 SHA，其余结果由测试逐字节比较。

### 原始命令的新进程运行

使用原始命令加 `--profile`，每轮 21 对，第一次观察单列，20 对统计；第二轮
反转起始顺序。两组运行不重叠，也不与编译或其他基准混跑。

| 新进程轮次 | DT3 中位数 / P95（秒） | DT4 中位数 / P95（秒） | CPU 中位数（秒，前→后） | 其他 CPU 中位数（前→后） |
|---|---:|---:|---:|---:|
| 正向 | 1.242035 / 1.878913 | 1.294014 / 1.610473 | 9.750 → 10.492 | 25.09% → 29.43% |
| 反向 | 1.517324 / 1.696328 | 1.424503 / 1.582510 | 11.289 → 11.055 | 42.41% → 39.84% |

首轮中位数增加 4.2%，反向复测减少 6.1%，两轮外部负载明显不同；不能宣称
稳定的新进程加速，也未复现持续的中位数回退。合并 40 次/版本中位数
1.472914 → 1.398632 秒仅作描述，不作为独立收益证据。84 个 AVIF 哈希相同。
没有重启系统或清除 OS 页缓存，这些是新进程测试，不是真正磁盘冷启动测试。

### 连续运行及最终验收脚本

候选连续 50 次：峰值 WS **445.11 MiB**，峰值 commit **446.59 MiB**，低于
512,000,000 字节（488.28125 MiB）预算。热任务中位数 1.377399 秒、P95
1.550934 秒；同期其他 CPU 平均 43.86%。前/后十次中位数 1.303109 /
1.507485 秒，存在变慢，不能声称长期尾延迟稳定。50 次输出及缓存断言通过。

`scripts/bench-service.py` 新增可选 `--jobs-per-process`、`--max-p95-seconds`
和 `--max-peak-mb`。绝对预算按每个进程独立判断，热 P95 排除该进程首任务；
内存包含首任务，并明确换算 MB/MiB。缺失全部内存观测不能通过指定内存预算。
任一绝对预算或原有相对变慢检查失败均返回 2；不传绝对预算保留原来的用法。
日志和环境文件保留逐次分段时间、CPU、内存以及可执行文件哈希。

最终清理后的测试二进制执行：

```powershell
python -B scripts/bench-service.py --test-exe target/release/deps/vimg-9ed91abc5ed0c1aa.exe --dll-dir D:/ffmpeg-dev/libav-deploy --output-dir .scratch/startup/phase12/final-gate --rounds 1 --jobs-per-process 50 --max-p95-seconds 1.3 --max-peak-mb 512
```

| 最终进程 | 热样本数 | 中位数（秒） | P95（秒） | 观测峰值 WS（MB） | 其他 CPU 中位数 |
|---|---:|---:|---:|---:|---:|
| fresh | 49 | 1.425146 | 1.700852 | 464.97 | 41.63% |
| aged | 49 | 1.246158 | 1.393263 | 469.25 | 27.76% |

绝对预算超限：`True`；相对变慢：`False`。
本次返回 2，仅 P95 超限；两个进程都满足内存预算。原来只检查相对变慢时，
这组真实慢任务会被判为通过；新增门槛准确捕获了这个验收缺口。
这里测量真实服务执行与缓存路径，不包含 DDS 传输；内存为可观测到的累计
进程峰值，不能外推为任意输入或无限运行的硬上限。

### 正确性与复现材料

- 16 组输入共 4320 帧 RGB、4320 个源 PTS、16 个 AVIF 与历史标准逐字节一致。
- 清理后重新构建的最终主程序另执行原始命令，AVIF SHA 再次匹配标准值。
- 原生 release 测试 73 passed / 7 ignored；无默认特性测试 63 passed / 4 ignored。
- 基准验收逻辑 6 个测试通过；历史真实慢/快记录回放的 5 个回归检查通过。
  验证覆盖稳定但超时、各进程独立尾部、首任务排除、十进制 MB 边界、缺失
  内存观测和旧用法。Python 测试先在旧接口失败，补齐实现后通过。
- `libav.rs` rustfmt 检查、`git diff --check` 通过。既有 encode.rs 的
  unused_mut 警告保持原状。没有更改系统电源计划、安装目录或用户服务。
- 基线主程序 SHA-256：`3aa05301f12fa00ac96053b98fe7a0e4eedecc1c45d9e9fa6ff02f3cf30fd6a9`。
- 最终主程序 SHA-256：`3208446ba22ef953dfcd8a6eaa12a4280dd985fe6ea51df2500320f9ba005052`。
- 最终测试程序 SHA-256：`43470cf5a499c2f7eb9d2a3e943e34f12c5e1311a0c1ce6f88dc23af525c4a43`。
- 单变量测量主程序：`confirmation/candidate.exe`，SHA-256
  `d442396cf8bc3b1de3abf5b4f20fc5be0821790884b45670fd30717351b63b22`。
- 同二进制线程对照测试程序 SHA-256：
  `07a755967dd6d3dd741e449cd1c6e53ab53fbbe9c227a2612f2e97f6b79b76ce`。
- 材料位于 `.scratch/startup/phase12/`：`baseline/`、`probe/`、`dt4/`、
  `confirmation/`、`cli-reverse/`、`final-gate/`，以及测试日志和汇总 JSON。
  最终编译已移除临时测试开关；生产算法仅有上述长回溯线程数变化。

## 2026-09-12：延后原生编码器初始化，降低单任务内存峰值

本轮基线为 jj `884101ac`，服务默认一个 worker。先复现单任务连续生成
时约 537 MiB 的峰值，再按阶段采样，最终将 libav 预览的编码器初始化
推迟到首个完整拼图到达时。主要收益是减少解码与编码内存同时存活。

**正式交替对照的两轮峰值 WS 中位数 536.9 → 424.6 MiB，
降低 20.9%；连续 50 次生成峰值为
443.7 MiB，内存门限通过。代价是热任务中位数
1.247889 → 1.271409 秒，增加约
23.5 毫秒（1.9%）。
本轮不宣称单任务提速或全部性能预算达成。**

### 复现与定位

通过 `.scratch/startup/phase11/memory_gate.py` 驱动实际常驻服务 ignored
测试，每进程连续十次生成并检查十次缓存。基线两轮峰值
536.574 / 537.676 MiB，
输出 `MEMORY_GATE FAIL`。第一轮首任务峰值约 449 MiB，第六至十任务
逐渐超过预算；任务结束后的工作集在约 47–320 MiB 间变化。

本轮门限按 ADR-0001 的 **512 MB = 512,000,000 字节 = 488.28125 MiB**
计算；表格继续使用二进制 MiB，避免将两种单位混用。

在修改行为前，依次检查三个可证伪判断：解码/编码活跃内存重叠、重复任务
后的分配保留、等待慢采样点时的帧积压。仅在 Windows 测试构建加入
`[DEBUG-mem11]` 阶段采样，未将它混入正式性能统计。代表性首任务如下：

| 阶段 | 从任务开始约计（秒） | 工作集（MiB） | 提交内存（MiB） |
| --- | --- | --- | --- |
| 开始 | 0.000 | 22.3 | 19.3 |
| 编码器已打开 | 0.052 | 157.7 | 289.9 |
| 第一个采样点完成解码附近 | 0.323 | 452.2 | 589.1 |
| 首个完整拼图就绪 | 0.914 | 190.5 | 323.7 |
| 编码器结束 | 1.206 | 48.2 | 47.7 |

峰值出现在首个拼图就绪前，编码器尚未收到拼图，却已持有内部缓冲。
后续任务的峰值工作集升高而峰值提交内存相对稳定，不能直接按泄漏判断。
本轮先消除这一不必要的存活重叠，没有裁剪工作集、强制堆压缩或修改分配器。
正式门限复测中，峰值提交内存也从基线两轮约
599.7 / 600.9 MiB 降到
417.9 / 424.0 MiB，收益并非仅来自驻留页变化。

### 保留的实现与边界

- 仅当当前 Capture attempt 为 libav、满足固定 Preview profile、使用进程内
  AVIF 编码器时，GridEncoder 初始保存配置，在首次 write_grid 时初始化。
- 首个拼图交给原有启动路径，初始化成功后发送一次；原有 FFmpeg 编码器
  回退仍然有效。非 libav 后端、显式子进程编码与其他输出配置继续提前初始化。
- 首个拼图前捕获失败时，不创建编码器资源；没有收到拼图便 finish 会返回
  fatal 错误。既有后台线程退出、失败清理、整次后端回退及发布逻辑继续生效。
- 解码线程数、缓存容量、选帧、缩放、SVT lp=2、CRF、preset 和 DDS 均未改变。
  初始化成本现在计入首个拼图的 encoder_write 阶段，比较阶段耗时时须考虑这一点。
- 增加初始化时机的生命周期测试；常驻 ignored 测试支持
  `VIMG_BENCH_REPETITIONS`（默认 10，范围 1–1000），用于长序列验证。
  `VIMG_BENCH_EAGER_ENCODER` 仅在测试构建有效，便于同二进制对照。

设计见 [ADR-0007](docs/adr/0007-defer-native-preview-encoder-initialization.md)。
通过把资源创建放在首次实际使用的接口内，后续调整调用顺序时有明确的回归检查。

### 新进程与常驻单任务对照

独立命令沿用 `vcs -c3 -H160 -n9 sample/input.mkv --output <cache>.avif`
并加 `--profile`，基线/新版交替 21 对，首对单列，后 20 次统计。
没有重启或清除 OS/磁盘缓存，不能视为真正的磁盘冷缓存启动。

常驻对照为两轮各两个驻留进程，每次只触发一个生成任务并交替执行，每进程
十次生成和十次缓存检查；排除各自首任务后每组 18 个热任务。实际经过
Scheduler、渲染与缓存路径，不包含 DDS 传输。所有计时均与编译串行执行。

| 指标 | 基线 | 新版 |
| --- | --- | --- |
| 首次观测的新进程（秒） | 1.597767 | 1.696654 |
| 新进程中位数（秒） | 1.435806 | 1.445251 |
| 新进程 P95（秒） | 1.585901 | 1.516567 |
| 新进程 CPU 中位数（秒） | 10.945312 | 10.945312 |
| 新进程后台 CPU 中位数 | 36.46% | 35.67% |
| 常驻热任务中位数（秒） | 1.247889 | 1.271409 |
| 常驻热任务 P95（秒） | 1.395984 | 1.424250 |
| 热任务 CPU 中位数（秒） | 10.429688 | 10.359375 |
| 热任务后台 CPU 中位数 | 30.81% | 30.44% |
| 两轮服务峰值 WS（MiB） | 533.621 / 540.184 | 423.344 / 425.832 |

新进程中位数增加约 0.7%，CPU 中位数相同；热任务中位数增加约 1.9%，
后台负载中位数接近，因此保留这一小幅耗时代价，不全部归因于外部负载。
此前同二进制探索也测得约 1.7% 的热任务中位数增加，与正式对照方向一致。

### 内存门限与连续 50 次生成

重复原来的内存门限命令，仅替换测试 exe：两轮十任务峰值
424.012 / 430.094 MiB，
输出 `MEMORY_GATE PASS`。任务结束后的工作集仍在约 43–248 MiB 间变化，
本轮改善的是峰值重叠，并未强制清空全部保留内存。

再运行单进程连续 50 次生成，每次均检查对应缓存命中，50 次全部完成：

| 指标 | 新版 |
| --- | --- |
| 峰值 WS | 443.668 MiB |
| 峰值提交内存 | 440.645 MiB |
| 首十任务中位数 | 1.189951 秒 |
| 末十任务中位数 | 1.195371 秒 |
| 排除首任务后的中位数 / P95 | 1.210477 / 1.400892 秒 |
| 总进程 CPU 时间 | 514.359 秒 |
| 后台 CPU 平均估计 | 30.92% |

约 30 / 40 / 50 / 60 秒时的累积峰值 WS 为 435.2 / 435.6 / 437.8 /
443.7 MiB。50 次内没有重新超预算，但这仍是有限长度、单个代表样本的
验证，不保证任意输入或无限运行时间都满足同一限额。

**本轮内存门限通过；1.3 秒 P95 目标仍未稳定达到。** 原生后端的后续
性能工作应继续单独测量尾延迟，不能用峰值内存改善替代延迟达标。

### 未保留的尝试与正确性验证

为减少约 24 毫秒的延迟代价，额外尝试在九个采样点中六个完成后提前
初始化编码器。同二进制交替对照得到中位数 1.280187 / 1.281277 秒，
CPU 中位数 10.414 / 10.734 秒，峰值略增，未测得收益。已撤回这一
完成计数与提前初始化分支，最终保持首拼图方案。原始数据在 `prepared/`。

- 原生测试 73 passed、7 ignored；无原生功能测试 63 passed、4 ignored。
  生命周期测试在强制旧初始化模式下按预期失败，在最终模式下通过。
  原有 encode.rs unused_mut 警告保持不变。
- 正式交替服务 40 次生成、50 次长序列生成及各自缓存检查通过，全部
  输出核对旧 AVIF 字节；另外两轮内存门限测试的 20 次生成与缓存检查通过。
  独立命令 42 次输出均为旧样本 SHA-256：`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- 16 个视频样本，包括 H.264、HEVC、VFR、长 GOP、多流、时间偏移、
  帧率边界、色彩范围、非方形像素和隔行输入：共 4320 RGB 帧、4320
  源 PTS 以及全部 AVIF 均与既有 golden 完全一致。
- 所有本轮临时阶段采样已从源码移除；未获益的预初始化代码也已撤回。
  归档在 `.scratch/startup/phase11/`，正式数据在其 `final/` 子目录：
  `cli-results.json`、`paced-results.json`、`memory-check/memory-gate.json`、
  `long-results.json`、`verified/results.json`，以及逐次日志与驱动脚本。
- 恢复最终方案后重新运行原生测试。复编译测试 exe 与实测 exe 的指令
  和数据一致，仅 PE 链接时间戳及 PDB age 不同；归一这两个字段后字节
  完全相同，校验记录见 `test-identity.json`。主程序仍是实测版本。

| 二进制 | SHA-256 |
| --- | --- |
| 基线主程序（884101ac） | `0e6b5948d1d91bee6948e38976bed21311f233b718079df7877a35c39c90ee3c` |
| 正式主程序 | `3aa05301f12fa00ac96053b98fe7a0e4eedecc1c45d9e9fa6ff02f3cf30fd6a9` |
| 基线测试程序 | `09bb84543c4f8d6b246c7609ef4f96ec939e5a272ff3690678fd0a53401fd1f1` |
| 实测正式测试程序 | `841dd412a788c2a60b9515a423c3063a7370b457510aacf671a5b0f2e47df47d` |
| 恢复后复编译测试程序 | `695857e3e0cc6d9ddd50969e59d7358dcaeecbaf61293003fcaaa581ce8c10b7` |

交付 `target/release/vimg.exe`；已安装的 exe 和用户正在运行的服务未被替换。

## 2026-09-12：限制服务并发，降低批量任务的 CPU 与内存开销

本轮基线为 jj `917eb598`。保留上一轮 Windows 高性能核心策略，仅调整服务
同时执行的任务数。现有 CONTEXT.md 与 ADR-0001 约定默认一个执行任务、
最多九个排队任务，但代码实际启动十个 worker；每个视频内部又有多路解码
与编码并行。本轮恢复默认一个 worker，并增加 `serve --jobs 1..10`（`-j`）。

**正式版本同二进制 ABBA 对照：十任务批次的首个输出中位数
12.136 → 1.216 秒，峰值 WS 中位数
3942.0 → 537.3 MiB，减少
86.4%；进程 CPU 时间
139.352 → 106.992 秒。整批耗时
12.372 → 12.932 秒。**

正式对照的整批中位数增加 4.5%，
CPU 时间减少 23.2%。
本轮以少量批量吞吐代价换取首个预览延迟和资源占用的明显改善；探索轮的
整批提速没有在正式对照中重现，不将其作为稳定收益。

### 行为与取舍

- `vimg serve` 默认一个正在执行的预览，最多九个排队；`--jobs 4` 可提高
  批量并发，`--jobs 10` 恢复此前的最大并发。运行和排队的任务总数仍不超过十。
- 最新排队任务优先执行。满容量时保留正在运行的任务，替换最旧的未开始
  任务；只有十个任务全部运行时，新独立请求才收到 `busy`。重复请求继续合并。
- worker 数量在启动时确定，对原生后端、显式 FFmpeg 和自动回退均生效。
  CPU 策略、解码、选帧、缩放、编码参数、缓存和 DDS 协议不变。
- 四并发在探索测试中整批吞吐最佳，但首个预览更晚、内存更高。因此默认
  按交互预览预算选择一并发；不声称它适合所有视频、硬件或批处理负载。
  见 [ADR-0006](docs/adr/0006-bound-preview-service-concurrency.md)。

### 实验方法与探索结果

新增 ignored 测试 `command::serve::tests::queued_service_jobs_and_cache_hits`。
预先提交十个不同缓存路径、同一 `sample/input.mkv` 的任务，提供完整媒体
描述，进程静置十秒后释放指定数量的 worker。使用实际 Scheduler、
complete_job、渲染、manifest 发布和缓存校验路径。CPU 策略为 auto，本机
使用 16 个高性能逻辑 CPU。没有编译与性能测量同时执行。

首个输出和整批耗时从释放批次开始计时，不含十秒静置、提前探测、DDS
传输，也不含已有执行任务的剩余时间；因此不等于用户请求到展示的完整
交互延迟。CPU 为子进程生存期的累计 CPU 时间，峰值 WS/commit 使用
Windows 进程计数器。后台 CPU 估计包含静置区间，不能当作渲染期间的精确负载。

同一探索二进制按 `10,1,2,4`、`4,2,1,10` 的顺序运行；每种两次，以下
各项为两次观测的中位数。此样本量不用于计算批次 P95。

| 并发 | 首个输出（秒） | 整批（秒） | 进程 CPU（秒） | 峰值 WS（MiB） | 峰值 commit（MiB） |
| --- | --- | --- | --- | --- | --- |
| 1 | 1.273611 | 12.069111 | 105.781 | 542.1 | 603.5 |
| 2 | 2.588315 | 11.611451 | 132.492 | 939.4 | 1145.6 |
| 4 | 4.221471 | 10.683525 | 136.484 | 1637.7 | 2228.1 |
| 10 | 13.825861 | 14.169948 | 152.289 | 3882.2 | 5220.0 |

探索轮十并发的后台 CPU 均值估计约 34.9%，一并发约 24.6%；存在负载
差异，不能把全部墙钟差值归因于代码。因此另外用正式版本重复 ABBA。

### 正式版本：十并发与默认一并发

同一个正式测试二进制按 `10,默认,默认,10` 顺序执行。默认组没有设置
worker 环境覆盖，直接使用生产 CLI 解析出的默认值；十并发组经同一个
CLI 解析器设置 `--jobs 10`。原始四次观测如下：

| 轮次 | 并发 | 首个输出（秒） | 整批（秒） | 进程 CPU（秒） | 峰值 WS（MiB） | 后台 CPU 估计 |
| --- | --- | --- | --- | --- | --- | --- |
| 1 | 10 | 13.065429 | 13.234589 | 142.875 | 3929.7 | 32.05% |
| 1 | 1 | 1.223560 | 13.756487 | 112.328 | 537.2 | 29.27% |
| 2 | 1 | 1.208465 | 12.107964 | 101.656 | 537.4 | 23.22% |
| 2 | 10 | 11.206505 | 11.509978 | 135.828 | 3954.3 | 23.77% |

最新排队任务在默认一并发下均为首个完成。所有十任务批次均生成完整输出，
没有靠丢弃任务缩短总耗时。仍有后台负载波动；内存和首个输出的差异明确，
整批速度不应推广为其他机器上的固定提升比例。

### 单任务：独立新进程与常驻服务

独立命令沿用 `vcs -c3 -H160 -n9 sample/input.mkv --output <cache>.avif`
并加 `--profile`，基线与候选交替 21 对，首对单列，后 20 次统计。
常驻对照为两轮各两个进程，按交替顺序逐一触发任务；每进程十次生成和
十次缓存检查，排除各自首任务后每组 18 个热任务。每次只触发一个生成，
用于检查此前单任务延迟收益是否保留，不用于证明 worker 池并发行为。

| 指标 | 基线 | 新版 |
| --- | --- | --- |
| 首次观测的新进程（秒） | 1.445704 | 1.408452 |
| 新进程中位数（秒） | 1.261803 | 1.299899 |
| 新进程 P95（秒） | 1.321420 | 1.391774 |
| 新进程后台 CPU 中位数 | 29.34% | 32.52% |
| 常驻热任务中位数（秒） | 1.244887 | 1.240860 |
| 常驻热任务 P95（秒） | 1.491011 | 1.642444 |
| 热任务 CPU 时间中位数（秒） | 10.421875 | 10.507812 |
| 热任务后台 CPU 中位数 | 28.47% | 30.84% |

首轮 CLI 候选中位数高约 3%，同时后台负载更高，因此反转每对运行顺序再
测 21 对，同样剔除首对。没有修改或重编译二进制，也保留首轮全部数据。

| 反序 CLI 复测指标 | 基线 | 新版 |
| --- | --- | --- |
| 新进程中位数（秒） | 1.447680 | 1.434805 |
| 新进程 P95（秒） | 1.563500 | 1.591875 |
| 进程 CPU 中位数（秒） | 11.101562 | 10.898438 |
| 后台 CPU 中位数 | 33.76% | 33.43% |

反序复测的中位数差值约 -0.9%，首轮约 3% 的上升未稳定复现。两轮都
存在外部负载变化，结论限定为未观察到稳定的 CLI 中位数退化，不宣称冷启动提速。

常驻热任务中位数基本持平，尾部仍受波动影响：候选最高 1.642444 秒的
观测同时记录约 54.33% 后台 CPU，基线最高 1.491011 秒对应约 43.51%。
这是同时观测，不能单独证明负载是全部原因；保留尾部原始值，不声称本轮
改善单任务 P95，也不删除高负载样本。

未重启或清除 OS/磁盘缓存，新进程数据不代表真正的磁盘冷缓存启动。
本轮目标是服务批量资源预算，独立命令未修改解码或编码路径，不能把小幅
时间差解释为新的单任务算法提速。512 MB 单任务内存预算仍未达到；绝对
1.3 秒 P95 也需要结合负载继续验证，不能用首个输出或中位数替代。

### 正确性、构建与复现

- 原生 release 测试：72 passed、7 ignored；无原生功能测试：63 passed、
  4 ignored。ignored 性能案例另行执行。原生测试仅保留既有 encode.rs
  的 unused_mut 警告。修改文件通过 rustfmt 检查与 git diff --check。
- 探索 80 次、正式批次 40 次、常驻 40 次，合计 160 次服务渲染与相应
  160 次缓存命中检查通过；独立命令两轮另外完成 84 次。输出均与旧基准 AVIF
  字节一致，SHA-256 为 `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- 默认值与 `--jobs/-j` 的 1–10 全范围、非法值、一个运行加九个排队时的
  保护/替换、十个运行时 busy、合并与失败清理均有测试覆盖。
- 主程序产物：`target/release/vimg.exe`。本轮未替换已安装的基线 exe，
  也未重启用户现有服务。服务采用新参数需要使用新 exe 启动。
- 原始数据与脚本在 `.scratch/startup/phase10/`：`queue-probe-results.json`、
  `queue-final-results.json`、`cli-results.json`、`cli-repeat-results.json`、
  `paced-results.json` 及逐次日志。
  queued ignored 测试支持 `VIMG_BENCH_BATCH_JOBS`（默认十）、
  `VIMG_BENCH_BATCH_WORKERS`（缺省使用 CLI 默认）、
  `VIMG_BENCH_VIDEO` 和 `VIMG_BENCH_REFERENCE_AVIF`，可独立复现。

| 二进制 | SHA-256 |
| --- | --- |
| 基线主程序（917eb598） | `714381a10a3dae5a8628beee294acfd9c5b9a89a515a42820e834132c2fce95f` |
| 新版主程序 | `0e6b5948d1d91bee6948e38976bed21311f233b718079df7877a35c39c90ee3c` |
| 基线测试程序 | `516d8e1403acb1318444d70e6c04482e3ca20baf333f305ab4e0f83bcf2c26f2` |
| 正式测试程序 | `09bb84543c4f8d6b246c7609ef4f96ec939e5a272ff3690678fd0a53401fd1f1` |
| 探索测试程序 | `1f4f20472d203a12e14d228970260718e2e9182117b4e4c151e3a0f7828c0cfc` |

## 2026-09-12 21:25：Windows 常驻预览采用高性能核心策略

本轮基线为 jj `6238867d`。先验证直接 swscale 替代滤镜图，未保留；随后在
同一台 i9-12900K 上再次复现常驻服务后段约 1.9 秒的退化，并以同一二进制
的 CPU 亲和性对照找到有效干预。最终只修改服务启动策略、相关选项与验证
入口，解码、选帧、缩放和编码代码均保留基线实现。

**正式实现的交替服务测试：热任务中位数 1.870436 → 1.101348 秒，
P95 1.996558 → 1.274190 秒，约缩短 41%。单次 CLI 中位数
1.237219 → 1.230888 秒，基本持平。高负载复测仍出现约 1.45 秒的 P95，
且单服务峰值 WS 仍超过 512 MB，因此不宣称全部性能预算已达成。**

### 保留的代码与适用范围

- `serve --cpu-policy auto` 默认在支持原生解码的 Windows 构建、auto/libav
  后端下，根据 Windows CPU Set 的 EfficiencyClass 选择最快的一类核心。
  本机选出 16 个逻辑 CPU；掩码由系统数据计算，没有硬编码 `0xffff`。
- 在创建服务 worker 前设置本进程亲和性；保留已有的亲和性和 process-default
  CPU Sets。同构 CPU、多处理器组、无可用高性能核心、其他平台及显式选择
  `--capture-backend ffmpeg` 时继续使用系统调度。auto 的整次回退仍沿用
  服务启动时的策略。查询或设置失败只打印提示，不让服务启动失败。
- `serve --cpu-policy all` 保持系统调度，供批量任务及其他硬件比较使用。
  独立 `vcs` 命令的调度策略保持不变。未修改全局电源计划、进程优先级、
  缓存版本、DDS 协议或十任务容量。

Windows 将更高的 EfficiencyClass 定义为更快、能效更低的核心；自动策略
依据这一公开字段，而不依赖处理器编号顺序。
[Microsoft CPU Set 文档](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information)。
设计与边界见 [ADR-0005](docs/adr/0005-windows-preview-service-cpu-policy.md)。

### 退化复现与可证实的结论

直接缩放实验的两轮单服务测试，两个版本都在第 8–10 个任务变慢。基线
前七任务中位数 1.157898 / 1.152103 秒，末三任务 1.907696 / 1.808662 秒。
因此这次退化不是缩放候选引入的。变慢时记录的后台 CPU 比例反而降低，不能
仅凭“此前别的程序 CPU 高”解释这组现象。

随后只使用原基线测试程序，在启动后静置十秒，再运行十次生成与缓存检查。
按默认 / 高性能核心 / 高性能核心 / 默认的 ABBA 顺序执行四个独立进程：

| 调度 | 20 任务中位数 / P95（秒） | 两轮首三任务中位数（秒） | 两轮末三任务中位数（秒） |
| --- | --- | --- | --- |
| 系统默认 | 1.942406 / 2.129684 | 1.932256 / 1.948177 | 2.054028 / 1.854198 |
| 高性能核心 | 1.093907 / 1.190286 | 1.117347 / 1.093932 | 1.012303 / 1.111626 |

这说明不需要先累积任务便可变慢，并支持大小核调度相关的解释；没有获得
线程调度轨迹，仍不能断言 Windows 内部究竟使用了哪个调度机制。上一轮
WPR 的 Windows 管理员权限限制未改变，本轮没有重复尝试或修改系统设置。
诊断原始数据：`.scratch/startup/phase8/aged-affinity/`。

### 正式实现：新进程与常驻服务

新进程使用原命令参数并加 `--profile`，基线与正式候选交替 21 对。首对
单列，余下每组 20 次统计；每次 AVIF 均为相同 SHA-256。没有重启或清除
操作系统/文件缓存，本表不代表真正的磁盘冷缓存启动。

| 指标 | 基线 | 新版 |
| --- | --- | --- |
| 首次观测的新进程（秒） | 1.546669 | 1.433798 |
| 新进程中位数（秒） | 1.237219 | 1.230888 |
| 新进程 P95（秒） | 1.365349 | 1.428866 |
| 新进程 CPU 时间中位数（秒） | 10.015625 | 9.765625 |
| 新进程后台 CPU 中位数 | 29.18% | 28.58% |
| 常驻热任务中位数（秒） | 1.870436 | 1.101348 |
| 常驻热任务 P95（秒） | 1.996558 | 1.274190 |
| 热任务 CPU 时间中位数（秒） | 9.585938 | 9.507812 |
| 热任务后台 CPU 中位数 | 17.28% | 24.72% |
| 单服务两轮峰值 WS（MiB） | 548.316 / 548.719 | 533.594 / 537.816 |

常驻表为两轮各两个驻留进程，每次只触发一个生成任务，按 ABBA 交替；各
进程生成十次并检查十次缓存命中，剔除各进程首任务后每组 18 个热任务。
采样同时记录系统/进程 CPU 时间及 Windows 峰值 WS。它经过真实服务渲染
与缓存路径，不含 `ya` DDS 消息传输耗时。该轮新版后台负载反而更高，仍有
明确延迟收益。CLI P95 有上升，候选尾部两次对应约 39–42% 的后台 CPU；
不据此声称 CLI 有提速或稳定的尾延迟改善。

再运行原有退化检测脚本，新版立即工作与静置十秒的首三任务中位数分别为
1.093581 / 1.235875 秒（比值 1.130）；各自末三/首三比值为 1.154 / 0.972，
未超过 1.3 退化门限，脚本退出 0。但该轮热任务 P95 分别为 1.431084 /
1.447788 秒，后台 CPU 最高约 45%，**通过相对退化检查不等于通过绝对
1.3 秒 P95 预算**。详见 `.scratch/startup/phase9/age-gate/`。

### 批量吞吐与 CPU 代价

使用同一正式测试二进制，切换测试专用 all / auto 参数，先静置十秒，再在
同一进程同时释放 4 或 10 个实际服务渲染调用。每种规模按 ABBA 执行，每组
两次；每个批次内的所有 AVIF 字节一致。这是渲染吞吐测试，不包含 DDS
消息处理，也不替代既有调度器容量测试。

| 并行任务数 | 策略 | 两轮批次完成时间（秒） | CPU 时间中位数（秒） | 峰值 WS 中位数（MiB） | 峰值提交内存中位数（MiB） |
| --- | --- | --- | --- | --- | --- |
| 4 | all | 6.784204 / 6.415816 | 38.453 | 1705.0 | 2298.3 |
| 4 | auto | 3.770432 / 3.857355 | 52.648 | 1625.9 | 2218.4 |
| 10 | all | 17.631929 / 18.500138 | 99.109 | 4852.6 | 5825.2 |
| 10 | auto | 11.488844 / 10.720655 | 138.375 | 3959.3 | 5391.5 |

4 任务的批次时间约缩短 42%，10 任务约缩短 39%；对应总 CPU 时间增加约
37% / 40%。保留默认自动策略是为了预览延迟和本轮批次完成时间，不能把它
描述成所有维度都更省资源；`--cpu-policy all` 保留原调度选择。批量峰值
内存是整个并行进程的口径，不是单任务内存预算通过的证据。

### 正确性、构建与复现

- 原生 release 普通测试：71 passed、6 ignored；无原生功能普通测试：
  62 passed、4 ignored。新增测试覆盖 CPU 拓扑解析和命令行策略选择。
- 真实服务交替测试的四个进程，首输出均与基线 SHA-256 一致；各进程内
  后续九个输出逐字节对照首输出，并验证全部缓存命中。
- 为扩展输入覆盖，对正式 CLI 子进程施加与服务相同的高性能核心亲和性，
  对照此前未改动的基线原始输出：H.264、HEVC、VFR、长 GOP、多视频流、
  音频先出现、时间偏移、5/60/29.97 fps、短视频、BT.709 limited/full、
  非方形像素和隔行等共 16 组；4,320 个 RGB 帧、4,320 个 PTS 和 16 个
  AVIF 全部一致。此处没有将 CLI 等价亲和性测试称为完整 DDS 端到端测试。
- 修改的 Rust 文件通过 rustfmt 检查，diff 空白检查通过。既有 encode.rs
  测试中的 unused_mut 警告仍在；未为此修改无关代码。

```powershell
cargo build --release --features in-process-decode
cargo test --release --features in-process-decode --no-run
python scripts/bench-service.py --test-exe target/release/deps/vimg-9ed91abc5ed0c1aa.exe --dll-dir D:/ffmpeg-dev/libav-deploy --output-dir .scratch/service-cpu-policy-new --rounds 1 --idle-seconds 10
.\target\release\vimg.exe serve
# 对照原系统调度：
.\target\release\vimg.exe serve --cpu-policy all
```

构建沿用 `D:/ffmpeg-dev/ffmpeg-8.1.2-full_build-shared/lib/pkgconfig` 和
`D:/ffmpeg-dev/libav-deploy` 的本地配置；所有计时均在编译结束后执行。
最后扩展正确性验证与无原生功能编译可以并行，但这些运行未纳入计时。
电源方案仍为高性能 `8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c`，未修改。

基线 exe SHA-256：`47d8e7a0df52cd9671fbe5803f40bc181c325fe46837323dbbee0b1634547663`。
正式 exe SHA-256：`714381a10a3dae5a8628beee294acfd9c5b9a89a515a42820e834132c2fce95f`。
正式测试 exe SHA-256：`516d8e1403acb1318444d70e6c04482e3ca20baf333f305ab4e0f83bcf2c26f2`。
主样本 AVIF SHA-256：`3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。

详细数据与脚本在 `.scratch/startup/phase9/`：`summary.json`、
`paced-results.json`、`parallel-results.json`、`age-gate/`、`verified/`、
`final-summary.json`。发布产物为 `target/release/vimg.exe`，未替换
`D:/Apps/ffmpeg/vimg.exe`，也未重启用户已有服务。

### 未保留：直接缩放原型

先实现了直接 `sws_scale_frame` 替换滤镜图的局部原型；算法、颜色属性与
单线程策略对齐现有滤镜，目的只是移除图初始化和逐帧流转开销。原型每帧
由 swscale 分配目标缓冲区，尚不包括持久缓冲区复用。与基线对照的 16 组
输入、4,320 帧、PTS 和 AVIF 均一致，主样本 30 个编码前/解码后网格也一致。

新进程中位数 1.271554 → 1.250025 秒（约 -1.7%），但后台 CPU 中位数
24.91% → 22.18%；交替服务中位数 1.924204 → 1.907030 秒（约 -0.9%），
CPU 时间 9.531250 → 9.570313 秒，峰值内存没有稳定改善。单进程服务两轮
末三任务对照分别为 1.907696 → 1.815349 和 1.808662 → 1.900450 秒，方向
相反。证据不足以保留额外 FFI 与颜色适配维护成本，因此生产 libav.rs 已
完整恢复。此结论只针对该原型，不能排除未来直接写入可复用缓冲区的收益。

原型代码与二进制仅保存在 `.scratch/startup/phase8/`，候选 SHA-256 为
`a840df07e32dbd73e31bcd836bce025d4b865b8fbada60f307ab35025a7c301a`；未进入正式发布程序。

## 2026-09-12 20:12：已知时长的帧提前提交，减少解码工作与服务内存占用

本轮基线为 jj `95d4bf46`，生产程序仍是 `9f4f9269`。保留一项局部优化：
帧的 packet duration 已知且为正时，直接进入缩放与 CFR 选帧，不再等待下一
个解码帧；缺少 duration 时继续保留帧并用下一时间戳推断。选满三十帧后
立即停止接收，避免继续保留不需要的下一帧。完整 probe、seek、预滚恢复
策略、2/3 解码线程选择、缩放与编码配方均未改变。

**主样本解码帧数从 566 降到 557，预滚仍为 254。单服务进程的峰值 WS
两轮减少约 8–16 MiB，峰值提交内存减少约 18–19 MiB。整次耗时的收益尚不
稳定，本轮按减少工作量和内存占用保留，不宣称冷启动或热任务显著提速。**
十二组输入输出完全一致；历史约 1.8 秒的服务变慢仍未确定根因。

### 现状复测与调度记录限制

先使用上一轮通用基准运行二十个生成任务和二十次缓存命中检查。立即开始
与静置十秒的前三任务中位数为 1.257507 / 1.173627 秒，末三任务为
1.227639 / 1.110201 秒，没有复现原有明显退化。对应数据在
`.scratch/startup/phase7/initial/`，未将这组结果混入候选比较。

准备了只启用 CpuConfig、ProcessThread、CSwitch、ReadyThread 和
ThreadPriority 的 WPR profile，缓冲上限配置为 64 × 256 KiB，不采集调用栈。
启动记录时 Windows 返回 `0x80070005 Access is denied`；工具沙箱升级执行
也未提供所需的 Windows 内核跟踪权限。**没有生成有效调度轨迹**，并确认
WPR 未处于记录状态。

只读 CPU Sets 查询确认逻辑处理器 0–15 的 EfficiencyClass 为 1，16–23 为
0。官方说明更大的 EfficiencyClass 表示更高性能、较低能效；这是拓扑信息，
并不能证明 vimg 实际运行在哪些核心上。[Microsoft CPU Set 信息](https://learn.microsoft.com/en-us/windows/win32/api/winnt/ns-winnt-system_cpu_set_information)
当前没有改变线程亲和性、进程优先级或全局电源方案。WPR profile 与自动结束
记录的脚本保存在实验目录，供具备权限时使用；本轮不据此推断具体调度根因。

### 新进程 AB/BA

命令仍为 `vcs -c3 -H160 -n9 sample/input.mkv --output <实验目录>/cli-<版本>.avif --profile`。
Python CreateProcess 启动无控制台进程，先记录每版首次观测，再交错执行
二十轮 AB/BA。统计不含首次观测，P95 为 nearest-rank。计时期间没有编译、
像素 dump 或调度记录。未重启、未清空文件缓存，**不是磁盘冷缓存基准**。

| 新进程，二十次/版本 | 基线 | 候选 |
|---|---:|---:|
| 墙钟中位数 | 1.228924s | 1.233011s |
| 墙钟 P95 | 1.322506s | 1.315743s |
| 进程累计 CPU 中位数 | 9.789062s | 9.703125s |
| 其余 CPU 占用估算中位数 | 29.3% | 29.6% |
| 首次观测，单次不入统计 | 1.256103s | 1.192781s |

墙钟中位数增加约 0.3%，CPU 中位数减少约 0.9%；profile 总耗时中位数
1.1385 → 1.1380 秒，属于基本持平。首网格仅 0.7830 → 0.7765 秒，不能把
少解九帧直接换算为同等比例的整次提速，长预滚仍占主要成本。

### 服务交错任务与单进程连续任务

第一组用同一生产配置的两版 release 测试程序同时驻留，逐任务交错放行，
每次只处理一个任务，两轮交换开始顺序。共四十次生成及四十次缓存命中
断言通过。排除每进程首任务后，每版本十八个热任务：

| 逐任务交错 | 基线 | 候选 |
|---|---:|---:|
| 热任务中位数 | 1.137123s | 1.124487s |
| 热任务 P95 | 1.378594s | 1.337009s |
| 任务 CPU 中位数 | 9.867188s | 9.632812s |
| 其余 CPU 占用估算中位数 | 26.9% | 28.3% |
| 两轮峰值 WS | 557.9 / 570.0 MiB | 552.0 / 547.1 MiB |

该组墙钟约减少 1.1%，CPU 约减少 2.4%，峰值 WS 分别减少 6.0 / 22.8 MiB。
由于两个进程的驻留与任务间空闲可能影响内存驻留，再补充单个服务进程
连续运行的四段 A/B/B/A，每段十次生成与十次缓存命中，全部通过：

| 顺序 | 热任务中位数 / P95 | 其余 CPU 平均估算 | 峰值 WS | 峰值提交内存 |
|---|---:|---:|---:|---:|
| 基线 0 | 1.133150 / 1.256101s | 30.4% | 560.3 MiB | 631.9 MiB |
| 候选 0 | 1.133255 / 1.293927s | 32.5% | 544.2 MiB | 614.1 MiB |
| 候选 1 | 1.207252 / 1.295512s | 34.4% | 552.2 MiB | 612.4 MiB |
| 基线 1 | 1.115997 / 1.158957s | 26.4% | 560.7 MiB | 631.0 MiB |

连续热任务合并中位数 / P95 为 1.119387 / 1.256101 →
1.150909 / 1.295512 秒，候选更慢；候选的外部负载也更高。这一结果保留在
报告中，因此不把交错组的微小时间差当成已证实的热任务提速。
峰值提交内存两轮分别减少 17.8 / 18.6 MiB，支持减少解码缓冲持有的资源
收益。提交内存与工作集不是同一指标，不能把提交内存作为 RSS 使用。

两种服务比较都直接调用真实服务执行路径，不包含 DDS/ya 通知，也不是
十任务并发。当前候选连续组 P95 恰在 1.3 秒内，但交错组为 1.337 秒，
**仍不能宣称全面满足 1.3 秒 P95 目标；单服务峰值 WS 544–552 MiB 也仍
超过 512 MiB。** 内存记录使用 Windows 累计峰值计数，进程退出后的缺失
读数不当作零值。

### 工作量与正确性

主样本视频包消费 1111 → 1102，解码帧 566 → 557。八组原有样本中，
H.264 为 538 → 528、HEVC 为 537 → 527、VFR 为 421 → 413、长 GOP 为
699 → 690；预滚帧数均不变。减少的是输出窗口尾部不再需要的解码与帧引用，
没有放宽预滚或丢帧恢复规则。

十二组输入包括主样本、H.264 MP4、HEVC MKV、VFR MKV、长 GOP MP4、
双视频流、音频在前、非零起始时间，以及新增的 5fps、60fps、30000/1001fps
和 0.8 秒短视频。**3240 帧 RGB、3240 个源 PTS、十二个最终 AVIF 均与
基线逐字节一致。** 主样本 authority 的 270 个 PTS/time-base、三十张编码前
网格、三十张解码后网格及 AVIF 也一致。

release 特性测试 67 passed / 5 ignored，无默认特性测试 58 passed /
4 ignored。本轮代码的 rustfmt 与 git diff --check 通过；构建仍提示未改动的
encode.rs 测试变量有既有 unused_mut 警告。十二组输入检查直接执行修改后的
libav 路径及完整编码链路。

### 产物及复现

最终 `target/release/vimg.exe` SHA-256：
`47d8e7a0df52cd9671fbe5803f40bc181c325fe46837323dbbee0b1634547663`。

基线主程序 SHA-256：`9e3256f2934281a52447eae1e8f84b9c1c3b80955b531dfa9614cbe44b41f29e`。

候选 release 测试程序 SHA-256：
`5fc79e8b508d33a6a03ddd863a8f3ddce3d86c4c4e90b347eb355820e8c14489`。

本地忽略目录 `.scratch/startup/phase7/` 保留两版程序、`cli-results.json`、
`paced-results.json`、`paced-summary.json`、`service-results.json`、
`summary.json`、逐次日志和 Python 驱动；正确性材料在 `verification-final/`、
`boundaries/`、`authority/`，工作量计数在 `verification-final/work-counts.json`。
`scheduler.wprp`、`capture.ps1`、`trace_jobs.py` 是未成功启用的调度跟踪准备
材料，`cpus.json` 仅为拓扑快照。PATH 中已安装的程序未被替换。

## 2026-09-12 19:50：静置变慢本轮未复现，加入可重复运行的服务对照基准

继续追踪上一轮“进程静置十秒后，首任务也变慢”的现象。本轮没有改动 Rust
生产代码、FFmpeg 参数、优先级、亲和性或电源设置；主程序仍为 jj `9f4f9269`
的产物。**同一测试程序在当前环境中不再稳定复现此前约 1.6 倍的变慢，
不能把进程存活时间认定为充分触发条件，也不宣称问题已经修复。**

### 先检查原有复现条件

沿用上轮 `paced-test.exe`，SHA-256 为
`7cd71c38c0bf6f5070aa15167f085c9eab40764642647d3b51d09dfef1d0411c`。
先静置十秒与立即开始，各十任务，当前 6 秒线程门槛下，前三个任务中位数
分别为 1.173692 / 1.091338 秒，比值 1.075；双方后段仍约 1.1–1.3 秒。
首轮驱动的汇总变量名错误已修正，完整原始测量数据保留，并由后续正式驱动
重新完成对照。子进程的生成及缓存断言均通过。

再用 test-only 开关恢复旧 1.5 秒线程门槛，静置三十秒后处理十任务：前三个
中位数 1.131492 秒，后三个 1.120758 秒，仍未复现。另一次当前 6 秒策略
立即开始的十任务为 1.120995 / 1.058276 秒。旧策略也稳定，说明本轮恢复
正常不能仅归功于上一轮线程调整。

分阶段记录显示，本轮三十秒静置后的旧策略解码约 0.907–1.046 秒、编码
收尾约 0.166–0.199 秒。此前 `phase3/service-profile.json` 中的慢任务则
同时出现解码约 1.48 秒、编码收尾约 0.34 秒，总 CPU 仍约 9.2–9.3 秒。
这提示需要在异常发生时区分线程运行、就绪与等待，而不是继续假设某个
Capture 窗口或累计分配次数必然触发。由于本轮没有得到相同慢任务现场，
尚未采集能确认根因的快/慢调度轨迹，没有凭正常任务数据调整线程亲和性。

当前只读查询得到电源方案为“高性能”，GUID
`8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c`，24 个逻辑处理器。上轮没有记录
全局电源方案，不能证明两轮之间设置是否变化。也没有发现名称匹配
Process Lasso / ParkControl 等工具的运行进程；这不是排除第三方调度影响
的完整证据。已询问用户两轮之间是否调整过相关设置，当前未获得确认。

### 正式 AB/BA：同一二进制的立即运行与静置十秒

新增 `scripts/bench-service.py`，仅依赖 Windows 和 Python 标准库。调用
现有 ignored 服务基准，每个进程执行十次真实生成与十次缓存命中断言；
第一轮先立即运行再静置运行，第二轮交换顺序。一次只运行一个基准进程，
没有同时编译或像素 dump。命令不是从磁盘冷缓存启动，测量也不包含 DDS/ya
通知耗时；测试期间清除子进程继承的 VIMG 实验开关，使用当前生产门槛。

| 执行顺序 | 前三任务中位数 | 后三任务中位数 | 其余 CPU 占用中位数 | 进程峰值 WS |
|---|---:|---:|---:|---:|
| 第 0 轮，立即运行 | 1.308989s | 1.140516s | 28.4% | 566.7 MiB |
| 第 0 轮，静置十秒 | 1.272409s | 1.504791s | 38.4% | 558.5 MiB |
| 第 1 轮，静置十秒 | 1.221496s | 1.112863s | 36.5% | 556.4 MiB |
| 第 1 轮，立即运行 | 1.126862s | 1.217094s | 30.9% | 568.6 MiB |

静置组与立即运行组的前三任务比值分别为 0.972 / 1.084，没有重复此前
约 1.60 的差异。第 0 轮静置组后段仍有约 18% 上升，同时外部负载更高，
不能把所有时序波动都视为同一个根因。

每进程排除首任务后，两组各 18 个热任务：立即运行中位数 / P95 为
1.216003 / 1.350517 秒，静置十秒为 1.269610 / 1.534036 秒。P95 使用
nearest-rank，18 个样本时等于最大值。**没有触发相对变慢检测，不等于
通过 1.3 秒 P95 或 512 MiB 内存目标；本轮这两项目标仍未满足。**

### 基准使用及校验

先生成带 in-process-decode 的 release 测试二进制，并在 DLL 可用的环境运行：

```powershell
cargo test --release --features in-process-decode --no-run
python scripts/bench-service.py --test-exe target/release/deps/vimg-9ed91abc5ed0c1aa.exe --dll-dir D:/ffmpeg-dev/libav-deploy --output-dir .scratch/service-age-new --rounds 2 --idle-seconds 10
```

测试二进制名称随构建变化，应采用 cargo 输出的路径；不是普通的 vimg.exe。
输出目录必须尚不存在，避免覆盖旧证据。脚本记录二进制 hash、视频大小与
修改时间、当前电源方案、逐任务阶段耗时、累计线程 CPU、其余 CPU 占用
估算、缓存耗时和进程累计峰值内存，以及完整 stdout/stderr 日志。
内存计数在任务边界读取，若进程已经退出则记为缺失，不伪造零值。

默认相对检测门槛为 1.3 倍：检查同一进程末三任务相对前三任务，以及每轮
静置组前三任务相对立即运行组前三任务；超过时退出码为 2，错误退出为 1，
未触发相对检测为 0。它只是异常检出信号，不能自动证明代码回归或修复。

用 `phase5-threshold/age-results.json` 回放检出历史异常：前三任务比值
1.601，判红；本轮初次对照比值 1.075，判绿。正式驱动的 40 次生成和
40 次缓存检查通过，错误传入普通 vimg.exe 也能快速报错并清理子进程。
本轮共 80 次真实生成及 80 次缓存断言通过；没有生产代码变化，因此未重复
上轮八组像素/PTS 校验，也没有把缓存断言当成新的跨版本像素比较。

原始数据在 `.scratch/startup/phase6/`：`age-results.json`、`old-aged30.json`、
`new-fresh.json`、`detector-validation.json`、`controlled/` 下逐进程 JSON、
日志、`summary.json` 和 `environment.json`。这些本地实验文件被忽略；
通用驱动进入版本管理，以便异常重现时使用同一命令收集证据。

主程序 `target/release/vimg.exe` SHA-256 仍为
`9e3256f2934281a52447eae1e8f84b9c1c3b80955b531dfa9614cbe44b41f29e`。
后续若再次出现稳定变慢，应在同一系统状态下采集线程调度记录，再验证
调度竞争、核心分配或应用等待的具体假设；当前证据不足以选择其中一个。

## 2026-09-12 14:55：减少短预滚解码线程，复现与进程存活时间相关的服务变慢

本轮基线为 jj `28919ab5`，生产代码仍为 `7f3d8450`。保留一项生产调整：
第三个帧解码线程的预滚门槛由 1.5 秒提高到 6 秒。主样本九路 Capture 的
配置线程数合计从 23 降为 20；只有两个长预滚窗口使用三个线程，其余使用
两个。这不是进程的全部 OS 线程数。完整 probe、seek、选帧、缩放及编码
参数不变，主样本仍解码 566 帧，其中预滚 254 帧。

新进程两轮独立比较都观察到 CPU 时间下降约 2.7%，墙钟中位数下降约
2.2% / 4.9%；服务峰值 WS 减少约 14–22 MiB。**服务长时间运行后的变慢
尚未解决，不能宣称已达到热任务 P95 ≤1.3 秒或峰值内存 ≤512 MiB。**

### 最终发布产物的新进程测量

使用 `vcs -c3 -H160 -n9 sample/input.mkv --output <实验目录>/cli-<版本>.avif --profile`。
Python CreateProcess 启动无控制台子进程，墙钟覆盖启动到退出；先记录双方
首次观测，再做 20 轮交错 AB/BA。统计不包含首次观测，P95 为 nearest-rank。
正式计时没有并行编译、像素 dump 或硬件实验。没有重启或清空系统文件缓存，
**这里是新进程耗时，不是真正的磁盘冷缓存启动**，也不能直接与历史不同
驱动的绝对耗时比较。CPU 是全部线程累计时间，可能大于墙钟时间。

| 最终产物，20 次/版本 | 基线 | 优化后 |
|---|---:|---:|
| 新进程中位数 | 1.407624s | 1.339266s |
| 新进程 P95 | 1.561673s | 1.509141s |
| 进程 CPU 中位数 | 10.773438s | 10.476562s |
| 其余 CPU 占用估算中位数 | 34.8% | 32.7% |
| 首次观测（单次，不入统计） | 1.611128s | 1.744558s |

最终产物墙钟中位数减少 4.86%，
CPU 中位数减少 2.76%。
此前相同生产策略的独立 20 轮比较为 1.252827 → 1.225736 秒，CPU 为
10.195313 → 9.921875 秒。两轮方向一致，但候选测量时其余 CPU 占用均略低，
这是带负载的描述统计，不把 4.9% 当作隔离环境下的固定收益。最终双方首次
观测为 1.611 / 1.745 秒，也不支持单凭首次运行宣称冷启动提升。

### 服务交错任务与连续任务

为减轻整段 AB/BA 的负载漂移，给现有 ignored 服务基准增加 stdin 逐任务
放行，以及仅在 test 构建存在的 `VIMG_BENCH_DT3_THRESHOLD` 门槛覆盖。
同一测试二进制同时驻留两个进程，分别使用 1.5 / 6 秒门槛，每次只放行一个
生成任务，逐任务及逐轮交换顺序。两轮共 40 次真实生成、40 次缓存命中断言
通过；每个进程排除首任务后，各版本合并 18 个热任务。该基准直接调用服务
执行路径，不包含 DDS/ya 通知，也不是十任务并发。

| 同一二进制交错热任务 | 基线 | 优化后 |
|---|---:|---:|
| 中位数 | 1.712789s | 1.699356s |
| P95（18 个样本时为最大值） | 1.847666s | 1.817554s |
| 任务 CPU 中位数 | 9.648438s | 9.617188s |
| 其余 CPU 占用估算中位数 | 17.9% | 19.2% |
| 两轮进程峰值 WS | 582.9 / 585.1 MiB | 566.9 / 570.7 MiB |

墙钟差异约 0.8%，不足以认定稳定热任务提速；峰值 WS 两轮分别减少
16.1 / 14.4 MiB。该测法保留了两进程的任务间空闲时间，不等同于连续满载。

此前整段连续运行的四次序列按 A/B/B/A 执行，每进程十次生成及十次缓存命中
均通过，但候选第一段受到更高外部负载影响。保留全部结果，避免仅报告有利
序列；下表热任务排除首任务，CPU 占用为该整段平均估算值。

| 顺序 | 热任务中位数 / P95 | 前七个 / 后三个任务中位数 | 其余 CPU | 峰值 WS |
|---|---:|---:|---:|---:|
| 基线 0 | 1.134 / 2.287s | 1.125 / 1.985s | 31.3% | 591.4 MiB |
| 候选 0 | 2.159 / 2.639s | 1.860 / 2.159s | 51.7% | 570.2 MiB |
| 候选 1 | 1.288 / 2.821s | 1.211 / 2.145s | 36.6% | 558.5 MiB |
| 基线 1 | 1.313 / 1.784s | 1.237 / 1.727s | 26.4% | 580.1 MiB |

连续热任务合并中位数为 1.222 → 1.969 秒，不能忽略这个较差结果，也不能
用明显不同的外部负载把它单独归因为代码回归。交错任务用于补充控制该变量。
另做每版本四组双 CLI 进程并发，两任务全部结束的中位数 2.041 → 2.058 秒，
所有输出相同，没有吞吐量收益证据；不外推为十任务服务并发结果。

### 变慢复现：先静置也会影响首任务

同一服务测试二进制、同一 1.5 秒基线门槛，比较进程 ready 后先静置 10 秒
与 ready 后立即开始，双方各十次生成和十次缓存断言均通过：

- 静置 10 秒后首任务 1.712898 秒，十个任务都在 1.709–1.789 秒。
- 立即开始首任务 1.111676 秒，前七个在 1.060–1.359 秒，后三个为
  1.977 / 2.003 / 2.014 秒。
- 静置后的首任务 CPU 为 9.375 秒，其余 CPU 约 16.0%；立即开始首任务
  CPU 为 9.938 秒，其余 CPU 约 25.8%。

交错任务中，变慢也提前出现在较小的任务序号附近。这些观察支持把**进程
存活时间及任务间空闲**作为下一步控制变量，削弱了“必须累计处理若干文件才
触发”以及“只由外部 CPU 更高导致”的解释。单轮静置对照仍有时序和负载
混杂，尚未证明 Windows 调度、核心分配、功耗策略或应用等待中的具体根因。

额外一轮十任务检查中，变慢前后公开可读的进程优先级一直是 NORMAL，
affinity mask 一直是 `0xffffff`，ProcessPowerThrottling 的 ControlMask /
StateMask 一直为 0。这不能排除其他调度状态变化；没有修改系统优先级、
亲和性或功耗设置。

另用测试原型在进程内调用 `timeBeginPeriod(1)`，退出时配对
`timeEndPeriod(1)`。官方文档说明该 API 请求较高的周期计时精度，并要求
成对释放；这不是 QPC 精度调整。[Microsoft timeBeginPeriod 文档](https://learn.microsoft.com/en-us/windows/win32/api/timeapi/nf-timeapi-timebeginperiod)
两组均先静置 10 秒，以默认 / 1ms / 1ms / 默认顺序各处理十任务，40 次
生成和缓存断言全部通过。默认 / 1ms 的二十任务中位数分别为
1.760576 / 1.717618 秒；
所有任务仍在 1.65–1.99 秒，未恢复到约 1.1 秒。该请求没有解决复现的问题，
**计时器原型已撤回，生产代码及最终测试二进制均不包含它**。

### 本轮未采用的调度方案

限制较快 worker 的接收预取量为 1 / 4 / 8 帧，初筛每版本六次有效测量。
首网格中位数从 0.884 秒降到 0.663 / 0.725 / 0.735 秒，但整个新进程从
1.389 秒升到 1.521 / 1.505 / 1.517 秒，峰值 WS 从 489.3 MiB 升到
563.0 / 541.8 / 543.1 MiB，未采用。

长预滚窗口增加到四线程，初筛有小幅收益，正式 20 轮新进程中位数却为
1.241990 → 1.244061 秒，CPU 中位数增加约 3.5%，未采用。其服务候选
运行使用 VIMG_PROTO 环境开关，触发既有原型缓存失效策略，首任务后的缓存
断言失败；这是基准环境与缓存策略冲突，**该轮没有有效的 DT4 服务比较**。
预取、四线程及计时器补丁仅保留在忽略的实验目录中。

### 正确性、产物及复现材料

最终主程序与基线比较八组输入：主样本、H.264 MP4、HEVC MKV、VFR MKV、
长 GOP MP4、双视频流 MP4、音频在前的 MP4、非零起始时间 MKV。
2160 帧 RGB、2160 个源 PTS 和八个 AVIF 逐字节一致。主样本 authority 的
270 个 PTS/time-base、30 张编码前网格、30 张解码后网格及 AVIF 也一致。
额外 MPEG-TS 在双方显式 libav 模式都报“无带时间戳源帧”，不计入成功样本，
也不宣称修复已有 TS 支持问题。最终 release 特性测试 67 passed / 5 ignored，
无默认特性测试 58 passed / 4 ignored。本轮两个 Rust 文件的 rustfmt 检查及
git diff --check 通过；全仓库 cargo fmt --check 仍报告未改动的 capture.rs
三处既有格式差异，本轮未调整该文件。

- 最终主程序：`target/release/vimg.exe`，SHA-256
  `9e3256f2934281a52447eae1e8f84b9c1c3b80955b531dfa9614cbe44b41f29e`。
- 本轮基线主程序 SHA-256：`512864cb99e6b87e9822c4dd324293911f6ca7a164435f3f0b2476402a632e2b`。
- 同一二进制服务交错/静置基准 SHA-256：
  `7cd71c38c0bf6f5070aa15167f085c9eab40764642647d3b51d09dfef1d0411c`。
- 最终 CLI、八组验证和 authority：`.scratch/startup/phase5-final/` 内
  `cli-results.json`、`summary.json`、逐次日志、`verification-final/`、`authority/`。
- 服务、双进程及诊断：`.scratch/startup/phase5-threshold/` 内
  `service-results.json`、`parallel-results.json`、`paced-results.json`、
  `paced-summary.json`、`age-results.json`、`policy-results.json`、
  `timer-results.json`、对应 Python 驱动和逐次日志。计时器原型存于
  `timer-prototype.patch` / `timer-test.exe`，不在发布产物中。
- 预取与 DT4 实验：`.scratch/startup/phase5/` 内 `screen-results.json`、
  `screen-summary.json`、`cli-results.json`、`scheduling-prototypes.patch`。

实验目录被忽略，不进入发布代码。PATH 中已安装的 vimg.exe 未被替换。
后续应先跟踪相同进程静置前后的解码线程运行、就绪和等待时间，以区分调度
与应用等待，再决定下一项生产改动。

## 2026-09-12 14:07：共享探测两版候选未通过收益门槛，保留原实现

本轮继续验证上一轮提出的计划探测复用。基线为 jj `856c21b1`，其生产代码
仍为 `7f3d8450`。**两版候选均未证明新进程与服务热任务的整体收益，未合入
生产代码。已恢复原 release 主程序；本次只提交实验结论。**

### 实验实现及范围

第一版让计划保留一次完整 probe 的参数；九个 worker 独立打开文件头，
深拷贝解码参数。完整 DDS 元数据仍跳过计划 probe，改在 Capture attempt
开始时探测一次。仅允许具有编码头的单视频流 H.264/HEVC MKV/MP4，校验
文件大小/修改时间、流序号/ID、流数、codec、时间基、尺寸和 extradata；
不匹配则重新完整探测。没有跨任务缓存或共享可变 AVFormatContext。

第二版另外把参数复制到各 worker 的解复用器 stream codecpar，检查仅复用
decoder 参数是否遗漏了 DTS 推导需要的 B 帧重排信息。FFmpeg 的 demux
实现会使用内部 codec context 的 has_b_frames 推导 DTS，并从 stream 参数
初始化该 context。这是实验假设的依据，不代表复制这些字段就等价于完整
find_stream_info。[FFmpeg demux.c 源码](https://ffmpeg.org/doxygen/8.0/demux_8c_source.html)

### 同条件性能比较

每版均与同一基线交错执行 20 轮 AB/BA，另记录各自首次观测，合计 84 次
新进程。命令参数为 `vcs -c3 -H160 -n9 sample/input.mkv --output <实验目录>/cli-<版本>.avif --profile`。
Python 使用 CreateProcess 启动无控制台子进程，墙钟覆盖整个子进程生命周期；
不能直接与历史 PowerShell 驱动的绝对数值比较。没有重启或清空系统文件缓存，
首次观测也已在正确性检查之后，**不代表真正磁盘冷缓存启动**。

服务每版按 AB/BA 各运行两次，每个进程十个真实生成任务和十次缓存命中。
下表热任务排除每进程首任务，合并各版本 18 个任务；P95 用 nearest-rank，
18 个样本时等于最大值。服务不含 DDS/ya 通知，也不是十任务同时运行。

| 实验 | 指标 | 基线 | 候选 |
|---|---|---:|---:|
| 仅共享解码参数 | 新进程首次观测 | 1.297s | 1.248s |
| 仅共享解码参数 | 新进程中位数 | 1.282s | 1.276s |
| 仅共享解码参数 | 新进程 P95 | 1.398s | 1.376s |
| 仅共享解码参数 | 进程总 CPU 中位数 | 10.555s | 10.758s |
| 仅共享解码参数 | 服务热任务中位数 | 1.298s | 1.326s |
| 仅共享解码参数 | 服务热任务 P95 | 1.431s | 1.375s |
| 同时填充解复用参数 | 新进程首次观测 | 1.376s | 1.431s |
| 同时填充解复用参数 | 新进程中位数 | 1.372s | 1.396s |
| 同时填充解复用参数 | 新进程 P95 | 1.531s | 1.524s |
| 同时填充解复用参数 | 进程总 CPU 中位数 | 11.062s | 11.445s |
| 同时填充解复用参数 | 服务热任务中位数 | 1.273s | 1.289s |
| 同时填充解复用参数 | 服务热任务 P95 | 1.372s | 1.460s |

第一版新进程中位数仅减少约 0.5%，服务中位数增加约 2.1%；第二版分别
增加约 1.7% 和 1.3%，新进程 CPU 中位数增加约 3.5%。这些是带负载的
描述统计，不能把小幅差异直接认定为稳定回归，但不足以支持采用更复杂的实现。

持续记录 GetSystemTimes/GetProcessTimes，正式计时期间没有编译、RGB dump、
硬件原型或 QoS/计时器修改。新进程测试中，估算其余 CPU 占用中位数：
第一版基线/候选 32.1%/31.6%，第二版 35.5%/34.8%。第二版四次服务序列
的其余 CPU 平均值依次为 32.9%、34.2%、37.2%、38.6%；仍存在明显外部
负载，不能宣称完全隔离。第二版峰值 WS：基线 579.3/580.5 MiB，候选
580.6/579.1 MiB，也没有实质内存收益。

### 为什么不采用

第一版主样本诊断日志中，worker open 阶段由约 25–29ms 减少到 2–4ms，
但九路并行，不能把九次差额直接相加当作墙钟收益。更关键的是，两版候选
的主样本预滚帧计数均由 254 增至 286，合计多 32 帧；复制解复用参数后
这一差异仍然存在。最终采样 PTS/像素相同，但解码工作量没有完整保持。

结果支持“缩短 probe 阶段不等于减少整个任务耗时”，尚不能证明额外预滚帧
的全部原因。完整探测形成的内部时间戳状态不止 AVCodecParameters，当前
没有可靠理由继续用调整跳帧阈值补偿。保留完整探测路径更符合本轮收益门槛。

### 正确性及复现材料

第二版 7 组成功生成的输入（主样本、H.264 MP4、HEVC MKV、VFR MKV、
双视频流 MP4、音频在前的 MP4、非零起始时间 MKV）共 1890 帧 RGB、
1890 个源 PTS、7 个最终 AVIF 均与基线逐字节一致。主样本 authority 的
270 个 PTS/time-base、30 张编码前网格、30 张解码后网格和 AVIF 也一致。
额外 MPEG-TS 在基线和候选的显式 libav 模式下均报相同的“无带时间戳源帧”
错误，因此不计入成功输出验证，也不宣称修复了现有 TS 支持问题。

候选 release 测试 67 passed/6 ignored，默认特性测试 58 passed/4 ignored；
单独运行新增探测集成测试通过，覆盖 MP4/MKV 复用、双视频流/TS 不复用、
参数独立副本、文件 stamp/编码头不匹配后完整探测，以及缺失输入错误。
两版连续服务测试共通过 80 个生成任务和 80 次缓存命中断言。

原始第一版数据在 `.scratch/startup/phase4/`，第二版在
`.scratch/startup/phase4-demux/`：`cli-results.json`、`service-results.json`、
逐次日志、`verification-final/`、`extra/`、`authority/`、`summary.json`。
第二版完整候选补丁保存在 `shared-probe.patch`，独立模块保存在
`libav_input.rs`；候选 exe 也保留在实验目录。实验目录被忽略，不进入发布代码。

第一版候选主程序 SHA-256：`82cbbc5cef8a7d9089abee5ced4457d6118f3503c3c0db1e1ddccebd3cdeaffa`。

第二版候选主程序 SHA-256：`14971d69fcdfad426621893eaa2e3d4c3e519b64b17d24c6c446adf595be276d`。

恢复的 `target/release/vimg.exe` SHA-256 为
`512864cb99e6b87e9822c4dd324293911f6ca7a164435f3f0b2476402a632e2b`，
与本轮开始时一致。后续优先分析最慢 Capture window 的长预滚解码成本和
任务间资源分配；本轮不把共享探测列为已完成的生产优化。

## 2026-09-12 13:32：按用户说明复测 CPU 负载影响

用户指出前次测试期间另有程序占用较高 CPU。本轮不修改程序、不重新编译，
直接复用前次保存的 baseline/candidate release 测试二进制，按 AB/BA 顺序
各执行两次；每个进程运行十个真实服务生成任务及十次重复缓存请求。
没有启用原型、额外 profile、QoS 或定时器策略开关。

**本次未重现稳定的“后段从约 1.0s 上升到 1.84s”趋势，也未重现候选持续
比基线更慢。上一轮结果不能据此认定为已确认的代码回归。** 外部负载干扰是
合理解释，但前次没有同步系统 CPU 轨迹，本次不能反推确定其根因。

### 同一进程的前后段比较

“前段”指第 1–7 个任务，“后段”指第 8–10 个任务，均列中位数；包括真实
服务 complete_job、VCS、编码与 manifest，不含 DDS/ya 通知，非十任务并发。

| 组次/版本（实际执行顺序） | 前段中位数 | 后段中位数 | 十任务范围 |
|---|---:|---:|---:|
| 1 / baseline | 1.259s | 1.165s | 1.106–1.502s |
| 1 / candidate | 1.201s | 1.142s | 1.098–1.294s |
| 2 / candidate | 1.215s | 1.150s | 1.108–1.433s |
| 2 / baseline | 1.181s | 1.251s | 1.137–1.425s |

候选两次的后段均未上升。基线第二次后段约增加 6%，其中第 9 个任务为
1.425s，同期估算非被测进程 CPU 占用为 45.8%，高于该次运行平均 35.9%；
这是相关观测，不能单凭这一点确定因果。

合并每个进程排除首任务后的九次，得到每版本 18 个热任务的描述统计：

| 指标 | baseline | candidate |
|---|---:|---:|
| 热任务中位数 | 1.226s | 1.182s |
| 热任务 P95（nearest-rank，18 个样本时为最大值） | 1.502s | 1.433s |
| 二十次缓存命中中位数 | 0.704ms | 0.808ms |
| 两次进程累计峰值 WS 观测 | 590.6 / 585.3 MiB | 584.4 / 582.4 MiB |

这是两段连续任务序列的合并统计，不能当成 18 次独立启动试验；本轮也没有
验证真正磁盘冷缓存。峰值内存与热任务 P95 仍未满足 ADR 的 512 MiB/1.3s
目标，不将局部样本的差异宣称为稳定整体收益。

### 同步 CPU 观测

每次启动前采样 3 秒系统 CPU；运行时每 250ms 读取 GetSystemTimes 与
GetProcessTimes，另在每个任务输出完成标记时记录区间值。总 CPU 占比按
系统 kernel+user 时间增量扣除 idle 计算；再扣除被测进程 CPU 时间，估算
其余负载。GetSystemTimes 的 kernel 字段包括 idle，按文档扣除一次。
[Microsoft GetSystemTimes 文档](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-getsystemtimes)

| 组次/版本 | 启动前系统 CPU 中位数 | 运行期系统 CPU 平均值 | 估算其余 CPU 平均值 |
|---|---:|---:|---:|
| 1 / baseline | 7.7% | 69.5% | 33.3% |
| 1 / candidate | 6.9% | 66.9% | 30.8% |
| 2 / candidate | 17.6% | 71.9% | 36.2% |
| 2 / baseline | 14.5% | 71.7% | 35.9% |

机器有 24 个逻辑处理器，百分比以整机总容量为分母。“其余 CPU”包含系统
活动、其他进程和监测开销，不能全归因于用户应用。本轮仍有明显负载，部分
250ms 区间的系统 CPU 达到 100%；这是带负载观测的复测，并非完全隔离实验。

四次集成测试全部通过：40 个生成任务、各进程内输出字节一致性，以及 40
次缓存命中断言。应用代码和主程序 SHA-256 均未改变；仅补充本节报告。
继续保留上一节原始数据作为历史记录，暂不因前次波动回退优化或调整调度策略。

原始数据与驱动在 `.scratch/startup/retest-idle/`：`bench_service_load.py`、
`results.json`、`{0,1}-{baseline,candidate}.json` 和对应完整测试日志。脚本
逐任务记录耗时、CPU 时间、负载区间，并保留 250ms 原始样本和二进制 SHA-256。
本次 baseline 测试 exe SHA-256 为
`69013327dcbceb864dd566d2a062b3b407ecc6c91d55af8c438416fbb2f245bd`；
candidate 为 `8d448177e0996bff051912b6932922f88e276b149c5ae70a9638c70067dd28d1`。
这些是测试程序的指纹，主程序仍为下一节记录的 `512864cb…`。

## 2026-09-12：继续优化拼图与标签，验证共享探测候选

本轮以前一轮已保存的 jj **`d8ac972d`** 为基线。基线 exe SHA-256：
`876598fba528d1bcb98407722ad70997c3fcbdf14674bac36a6a053d7d526358`；
本轮最终 exe：
`512864cb99e6b87e9822c4dd324293911f6ca7a164435f3f0b2476402a632e2b`。
release 产物在 `target/release/vimg.exe`。

### 本轮保留的修改

1. **RGB 图块逐行复制。** 当前 Cargo.lock 锁定 image 0.25.8，其
   `GenericImage::copy_from` 对每个像素执行 get/put，RgbImage 没有覆盖此实现。
   固定尺寸的 RGB 网格现在验证图块尺寸后，通过安全的 slice 逐行复制。
   没有增加 unsafe、依赖升级或改变像素格式；最后一行未填满的网格仍保持黑色。
2. **每个 Capture attempt 复用标签覆盖率。** `MemoryJoiner` 保存网格布局、
   每个时间标签的背景范围和逐像素透明度，30 帧共用。只缓存绘制数据，不缓存
   视频像素；背景混合、字形绘制顺序、整数截断和相互重叠的字形保持原样。
   在等待首组采样帧之前准备标签，准备耗时也计入 profile 的 join 字段。
3. **按需生成 SourceSelection。** 普通运行不再分配、格式化最终会被丢弃的
   270 条 source time-base 记录；authority 模式继续完整记录。RGB/PTS 原型
   dump 的输出独立保留。

### 完整命令：新进程、热文件缓存

执行用户指定的 `vcs -c3 -H160 -n9 sample/input.mkv --output ...`，附加
`--profile`，使用相同 DLL 和视频。AB/BA 交错，各 20 个计入统计的新进程，
另各 1 次首轮观测；wall 包含进程/DLL/解码器/编码器初始化。P95 为 nearest-rank。

| 指标 | d8ac972d 基线 | 本轮最终版本 |
|---|---:|---:|
| 首轮观测 | 1.545s | 1.519s |
| wall 中位数 | 1.529s | 1.507s |
| wall P95 | 1.751s | 1.742s |
| 拼图 join 中位数（包含标签准备） | 32ms | 21ms |
| plan setup 中位数 | 11ms | 11ms |
| decode 中位数 | 1.203s | 1.204s |
| encoder tail 中位数 | 218ms | 211ms |
| profile total 中位数 | 1.436s | 1.417s |

拼图阶段本批次减少 **约 34% / 11ms**；完整命令中位数仅减少 **约 1.4%**。
机器负载在测量中有明显变化，两组 wall 范围分别为 1.361–1.890s、
1.333–1.830s。不能把这批绝对时间与上一节更低负载时的 1.198s 直接比较，
也不能将完整命令的全部差值归因于代码。所有 42 次运行的 AVIF 哈希一致。

另各 8 次交错 CPU 采样：主线程中位数两组均为 0.140625s；进程总 CPU
11.593750 → 11.960938s（约增加 3.2%）。**未观察到整进程 CPU 的可靠下降。**
本轮保留的是经过输出等价验证、确实减少拼图工作量的局部优化，没有宣称
获得显著的整体加速或达到 ADR 的 1.3s P95。

没有清空 OS 文件缓存或重启机器，首轮只是首轮观测，不能作为真正的磁盘冷
缓存收益证据。程序每次全新初始化与下面的常驻服务热任务分开统计。

### 常驻服务热任务：仍有后段变慢，未证明改善

用既有 `repeated_service_jobs_and_cache_hits` 执行两轮 AB/BA 对照，每个
进程连续生成十个不同 cache path，然后各重复请求一次验证命中。使用真实
complete_job、VCS、libav/SVT 和 manifest；不含 DDS/ya 传输，不是十任务并发。
下表的“热任务”指每个进程排除第一个任务后的九个任务。

| 轮次/版本（执行顺序） | 首任务 | 热任务中位数 | 热任务最大值 | 峰值 WS | 峰值 commit |
|---|---:|---:|---:|---:|---:|
| 1 / baseline | 1.140s | 1.147s | 1.851s | 591.9 MiB | 653.4 MiB |
| 1 / candidate | 1.101s | 1.319s | 2.521s | 585.2 MiB | 647.6 MiB |
| 2 / candidate | 1.216s | 1.370s | 2.141s | 576.8 MiB | 650.1 MiB |
| 2 / baseline | 1.222s | 1.079s | 1.986s | 585.4 MiB | 653.1 MiB |

四个进程的十任务生成、字节一致性和十次缓存命中断言全部通过。
候选的两组 cache hit 中位数为 0.798ms、0.985ms。**两版都在后段变慢，
本批次候选的服务热耗时还更差，不能宣称改善服务吞吐或排除热路径回归。**
峰值仍超过 ADR 的 512 MiB 预算。局部拼图加速不足以解决整体热任务延迟。

随后增加仅在该忽略测试中使用的 `VIMG_BENCH_PROFILE=1`，输出每个任务的
现有阶段 profile。独立一轮候选中，第 1–7 个任务 wall 0.999–1.123s，
第 9/10 个为 1.838/1.839s；相应进程 CPU 仍约 9.17/9.31s，未同步翻倍。
第 7 → 9 个任务的 decode 0.838 → 1.488s、encoder tail 0.155 → 0.338s，
join 仍为 15ms。说明后段额外延迟并非由拼图用时增加直接解释，根因尚未确认。
按任务结束时采样的 WS 也会从约 50MiB 上升到 370MiB 后回落到 75MiB；
不能继续用“全部都是不可回收泄漏”或“全部已经解决”概括。

还通过测试驱动仅对新建测试子进程分别请求 HighQoS、保留已有计时器精度请求，
核对返回成功及 ControlMask/StateMask；均未消除变慢，没有修改系统电源计划，
也没有接入生产代码。这两次跨时段实验不能用于量化策略效果或确定根因。
[Windows 进程节能策略说明](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation)
后续若继续追查热延迟，应在受控负载下采集线程等待/调度轨迹，并对候选拆分
消融；不应以更多解码线程、提高进程优先级或清理全局堆作为未经验证的修复。

这也补充了上一节仅一轮十任务观测的边界：先前 RGB 引用泄漏确已修复，
但服务后段延迟并未被全面解决。本轮提交是局部拼图优化及诊断支持，
不是服务性能契约达标结论。

### 标签阶段的独立测量

release 忽略测试 `benchmark_preview_label_cache` 交错执行 8 轮；每轮绘制
九个时间标签 × 30 张 RGB 网格。计时包含每个任务重新准备标签，排除网格
分配与复制（它们已包含在上面的实际 join 计时中）。

- 原逐帧布局/光栅化：中位数 **1.843ms**。
- 预计算后逐帧混合：中位数 **0.451ms**，约减少 75.5%。
- 九个标签的 coverage Vec 容量合计 **13,824 字节**，只随本次 attempt 存活。

这只是约 1.4ms 的局部收益，不能当成整个拼图或整条命令的 75.5% 加速。

### 共享探测：已测量，未接入默认路径

实验先完整探测一次并深复制 codec 参数，再让九个窗口分别只读容器头，
独立 seek 和解码。四组输入共 1080 张 RGB、1080 个 PTS 及最终 AVIF 一致。
各 12 轮交错 wall 中位数 1.234898 → 1.195751s（约减少 3.2%）；另各
4 次进程 CPU 中位数 9.851563 → 10.078125s，未同步下降。首轮观测
1.261 → 1.306s。

容器头并不总是包含完整信息，完整探测还会读取和解码部分包，不能仅凭复制
codec 参数就普遍替代 demuxer 初始化。
[FFmpeg demuxing 文档](https://ffmpeg.org/doxygen/8.0/group__lavf__decoding.html)
该原型尚未补齐格式范围、流匹配、源文件变化和头信息不完整的生产回退门槛；
本轮小幅 wall 趋势不足以支持直接启用。因此恢复现有完整探测路径，将原型
patch、exe 和日志保存在 `.scratch/startup/phase3/`，未混入最终源码或上述收益。

### 验证及复现

- 原标签绘制实现作为 test-only 像素参考，覆盖横/竖/小尺寸图像、空白/长标签、
  组合字符、三档背景透明度、连续变化的像素和非零绘制偏移。
- 网格测试覆盖 0/1/2/3/7 列、缺省标签、空白尾格、不同帧内容、数量/尺寸错误。
- 四类视频（sample MKV、H.264 MP4、HEVC MKV、H.264 VFR）各 270 张 RGB
  和 270 个 PTS 与基线相同；四个最终 AVIF 的哈希也分别相同。
- 另实际运行 baseline/candidate 的 authority record：270 个选择 PTS/time base、
  30 张编码前 PNG、30 张解码后 PNG 和最终 AVIF 全部一致，确认按需记录未破坏
  authority 模式。sample AVIF 仍为
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- 最终 release 测试：67 passed / 0 failed / 5 ignored；标签微基准、连续服务
  测试另行显式运行。默认 feature 测试：58 passed / 0 failed / 4 ignored。

CLI 复现：为相同 FFmpeg DLL 配置 PATH 后运行
`scripts/bench-startup.ps1 -Baseline .scratch/startup/phase3/baseline.exe -Candidate .scratch/startup/phase3/candidate.exe -OutputDirectory .scratch/startup/phase3/final-comparison-repeat -Runs 20`。
标签微基准：`cargo test --release --features in-process-decode benchmark_preview_label_cache -- --ignored --nocapture`。
原始记录包括 `final-comparison/results.csv`、`candidate-cpu.json`、
`labels-bench.log`、`verification-final/results.json`、`authority/results.json`；
热任务证据为 `service-{baseline,candidate}-memory-{0,1}.log`、
`service-profile.json` 及对应阶段日志；设置 `VIMG_BENCH_PROFILE=1` 后运行
`cargo test --release --features in-process-decode repeated_service_jobs_and_cache_hits -- --ignored --nocapture`
可以复现阶段诊断。临时 Windows 策略实验在 `profile_service.py` 的 qos/timer
模式及对应 `service-profile-{qos,timer}.json` 中。
共享探测实验使用 `shared-probe.patch`、`shared-probe.exe`、`shared-probe-cpu.json`、
`prototype-comparison/results.csv`。汇总计算脚本为 `summarize.py`。

## 2026-09-12：jj 基线保存后的优化实现

开始修改前已用 `jj commit` 保存完整工作区：**`6b4e9a45`**，change
`pnymmsut`，描述 `perf: retain capture frames and reduce preview scale startup overhead`。
本节 CLI/CPU 的基线是该状态的 release exe
`fe315f8e6a52d7404b861e9c09c13f63c83820494749ea0c7f77387cb84ce2b7`。
最终 exe SHA-256 为
`876598fba528d1bcb98407722ad70997c3fcbdf14674bac36a6a053d7d526358`。

### 保留的修改

1. **事件唤醒替代忙轮询。** 保留九路容量为 2 的队列与原来的就绪扫描顺序；
   空队列时使用 Condvar 等待。通知与扫描到等待的转换共用锁，避免丢失唤醒；
   入队时不持有该锁，避免满队列死锁。发送者先断开队列再通知，覆盖正常退出、
   错误和 panic，消费者取消时仍可释放阻塞的发送者。
2. **网格所有权与编码缓冲复用。** `write_grid` 直接接收生成的 `RgbImage`，
   不再整图 clone；复用 RGB/YUV AVFrame，写 YUV 前调用
   `av_frame_make_writable`，保护编码器可能仍持有的引用。
3. **DDS 元数据链路补齐 codec。** 插件提取 `codec_name`，仅在视频流不歧义时
   发送 codec/time base；`vimg send --codec` 和服务 JSON 解析保持该字段。
   完整描述符可以跳过计划阶段的再次 probe，旧客户端或不完整描述符仍会探测。
4. **服务端缓存复查。** 任务出队后核对 source path、size、纳秒 mtime、
   AVIF header、output size/mtime、profile、backend policy 及 manifest；
   匹配则直接通知全部等待者。旧 manifest、变化/损坏的输出或源文件走生成路径。
   原型开关运行禁用服务端缓存复用，并在 manifest 中标记，避免掩盖诊断或被
   正常服务复用。插件既有缓存读取协议保持兼容。
5. **修复缩放输出帧的引用泄漏。** 连续任务测量暴露热运行退化后，检查本地
   ffmpeg-next 的 Sink wrapper，发现它直接调用 buffersink；该 API 会将新
   frame 引用移入目标，并不会清理目标旧内容。现在每次接收缩放输出前先
   `av_frame_unref(rgb)`。之前的像素已经复制为独立 RgbImage，释放安全。
   [FFmpeg buffersink 实现](https://ffmpeg.org/doxygen/8.0/buffersink_8c_source.html)

第 5 项是本轮实现及连续任务验证时补查到的既有问题。它修正了历史报告中
“解码器/特定窗口并发残留”的不完整归因：至少缩放输出 AVFrame 的旧引用没有
释放是明确的调用方泄漏。回归测试验证输出帧替换后旧 buffer 引用数由 2 降到 1，
剩余的 1 是测试主动保留的观察引用。

### 单次 CLI 与 CPU

相同 FFmpeg DLL、sample/input.mkv、固定参数、输出哈希门槛；最终版本各
20 次新进程热文件缓存运行，交错顺序，P95 使用 nearest-rank。

| 指标 | jj 保存的基线 | 最终版本 |
|---|---:|---:|
| 首轮观测 | 1.151s | 1.425s |
| wall 中位数 | 1.239s | 1.198s |
| wall P95 | 1.457s | 1.575s |
| profile total 中位数 | 1.141s | 1.107s |
| decode 中位数 | 0.959s | 0.925s |
| encoder tail 中位数 | 0.168s | 0.164s |
| 单次峰值 WS（独立各 1 次） | 503.3 MiB | 497.7 MiB |

**单次 wall 中位数约降低 3.4%，P95 本批次反而增加约 8.1%；不能宣称尾延迟
或冷启动已改善。** 本机绝对延迟有波动，且未清空系统缓存，首轮不是受控的
磁盘冷缓存。所有进程/DLL/解码器/SVT 初始化仍包含在完整命令计时中。

另用 Windows GetThreadTimes/GetProcessTimes 各四次交错采样：

| CPU 中位数 | 基线 | 最终版本 | 降低 |
|---|---:|---:|---:|
| 主线程 | 0.796875s | 0.132813s | **83.3%** |
| 整个进程 | 11.023438s | 10.500000s | 4.7% |

CPU 时间不等于 wall；本轮最稳定的单次任务收益是减少空转占用。
事件唤醒单独消融的 10 次/版本中位数约 1.22 → 1.21s，亦未显示明显的 wall
改善。修复引用泄漏之前的组合版本 20 次对照为 1.156 → 1.147s，P95
1.271 → 1.286s；这些中间测量不替代最终结果。

### 同一进程连续任务与重复请求

新增可显式运行的 release 集成测试 `repeated_service_jobs_and_cache_hits`：
一个进程内，连续生成十个不同 cache path 的相同视频预览；每个完成后再提交
同一请求，断言命中且不能再次调用 capture/publish。十个 AVIF 必须逐字节相同。
使用真实的服务调度、complete_job、libav/SVT 和 manifest 代码，**不包含 DDS
网络传输和 `ya pub-to` 的耗时，也不是十任务并发吞吐测试**。

以下对照专门隔离最后的 buffersink 引用修复。修复前版本已经包含事件唤醒、
编码缓冲复用与服务缓存，二者各连续运行十个任务；峰值由 Windows
PeakWorkingSetSize/PeakPagefileUsage 读取：

| 指标 | 引用修复前 | 引用修复后 |
|---|---:|---:|
| 十任务峰值 WS | 934.9 MiB | **582.1 MiB** |
| 十任务峰值 commit | 1037.7 MiB | **652.7 MiB** |
| 第 1 个任务 | 1.117s | 1.232s |
| 第 8 个任务 | 1.391s | 1.215s |
| 第 9 个任务 | 1.913s | 1.167s |
| 第 10 个任务 | 2.166s | **1.282s** |

修复后十次生成的范围为 **1.135–1.312s**；十次缓存复用为
**0.475–0.850ms，中位数 0.660ms**。本次十任务不再出现后段持续升到 2s
的形态，但这不等于任意长时间服务的内存上限证明。峰值 WS 仍高于 ADR 的
512 MiB 预算，未宣称全部性能契约已达成。

### 验证与复现

- 最终 release 测试：**65 passed / 0 failed / 4 ignored**；连续十任务测试
  另外显式运行通过。测试覆盖唤醒、断开、发送者 panic、满队列取消、旧 RGB
  buffer 释放、YUV 编码往返、完整 DDS 描述符免 probe、缓存失效及等待者通知。
- 默认 feature 配置 **56 passed / 0 failed / 3 ignored**。顺带修复既有
  preview 测试辅助函数缺少 `in-process-decode` 门控的问题。
- `lua scripts/test-gridthumb-metadata.lua` 验证 preload → DDS payload 链路，
  覆盖单视频、多视频歧义和封面图；`luac -p gridthumb.yazi/main.lua` 通过。
- 固定样本、H.264 MP4、HEVC MKV、H.264 VFR MKV 共 **1080 张 RGB、1080 个
  PTS 和四个 AVIF** 均与 jj 基线一致。固定样本 SHA-256 仍为
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- `git diff --check` 通过。原始 CSV/日志/采样器/二进制保留在
  `.scratch/startup/phase2/`，最终数据为 `stable-comparison/results.csv`、
  `stable-cpu.json`、`verification-stable/results.json`、
  `service-before-memory.log`、`service-stable-memory.log`。

```powershell
$env:PKG_CONFIG_PATH = 'D:\ffmpeg-dev\ffmpeg-8.1.2-full_build-shared\lib\pkgconfig'
$env:PATH = 'D:\ffmpeg-dev\libav-deploy;' + $env:PATH
cargo test --release --features in-process-decode repeated_service_jobs_and_cache_hits -- --ignored --nocapture
.\scripts\bench-startup.ps1 -Baseline .\.scratch\startup\phase2\baseline.exe -Candidate .\target\release\vimg.exe -OutputDirectory .scratch/startup/phase2/recheck -Runs 20
.\target\release\vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output output3.avif
```

本轮没有直接删除九个 worker 的 stream-info probe：它们需要独立且完整的
codec 参数、像素格式与 seek 状态。本次减少的是 DDS 完整描述符下的 plan
probe；跨 worker 的 header/codec 参数共享仍需单独实现和验证。亦未改变
并发任务上限、帧数、CRF、preset 或硬解策略。PATH 中的旧版 exe 未被替换，
新版及匹配 DLL 位于 `target/release`。

## 2026-09-12：进一步效率审查

详见 [当前代码效率复核](docs/reviews/2026-09-12-efficiency-review.md)。
本轮未修改生产代码；Standards/Spec 两轴未发现上轮新增的功能或所有权缺陷。
补测完整任务 wall 为 1.269–1.396s，主线程 CPU 为 0.844–0.875s；结合
九路 `try_recv + yield_now`，优先建议验证事件唤醒。CPU 减少量不能直接当作
wall 改善量。其它候选为重复 probe 复用、grid 所有权传递、标签 coverage
缓存和服务端缓存复查，均尚未实现或取得性能收益。

现有探针中最慢 cap7 的代表性分解：open 26.8ms、seek 28.8ms、setup 3.2ms、
send_packet 923.5ms、receive 1.1ms、emit 66.5ms，总计 1.0968s；join 32ms，
encoder tail 214ms。后续方案应按这些关键路径量级评估，而非重复调整已否决的
硬解或丢帧策略。原始证据位于 `.scratch/startup/review-cpu.json` 和
`review-profile-{1,2,3}.log`。

## 2026-09-12：当前源码的启动与热缓存运行优化

保持 `vcs -c3 -H160 -n9 sample/input.mkv --output ...` 的帧选择、尺寸、
30 帧动画、CRF 和编码参数不变。本轮修改在 `src/command/libav.rs`：

- 用 `av_frame_ref` 保留解码帧，代替 `Video::clone` 对全部 YUV 平面的深拷贝。
  解码器复用 AVFrame 时，待调度帧仍独立持有有效的 buffer 引用。
- 缩放阶段直接转移该帧所有权，消除第二次全分辨率深拷贝。硬件帧继续按原路径下载。
- 每个缩放 filter graph 使用 1 个线程；九个 capture window 已经并行，
  避免为每个小尺寸缩放器初始化自动大小的线程池。

### 测量口径与版本

PATH 中实际执行的 `D:\Apps\ffmpeg\vimg.exe` 是旧版，不支持 `--profile`。
它的四次有效运行是 **3.302 / 2.785 / 2.684 / 2.601s**（首次在前）。
这些数据仅用于确认用户所用版本；下面的优化幅度以**修改前当前源码重新编译**的
release 为基线，避免把已有功能收益算成本轮优化。

两端均使用 `cargo build --release --features in-process-decode`、相同的
FFmpeg 8.1.2 shared DLL 和 3,210,297,211 字节的 `sample/input.mkv`。
基线可执行文件 SHA-256：
`c83acc09d12db117c9dde6804faf9aee2473713a93061e1a69572eb684ce8544`。
优化后可执行文件 SHA-256：
`fe315f8e6a52d7404b861e9c09c13f63c83820494749ea0c7f77387cb84ce2b7`。
输出放在 `.scratch/startup/`，未覆盖用户已有修改的 `output3.avif`。

每次启动全新 exe，因此计时包含进程启动、DLL 加载以及解码器、缩放器和
SVT 的重新初始化。交错轮换执行顺序，20 次热缓存运行/版本，首轮另列；
计时覆盖完整命令退出，SHA 校验在计时结束后进行。P95 使用 nearest-rank。
**这里的热指系统文件缓存；不是常驻 serve 进程的热任务。没有重启系统或清空
standby/file cache，因此不把首次观测冒充真正的磁盘冷缓存测试。**

### 最终同批次结果

| 指标 | 修改前源码 | 优化后 | 改善 |
|---|---:|---:|---:|
| 首轮观测（系统缓存已热，新进程） | 1.769s | 1.421s | 19.7% |
| 20 次 wall 中位数 | 1.784s | **1.411s** | **20.9%** |
| 20 次 wall P95 | 1.936s | **1.633s** | **15.6%** |
| profile total 中位数 | 1.690s | 1.313s | 22.3% |
| decode 中位数 | 1.453s | 1.102s | 24.2% |
| first_grid 中位数 | 1.205s | 0.916s | 24.0% |
| plan_setup 中位数 | 0.011s | 0.011s | 基本不变 |
| join 中位数 | 0.040s | 0.032s | — |
| encoder_tail 中位数 | 0.211s | 0.205s | 基本不变 |

独立的 `PeakWorkingSetSize` 采样（每版本 1 次，非并发运行）：
峰值 WS **567.5 → 501.2 MiB**，峰值 commit **704.8 → 632.5 MiB**。
这不是持续服务内存上限或泄漏修复的证明。此批次 wall P95 仍高于 ADR 的
1.3s 目标，不宣称已达到全部性能契约。

不带 `--profile` 的优化后命令另测 3 次：**1.507 / 1.672 / 1.595s**。
后台负载导致绝对时间变化，应以同批次交错对照判断收益，而不是只取最快一轮。

消融实验：仅消除两次整帧复制时，8 次/版本交错 warm 中位数
1.739 → 1.408s；在此基础上限制缩放线程，6 次/版本中位数
1.407 → 1.290s，P95 1.533 → 1.544s。后一个小样本不能证明尾延迟改善，
最终合并结果以上方 20 次对照为准。

### 输出与回归验证

- 固定样本、H.264 MP4、HEVC MKV、H.264 VFR MKV 四组输入，强制 libav
  后端，逐组比较 270 张 RGB、270 个 source PTS 和最终 AVIF；全部一致，
  共 **1080 帧 RGB + 1080 个时间戳**。
- 固定样本所有最终对照输出 SHA-256 保持
  `3f0fa2be39601e3b083287ddd0f66d603ff593b3dde82d12efae99954f3be4f2`。
- 新增帧生命周期回归测试：保留帧后，模拟解码器将原 buffer 变为可写、
  修改像素/PTS 并释放原帧，验证保留帧的像素与时间戳仍正确。
- `cargo test --features in-process-decode`：**57 passed，0 failed，3 ignored**；
  新增生命周期测试、已有编码往返、probe 和回退测试均通过。`git diff --check` 通过。
- 全仓库 `cargo fmt -- --check` 检出了已有格式差异（包括未修改的
  `capture.rs`、`encode.rs` 及原型代码）；本轮未扩大成全仓库格式整理。

### 复测与运行

可复用的计时脚本为 `scripts/bench-startup.ps1`，原始 CSV、逐次日志、
两端二进制和四组帧验证结果保留在本机 `.scratch/startup/`。

```powershell
$env:PATH = 'D:\ffmpeg-dev\libav-deploy;' + $env:PATH
.\scripts\bench-startup.ps1 `
  -Baseline .\.scratch\startup\baseline.exe `
  -Candidate .\target\release\vimg.exe `
  -OutputDirectory .scratch/startup/recheck -Runs 20
```

已将匹配的 DLL 放入 `target/release`，可直接使用以下产物：

```powershell
.\target\release\vimg.exe vcs -c3 -H160 -n9 .\sample\input.mkv --output output3.avif
```

PATH 中的旧版 exe 未被替换；直接输入 `vimg.exe` 仍会调用旧版。

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

## 服务模式 10 次任务返回间隔测试（2026-08-02，hwaccel-dt 分支）

用隔离 Yazi 实例（DDS 中转）+ `vimg serve --capture-backend libav` + 10 个
不同 cache 的 `vimg send` 请求实测服务模式的任务返回间隔。完成时刻取
服务日志 `[serve:N] Done` 时间戳（`vimg send` 是短命进程，其 DDS id 在
退出后不可达，ready 通知 10/10 投递失败——这是诊断命令的固有局限，
yazi 插件路径的 sender 是长驻实例，不受影响）。测试脚本与原始日志在
`.scratch/srvtest/`。

### 串行提交（每个任务完成后才提交下一个）

| job | submit→done | done 间隔 |
|---|---:|---:|
| 0 | 1.774s | — |
| 1 | 1.851s | 1.898s |
| 2 | 1.948s | 1.985s |
| 3–9 | **3.10–3.40s** | 3.14–3.42s |

前 3 个任务 ~1.8s（与 CLI 单次一致），第 4 个起稳定恶化到 ~3.2s。
CLI 模式连续 10 次对照（新进程）无此两段式（1.6–2.4s 波动），说明是
服务进程内累积，不是机器/页缓存问题。

### 并发提交（0.2s 间隔连发 10 个，10 worker 全占用）

| 指标 | 值 |
|---|---:|
| submit→done min / median / max | 3.20s / **10.87s** / 14.23s |
| done 间隔 min / median / max | 0.13s / 1.64s / 4.80s |
| 全部完成 | ~14s |

前 5 个任务并行（3.2–7.6s，CPU 争抢使单任务从 1.8s 拉长），后 5 个排队。
0.5s 间隔的中间态批次完成时间为 6.6–13.6s。

### 进程内累积（附带发现，待查）

- 服务进程 WorkingSet 随任务单调增长：**每任务 +~70MB 常驻**（10 任务后
  93MB → 765MB），线程数稳定（12–15），排除线程泄漏；
- 串行两段式（1.6s→3.2s）与 WS 累积同步出现，怀疑 SVT-AV1 deinit 或
  Windows 堆段缓存的进程内残留；64GB 内存空闲 38GB，非物理内存压力。
- 结论：服务模式 10 并发满载全部完成约 14s；单任务热路径 ~1.6s；连续
  处理下任务延迟会因进程内累积恶化到 ~3.2s/次，需要单独的泄漏定位
  （每任务后 `PeakWorkingSet` 采样 + SVT deinit 探针）再决定是否修。

## 服务模式每任务 ~75MB committed 泄漏定位（2026-08-02，hwaccel-dt 分支）

承接上一节"WS 每任务 +70MB 常驻"的发现做系统性二分。全部实验在服务模式
（serve + 串行提交）下用 GetProcessMemoryInfo 的 WorkingSet/PagefileUsage
（commit）逐任务采样；Windows 堆与 mimalloc 两个全局分配器结果一致。

### 二分矩阵（每任务 commit 增量）

| 配置 | 泄漏 | 排除/锁定 |
|---|---:|---|
| n=9 完整任务 | **+75MB** | 基线 |
| n=9 + SKIP_ENCODE（无 join/SVT/写文件） | +60MB | 排除编码、join、写盘 |
| n=9 + NO_DECODE（demux-only，无 decoder） | +1MB | **锁定 decoder 侧** |
| n=9 + DT=1（单线程解码） | +75MB | 排除 frame threading |
| n=9 + discard=none（无 skip 切换） | +60MB | 排除 skip_frame 状态机 |
| n=9 + 窗口整体偏移（cap1-9 位置） | +1MB | **锁定窗口位置集合** |
| n=1/3/6/7/8（cap0-7） | +1MB | 排除 1-8 窗口 |
| n=1 + 偏移（cap8 位置单独） | +1MB | cap8 单独不泄漏 |
| n=9 + mi_collect(true) 强制回收 | 不回落 | **真泄漏，非分配器空闲页缓存** |

### 结论

- 每任务真泄漏约 **75MB committed**（10 任务后 ~780MB），两个分配器一致，
  `mi_collect` 强制回收无效 → 块仍被引用。
- 泄漏条件精确收窄为：**cap8 窗口（3112s，文件深处）+ 同时与 8 个窗口
  并发解码**。n≤8、cap8 单独、窗口整体偏移后的 9 并发均不泄漏。与编码、
  join、demux/seek、线程数、skip 策略、分配器均无关。
- 机制未最终定位：cap8 单独解码不泄漏但并发时泄漏，指向 FFmpeg h264
  解码器/AVIO 在特定流位置与并发访问下的进程内资源残留；继续定位需要
  UMDH/Dr. Memory 级堆追踪，或换 FFmpeg 构建/版本对照。

### 缓解建议（工程层面）

1. **服务模式定期回收**：任务计数达到阈值（如 100）后优雅重启 serve 进程
   （yazi 插件需处理服务重建），或按 WS 水位重启。
2. **对照 FFmpeg 构建**：gyan 8.1.2 shared 是否有此泄漏可用其他构建
   （BtbN、lgpl）验证；若为 FFmpeg 8.1.x 回归则升级可解。
3. 泄漏量级（75MB/任务）在预览场景（数十任务）内不致命，但长时间驻留
   服务会持续增长，重启回收是当前最实用的兜底。
4. 本分支的 `VIMG_PROTO_SKIP_ENCODE / NO_DECODE / DT / DISCARD /
   IGNORE_START / MI_STATS / CAPTURES` 探针开关保留，供后续堆追踪复用。
