# macOS 按进程时区：公开接口与注入边界

调查日期：2026-10-10。目标包括系统应用及任意进程。主机信息由实验负责人提供：macOS 27.0 (26A428)、arm64、SIP disabled。本文仅记录文档/源码证据；公开源码不等于当前主机二进制实现，实际结果由同目录 PoC 补充。

## 结论

- 有明确基础的首选方案是在启动目标前传入 `TZ=Asia/Tokyo`。它是 libc 的进程环境配置；不需要改变系统时区。Foundation 是否完全遵从、系统应用是否保留环境、子进程是否继承，需逐项实测。
- `DYLD_INSERT_LIBRARIES` 提供启动时注入入口，但“任意进程，包括系统应用”不能由开发者账号、ES entitlement、SIP disabled 三项直接保证。目标签名、AMFI 决策、架构和实际加载路径仍需测量。
- Endpoint Security 的公开 AUTH_OPEN 接口无法返回替代路径、文件描述符或内容，因此不是 `/etc/localtime` 重定向机制。
- 仅拦截 `open("/etc/localtime")` 覆盖不足。至少公开 CF 实现还读取符号链接、维护缓存；目标也可能显式指定时区，或把请求交给另一个进程。

## libc：环境、文件与缓存

**证据**：Apple 的 `tzset(3)` 手册将 `TZ` 定义为 `localtime` 的转换配置；不合法设置会落到 UTC。Apple Libc 公开源码 `tzset_basic` 通过 `getenv_copy_np("TZ")` 取值；不存在时转入 `tzsetwall_basic`，后者加载默认时区文件。代码会缓存环境值，并使用 `com.apple.system.timezone` 通知；无 bootstrap port 时检查默认符号链接 mtime。

