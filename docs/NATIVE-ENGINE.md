# 原生定位与悬停预览设计 · 0.3.0

2026-11-09。用户要求替换激活后迁移路线，优先验证 Edge / VS Code 的冷启动和最小化恢复体验。

## 执行路径

1. 独立的 `Probe.ahk` 每约 750ms 读取原生任务栏 UIA 应用按钮。控制层核对 AppID、真实路径与现有窗口 HWND/PID，发布带任务栏 HWND 和物理矩形的缓存。过期 3 秒后不再用它命中。
2. DLL 的独立线程接收原生低级鼠标/键盘钩子。使用鼠标事件自带的物理坐标。普通左键有效释放后，64 位应用的事务在事件透传给 Explorer 前就已准备好。自身状态窗口向控制器投递 `0x8054`，预置几何或最小化还原位置。需要显示后定位的点击向控制器投递 `0x8055`。
3. Windows 把 `WH_CBT` 钩子加载到同一桌面的相关 64 位应用。只有回调确实运行在目标 HWND 所属进程和线程，且匹配事务的 HWND/PID 或已核验冷启动路径，才会定位。
4. `HCBT_CREATEWND` 调整初始几何；临时 `SetWindowSubclass` 处理应用在首次显示前重新提交的 `WM_WINDOWPOSCHANGING`。先调用应用窗口过程，再修正可变几何结构，避免应用自己的旧位置还原覆盖目标。
5. 最小化恢复在 `HCBT_MINMAX` 中更新仍处于最小化状态的还原位置，并处理首次可见几何。最大化通过目标工作区和 DPI 边框计算，不先还原、再最大化。
6. 第一次可见 `WM_WINDOWPOSCHANGED` 后等待 250ms，再核对窗口实际所在屏幕。等待期间拦截指向其他屏幕的旧位置。若窗口仍在前台却回到原屏，最多补移一次并再次核对。已经可见的窗口在激活前用 `SetWindowPos` 直接定位，同样确认最终位置。

原生路径保留 Windows 的点击、显示和恢复流程。AHK 的旧 `DoMove` 在原生模式有显式退出保护；32 位兼容定位有独立且明确的身份、期限及成功确认逻辑。自身窗口仍由 `ControllerProcess/GetShared` 排除原生子类，仅通过专用消息准备位置，不调用显示或激活。

32 位兼容路径每 50ms 检查当前有效的任务栏事务，只接受匹配的已显示、非最小化前台窗口；已有候选必须精确匹配 HWND/PID，冷启动必须匹配完整路径及所需身份。稳定至少 80ms 后只请求一次移动，最多用 1 秒确认目标。此路径不保证显示前定位。其他应用内部的启动入口尚不建立任务栏事务。

修正 `WM_WINDOWPOSCHANGING` 的几何后，若应用原先禁止移动/缩放或采用不同几何，同时清除 `SWP_NOREDRAW`、设置 `SWP_NOCOPYBITS`，让窗口按新几何绘制。可见激活也使用短期子类；成功依据实际目标屏幕确认，不能只依据 `SetWindowPos` 返回值。

## 分组与取消

多窗口应用的分组按钮只准备上下文，不随便挑一个窗口定位。用户实际点击原生缩略图后，用之前核验的候选 HWND/PID，匹配 Windows 同步发出的恢复/激活事件。支持从按钮悬停进入预览；上下文有短期时限。

`WH_CALLWNDPROC` 观察 `WM_CLOSE` / `SC_CLOSE`；关闭预览会取消定位，避免随后其他窗口被激活时误当成用户选中。复用的隐藏窗口收到 `WM_SHOWWINDOW(TRUE)` 时，可提前安装短期几何保护。

其他输入、暂停、显示拓扑变化、超时使事务 epoch 失效。按下和释放之间发生取消也会拒绝这次释放。有限等待约束为冷启动配置值（默认 8 秒）、预览选择约 1.8 秒；没有持续锁定屏幕。

## 并发和资源

