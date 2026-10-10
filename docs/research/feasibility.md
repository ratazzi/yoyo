# macOS 按进程时区：可行性验证

**最新状态（2026-10-11）**：已实现并运行 menubar + root ES 常驻服务，在 AUTH_EXEC 内自动注入 CLI。界面支持逐程序固定时区、每次询问、默认不注入，`.app` 子目录、CLI 通配符、子进程继承/显式覆盖及可选行为日志。原装系统 date、80 次并发 CLI 启动、进程链及询问 UI 已通过实际验证。ES 可停用；启动器模式按计划稍后实现。使用方法和验证边界见 [RUNNING.md](RUNNING.md)。下文保留早期可行性记录。

**名称与数据验收已补齐**：CF/NS/ICU 默认名称、NSURL/NSString/C 链接解析、`/etc/localtime` 读取和 metadata 均返回指定时区；严格测试同时要求 IANA 名称、规则数据与时间偏移正确。已覆盖的用户态接口全部通过，独立内核 trap 等边界见运行说明。

验证日期：2026-10-10。本机 macOS 27.0 (26A428)，Apple Silicon arm64，`csrutil status` 为 disabled。宿主默认时区 Australia/Melbourne。没有修改系统时区、`/etc/localtime`、boot-args 或系统签名。

## 结论

**可以实现按启动进程指定“默认时区”的 menubar 工具，且本机已验证注入系统命令成功；当前证据不足以承诺“所有系统应用、所有子进程和后台服务都一致”。**

用户要求注入为必需路径，因此产品方向改为 **启动注入 + 持续 hook**。纯 `TZ` 和仅设置 TZ 的构造函数保留作对照，不能作为产品实现。Endpoint Security 不能充当文件重定向驱动。

## 第二轮：持续 hook 验证

新增 `enforced.m`：通过 dyld `__interpose` 拦截 `getenv/setenv/unsetenv/putenv/tzset` 以及 CF system/default 时区接口；通过 Objective-C runtime 替换 NSTimeZone 的 system/local/default getter 和 default setter。配置在构造函数中复制并保持，目标之后修改 PROCESS_TIMEZONE 不会更新它。这是最小可行性探针，不是完整生产实现。

新增 `adversary.m`：主动清除 TZ、将 TZ 改为 New_York、putenv 改为 UTC、重置 CF/NS 时区缓存，以及把 NS/CF default 改为 UTC。每一步检查 libc、CF system/default、NS system/local/default、新建 NSDateFormatter，固定 Tokyo 为预期，任一步不符即非零退出。

**本机结果：仅构造函数设置 TZ 的旧注入在对抗测试中失败；持续 hook 版本全部通过，且注入系统 `/bin/date` 成功。** `zsh run.sh` 同时运行负对照与持续 hook 测试。

此探针还没有 hook `/etc/localtime` 文件访问、没有直接实现 libc localtime/mktime 替代、没有覆盖绕过 interpose 的内部调用，也没有限制应用显式创建其他时区、直接访问 environ、直接读取时区文件或自行计算时区。不能把这些测试通过解释为防恶意绕过的隔离边界。初版使用 dlsym(RTLD_NEXT) 回调原函数发生崩溃；已改为同一 interposing image 内直接引用原符号，并通过整套验证。

## 已执行的测试

运行 `zsh run.sh`。源码为 `probe.m`、`inject.c`，完整本机输出在 `build/results.txt`。`build/` 为可重建产物。

| 测试 | 实测结果 |
| --- | --- |
| 无 TZ 启动自制 probe | libc、CF、NSTimeZone、NSDateFormatter 均为 Melbourne |
| `TZ=Asia/Tokyo` 启动 probe | 上述默认时区和格式化结果均为 Tokyo |
| 运行中 `setenv(TZ)` + `tzset()` | libc 改变；CF、Foundation 保留原时区 |
| 随后调用 `NSTimeZone.resetSystemTimeZone` | 本次测试 CF、Foundation 及新建 formatter 改为 Tokyo |
| DYLD 构造函数设置 TZ，启动自制 probe | 构造函数执行，上述默认时区全部为 Tokyo |
| DYLD 注入原装 `/bin/date` | **成功**，构造函数执行，epoch 0 输出 `1970-01-01 09:00:00 JST +0900` |
| 启动 `/bin/date` 只设置 TZ | 同样为 Tokyo，无需注入 |
| ad-hoc 签名且设置 runtime flag 的自制 probe | 本机仍注入成功；不能把硬化运行时一概视为本机的阻断条件 |
| NSWorkspace 启动自制 `.app` | **未通过**：`NSCocoaErrorDomain 259` / `kLSNoExecutableErr -10827`；可执行文件存在、plist 合法、codesign verify 成功，原因尚未确定 |

首次 `/bin/date` 注入因 dylib 只有 arm64 而失败：该系统二进制要求 arm64e。改为 arm64 + arm64e 双架构后成功。该结果只代表这个系统二进制及当前主机策略。

可选 GUI 探针：`zsh run.sh --gui`，使用 `launch.m` 和 `probe-Info.plist`。当前不能将 GUI 启动环境传播标记为本机实测成功。

## 方案判断

### 1. 启动时设置 TZ：基础对照

