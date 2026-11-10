#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#Warn VarUnset, StdOut
#Include lib\Native.ahk
#Include lib\Policy.ahk
#Include lib\Instance.ahk
#Include lib\StatusWindow.ahk
#Include lib\NativeEngine.ahk
#Include lib\DisplayStartup.ahk

if A_LineFile = A_ScriptFullPath {
    Desktop.Physical()
    argument := A_Args.Length ? A_Args[1] : ""
    if argument = "--check" {
        identityCheck := WindowIdentity(A_ScriptDir . "\settings.ini")
        if IniRead(A_ScriptDir . "\settings.ini","General","Engine","native") = "native"
            NativeEngine.CheckRuntime()
        FileAppend("TaskbarFollow: configuration and script load OK`n", "*", "UTF-8")
        ExitApp(0)
    }
    automated := argument = "--startup-test" || argument = "--lifecycle-test" || argument = "--status-test"
    if automated
        DllCall("user32\SetPropW", "ptr", A_ScriptHwnd, "wstr", "TaskbarFollow.TestOnly", "ptr", 1)
    try {
        if !automated && !FollowInstance.Acquire(argument != "--background")
            ExitApp(0)
        Follow := TaskbarFollow(automated,argument = "--background")
        Follow.Start(argument = "--lifecycle-test")
        if argument = "--startup-test"
            SetTimer(ObjBindMethod(Follow, "FinishStartupTest"), -1800)
        else if argument = "--status-test" {
            Follow.ShowStatus()
            SetTimer(ObjBindMethod(Follow, "FinishStatusTest"), -2500)
        }
    } catch as startupError {
        if automated
            FileAppend("startup FAIL: " . startupError.Message . " (line " . startupError.Line . ")`n", "*", "UTF-8")
        else if argument = "--background" {
            try {
                DirCreate(A_ScriptDir . "\logs")
                FileAppend(FormatTime(A_Now,"yyyy-MM-dd HH:mm:ss") . " background startup failed: "
                    . startupError.Message . "; line=" . startupError.Line . "`n",A_ScriptDir . "\logs\TaskbarFollow.log","UTF-8")
            }
        }
        else
            MsgBox("随屏启动失败：`n" . startupError.Message . "`n`n请保留整个程序文件夹，并查看 logs 文件夹。", "随屏 · 启动失败", "Iconx")
        ExitApp(1)
    }
}

ForegroundEvent(hook, event, hwnd, objectId, childId, threadId, time) {
    ; The callback must return promptly. No UIA, window moves, sleeps or process queries here.
    DllCall("user32\PostMessageW", "ptr", A_ScriptHwnd, "uint", 0x8052, "uptr", hwnd, "ptr", 0)
}