来源：[Apple tzset(3)](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man3/tzset.3.html)、[Apple Libc localtime.c](https://github.com/apple-oss-distributions/Libc/blob/main/stdtime/FreeBSD/localtime.c)（`tzset_basic`、`tzsetwall_basic`、`notify_register_tz`）。

**推断**：启动前设置 TZ 比进程运行后再改环境可靠。仅设置环境不改 UTC 时间戳，只改变转换/显示结果。默认文件替换不保证所有已运行进程立即刷新，必须考虑缓存和通知。

## CoreFoundation/Foundation：不能把 default 当作 system

**证据**：Apple 公开 CF 源码（文件版权时间 2015，不能视作 macOS 27 实现承诺）依次尝试 `TZFILE`、`TZ`、`readlink(TZZONELINK)`。`CFTimeZoneCopySystem` 和 `CFTimeZoneCopyDefault` 各有缓存；`CFTimeZoneSetDefault` 只改 default，`CFTimeZoneResetSystem` 清除 system。来源：[Apple CFTimeZone.c](https://github.com/apple-oss-distributions/CF/blob/main/CFTimeZone.c)（`__CFTimeZoneCreateSystem`、`CFTimeZoneCopySystem`、`CFTimeZoneSetDefault`）。

**当前文档证据**：`NSTimeZone.local` 跟踪系统时区，`system` 缓存直到 reset；从 macOS High Sierra 起 local 跟踪 system，旧版本则跟踪 default。来源：[Apple NSTimeZone.local](https://developer.apple.com/documentation/foundation/nstimezone/local)。

**推断**：注入库中调用 `NSTimeZone.default = ...` 不足以承诺覆盖 `system` / `local` / `TimeZone.autoupdatingCurrent`。仅 hook 文件 open 也可能错过 readlink。验证需要同时打印 libc、CF system/default、NS system/default/local 和 formatter。

## DYLD、Hardened Runtime、Library Validation、SIP

**文档证据**：目标的 `com.apple.security.cs.allow-dyld-environment-variables` 允许 dyld 读取 `DYLD_` 环境变量。若注入库不满足目标所期待的 Team ID，还需目标的 disable-library-validation。来源：[Apple Allow DYLD environment variables](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)。

**文档证据**：Hardened Runtime 默认启用 Library Validation，常规允许 Apple 签名或与主程序同 Team ID 的库。这个 entitlement 属于被注入目标，不能只加在 menubar launcher 上就替目标放行。来源：[Apple Disable Library Validation](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation)。

**源码证据**：dyld `ProcessConfig::Security` 从 AMFI 取得 path 环境、library interposing、libSystem override 等分别控制的标志；`SyscallDelegate::amfiFlags` 调用 `amfi_check_dyld_policy_self`，还传入 restrict segment / FairPlay 加密情况。来源：[Apple DyldProcessConfig.cpp](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldProcessConfig.cpp)、[Apple DyldDelegates.cpp](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldDelegates.cpp)。

**SIP 的证据边界**：Apple 历史 SIP 文档说明受保护进程会清除 DYLD 环境并禁止 task attach。来源：[Apple Runtime Protections](https://developer.apple.com/library/archive/documentation/Security/Conceptual/System_Integrity_Protection_Guide/RuntimeProtections/RuntimeProtections.html)。但 Apple DTS 在 2022 官方论坛中明确说关闭 SIP 能绕过其讨论的 Hardened Runtime DYLD_LIBRARY_PATH 限制。来源：[Apple DTS 讨论](https://developer.apple.com/forums/thread/703757)。

**因此不能过度下结论**：既不能说 SIP off 保证所有系统应用可注入，也不能凭通用 entitlement 文档断言 SIP off 时所有 hardened 目标依然阻止注入。当前 macOS 27 的 AMFI 有效政策应以本机 PoC 为准。公开 dyld 源码展示机制，但没有公开完整 AMFI 策略，不能从这些文件推导全覆盖。

**开发者账号的边界（推断）**：Developer ID 允许签署自己的代码，不会把自己的库变成 Apple platform code，也不会自动获得其他应用的 Team ID 或修改对方 entitlement。对自己可控制的目标，签名和 runtime exceptions 是正常可行路径；重签第三方/系统应用会改变目标身份及原有权限，应单独评估。

## Endpoint Security：可监控/拒绝，不可替换

**证据**：`es_respond_flags_result(client, message, authorized_flags, cache)` 的第三参数只作为 flags mask。Apple WWDC 解释 AUTH_OPEN 可将读写请求限制为只读；其余 AUTH 一般是 ALLOW/DENY，多个 ES 客户端结果取最严格策略。来源：[Apple es_respond_flags_result](https://developer.apple.com/documentation/endpointsecurity/es_respond_flags_result(_:_:_:_:))、[Apple WWDC20 Build an Endpoint Security app](https://developer.apple.com/videos/play/wwdc2020/10159/)。

**接口推导**：该响应没有替代 path/fd/bytes 参数，因此不能把 A 进程的 `/etc/localtime` 返回为东京、B 进程返回为伦敦。修改收到的 message 内存也不构成受支持的内核操作修改 API。ES entitlement 适合审计目标访问和进程生命周期，不解决文件虚拟化。

**竞态推断**：收到 AUTH_OPEN 后临时改全局符号链接，再放行并恢复，会影响其他同时访问者，也无法覆盖只看 readlink 的代码。不能当作可行的按进程隔离方案。

## `/etc/localtime` 虚拟化的现实边界

调查所查 Apple 公开接口中未发现针对任意既有进程的 per-process mount namespace 或返回不同 `/etc/localtime` 内容的机制。这是“没有找到公开接口”，不是证明内核中不存在私有机制。

可注入目标可以在用户态拦截文件/时区 API，但需覆盖具体调用与缓存，不能承诺任意程序。全局替换 `/etc/localtime` 是全系统修改，无法同时满足多个目标不同的时区。若要求完全透明地覆盖系统应用、直接系统调用、XPC/launchd helper 和第三方运行时，需要内核/私有机制或隔离虚拟机等级的方案，目前没有由本次公开资料证明的通用 menubar 实现。

## 最小验证矩阵

1. 原始进程与 `TZ` 启动对照：libc、CF、Foundation、formatter，同时检查系统时区没有变化。
2. unsigned/ad hoc、自签 hardened、allow-dyld、allow-dyld + disable-LV 目标分别测试 constructor marker 和时区行为。
3. Apple 系统命令及至少一个系统 GUI app：区分变量被清除、库加载失败、库已加载但 hook 未覆盖。
4. 分别验证 CF/NS system/default/local，以及显式时区 formatter；不能以某个日期字符串变化代表所有时区 API 被覆盖。
5. 检查目标 helper/XPC 的真实时区；只注入主进程的结果不能外推到整个应用。
