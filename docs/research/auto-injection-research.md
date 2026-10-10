# 自动注入：Finder、终端及 launchd 启动路径

调查日期：2026-10-10。目标为不使用垫片、不要求用户通过专用启动器，自动给任意新进程指定时区。当前主机为 macOS 27.0 (26A428)、arm64、SIP disabled；本文区分资料事实和待验证路线。

## 当前结论

**补充发现，修正验证优先级**：有一个比启动域环境传播更符合用户要求的公开实现：[Saagar Jha 的 library_injector.cpp](https://gist.github.com/saagarjha/a70d44951cb72f82efee3317d80ac07f)。它把 AUTH_EXEC 授权等待与独立 Mach 操作组合，在放行前调整目标初始启动环境，让 dyld 加载指定库；它没有使用 ES response 来编辑环境，也不是通知之后再运行远程 dlopen。代码包含 arm64/arm64e 和版本相关的底层处理，不能作为 macOS 27 兼容性证明。应优先验证这一候选，下面关于 launchd 优先的建议保留为早期调查记录，并由本段取代。

另一个 GUI 范围候选是 [MIP](https://github.com/LIJI32/MIP)：其 README 说明注入 launchservicesd，在 Cocoa 应用的 `_LSApplicationCheckIn` 等待期间加载插件。README 声明 ARM64、Rosetta 2 以及截至 Sonoma 的支持。这条路线不等于任意 CLI/daemon 覆盖，也不保证早于 dyld initializer，当前主机尚未验证。

有两条值得验证的工程路线：通过启动环境让 dyld 自动加载，或驻留服务发现新进程后进行 Mach 注入。前者最有机会在目标代码运行前生效，但环境传播和过滤影响覆盖范围；后者可自动覆盖更多启动来源，却不能凭进程通知保证早于全部 initializer。尚未找到公开接口能直接满足“任意来源、任意系统/第三方程序、每次都在最早初始化前按程序注入”的保证。

ES 是生命周期观察/授权入口，不是环境编辑接口。`AUTH_EXEC` + 修改 event env、`NOTIFY_EXEC` + SIGSTOP 都不能直接当作已经证明的无竞态启动注入方案。

## launchctl setenv 的语义和覆盖限制

**本机一手证据**：`man launchctl` 的 `setenv key value` 描述是：给调用者 context 内，由 launchd 未来启动的进程设置环境。`getenv` 查询该 context 的启动环境；`unsetenv` 清除未来启动时的设置。`launchctl debug service-target --environment ...` 则针对某个 service 的下一次启动，执行一次后清除调试配置。参考本机 `/usr/share/man/man1/launchctl.1`（当前 Apple 安装的手册；用 `man launchctl` 阅读），以及 [Apple launchd 源码仓库](https://github.com/apple-oss-distributions/launchd)（历史开源版本，不能替代当前实现）。

**推断**：给 GUI context 设置 `DYLD_INSERT_LIBRARIES` 是可验证的“后台自动加载”候选，用户可照常从 Finder 启动。然而设置不会追溯修改已经运行的 Terminal、shell、Finder 等进程的 environment；从现有 shell 启动的子进程继承 shell 自己的环境，不能保证取得 launchd 新设置。用户 context、GUI context、system daemon 是不同覆盖范围。每个服务也可能明确提供/过滤自己的环境。

**资料空白**：本次没有找到足以确认 macOS 27 `launchctl setenv DYLD_*` 是否在所有 context 接受、传播或过滤的 Apple 公开契约。网络二手说法互相冲突，应通过本机受控试验决定，不能把 `getenv` 能读到直接当作目标进程一定收到。后续仍有 dyld/AMFI 独立决策：[Apple allow-dyld entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)、[Apple DyldProcessConfig.cpp](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldProcessConfig.cpp)。

**建议试验**：先记录原值，只在受控 context 设置一个仅写 constructor marker 的 dylib；分别用全新 Finder app、全新 Terminal 里的 CLI、原有 Terminal CLI、临时 LaunchAgent、LaunchDaemon 检查 env 与 marker。试验后恢复原值。不要一开始全局加载包含 Foundation 初始化或时区 hook 的库，避免把加载失败和业务行为混在一起。

## Endpoint Security exec 阶段

**当前 SDK 一手证据**：本机 Xcode `MacOSX.sdk/usr/include/EndpointSecurity/ESMessage.h` 的 `es_event_exec_t` 注释说明：`message.process` 描述调用 exec 的旧程序，`event.exec.target` 描述替换后的新程序；同一 PID 的 pidversion 可变，audit token 不同。target 的签名状态对应 exec 已完成但二进制尚未运行的快照。环境为 packed data，由 `es_exec_env`/`es_exec_env_count` 读取。官方接口：[es_event_exec_t](https://developer.apple.com/documentation/endpointsecurity/es_event_exec_t)、[es_exec_env](https://developer.apple.com/documentation/endpointsecurity/es_exec_env(_:_:))。

**API 证据**：AUTH_EXEC 通过 `es_respond_auth_result` 回应 ALLOW/DENY；Apple 示例就是按新程序 signing ID 阻止或放行，没有替换 argv/env/task 的参数。[Apple WWDC20 ES 示例](https://developer.apple.com/videos/play/wwdc2020/10159/)、[es_respond_auth_result](https://developer.apple.com/documentation/endpointsecurity/es_respond_auth_result(_:_:_:_:))。

**因此**：ES event 中的字符串是观察数据，不是可写入内核 exec 参数的控制面。不能修改 `es_exec_env` 指向的内存后就宣称改了目标 environment。ES entitlement 也不自动提供目标 Mach task control port。

**AUTH 阶段 task 注入的未证实部分**：没有找到 Apple 契约承诺 AUTH_EXEC callback 时可以 `task_for_pid` 访问一个已经完成映射、可运行 `dlopen` 的新 task，并允许在 authorization reply 前运行远程代码。公开 [XNU kern_exec.c](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_exec.c) 有权限检查、映射/凭据切换等多个阶段，且 ES 内部实现不在该文件中，无法据此精准定位当前 ES callback 时机。即使 task_for_pid 返回成功，还需核实 task 与新 pidversion 对应，以及 exec 后是否撤销旧 task 权限。此路线只能标作待测研究，不能作为已可行设计。

## NOTIFY_EXEC + SIGSTOP 为什么没有最早执行保证

**证据与推导**：SDK 描述事件产生时的快照，不承诺通知交付后进程仍停在同一点；NOTIFY 没有授权响应屏障。因此异步收到 NOTIFY_EXEC 再发 SIGSTOP，期间目标可执行 dyld、initializer、main，甚至退出。PID 复用也需以 audit token/pidversion 校验。SIGSTOP 成功只证明之后停住，无法撤回已经发生的初始化。

若 AUTH_EXEC callback 内先排队 SIGSTOP 再 ALLOW，仍需实际核实 exec 线程的 pending signal 交付时机、task 更换、信号屏蔽语义和 loader 状态；Apple 没有在上述 ES 文档中提供“先于 dyld 初始化暂停”的契约。不应把这一变体提升为已证明无竞态。

**另一个工程问题（推断）**：在任意加载阶段冻结主线程后创建远程线程运行 `dlopen`，可能遇到 loader/Objective-C/runtime 锁，或在 libSystem 尚未初始化时调用 runtime。普通运行后注入样例不能证明这种很早阶段也安全。

## 一手开源项目证明了什么

### yabai

[当前 loader.m](https://github.com/asmvik/yabai/blob/master/src/osax/loader.m) 明确找到 `com.apple.dock`，并要求 `isFinishedLaunching == YES`，随后 `task_for_pid`、分配远程内存、创建远程线程、通过 pthread 加载 payload。这是“已运行系统应用可 Mach 注入”的直接工程例证，刻意不是最早启动注入。

Apple Silicon 路径处理 PAC 和 `thread_convert_thread_state`，对 macOS 14.4 及以后还有不同线程创建分支。[当前 CHANGELOG](https://github.com/asmvik/yabai/blob/master/CHANGELOG.md) 记录对 macOS 26.2/26.3/26.4/26.6 的持续适配；本次查看未找到 macOS 27 的验证声明。因此可借鉴 loader 作为受控 PoC 基础，但不能把 Dock 特定成功推广为所有进程，也不能把源代码 `>=15` 分支视作经过 macOS 27 验证。

### MacForge

[官方仓库](https://github.com/MacEnhance/MacForge) 说明 plugin injection。其 [CHANGELOG](https://github.com/MacEnhance/MacForge/blob/master/CHANGELOG.md) 记载 helper 负责注入和自动加载，1.2.0 Beta 1 加入 M1 支持及新注入代码，要求每个插件更新以支持 arm64/arm64e。旧官网“不支持 M1”文字不能覆盖这条更晚的一手记录。

该项目证明后台 helper + 插件管理是可用的产品形态；资料没有给出任意 CLI/daemon 全覆盖、initializer 前执行或 macOS 27 保证。应检查当前 injector 源码并在本机跑 marker，不能直接安装旧版后假定适用。

### mySIMBL

[官方仓库 README](https://github.com/w0lfschild/mySIMBL) 明确已停止、由 MacForge 替代；支持范围是 10.10–10.13，Mojave 需额外关闭 SIP/AMFI。适合作为历史机制参考，不能当 macOS 27 arm64e 可行性依据。

## 真实可验证的下一步路线

1. **先测 launchd 环境注入覆盖范围**：这是最少自定义低层机制、最接近启动前执行的路线。若 macOS 27 允许 GUI context 注入，menubar 管规则、注入库 constructor 查当前 executable 后设置 TZ；对不匹配目标立即返回。仍需补上已有 shell、不同用户及 system domain 的传播问题。
2. **再测驻留 helper 的运行后 Mach 注入**：先自己创建一个持续运行的 arm64 probe，再选无用户数据的系统进程；逐项记录 task port、remote allocation、thread、dlopen、constructor。参照 yabai 的 arm64/PAC 处理，保留 target 架构和 exact OS 验证。
3. **时区业务与加载机制分开验收**：成功加载后执行 `setenv + tzset + CF/NS reset`，验证当前/default/local 和 formatter；这能用于长时间运行应用，但早期已建 formatter/显式时区对象仍可能保留旧配置。
4. **若严格要求第一条目标初始化前执行**：建立 constructor 立即读取时区并写 marker、main 极快退出的测试程序；压力跑多次。ES notify/Mach 路线只要一次 marker 先于注入就不满足保证。零次失败也只能说明该测试下未复现竞态，不能成为公开平台保证。

如果启动环境路径无法覆盖所有来源，运行后注入也达不到严格最早时机，则“无启动器、任意进程、启动前保证”目前仍是未验证的私有/系统级研究问题；需要进一步研究父进程 spawn 拦截或系统加载路径，而不能从 ES 权限直接跳到可实施承诺。父进程拦截本身仍意味着注入启动链上的其他程序，并有额外稳定性和版本适配成本。
