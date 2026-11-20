# Skynet 的 Zig 迁移路线图

目标是通过迁移现有 Skynet 内核，理解线程调度、内存所有权和系统 I/O，并用行为测试支撑后续加固。范围以 `skynet-src/` 和 `service-src/` 的现有原生系统模块为主。Lua 应用、Lua 库和原生扩展用于验证兼容性。

## 当前基线

- 上游基线为 [`12a5e47`](https://github.com/cloudwu/skynet/commit/12a5e47eafb8ed93115ffe9ac776aec5d59655b3)。迁移在 `roowe/skynet` 的 `codex/zig-build` 分支进行。
- [`build.zig`](../build.zig) 已用 Zig `0.17.1` 在 Apple Silicon macOS 上构建 C 内核、仓库自带的 Lua 和默认原生模块。
- [`zig build smoke`](../test/build_smoke.lua) 与 Make 产物共用离线测试，覆盖 Lua 启动、动态库加载、消息往返和定时器。构建命令见 [README](../README.md#build-with-zig-on-apple-silicon-macos)。

## 里程碑

| 阶段 | 改动 | 验收 |
| --- | --- | --- |
| 0 · 已完成 | 用 Zig 构建现有 C 代码 | Make、Zig Debug 和 Zig fast 通过同一套冒烟测试 |
| 1 · 下一步 | 迁移 [`skynet_timer.c`](../skynet-src/skynet_timer.c) 的时间轮 | 虚拟 tick 覆盖立即投递、跨桶、`u32` 回绕和单次投递。真实运行时保留 `PTYPE_RESPONSE`、session 和 10 ms tick 语义 |
| 2 | 补齐 Linux 的 Zig 构建 | 在 Linux 原生验证 jemalloc、主程序符号导出、动态模块加载及同一套冒烟测试 |
| 3 | 先迁 [`skynet_mq.c`](../skynet-src/skynet_mq.c)，再迁 [`skynet_handle.c`](../skynet-src/skynet_handle.c)、服务生命周期和 worker 调度 | 验证服务内 FIFO、就绪队列去重、worker 交接时同一服务回调串行。并发 `grab/retire` 时引用有效，退出后待处理消息按所有权约定释放 |
| 4 | 迁移 [`socket_server.c`](../skynet-src/socket_server.c) 和 socket 事件桥接 | macOS `kqueue`、Linux `epoll` 各跑回环测试，覆盖连接、部分读写、待发数据期间关闭与缓冲区回收 |
| 5 | 迁移 [`service-src/`](../service-src) 内的原生系统模块 | `logger` 可独立迁移。`gate`、`harbor` 等 socket 契约稳定后再迁。`snlua` 单独验证 Lua 状态创建、初始化失败与释放 |

## 下一步如何开工

1. 对照 C 时间轮，记录虚拟 tick 输入与投递序列。加入 `time <= 0`、跨桶、回绕、同 tick 顺序和目标已退出的用例。
2. 用 Zig 实现时间轮，保留 [`skynet_timer.h`](../skynet-src/skynet_timer.h) 的调用边界。用原 C 路径对照投递顺序、目标 handle 和 session。
3. 接入 Zig 构建并跑相同的 Lua 冒烟。时间轮达到行为等价后，为迁移中发现的共享时钟和内存生命周期问题单独补回归和修复。

## 每次合入的条件

- 保持模块名、导出符号、Lua API、消息格式和分配释放协议。跨 C/Zig 边界沿用头文件中的类型与调用约定，优先让内部结构保持私有。
- 每次只替换一个可验证的边界。先提交行为等价的移植，再提交会改变行为的加固。加固测试应能在旧实现上暴露对应问题。
- 并发与 I/O 测试在对应平台运行。Make 暂作 C 对照和其他平台的构建入口。模块完成行为对照和平台验证后，收口临时切换逻辑。