- UIA、快捷方式和进程属性查询在辅助进程或 AHK 控制层；低级输入线程中没有 COM、文件日志、Sleep 或应用进程查询。
- 固定 ABI：`NativeEntry=3104` 字节，`NativeStatus=168` 字节，`NativeIntent=3136` 字节；DLL 用 `static_assert` 检查。UIA 消息核对发送 HWND、magic、长度；控制层先复制数据再异步处理，避免在 WM_COPYDATA 中做 COM 查询。
- 缓存双缓冲加序列检查；输入线程单独发布事务，每次新事务取得独立 epoch。其他输入递增取消 epoch；针对旧事务的完成/失败只以 CAS 取消它自己的 epoch，避免取消后来点击。`TF_CancelCompatibility(serial)` 只接受当前有效的同序号显示后定位事务。首次 HWND 绑定使用包含事务 serial 的原子 claim，防止旧事务污染新点击。
- 共享映射按 DLL 完整路径和 Windows 桌面区分，避免测试桌面与实际桌面互相影响。运行实例交接使用原有单实例机制。
- 临时子类只能在窗口所属线程安装。上下文用调用计数保护嵌套消息期间的移除，位置确认、取消或过期后结束定位。
- 实际装过子类的进程 pin 当前 DLL，保证卸载全局钩子后潜在回调地址仍有效。组件文件按源码内容摘要命名；已映射的旧组件不被覆盖，应用退出时由 Windows 释放。
- 控制器退出停止全局钩子，禁用共享状态；进程异常退出后，约 2.5 秒失去心跳也停止定位。重新启动可复用被目标进程暂时持有的无效映射。

## 明确边界

这是普通用户权限的 Windows 桌面原型。显示前注入组件为 64 位；已核验的 32 位应用使用上述显示后兼容路径。更高权限、受保护/禁止扩展点的进程不保证处理。冷启动依据已核验的完整可执行文件路径启用；多身份共享程序路径时必须核验精确 AppID。资源管理器只接受 `CabinetWClass` / `ExploreWClass` 文件夹窗口，排除同一个 explorer.exe 中的其他 shell 窗口。无可靠路径的应用仍需现有可核验 HWND/PID 关联。非独立拥有者对话框、工具窗口和无激活窗口排除。

显式配置的别名用于 AHK 身份匹配、缓存索引及32位兼容路线；相同AppID的其他安装仍须路径核验。64位原生冷启动沿用原先的宿主策略：共享宿主置 `TF_REQUIRE_APP_ID` 后精确核对，唯一路径且未置此位时依路径处理，不能将32位路径中的显式ID拒绝规则泛称为所有64位冷启动的保证。重复的冲突别名保留首个有效声明，后续冲突不覆盖已有映射。

已打包的桌面应用按当前用户注册的包和清单中的应用 ID 查找可执行文件。点击时没有已知窗口的 64 位应用包可补充定位。若原生钩子未完成，控制层核对已显示的前台窗口的完整路径与精确 AppID，稳定后请求一次移动并验证位置。原生钩子已绑定窗口时优先等它完成。

完成位置核验后，窗口后续移动由应用和用户控制。首次绘制和最终位置应分别通过应用的实际任务栏操作验证。

运行时从 Explorer 正常双击即可，不需要管理员。自动化沙箱可能允许安装钩子句柄却阻止 DLL 进入子进程；本次已通过沙箱外对照确认这一点。原生独立进程测试在普通用户环境运行，创建独立测试桌面，无需切换用户正在看的桌面。

## 0.3.0：PWA 与预览层

Edge 的有参数 PWA 快捷方式独立保存 AppID、profile、app-id 和实际宿主路径。它们不加入普通 exe 名映射。冷启动事务要求精确窗口/包 AppID；创建阶段仅挂接观察，身份在创建后设置时，在显示前的几何消息里再次核验，匹配后才 claim 和定位。未匹配窗口不会修改几何。

`PeekPreview.h` 在控制器进程创建无激活工具窗口，以 `DwmRegisterThumbnail` / `DwmUpdateThumbnailProperties` 合成实时画面，保持比例。该窗口不激活，设置为不参与系统 Peek 淡出，并给任务栏缩略图弹层留出窗口区域空洞。源窗口的坐标、最小化状态、DWM 属性都不修改。

辅助进程在缩略图悬停时查询 UIA，控制器在输入回调外查询 MSAA 作为补充。候选来源受原生任务栏应用上下文约束；单候选使用已核验 HWND/PID，多候选要求唯一标题匹配。异步预览请求带代数，处理前重新核验鼠标仍在同一弹层且位置未明显改变，避免旧请求重新显示已关闭的预览。