class TaskbarFollow {
    __New(testOnly := false,backgroundStart := false) {
        this.Config := A_ScriptDir . "\settings.ini"
        this.Enabled := IniRead(this.Config, "General", "Enabled", "1") = "1"
        this.BringActive := IniRead(this.Config, "General", "BringActiveAcrossMonitors", "1") = "1"
        this.Timeout := Geometry.Clamp(Integer(IniRead(this.Config, "General", "ActivationTimeoutMs", "8000")), 1000, 15000)
        this.Delay := Geometry.Clamp(Integer(IniRead(this.Config, "General", "StableDelayMs", "180")), 100, 800)
        this.Identity := WindowIdentity(this.Config, false) ; show UI before reading shell shortcuts
        this.Pending := 0, this.Serial := 0, this.Generation := 0, this.CoolUntil := 0
        this.HelperPid := 0, this.HelperHwnd := 0, this.HelperHandle := 0, this.HelperReady := false
        this.HelperStarted := 0, this.HelperRestartAt := 0, this.Hook := 0, this.Callback := 0
        this.DisableMoves := testOnly
        this.TestOnly := testOnly, this.BackgroundStart := backgroundStart, this.Panel := 0, this.TrayBuilt := false
        this.NativeMode := !testOnly && IniRead(this.Config,"General","Engine","native") = "native"
        this.Native := 0, this.NativeRows := "", this.NativePublishing := false
        this.NativeHoverRows := "hide", this.NativeHoverBusy := false
        this.FollowPeek := IniRead(this.Config,"General","FollowPeek","1") = "1"
        this.Started := false, this.MappingsReady := false, this.StartTick := Desktop.Tick()
        this.SuccessfulMoves := 0, this.LastActivity := "程序已启动，正在连接任务栏识别器。"
        this.HideNoticeShown := false
        this.Pumping := false, this.TestMode := false, this.ReplyCount := 0, this.TestProbeSent := false
        logDirectory := A_ScriptDir . (testOnly ? "\tests\results\logs" : "\logs")
        this.LogPath := logDirectory . "\TaskbarFollow.log"
        DirCreate(logDirectory)
    }
    Start(testMode := false) {
        this.TestMode := testMode
        OnExit(ObjBindMethod(this, "Exit"))
        OnMessage(0x8051, ObjBindMethod(this, "HelperHello"))
        OnMessage(0x4A, ObjBindMethod(this, "HelperReply"))
        ; Native input identifies an explicit click on our own taskbar entry.
        ; Move only our GUI here; native hooks keep excluding controller windows.
        OnMessage(0x8054, ObjBindMethod(this, "OwnTaskbarClick"))
        OnMessage(0x8055, ObjBindMethod(this, "CompatibilityClick"))
        if testMode {
            this.StartHelper()
            SetTimer(ObjBindMethod(this, "Watchdog"), 250)
            SetTimer(ObjBindMethod(this, "FinishLifecycleTest"), -2500)
            return
        }
        this.BuildTray()
        if this.NativeMode {
            this.Native := NativeEngine(this)
            SetTimer(ObjBindMethod(this,"PollNative"),200)
        }
        this.StartHelper()
        SetTimer(ObjBindMethod(this, "Watchdog"), 250)
        OnMessage(0x8052, ObjBindMethod(this, "OnForeground"))
        OnMessage(0x7E, ObjBindMethod(this, "TopologyChanged")) ; WM_DISPLAYCHANGE
        OnMessage(0x1A, ObjBindMethod(this, "SettingsChanged"))
        OnMessage(0x218, ObjBindMethod(this, "PowerChanged"))
        taskbarCreated := DllCall("user32\RegisterWindowMessageW", "wstr", "TaskbarCreated", "uint")
        OnMessage(taskbarCreated, ObjBindMethod(this, "TopologyChanged"))
        if !this.NativeMode {
        Hotkey("~*LButton", ObjBindMethod(this, "LeftDown"))
        Hotkey("~*LButton Up", ObjBindMethod(this, "LeftUp"))
        for key in ["RButton", "MButton", "XButton1", "XButton2", "WheelUp", "WheelDown", "WheelLeft", "WheelRight"]
            Hotkey("~*" . key, ObjBindMethod(this, "OtherInput"))
        this.Keyboard := InputHook("V L0")
        this.Keyboard.KeyOpt("{All}", "N")
        this.Keyboard.OnKeyDown := ObjBindMethod(this, "OtherInput")
        this.Keyboard.Start()
        this.Callback := CallbackCreate(ForegroundEvent, , 7)
        this.Hook := DllCall("user32\SetWinEventHook", "uint", 3, "uint", 3, "ptr", 0,
            "ptr", this.Callback, "uint", 0, "uint", 0, "uint", 2, "ptr")
        ; Poll only an explicitly armed transaction; also covers a foreground event delivered before UIA's reply.
        SetTimer(ObjBindMethod(this, "Pump"), 50)
        }
        Hotkey("^!F12", ObjBindMethod(this, "Toggle"))
        this.Started := true
        ; Once the status window is visible, taskbar input must already be armed.
        if !this.TestOnly && !this.BackgroundStart
            this.ShowStatus()
        SetTimer(ObjBindMethod(this, "LoadIdentity"), -20)
        this.UpdateTray()
        this.Log("start; Windows build=" . A_OSVersion . "; monitors=" . MonitorGetCount() . "; background=" . this.BackgroundStart . "; remember-location setting untouched")
        if !this.Hook && !this.NativeMode
            this.Log("foreground-hook unavailable; explicit-click timer remains active")
    }
    BuildTray() {
        A_TrayMenu.Delete()
        A_TrayMenu.Add("显示运行状态", ObjBindMethod(this, "ShowStatus"))
        A_TrayMenu.Add()
        A_TrayMenu.Add("启用任务栏跟随", ObjBindMethod(this, "Toggle"))
        if this.NativeMode
            A_TrayMenu.Add("悬停预览随屏",ObjBindMethod(this,"TogglePeek"))
        A_TrayMenu.Add("连接第二块屏幕时自动启动", ObjBindMethod(this, "ToggleStartup"))
        A_TrayMenu.Add()
        A_TrayMenu.Add("打开配置（修改后重启）", (*) => Run('notepad.exe "' . this.Config . '"'))
        A_TrayMenu.Add("打开日志", ObjBindMethod(this, "OpenLog"))
        A_TrayMenu.Add("生成兼容性诊断（只读）", ObjBindMethod(this, "RunDiagnostics"))
        A_TrayMenu.Add("使用说明", (*) => Run('notepad.exe "' . A_ScriptDir . '\README.md"'))
        A_TrayMenu.Add()
        A_TrayMenu.Add("退出", (*) => ExitApp())
        A_TrayMenu.Default := "显示运行状态"
        this.TrayBuilt := true
        try TraySetIcon("shell32.dll", 16)
        this.UpdateTray()
    }
    UpdateTray() {
        if this.TrayBuilt && !this.TestMode {
            A_IconTip := "随屏 · 任务栏窗口跟随`n" . (!this.Enabled ? "已暂停" : (this.HelperReady && this.MappingsReady ? "运行中" : "正在连接任务栏识别器"))
            (this.Enabled ? A_TrayMenu.Check("启用任务栏跟随") : A_TrayMenu.Uncheck("启用任务栏跟随"))
            (DisplayStartup.IsEnabled(A_ScriptDir,this.StartupPath()) ? A_TrayMenu.Check("连接第二块屏幕时自动启动") : A_TrayMenu.Uncheck("连接第二块屏幕时自动启动"))
            if this.NativeMode
                (this.FollowPeek ? A_TrayMenu.Check("悬停预览随屏") : A_TrayMenu.Uncheck("悬停预览随屏"))
        }
        this.UpdateStatus()
    }
    UpdateStatus(*) {
        if IsObject(this.Panel)
            this.Panel.Update()
    }
    ShowStatus(*) {
        if !IsObject(this.Panel)
            this.Panel := FollowStatusWindow(this)
        this.Panel.Show(!this.TestOnly)
    }
    OwnTaskbarClick(monitorHandle,windowHwnd,*) {
        if !this.Enabled || !this.NativeMode || !this.Started || !IsObject(this.Panel)
            return 0
        try {
            if windowHwnd != this.Panel.Window.Hwnd || !this.Panel.Visible
                || Desktop.Pid(windowHwnd) != DllCall("kernel32\GetCurrentProcessId","uint")
                return 0
            monitor := Desktop.Monitor(monitorHandle)
            if !IsObject(monitor) || Desktop.SameMonitor(Desktop.MonitorOf(windowHwnd),monitor)
                return 0
            if !this.Panel.PrepareMonitor(monitor)
                return 0
            try this.Log("status self-follow prepared; target=" . monitor.Device . "; minimized=" . Desktop.IsMin(windowHwnd))
            return 1
        } catch as selfError {
            try this.Log("status self-follow error: " . selfError.Message)
            return 0
        }
    }
    CompatibilityClick(serial,monitorHandle,*) {
        if !this.Enabled || !this.NativeMode || !this.Started || !IsObject(this.Native)
            return 0
        return this.Native.BeginCompatibility(serial,monitorHandle)
    }
    HideStatus(*) {
        if !IsObject(this.Panel) || !this.Panel.Visible
            return
        this.Panel.Hide()
        if !this.TestOnly && !this.HideNoticeShown {
            this.HideNoticeShown := true
            TrayTip("仍在后台运行。再次点击桌面快捷方式或托盘图标可显示状态；彻底停止请选“退出”。", "随屏已收起", 1)
        }
    }
    LoadIdentity() {
        started := Desktop.Tick()
        try this.Identity := WindowIdentity(this.Config)
        catch as exception {
            this.Log("shortcut mapping initialization failed: " . exception.Message)
        }
        this.MappingsReady := true
        this.Log("identity ready; elapsed-ms=" . (Desktop.Tick() - started) . "; shortcuts=" . this.Identity.ShortcutCount)
        if this.NativeMode
            this.ReportActivity("应用映射已加载，正在准备原生任务栏定位。")
        else if IsObject(this.Pending)
            this.ReportActivity("初始化完成，正在继续处理刚才的任务栏点击。")
        else
            this.ReportActivity("初始化完成。请在另一块屏幕的任务栏点击应用，观察这里的处理反馈。")
        this.UpdateTray()
        this.Pump()
    }
    ReportActivity(text) {
        this.LastActivity := text
        this.UpdateStatus()
    }
    PollNative(*) {
        if IsObject(this.Native) {
            readyBefore := this.Native.Ready, movesBefore := this.SuccessfulMoves
            this.Native.Poll()
            if !readyBefore && this.Native.Ready {
                this.Log("native ready; cached buttons=" . this.Native.CacheCount)
                this.ReportActivity("原生定位已就绪。请从目标屏幕的任务栏打开或恢复应用。")
            } else if readyBefore != this.Native.Ready || movesBefore != this.SuccessfulMoves {
                ; Native.Poll reports new activity itself. Steady 200ms health
                ; polls must not drive GUI redraws or reset the visible clock.
                this.UpdateStatus()
            }
        }
    }
    PublishNativeCache() {
        if this.NativePublishing || !IsObject(this.Native)
            return
        this.NativePublishing := true
        try this.Native.Publish(this.NativeRows)
        catch as e
            this.Log("native cache error: " . e.Message . "; " . e.Extra . "; file=" . e.File . "; line=" . e.Line)
        finally this.NativePublishing := false
    }
    PublishNativeHover() {
        if this.NativeHoverBusy || !this.FollowPeek || !IsObject(this.Native)
            return
        this.NativeHoverBusy := true
        try this.Native.Hover(this.NativeHoverRows)
        finally this.NativeHoverBusy := false
    }
    OpenLog(*) {
        if !FileExist(this.LogPath)
            FileAppend("", this.LogPath, "UTF-8")
        Run('notepad.exe "' . this.LogPath . '"')
    }
    RunDiagnostics(*) => Run('"' . A_AhkPath . '" "' . A_ScriptDir . '\Diagnose.ahk"', A_ScriptDir, "Hide")
    Toggle(*) {
        this.Cancel("toggle"), this.Enabled := !this.Enabled
        if IsObject(this.Native)
            this.Native.SetEnabled(this.Enabled)
        if !this.TestOnly
            IniWrite(this.Enabled ? "1" : "0", this.Config, "General", "Enabled")
        this.ReportActivity(this.Enabled ? "已启用任务栏跟随，等待下一次应用点击。" : "已暂停跟随。程序仍在运行，但不会移动窗口。")
        this.UpdateTray()
    }
    TogglePeek(*) {
        this.FollowPeek := !this.FollowPeek
        if IsObject(this.Native)
            this.Native.SetPeekEnabled(this.FollowPeek)
        if !this.TestOnly
            IniWrite(this.FollowPeek?"1":"0",this.Config,"General","FollowPeek")
        this.ReportActivity(this.FollowPeek?"悬停预览随屏已启用。":"悬停预览随屏已关闭，点击定位继续运行。")
        this.UpdateTray()
    }
    StartupPath() => DisplayStartup.Path()
    ToggleStartup(*) {
        if this.TestOnly
            return
        path := this.StartupPath()
        enabled := !DisplayStartup.IsEnabled(A_ScriptDir,path)
        DisplayStartup.Set(enabled,A_ScriptDir,path)
        this.ReportActivity(enabled ? "屏幕连接检测已开启，连接第二块屏幕时自动启动。" : "屏幕连接检测已关闭。")
        this.UpdateTray()
    }
    StartHelper() {
        if this.HelperHandle
            this.StopHelper()
        this.HelperReady := false, this.HelperHwnd := 0, this.HelperStarted := Desktop.Tick()
        Run('"' . A_AhkPath . '" /ErrorStdOut=UTF-8 "' . A_ScriptDir . '\Probe.ahk" '
            . A_ScriptHwnd . " " . ProcessExist() . (this.NativeMode ? " --native" : ""), A_ScriptDir, "Hide", &pid)
        this.HelperPid := pid
        this.HelperHandle := DllCall("kernel32\OpenProcess", "uint", 0x101001, "int", false, "uint", pid, "ptr")
    }
    StopHelper() {
        if this.HelperHandle {
            ; An owned process HANDLE, not a possibly recycled PID. Never terminate Explorer or an application.
            if DllCall("kernel32\WaitForSingleObject", "ptr", this.HelperHandle, "uint", 0, "uint") = 0x102
                DllCall("kernel32\TerminateProcess", "ptr", this.HelperHandle, "uint", 0)
            DllCall("kernel32\WaitForSingleObject", "ptr", this.HelperHandle, "uint", 500, "uint")
            DllCall("kernel32\CloseHandle", "ptr", this.HelperHandle)
        }
        this.HelperHandle := 0, this.HelperPid := 0, this.HelperHwnd := 0, this.HelperReady := false
    }
    HelperHello(childHwnd, pid, *) {
        if pid = this.HelperPid && Desktop.Pid(childHwnd) = pid {
            this.HelperHwnd := childHwnd, this.HelperReady := true
            this.Log("UIA helper ready")
            this.UpdateTray()
            if !this.TestMode
                this.ProbePending()
            if this.TestMode && !this.TestProbeSent {
                this.TestProbeSent := true
                this.Serial += 1
                this.Pending := FollowIntent(this.Serial, this.Generation, Desktop.Tick(), 0, 0, Desktop.MonitorAt(0, 0), 0, 0, false, 0)
                DllCall("user32\PostMessageW", "ptr", this.HelperHwnd, "uint", 0x8050,
                    "uptr", this.Serial, "int64", Desktop.Point(0, 0))
            }
        }
    }
    HelperReply(sender, cds, *) {
        if sender != this.HelperHwnd || !this.HelperReady || !cds
            return 0
        magic := NumGet(cds, "uptr")
        if magic != 0x54424631 && !(this.NativeMode && (magic = 0x54424633 || magic = 0x54424634))
            return 0
        bytes := NumGet(cds, A_PtrSize, "uint"), ptr := NumGet(cds, A_PtrSize * 2, "ptr")
        if bytes < 2 || bytes > 32768 || Mod(bytes, 2) || !ptr
            return 0
        if magic = 0x54424634 {
            this.NativeHoverRows := StrGet(ptr,bytes//2-1)
            SetTimer(ObjBindMethod(this,"PublishNativeHover"),-1)
            return 1
        }
        if magic = 0x54424633 {
            this.NativeRows := StrGet(ptr,bytes//2-1)
            SetTimer(ObjBindMethod(this,"PublishNativeCache"),-1)
            return 1
        }
        this.ReplyCount += 1
        fields := StrSplit(StrGet(ptr, bytes // 2 - 1), "`n")
        i := this.Pending
        if !IsObject(i) || fields.Length < 2 || fields[1] != i.Serial || i.Serial != this.Serial
            return 1
        kind := fields[2]
        if kind != "app" && kind != "thumbnail" {
            this.Cancel(kind = "error" ? "UIA error" : "not-an-app-button", i)
            return 1
        }
        if fields.Length < 4
            return 0
        i.Kind := kind, i.AppId := fields[3], i.Probed := true
        if kind = "thumbnail" {
            Loop fields.Length - 4
                i.Names.Push(fields[A_Index + 4])
        }
        if (kind = "app" && i.AppId = "") || (kind = "thumbnail" && !i.Names.Length)
            this.Cancel("incomplete-identity", i)
        else {
            this.Log("confirmed " . kind . "; appId=" . i.AppId)
            this.ReportActivity("已识别任务栏应用，等待对应窗口激活。若身份无法确认，会跳过而不误搬。")
        }
        return 1
    }
    LeftDown(*) {
        this.Serial += 1, this.Pending := 0
        if this.DisableMoves || !this.Enabled || Desktop.Tick() < this.CoolUntil
            return
        ; Shift/Ctrl/Win clicks can mean new instance, elevation, or group cycling, not plain activation.
        for modifier in ["Shift", "Ctrl", "Alt", "LWin", "RWin"] {
            if GetKeyState(modifier, "P")
                return
        }
        Desktop.Physical()
        if !Desktop.Cursor(&x, &y)
            return
        cls := Desktop.Class(Desktop.RootAt(x, y))
        if !Desktop.IsTaskbar(cls) && !Desktop.IsThumbnail(cls)
            return
        monitor := Desktop.MonitorAt(x, y), before := Desktop.Foreground()
        if !IsObject(monitor)
            return
        i := FollowIntent(this.Serial, this.Generation, Desktop.Tick(), x, y, monitor,
            before, Desktop.Pid(before), Desktop.IsMin(before), Desktop.MonitorOf(before))
        this.Pending := i
        this.Log("click serial=" . i.Serial . "; physical=" . x . "," . y . "; target=" . monitor.Device . "; before-pid=" . i.BeforePid)
        this.ReportActivity(this.MappingsReady && this.HelperReady ? "检测到任务栏点击，正在确认是否为应用按钮…"
            : "已记住这次任务栏点击，识别器就绪后会在等待时限内继续处理。")
        this.ProbePending()
    }
    ProbePending() {
        i := this.Pending
        if !IsObject(i) || !this.IsCurrent(i) || !this.MappingsReady || !this.HelperReady || i.ProbeSent || i.Probed
            return
        i.ProbeSent := true, i.ProbeAt := Desktop.Tick()
        if !DllCall("user32\PostMessageW", "ptr", this.HelperHwnd, "uint", 0x8050,
            "uptr", i.Serial, "int64", Desktop.Point(i.X, i.Y))
            this.Cancel("probe-post-failed", i)
    }
    LeftUp(*) {
        i := this.Pending
        if !IsObject(i)
            return
        if !Desktop.Cursor(&x, &y) {
            this.Cancel("cursor-unavailable", i)
            return
        }
        this.Log("release serial=" . i.Serial . "; delta=" . (x - i.X) . "," . (y - i.Y) . "; held-ms=" . (Desktop.Tick() - i.Created))
        dragX := Max(4, DllCall("user32\GetSystemMetrics", "int", 68))
        dragY := Max(4, DllCall("user32\GetSystemMetrics", "int", 69))
        if !i.Release(x, y, Desktop.Tick(), dragX, dragY, this.Timeout)
            this.Cancel("drag-or-hold", i)
    }
    OtherInput(*) => this.Cancel("other-input")
    OnForeground(*) {
        if !this.Pumping
            this.Pump()
    }
    SettingsChanged(action, *) {
        if action = 0x2F ; SPI_SETWORKAREA
            this.TopologyChanged()
    }
    PowerChanged(action, *) {
        if action = 4 || action = 7 || action = 18
            this.TopologyChanged()
    }
    TopologyChanged(*) {
        this.Generation += 1, this.CoolUntil := Desktop.Tick() + 1800
        this.Cancel("display/power/taskbar-change")
        this.Identity.Cache.Clear()
        if IsObject(this.Native)
            this.Native.Cancel(1800)
    }
    Cancel(reason := "", expected := 0) {
        if IsObject(this.Native)
            this.Native.Cancel()
        if IsObject(expected) && (!IsObject(this.Pending) || this.Pending != expected)
            return ; a delayed old transaction must never cancel a newer click
        hadPending := IsObject(this.Pending)
        confirmed := hadPending && this.Pending.MoveConfirmed
        this.Serial += 1, this.Pending := 0 ; mutate before file I/O can yield to another input handler
        if hadPending
            this.Log("transaction end: " . reason)
        static descriptions := Map(
            "not-an-app-button", "这次不是任务栏应用按钮（如开始、搜索或托盘），已忽略。",
            "incomplete-identity", "未取得完整应用身份，本次跳过。可点击“兼容性诊断”。",
            "unrelated-foreground", "激活窗口的应用身份不匹配，本次跳过，避免移动无关窗口。",
            "already-on-clicked-monitor", "目标窗口已经在点击的屏幕上，无需迁移。",
            "expired", "等待激活已超时，本次未完成迁移。可查看日志或生成兼容性诊断。",
            "probe-timeout", "任务栏识别超时，正在重连识别器；本次不会猜测移动。",
            "startup-not-ready", "初始化或识别器重连超过等待时限，本次点击未完成跟随。请等待就绪后再试。",
            "UIA error", "读取任务栏失败，本次跳过。可生成兼容性诊断。",
            "other-input", "你开始了其他操作，已取消尚未完成的跟随。",
            "drag-or-hold", "这次点击移动过远或按住过久，已取消跟随。",
            "taskbar-drag", "检测到拖动任务栏图标，不执行窗口迁移。",
            "display/power/taskbar-change", "显示器或任务栏发生变化，已取消待处理动作，让 Windows 先恢复布局。",
            "target-disconnected", "点击时的显示器配置已改变，本次取消。",
            "monitor-changed", "显示器配置已改变，本次取消。",
            "already-there", "目标窗口已经在点击的屏幕上，无需迁移。",
            "minimized", "窗口尚未恢复，本次跳过。请从任务栏恢复窗口后再试。",
            "window-no-longer-eligible", "窗口状态已改变，不再适合迁移，本次停止跟随。",
            "placement-failed", "无法读取窗口位置，本次跳过。可生成兼容性诊断。",
            "rect-failed", "无法读取窗口大小，本次跳过。可生成兼容性诊断。",
            "set-placement-failed", "Windows 未接受窗口迁移请求。请检查目标应用是否以管理员权限运行，或生成兼容性诊断。",
            "restore-placement-failed", "Windows 未接受窗口还原请求。请检查目标应用是否以管理员权限运行，或生成兼容性诊断。",
            "helper-exited", "任务栏识别器已断开，正在重新连接。")
        if hadPending && !(confirmed && (reason = "other-input" || reason = "settled-or-focus-changed")) {
            reasonKey := StrSplit(reason, ":")[1]
            if descriptions.Has(reasonKey)
                this.ReportActivity(descriptions[reasonKey])
            else if reason = "settled-or-focus-changed"
                this.ReportActivity("本次跟随已结束，尚未确认窗口到达目标屏幕。窗口可能未接受迁移，或已切换焦点。")
            else if reason != "toggle"
                this.ReportActivity("本次未完成迁移。可查看日志或生成兼容性诊断，了解本次处理原因。")
        }
    }
    Matches(i, hwnd, data) {
        if i.Kind = "app"
            return this.Identity.Match(i.AppId, data)
        ; A thumbnail must expose an exact, unique window title AND actually activate that HWND.
        ; No localized string guessing; if the provider does not expose a title, fail closed.
        title := StrReplace(StrReplace(Desktop.Title(hwnd), "`n", " "), "`r", " ")
        if title = ""
            return false
        found := false
        for name in i.Names {
            if name == title {
                found := true
                break
            }
        }
        if !found
            return false
        count := 0
        for candidate in WinGetList() {
            if Desktop.Eligible(candidate) && Desktop.Title(candidate) == Desktop.Title(hwnd)
                count += 1
        }
        return count = 1
    }
    Pump(*) {
        if this.Pumping || !IsObject(this.Pending)
            return
        transaction := this.Pending, this.Pumping := true
        try this.PumpCore(transaction)
        catch as e {
            this.Log("transaction error: " . e.Message)
            this.Cancel("error", transaction)
        } finally {
            this.Pumping := false
        }
    }
    PumpCore(i) {
        if !this.IsCurrent(i)
            return
        now := Desktop.Tick()
        ; Keep an early taskbar click while initialization/reconnection finishes.
        ; No UIA watchdog starts before its request was actually submitted.
        if !this.MappingsReady || !this.HelperReady {
            if now >= i.Expires
                this.Cancel("startup-not-ready", i)
            return
        }
        this.ProbePending()
        if !i.Released {
            if !Desktop.Cursor(&heldX, &heldY) {
                this.Cancel("cursor-unavailable", i)
                return
            }
            if Abs(heldX - i.X) > Max(4, DllCall("user32\GetSystemMetrics", "int", 68))
                || Abs(heldY - i.Y) > Max(4, DllCall("user32\GetSystemMetrics", "int", 69)) {
                this.Cancel("taskbar-drag", i)
                return
            }
        }
        gate := FollowPolicy.Gate(i, now, this.Serial, this.Generation, this.Enabled)
        if !this.IsCurrent(i)
            return
        if gate = "wait" || gate = "empty"
            return
        if gate != "ready" {
            if gate = "probe-timeout" {
                this.StopHelper(), this.HelperRestartAt := now + 500
                this.UpdateTray()
            }
            this.Cancel(gate, i)
            return
        }
        target := Desktop.Monitor(i.Monitor.Handle)
        if !Desktop.Unchanged(target, i.Monitor) {
            this.Cancel("target-disconnected", i)
            return
        }
        foreground := Desktop.Foreground()
        ; Opening a grouped icon's thumbnail picker is not selecting a particular app window.
        if !i.MovedHwnd && i.Kind = "app" {
            for preview in Desktop.Thumbnails() {
                if !Desktop.SameMonitor(Desktop.MonitorOf(preview), target)
                    continue
                if !i.WaitingForThumbnail {
                    i.WaitingForThumbnail := true
                    this.Log("waiting for thumbnail selection; serial=" . i.Serial)
                    this.ReportActivity("任务栏已展开窗口预览。请选择其中一个窗口后，随屏再跟随该窗口。")
                }
                i.StableHwnd := 0
                return
            }
        }
        if i.MovedHwnd {
            if now - i.MovedAt > 1400 || foreground != i.MovedHwnd || Desktop.Pid(foreground) != i.MovedPid {
                this.Cancel("settled-or-focus-changed", i)
                return
            }
            if !Desktop.Eligible(foreground) {
                this.Cancel("window-no-longer-eligible", i)
                return
            }
            if !i.MoveConfirmed && Desktop.SameMonitor(Desktop.MonitorOf(foreground), target) {
                i.MoveConfirmed := true, this.SuccessfulMoves += 1
                this.ReportActivity("已确认：窗口现在位于本次点击的显示器。")
            }
            if FollowPolicy.MaySettle(i, now, foreground, Desktop.Pid(foreground))
                && !Desktop.IsMin(foreground) && !Desktop.SameMonitor(Desktop.MonitorOf(foreground), target) {
                this.DoMove(i, foreground, false)
            }
            return
        }
        ; The native taskbar minimizes the already-active app. Across monitors only, optionally
        ; reinterpret this explicit, identity-verified click as 'bring it here'. Same-monitor clicks stay native.
        if this.BringActive && !i.BeforeMin && i.Before && now - i.ReleaseAt >= this.Delay
            && Desktop.Pid(i.Before) = i.BeforePid && Desktop.IsMin(i.Before)
            && !Desktop.SameMonitor(i.BeforeMonitor, target) && Desktop.Eligible(i.Before) {
            data := this.Identity.Get(i.Before)
            if this.Matches(i, i.Before, data) && this.IsCurrent(i) {
                this.DoMove(i, i.Before, true)
                return
            }
        }
        if Desktop.IsShell(foreground)
            return
        data := this.Identity.Get(foreground)
        matches := this.Matches(i, foreground, data)
        if !this.IsCurrent(i)
            return
        if !matches {
            i.StableHwnd := 0
            ; A different app taking focus is not evidence of the requested launch succeeding.
            if foreground != i.Before
                this.Cancel("unrelated-foreground", i)
            return
        }
        if Desktop.SameMonitor(Desktop.MonitorOf(foreground), target) {
            this.Cancel("already-on-clicked-monitor", i)
            return
        }
        if FollowPolicy.Candidate(i, foreground, data.Pid, matches, Desktop.Eligible(foreground),
            Desktop.IsMin(foreground), now, this.Delay) && this.IsCurrent(i)
            this.DoMove(i, foreground, false)
    }
    IsCurrent(i) => IsObject(this.Pending) && this.Pending = i && i.Serial = this.Serial && i.Generation = this.Generation && this.Enabled
    DoMove(i, hwnd, restoreMin) {
        if this.NativeMode
            return
        if !this.IsCurrent(i) || !Desktop.Eligible(hwnd) || (!restoreMin && Desktop.Foreground() != hwnd)
            return
        result := WindowMover.Move(hwnd, i.Monitor, restoreMin)
        this.Log("move " . Desktop.Pid(hwnd) . " -> " . i.Monitor.Device . "; " . result . "; hwnd=" . hwnd
            . "; since-release-ms=" . (Desktop.Tick() - i.ReleaseAt))
        if result != "requested" {
            this.Cancel(result, i)
            return
        }
        if !i.MovedHwnd {
            i.MovedHwnd := hwnd, i.MovedPid := Desktop.Pid(hwnd), i.MovedAt := Desktop.Tick()
            i.Expires := i.MovedAt + 1450
        }
        i.LastAttempt := Desktop.Tick(), i.Attempts += 1
        this.ReportActivity("已提交窗口迁移请求，正在确认最终位置…")
    }
    Watchdog() {
        now := Desktop.Tick()
        if this.NativeMode && IsObject(this.Native) && this.HelperReady && this.Native.CacheCount && this.Native.CacheAge > 5000 {
            this.StopHelper(), this.Cancel("helper-exited"), this.HelperRestartAt := now + 500
            this.Log("native taskbar cache stale; reconnecting UIA helper")
            this.UpdateTray()
        }
        if this.HelperHandle && DllCall("kernel32\WaitForSingleObject", "ptr", this.HelperHandle, "uint", 0, "uint") != 0x102 {
            this.StopHelper(), this.Cancel("helper-exited"), this.HelperRestartAt := now + 1000
            this.UpdateTray()
        }
        if !this.HelperReady && this.HelperHandle && now - this.HelperStarted > 3500 {
            this.StopHelper(), this.HelperRestartAt := now + 2000
            this.Log("UIA helper startup timeout; no guessing fallback")
            this.UpdateTray()
        }
        if !this.HelperHandle && now >= this.HelperRestartAt {
            try this.StartHelper()
            catch as e {
                this.Log("helper start failed: " . e.Message), this.HelperRestartAt := now + 5000
            }
        }
    }
    Log(text) {
        try {
            if FileExist(this.LogPath) && FileGetSize(this.LogPath) > 1048576
                FileMove(this.LogPath, this.LogPath . ".1", 1)
            FileAppend(FormatTime(, "yyyy-MM-dd HH:mm:ss") . " " . text . "`n", this.LogPath, "UTF-8")
        }
    }
    FinishStatusTest() {
        try {
            if !IsObject(this.Panel) || !this.Panel.Visible || !this.HelperReady || !this.MappingsReady
                throw Error("Status UI or helper is not ready")
            this.Enabled := true
            this.UpdateTray()
            if !InStr(this.Panel.StateText.Text, "运行中")
                throw Error("Running state is not visible")
            configBefore := FileRead(this.Config, "RAW")
            this.Toggle()
            if !InStr(this.Panel.StateText.Text, "已暂停") || this.Panel.ToggleButton.Text != "启用跟随"
                throw Error("Pause state is not reflected")
            configAfter := FileRead(this.Config, "RAW")
            if configBefore.Size != configAfter.Size || DllCall("msvcrt\memcmp", "ptr", configBefore, "ptr", configAfter, "uptr", configBefore.Size, "int") != 0
                throw Error("Automated UI test modified real settings")
            this.Toggle()
            this.HideStatus()
            if this.Panel.Visible || !this.HelperReady
                throw Error("Hiding must keep the engine running")
            this.ShowStatus()
            if !this.Panel.Visible
                throw Error("Status window could not be restored")
            this.Panel.Window.Minimize()
            this.ShowStatus()
            if !this.Panel.Visible || Desktop.IsMin(this.Panel.Window.Hwnd)
                throw Error("Minimized status window could not be restored")
            this.Serial += 1
            this.Pending := FollowIntent(this.Serial, this.Generation, Desktop.Tick(), 0, 0, Desktop.MonitorAt(0, 0), 0, 0, false, 0)
            this.Cancel("set-placement-failed:5")
            if !InStr(this.LastActivity, "Windows 未接受窗口迁移请求")
                throw Error("Move failure was not reported")
            this.HelperReady := false
            this.UpdateTray()
            if !InStr(this.Panel.StateText.Text, "正在重连")
                throw Error("Disconnected helper was falsely labelled running")
            this.HelperReady := true
            this.UpdateTray()
            FileAppend("status window running/pause/resume/hide/reveal/minimized-reveal/failure-feedback/reconnect/settings-isolation PASS`n", "*", "UTF-8")
            ExitApp(0)
        } catch as exception {
            FileAppend("status UI FAIL: " . exception.Message . " (line " . exception.Line . ")`n", "*", "UTF-8")
            ExitApp(1)
        }
    }
    FinishStartupTest() {
        passed := this.Hook && this.Keyboard.InProgress && this.HelperReady
        FileAppend(passed ? "tray/hooks/keyboard/helper startup PASS`n" : "startup FAIL`n", "*", "UTF-8")
        ExitApp(passed ? 0 : 1)
    }
    FinishLifecycleTest() {
        passed := this.HelperReady && this.ReplyCount >= 1
        this.StopHelper()
        FileAppend(passed ? "helper startup/query/IPC/cleanup PASS`n" : "helper lifecycle FAIL`n", "*", "UTF-8")
        ExitApp(passed ? 0 : 1)
    }
    Exit(*) {
        this.Pending := 0
        if IsObject(this.Panel)
            this.Panel.SetRefreshActive(false)
        if IsObject(this.Native) {
            try {
                if !this.Native.Stop()
                    try this.Log("native shutdown not confirmed; remaining controller cleanup continues")
            } catch as shutdownError {
                try this.Log("native shutdown exception; remaining controller cleanup continues: " . shutdownError.Message)
            }
        }
        if this.Hook
            DllCall("user32\UnhookWinEvent", "ptr", this.Hook)
        if this.Callback
            CallbackFree(this.Callback)
        this.StopHelper()
    }
}

