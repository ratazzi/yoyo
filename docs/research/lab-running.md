# Timezone Lab 测试程序

**2026-10-11 已完成真实运行验收。** menubar 与 root ES daemon 已启动；普通终端、空环境、execve、posix_spawn 启动的测试 CLI 均自动注入，原装系统 `/bin/date` 也通过。20 组并发测试共 80 次 CLI 启动全部成功。

严格验收同时检查**时区名称、时间规则和文件内容**。CF、Foundation、ICU、`/etc/localtime` 路径解析、读取和 metadata 在已测接口中全部匹配指定时区；宿主真实设置没有被修改。

## 构建与签名

### 程序规则界面（已部署验证）

主窗口可以添加 `.app`、CLI 可执行文件或绝对路径通配符。选择一行，编辑策略、时区及日志开关，点击 **保存规则**。新增规则默认不注入，旧版五条测试规则迁移保留。

- **默认**：不加载 hook。显式默认子规则会移除继承的本工具注入，并恢复会话原始 `TZ` / `TZFILE`；子进程刻意清空环境时，不强行恢复变量。
- **固定时区**：启动前注入，时间、时区名称与已覆盖的 localtime 文件接口保持一致。
- **每次询问**：新独立启动询问一次，选择仅对本次启动会话有效，后代继承。取消、UI 不在线或超时都拒绝启动。等待最多 20 秒，且受 ES deadline 限制；无关程序继续启动。
- **范围**：精确 CLI > CLI 通配符 > `.app` 子目录。同级更具体者优先，完全同分按列表顺序。`*` 不跨 `/`。显式子规则优先；之后没有新规则则继承覆盖结果。
- **可选 ES**：启用/停用后台服务；停用时仍可编辑规则。启动器模式暂未实现。停止服务无法卸载已运行进程的 dylib，需重新启动这些进程。
- **行为日志**：逐规则开启，覆盖后代的执行、fork、退出、文件打开/映射/写入/链接/创建/移动/删除和 hook 时区调用。不记录文件内容、完整参数或环境变量。默认模式只有 ES 日志。日志开关可更新已跟踪进程的共享开关，hook 消息采用有界等待的尽力记录。

主窗口显示父子 PID、选择结果和 hook 加载回执。日志位于 `build/state/behavior.jsonl`，4 MiB 轮转、保留四个归档，可导出当前日志。ES 不能观察每次底层 `read`，文件访问以 open/mmap 等事件表示。

`zsh verify-rules.sh` 已通过空环境子进程继承、通配符覆盖、精确默认清除 hook 与恢复原始 TZ、应用子目录、文件和时区调用日志、文件内容不入日志。询问 UI 已验证固定/默认/取消/自然超时；等待期间系统 date 独立完成。取消及超时的测试程序没有入口输出，退出状态为 137。

当前仍使用用户可写的实验安装/配置目录。生产版需补受保护安装位置、配置写入权限、日志背压与 ES 丢事件报告；日志不是无损审计。控制 socket 验证签名 UI 与 owner UID，hook 回执匹配内核 peer PID/UID 与活动会话。跨用户进程的回执未验证。ES 关联共享服务/XPC 的行为有边界，不能承诺任意系统服务链都可继承。

所有命令在本目录运行，不需要 Python、Node 或第三方依赖；使用 Xcode Command Line Tools 的原生 clang。

```sh
zsh build-lab.sh
zsh verify-lab.sh
```

默认生成 ad-hoc 签名包 `build/TimezoneLab.app`，用于 CLI 对照测试和 UI 开发，不能提供 ES 许可。

在能访问系统 Keychain 的宿主终端使用用户指定的 Developer ID：

```sh
SIGN_IDENTITY=A5D59E9573A394C9AB54B3354913C818170B9948 \
  zsh build-lab.sh
```

`ES_PROVISIONING_PROFILE` 可指定其他 profile，默认直接使用 Floria 仓库的
`/Users/ratazzi/workspace/floria/provisioning/Floria_Endpoint_Security_Developer_ID.provisionprofile`。
实验 daemon 使用该 profile 绑定的 `floria.hola.ac.endpoint-security` signing ID 和 Team `74526N936A`，未修改 Floria，也未注册或替换它的 system extension。实验单独使用 `dev.timezone.lab.daemon` launchd label。

重新构建前，先在 menubar 中注销实验后台服务，避免它执行正在被覆盖的构建产物。默认测试时区是 Tokyo；也可以直接在设置窗口修改时区，无需重新构建。CLI fixture 可接收 epoch 0 预期偏移参数，界面会根据所选时区自动传入。

## 启动 menubar 和后台服务