原生低级输入回调只投递预览关闭消息；DWM 调用在工作线程消息处理中执行。移开、点击、按键、暂停、退出、源窗口销毁时关闭预览。原生定位事务已开始时不重新显示悬停层。预览开关与点击定位独立。

分组实时测试采用两个不同颜色的临时源窗口，从实际缩略图颜色独立确定预期来源，再核对预览 HWND 属性及目标显示器，检查移开后关闭、原窗口仍最小化且还原位置完全一致。

## CCSwitch 冷启动漏判修复（2026-11-09）

- 将缓存项解析提取为 `NativeEngine.ResolveEntry`，直接回归“快捷方式身份已知，但还没有窗口”的分支。已核验路径决定冷启动资格，不再使用应用名称白名单。多个候选路径冲突时只保留已有 HWND/PID，不猜冷启动路径。
- 对 PWA 或多个已知身份共享同一可执行文件的情况设置 `TF_REQUIRE_APP_ID`。目标进程内身份优先级为窗口显式 AppID、`GetCurrentProcessExplicitAppUserModelID`、打包应用 ID；显式窗口不匹配时不回退到进程匹配。
- 要求精确身份的临时子类等到显示阶段再 claim，避免创建后的隐藏几何消息过早使用进程身份，抢在应用设置窗口级身份之前定位。
- 无可靠路径/窗口的按钮不再从缓存中静默删除，真实点击会得到 `TF_UNSUPPORTED` 反馈；日志记录当前不可关联的按钮标识和加载的组件摘要，诊断报告单独显示冷启动资格。
- 仅后台隐藏、没有新建窗口的单实例唤醒不等同于冷启动；本次未对这条路径或所有真实应用做兼容性承诺。

## 每轮身份索引与解析复用（2026-11-09）

`NativeEngine.Publish` 验证 UIA 按钮几何后，由 `ResolveButtons` 建立一次 `NativeIdentityIndex`。显式 AppID 使用大小写精确索引；只有没有 AppID 的窗口才进入路径、进程名回退索引。两个匹配桶按原窗口枚举顺序合并，不改变分组候选的优先次序。

同一 AppID 只解析一次，按钮记录分别持有任务栏 HWND 和物理矩形，候选数组只读复用。路径只沿用原有的小写比较规则；已知宿主路径与无完整路径的进程名映射预先建立共享身份索引，避免逐按钮遍历全部映射。候选最多写入 32 个 HWND/PID，但冷启动路径歧义仍检查所有匹配窗口。

这些索引、规范化及文件资格缓存只活到本轮发布结束，不跨轮保存窗口身份或文件存在结果。异常身份在本轮不重复查询，其他正常按钮继续处理，最多输出 64 条成功记录。下一轮重新核验窗口、映射和文件，健康心跳、几何更新时间与原生 DLL 协议不变。

`tests/IdentityCache.ahk` 以原逐窗口匹配与解析逻辑作等价性对照，验证多屏独立几何、大小写、共享宿主、候选上限之外的路径冲突、错误隔离及跨轮变化，同时输出固定合成快照的微基准。

## UIA 筛选与批量缓存（2026-11-09）

`Probe.EmitCache` 调用 `Buttons(hwnd,true,false)`，使用类名条件直接查询应用 peer；条件指定 `IgnoreCase`，保留旧比较规则，不附加新的控件类型限制。每次调用都从任务栏 HWND 重新取得根元素并执行 `FindAllBuildCache`。复用的只有请求配置和筛选条件，没有跨轮元素或矩形缓存。[UIA 缓存与新快照](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-cachingforclients)

扫描缓存仅含 `UIA_AutomationIdPropertyId=30011` 和 `UIA_BoundingRectanglePropertyId=30001`，以 `TreeScope_Element`、`AutomationElementMode_None` 获取。读取 `CachedBoundingRectangle` 得到物理 RECT，避免逐按钮调用当前矩形。默认的 `Buttons(hwnd)` 及全后代诊断 `Buttons(hwnd,false)` 另用包含名称、类名的缓存，保留既有返回字段；`Hit` 仍使用原有 Full 缓存和父元素遍历。[cached-only 模式](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationcacherequest-put_automationelementmode)、[缓存矩形](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-get_cachedboundingrectangle)

扫描结果仍最多读取 300 项；应用查询现在将该上限用于筛选后的匹配项，避免开始、搜索等其他后代节点占用额度。每约 750ms 的发布、原生缓存过期、心跳和失败时不发布的行为保持原样，不因内容相同而省略更新。

