# 技术路线评估（对应 p1）

日期：2026-11-06。范围：用户提供的 Windows 11 原生任务栏、多显示器桌面。

## 结论

**AutoHotkey v2 优先、必要时使用 Windows API 的路线可行，适合做便携试用工具。**
但不能诚实承诺“所有应用从首帧就在目标显示器”“任何 Windows 11 更新都能精确识别”“与任何应用的位置恢复逻辑绝无竞争”。
本版核心全部用 AHK v2 编写，原生 UIA COM 与 Win32 API 通过 `ComCall` / `DllCall` 调用。C# 仅是可选双击启动器，不承担识别/搬窗逻辑。

## 为什么不是简单的鼠标位置 + 焦点变化

程序必须实际收到任务栏上的左键按下和有效释放，且 UIA 命中应用 peer：

1. `WindowFromPoint` + `GetAncestor` 先限定原生主/副任务栏、原生缩略图弹层的窗口族。
2. UIA 命中元素并向上查找应用按钮：ControlType=Button，ClassName=`Taskbar.TaskListButtonAutomationPeer`，非空 AutomationId。
3. 只在本次点击事务内等待激活，核对窗口/进程的 AppID 或明确的映射。未确认应用按钮、身份不明、身份不符都不迁移。
4. 目标显示器来自按下时的物理坐标，不是后来焦点变化时鼠标所在位置。
5. 新按键/其他点击、超时、显示器变动、焦点转向无关应用都会终止事务。
6. 单独打开分组缩略图并不等于选择窗口。只在缩略图精确、唯一标题与实际激活 HWND 相符时支持。

AutomationId 不是 HWND；Windows 没有在本实现所依赖的接口中给出一个可直接信任的“这次任务栏点击最终会激活哪个 HWND”的事务凭据。
因此，应用关联仍有边界；尤其冷启动、代理进程和共享可执行文件的不同任务栏组，不能当作无条件可靠的因果证明。

## API 与线程/进程边界

- AHK 鼠标热键用 `~` 透传真实点击，不发送替代鼠标动作。
- `SetWinEventHook(EVENT_SYSTEM_FOREGROUND, WINEVENT_OUTOFCONTEXT | WINEVENT_SKIPOWNPROCESS)` 只作通知。原生回调只投递消息，不执行 UIA、移动或 Sleep。
- 只有已确认任务栏点击的事务才会检查/处理前台。50ms 计时器用来补充消息时序，不会在空闲时遍历窗口搬家。
- `CUIAutomation8 / IUIAutomation2`、缓存请求、RawViewWalker 在独立的 AHK 辅助进程中使用。设置短连接/事务超时，另有主进程约 1.2 秒 watchdog；挂起时只终止自己持有 HANDLE 的辅助进程。
- UIA 命中请求用 PostMessage 传坐标/事务号，结果用带 magic 的 WM_COPYDATA 返回；核验发送 HWND、大小和事务号，旧响应不能覆盖新点击。
- 窗口身份：`SHGetPropertyStoreForWindow` 的 `System.AppUserModel.ID`；能取得时的 `GetApplicationUserModelId`；本地快捷方式 AppID/目标路径；可审计显式映射。不会按应用按钮的中文名字模糊猜进程。
- 本次已发现部分 Electron 应用没有可直接取得的窗口 AppID。为此读取固定/开始菜单 .lnk 中的明确 AppID 与 exe，而不是假定每个桌面进程都能远程查询到 AppID。
- `SetWindowPlacement`、`GetWindowPlacement` 处理普通/还原/最大化状态。最大化窗口需先排队还原到目标、再最大化；只改 rcNormalPosition 在实测中不会迁移可见最大化窗口。
- WINDOWPLACEMENT 的工作区坐标不直接当作屏幕坐标使用；显式转换上/左任务栏偏移。移动使用异步标志避免等待外部应用 UI 线程。

独立 UIA 进程不是系统服务、不会注入 Explorer；主进程退出会清理它，父进程失效时它也会自行结束。

## Windows 11 的实际限制

UI Automation 是受支持的无障碍 API，但任务栏内部控件类名、AutomationId 的语义和布局并没有在本工具中获得跨版本稳定保证。
本机实际观测到了正确 peer、应用标识和双任务栏，这支持“这条路线可试行”，并不等于未来所有版本都有相同结构。

不采用：任务栏图标颜色/坐标区域硬编码、按窗口标题猜应用、无条件 foreground hook 搬窗、Explorer 注入、发送 Win+Shift+方向键代替精确目标。
最后一种快捷键对当前焦点和多屏排列有额外依赖，也不能直接表达任意目标显示器，所以本版不用。

## 与“根据显示器连接记住窗口位置”的关系

微软的多显示器设置把位置记忆与显示器连接场景关联。本工具不替代该机制，也不操作其设置。
本版的可控边界是：**系统连接恢复保留给 Windows；用户真实任务栏点击只带走这次激活的窗口。**

显示器/工作区/任务栏生命周期变化会作废事务；迁移只做短期有限收尾。这样降低争抢概率，而不是假称能彻底消除所有时序竞争。
窗口被移动后，系统或应用可能记住新位置；如果应用在稍后反复强制恢复，本版放弃，不常驻纠正。

建议保持用户当前勾选状态，先完成真实操作验收。只有复现到具体兼容问题，再根据日志定位，不预先要求关闭一个对热插拔有用的系统选项。

## 参考资料（开发时直接核对官方页面与 SDK 头文件）

1. AutoHotkey v2 `ComCall`：https://www.autohotkey.com/docs/v2/lib/ComCall.htm
2. AutoHotkey v2 `DllCall`：https://www.autohotkey.com/docs/v2/lib/DllCall.htm
3. 官方运行时版本与发布资产：https://github.com/AutoHotkey/AutoHotkey/releases/tag/v2.0.31
4. 微软 UIAutomationClient.h（vtable 定义）：https://github.com/microsoft/win32metadata/blob/main/generation/WinSDK/RecompiledIdlHeaders/um/UIAutomationClient.h
5. IUIAutomation：https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nn-uiautomationclient-iuiautomation
6. UI Automation 线程注意事项：https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading
7. IUIAutomation2 事务超时：https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomation2-put_transactiontimeout
8. SetWinEventHook：https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwineventhook
9. WINDOWPLACEMENT（包括工作区/屏幕坐标差异）：https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-windowplacement
10. System.AppUserModel.ID：https://learn.microsoft.com/en-us/windows/win32/properties/props-system-appusermodel-id
11. GetApplicationUserModelId：https://learn.microsoft.com/en-us/windows/win32/api/appmodel/nf-appmodel-getapplicationusermodelid
12. Windows 多显示器与位置记忆设置：https://support.microsoft.com/en-us/windows/how-to-use-multiple-monitors-in-windows-329c6962-5a4d-b481-7baa-bec9671f728a

这里区分了官方 API 契约、实现中实际观察到的任务栏 peer，以及尚待验证的应用行为。不得把本机观测包装成微软的兼容承诺。