1. 打开 `build/TimezoneLab.app`，状态栏出现 `TZ Lab`，同时打开设置与测试窗口。本机已验证直接从工作区注册可用。Apple 建议注册 LaunchDaemon 的应用放在 `/Applications`；如需移动，应先注销服务、退出应用，再复制签名包并重新注册。报告仍写入工作区 `build/state/`。
2. 选择 **Register ES background service…**。通过 `SMAppService` 注册内嵌 LaunchDaemon，后台 daemon 以 root 运行，无需替换目标可执行文件或专用启动器。
3. 如显示需要审批，选择 **Open Login Items approval**，在系统设置中批准实验后台服务。
4. 如 ES 返回 `ERR_NOT_PERMITTED`，选择 **Open Full Disk Access**，将实验 daemon bundle 加入 FDA。它位于 `TimezoneLab.app/Contents/Library/LaunchServices/TimezoneLabDaemon.app`。然后注销、重新注册实验服务重试。
5. ES 心跳正常时显示 `ES: listening · Asia/Tokyo`。设置窗口与状态栏菜单均可运行时区探测和 CLI 启动路径验收，调用方不提供 DYLD 变量。
6. 退出菜单不会注销后台服务；停止实验请先选择 **Unregister ES background service**。服务没有安装全局 DYLD 环境变量。

本机登录项授权已通过用户 Touch ID 完成，ES client 已成功连接，不需要额外修改 TCC 数据库或系统策略。服务具备失败重启配置；已验证注销、重新注册后正常恢复。

## 选择时区与 CLI

选择程序规则，选择固定时区后保存。别名按已安装的 zoneinfo 规范化，例如 `Japan` → `Asia/Tokyo`。规则写入 `build/state/policy.json`，后台每秒加载；时区变更影响后续启动，日志开关可影响正在跟踪的进程。添加 CLI、路径通配符或 `.app` 规则的操作见上文。以下旧菜单英文名称对应主窗口的中文按钮。

已通过界面添加系统 `/bin/date`，并验证 Tokyo → New York → Tokyo 切换：空环境启动的 epoch 0 结果分别为 `+0900`、`-0500`、`+0900`，无需设置 TZ/DYLD 或更换启动入口。当前规则保留测试 CLI 和 `/bin/date`，因此普通 `date` 命令也会使用所选时区；需要恢复时可移除该目标或注销实验服务。

## CLI：寻找真实系统时区

```sh
build/TimezoneLab.app/Contents/Resources/bin/timezone-probe --scan-zoneinfo
```

JSON 包含：

- 第一次 constructor 内是否已加载 hook，以及 epoch 0 的 libc 时区偏移。
- libc `localtime` / `localtime_r` / `strftime`、CF system/default、NS system/local/default、calendar/autoupdating calendar、NSDateFormatter 和 ICU 默认时区名称。
- 负时间戳、2026 年夏季、2040 年及当前时间的偏移、DST 和 `mktime` 往返检查。
- `/etc/localtime` 的 `readlink`、`readlinkat`、`realpath`、NSFileManager、NSURL/NSString symlink 解析、`fcntl(F_GETPATH)`、`syscall(SYS_readlink)`。
- `open+read`、`openat+read`、`fopen+fread`、`open+mmap`、NSData、`syscall(SYS_open)+read` 的文件长度和 SHA-256。
- `stat`、`syscall(SYS_stat64)` 返回的大小与请求的 zoneinfo 是否一致。
- 可选扫描系统 zoneinfo，用文件内容匹配找回时区名及别名。结果可能不唯一，例如 Melbourne 与 Victoria 的数据相同。

`syscall()` 测试的是 libc 导出的 trampoline，已在注入库中拦截相关文件调用，并原样转发其他调用；它不是独立内联汇编的内核 trap。直接内联 trap、独立 helper/XPC、未列出的私有文件 API 仍需单独验证；这不是内核级文件命名空间。

```sh
build/TimezoneLab.app/Contents/Resources/bin/timezone-probe \
  --expect Asia/Tokyo --require-injected --attack --scan-zoneinfo
```

此命令应由正常终端直接运行，**不要手动设置 DYLD 变量**，用于验证独立 ES daemon。`--attack` 清除/修改 TZ、重置缓存、修改 NS/ICU default、修改 TZFILE；退出码验证 constructor 注入和默认 API 行为。加入 `--require-files` 会同时强制名称解析、文件内容、metadata 及 ICU 名称通过；界面运行探测时默认开启此严格模式。

menubar 分别显示 `Injected YES/NO`、`names MATCH/LEAK`、`data MATCH/LEAK`、`API PASS/FAIL`。数据状态包含文件内容及 metadata；只改变时间偏移不会通过严格验收。

## 名称与文件视图实现

`enforced.m` 锁定 TZ/TZFILE、CF/NS 默认时区及 ICU 默认 getter/setter；NSURL 和 NSString 的时区链接解析也返回指定的 canonical IANA 路径。显式创建其他区域的时区对象仍用于正常的跨时区转换。

`timezone-files.c` 为当前进程提供 `/etc/localtime` 的只读视图，覆盖 `/private/etc`、相对目录 FD、指向系统链接的别名，以及普通/non-cancel open、openat、fopen、readlink、realpath、stat、getattrlist 等调用。读取重定向到真实的目标 zoneinfo 文件，不生成固定偏移伪数据；mmap、fstat 和 FD 路径因此与真实目标数据一致。readlink 保留截断及不补零语义，no-follow 和无关文件操作另有兼容性测试。

