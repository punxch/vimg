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