`tests/UiaCache.ahk` 跨进程扫描自有工具窗口，检查缓存坐标与 Win32 物理矩形一致，并核对移动、缩放、改名后新快照更新、旧快照保持不变。可选的 `tests/UiaCacheSnapshot.ahk` 对实际任务栏做只读旧/新扫描比较和计时，不模拟输入或移动用户窗口。

## 退出与失败启动的生命周期（2026-11-09）

新调用者检查并使用 `TF_StopAndWait(timeoutMs)` 的 BOOL 返回值，旧 `TF_Stop()` 保留为 3000ms 包装。停止先设置独立原子停止标志，再禁用共享状态、取消事务并投递退出消息；工作线程在创建消息队列前后和发布运行状态时检查停止标志，避免启动超时后丢失退出消息或重新标为运行中。[消息队列与线程消息](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-postthreadmessagew)

只有等待结果为 `WAIT_OBJECT_0` 且钩子清理完成，停止才返回成功并释放线程句柄、就绪事件及控制器映射。超时返回 `ERROR_TIMEOUT`，其他错误保留实际错误码；失败时不释放资源，允许后续重试。生命周期入口使用非阻塞互斥保护，并发启动/停止返回 `ERROR_BUSY`，不会为争锁超出等待预算。状态读取和缓存发布仍由控制线程串行调用。[等待结果](https://learn.microsoft.com/en-us/windows/win32/api/synchapi/nf-synchapi-waitforsingleobject)

线程创建前增加一次 DLL 引用；正常结束最后用 `FreeLibraryAndExitThread` 释放。卸钩失败时保留剩余钩子句柄，并将额外模块引用留给停止重试回收；若重试确认钩子句柄已被系统移除，也可完成清理。控制器自身的钩子回调不借用控制器映射，其他进程的 payload 仍保留各自映射视图。[线程安全释放模块引用](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-freelibraryandexitthread)

AHK 的构造失败也走确认清理；如果新启动返回 `ERROR_ALREADY_INITIALIZED` 或 `ERROR_BUSY`，只释放本次加载引用，不停止其他调用者拥有的引擎。停止失败时保留 DLL 引用并记录原因，退出回调继续清理识别辅助进程；日志失败也不会中断该流程。整个控制器进程退出时由系统回收残留线程和资源，不使用 `TerminateThread`。

`TF_TestLifecycle` 提供仅在 `TF_TEST_MODE` 中使用的启动前/退出前事件门及启动错误注入，`TF_TestSetUnhookFailure` 提供测试模式卸钩失败。事件句柄由 DLL 复制到本生命周期，成功清理后关闭。生命周期测试不安装低级输入钩子，只使用自建桌面；AHK 的引用回归使用自有 DLL 副本及受控回调，不安装任何钩子。

## 官方 API 依据

- [DWM 动态缩略图](https://learn.microsoft.com/en-us/windows/win32/dwm/thumbnail-ovw)
- [DwmRegisterThumbnail](https://learn.microsoft.com/en-us/windows/win32/api/dwmapi/nf-dwmapi-dwmregisterthumbnail)
- [AccessibleObjectFromPoint](https://learn.microsoft.com/en-us/windows/win32/api/oleacc/nf-oleacc-accessibleobjectfrompoint)
- [System.AppUserModel.ID](https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id)

- [CBTProc](https://learn.microsoft.com/en-us/windows/win32/winmsg/cbtproc)：创建前参数、恢复/激活通知和移动尺寸结构。
- [SetWindowsHookExW](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowshookexw)：DLL、线程/桌面作用域和进程位数要求。
- [SetWindowSubclass](https://learn.microsoft.com/en-us/windows/win32/api/commctrl/nf-commctrl-setwindowsubclass)：窗口子类与线程约束。
- [WM_WINDOWPOSCHANGING](https://learn.microsoft.com/en-us/windows/win32/winmsg/wm-windowposchanging)：在显示变化提交前调整几何。
- [GetModuleHandleExW](https://learn.microsoft.com/en-us/windows/win32/api/libloaderapi/nf-libloaderapi-getmodulehandleexw)：回调模块的生命周期。
- [WINDOWPLACEMENT](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-windowplacement)：工作区坐标、正常位置和最大化还原状态。