`file-hook-check` 验证无关文件创建/读写、未拦截 syscall 转发、别名链接、no-follow、metadata，以及 ICU default calendar 的真实 ID、getter 缓冲区边界和 setter。不会写入宿主 `/etc/localtime` 或 zoneinfo。

## 自动注入器的边界

默认匹配本项目 `timezone-probe` 与 `cli-fixture` 的精确路径；设置窗口可增删其他 CLI 的路径。其他执行请求立即 ALLOW，不缓存 AUTH_EXEC 决策，不修改其环境。

匹配目标时，daemon 在授权等待期间获取 task、验证单线程和初始 Mach-O 启动栈、将启动字符串复制到目标新内存，再原位重建 argv/env/apple 指针向量，加入 DYLD 库路径和 PROCESS_TIMEZONE。**不修改 SP、不运行远程线程、不 patch dyld 或 AMFI 策略。** 保留既有 argv、其他 env、apple 数据和已有 DYLD 库列表；准备失败时只 DENY 被选中的测试进程。

状态 `prepared` 仅代表启动环境写入完成，不保证 dyld 最终允许加载。目标 constructor 的 readiness 符号及 CLI 报告才是加载验证。目标特有的 task port、dyld 或沙箱限制仍可能阻断注入；失败原因记录在 `build/state/exec-events.jsonl`。不要把已验证的 CLI 样本推广为所有程序都保证成功。

`--self-test` 用本进程的 Mach 内存操作验证 argv/env/apple 的保留与重排；它不证明真实 AUTH_EXEC 时机或跨进程权限。`test-suspended-exec.cpp` 是独立的、清空环境的暂停 CLI 加载实验，可用于隔离 Mach 权限问题；它是测试 driver，不是产品启动方式。

已验证原生 arm64 测试 CLI 和原装 arm64e `/bin/date`。x86_64 / Rosetta 尚未验证。当前 daemon 为非 PAC arm64 构建，只读取 SP，不进行多余的线程状态转换；早期版本的这一步曾在系统 date 上返回 `protection failure`，修复后回归通过。用户态已覆盖列出的时区文件获取接口，不承诺拦截任何程序自行实现的内核调用。

## 本次验证结果

| 项目 | 结果 |
| --- | --- |
| menubar / daemon / CLI / dylib 编译 | 通过 |
| bundle、plist 检查 | 通过 |
| 初始栈保留测试 | 通过 |
| 显式注入，constructor 和默认 API / mutation 验收 | 通过 |
| 注入后时区名称与 `/etc/localtime` 多途径读取 | 严格验收通过：名称、解析路径、TZif 内容、metadata 均匹配 Tokyo |
| ICU setter / TZFILE 修改对抗测试 | 名称与规则保持指定时区 |
| 别名配置 `Japan` | canonical 名称、路径和数据一致为 Asia/Tokyo |
| 无关文件与 syscall、ICU calendar 兼容性 | 独立 fixture 通过 |
| 真实 root ES AUTH_EXEC 自动 CLI 注入 | 普通/空环境 posix_spawn、fork+execve、shell exec 均通过，首次 constructor 已加载 hook |
| 并发真实启动验收 | 20 组并发 × 4 条启动路径，80/80 通过 |
| 原装系统 `/bin/date` 空环境自动注入 | 通过，Tokyo 返回 epoch 0 `1970-01-01 09:00:00 +0900` |
| 界面动态修改时区 | Tokyo → New York → Tokyo，系统 date 与四条 CLI 路径均通过 |
| 独立非 root 暂停子进程对照 | `task_for_pid` 被拒绝；最终方案经已授权 root ES daemon 工作 |
| 使用用户提供的 Developer ID 签名 | 2026-10-11 沙箱外构建签名成功，Team `74526N936A`，含 secure timestamp |
| 完整签名及 ES entitlement 验证 | 沙箱外 `codesign --verify --deep --strict` 通过，ES client/debugger entitlement 均存在 |
| 执行环境差异 | 沙箱内仍出现 identity 不可见及签名/entitlement 校验异常；同一产物在沙箱外验证通过，应在宿主环境验签 |
| ES daemon 直接以普通用户运行 | 按预期报告必须经 launchd 以 root 运行 |
| menubar UI、后台注册与 ES 授权 | 已运行验收，通过 Touch ID 批准后台服务，ES listening |
| 服务注销及重新注册 | 通过，保留规则并恢复 listening |

完整真实验收（当前配置需要 Tokyo，且规则包含系统 date 和测试 CLI）：

```sh
zsh verify-live.sh
```

`verify-system-cli.sh` 是系统 date 的回归测试；`verify-lab.sh` 验证未选中路径的宿主对照、阳性/阴性对照、mutation、文件/ICU 兼容性、签名与本进程启动栈。
测试证据位于 `build/evidence/live/`，界面生成的报告位于 `build/state/`。当前 `build/` 不纳入版本控制。