menubar 保存应用路径或 bundle ID → IANA 时区映射，通过 `NSWorkspace.OpenConfiguration.environment` 给**新实例**设置 TZ。Apple 提供此启动环境接口；本机已验证 TZ 的进程内效果，但 NSWorkspace 路径仍待验证。[Apple 文档](https://developer.apple.com/documentation/appkit/nsworkspace/openconfiguration)

已运行实例不能通过再次激活获得新环境，应显示需要重启。直接继承环境的子进程可能继承 TZ；launchd/XPC 独立启动的服务需要单独验证，不能视为普通 fork/exec 后代。

### 2. 启动注入与持续 hook：产品必需路径

已验证 `DYLD_INSERT_LIBRARIES` 构造函数设置 TZ 的路径，包括原装系统 `/bin/date`。应尽量早设置环境，避免其他库先初始化时区缓存；构造函数顺序仍需针对具体目标验证。当前探针没有实现运行中进程注入或通用 hook。

Apple 将 DYLD 环境变量许可、Library Validation 分别定义为目标进程策略；拥有开发者账号或给自己的 helper 加 entitlement 不会自动改变别的应用策略。SIP 关闭会改变部分检查，本机实测优先于“硬化必然拒绝”的泛化说法，但不提供任意进程成功的保证。[DYLD entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.allow-dyld-environment-variables)、[dyld 源码](https://github.com/apple-oss-distributions/dyld/blob/main/dyld/DyldProcessConfig.cpp)

### 3. hook /etc/localtime：可做用户态适配，不能视为万能覆盖

给可注入目标拦截相关路径访问是一个后续 PoC 方向，但尚未实测。需要覆盖实际使用的 API 和路径，包括 `readlink`、open 系列、解析后的 zoneinfo 路径；只 hook `open("/etc/localtime")` 不足以保证 CF/libc 都命中。还要考虑 dyld shared cache 内部调用、直接 syscall、已有缓存和沙箱文件权限。

修改宿主 `/etc/localtime` 是全局变更，不能让两个并发进程分别读取不同文件；不要采用“启动前切换、启动后恢复”，缓存和并发访问会产生竞态。

### 4. Endpoint Security：辅助观察与访问控制

`AUTH_OPEN` 的响应是授权 flags mask，不包含替代 path、fd 或文件内容。`AUTH_EXEC` 也不是改写目标 argv/env 的接口。ES 可辅助观察目标启动和时区文件访问，但自身不能重定向文件或注入环境。[Apple flags response](https://developer.apple.com/documentation/endpointsecurity/es_respond_flags_result(_:_:_:_:))

## 任意进程覆盖的实际边界

- TZ 影响默认时区；显式使用 UTC 或指定其他时区的业务代码不会因此改变。
- 远程服务返回的时区、浏览器定位结果、应用自己的配置和自带时区数据库，不等于操作系统默认时区。
- 启动环境不追溯改变既有进程；Foundation cache 重置也不保证更新已有 formatter、已有 calendar 或应用自建缓存。
- 一个应用可能由主进程、扩展、XPC service、launchd daemon 共同完成工作，需要分别测试。
- 开发者签名、ES entitlement、SIP disabled 都不能单独作为“所有进程支持”的判据。

## 建议的下一验证门槛

用户进一步要求目标从正常入口启动，无启动器垫片。最新候选为 **ES AUTH_EXEC + Mach 操作初始栈 + dyld 启动加载**，详见 `auto-injection-research.md`。公开实例为 [Saagar Jha 的 library_injector.cpp](https://gist.github.com/saagarjha/a70d44951cb72f82efee3317d80ac07f)：在授权响应前使用 task port 改写初始 envp，并处理 dyld 内存策略/启动指令。这不是 ES 的官方环境修改能力；对 macOS 27 的兼容性尚未实测。

**CLI 是硬性要求**：GUI check-in 路线不能作为最终方案；异步 exec 通知后追赶注入不满足短生命周期 CLI 的启动时机要求。新增 `verify-cli.sh`、`cli-fixture.c`、`cli-start-paths.c` 验收程序。fixture 在其 constructor 内进行首次时区读取，并检查实际 hook 导出的 readiness 符号；只看到 Tokyo 的环境效果不算通过。测试 driver 仅用于测试，不是产品启动垫片。

- `zsh verify-cli.sh --control`：显式注入阳性对照通过，首次 constructor 即已安装 hook 且时区为 Tokyo。
- `zsh verify-cli.sh`：测试 inherited env、posix_spawn 空环境、fork+execve 空环境、shell exec 空环境。当前没有独立自动注入 daemon，四条路径均失败，**自动 CLI 注入未实现**。
- 即使显式注入测试 parent，只有继承环境的子进程通过；三个空环境路径仍失败。实测确认环境继承不能满足自动 CLI 注入要求。

CLI 验证默认以 Asia/Tokyo 为预期配置。后续必须在独立 injector 运行、调用方未提供 DYLD 变量时让四条路径通过，再扩展系统 CLI、Rosetta、并发及错误恢复测试。有限测试通过也不能代表任意架构/任意签名二进制的普遍保证。

增加了只作用于自制 probe 的 `launchd-probe.plist`，直接配置程序和注入环境，没有脚本垫片。本次 `launchctl bootstrap gui/501 ...` 返回 `5: Input/output error`，随后查询确认服务未注册，没有创建 stdout/stderr。此实验未验证成功，不能将其解释为 dyld 注入失败，亦未确定错误原因。没有执行全局 `launchctl setenv`。

1. 解决本机 Launch Services 测试 bundle 启动失败，验证 GUI 新实例的 TZ 和注入传播。
2. 选一个系统 GUI 应用、一个硬化第三方应用、一个多进程浏览器，核对主进程、渲染进程和 XPC 行为。
3. 对不遵守 TZ 的具体目标观察调用路径，再决定是 CF/NS API hook、libc hook 还是路径 hook；不要先写全局文件拦截框架。
4. 验证非工具发起的 Finder/登录项/launchd 启动是否必须纳入范围；这需要独立的启动介入方案，普通 menubar launcher 无法自动覆盖。

本目录为可行性探针，尚未实现 menubar 产品或 Endpoint Security 扩展。`research.md` 是第一轮公开接口研究；产品方向以后续明确的“必须注入”要求及本页第二轮实验为准。
