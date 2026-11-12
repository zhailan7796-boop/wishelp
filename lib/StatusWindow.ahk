; A native, visible status window. It reports actual helper state, never a fake 'running' label.
class FollowStatusWindow {
    __New(owner) {
        this.Owner := owner, this.Measured := false, this.StateColor := "B45309"
        this.Displayed := Map(), this.RenderCount := 0, this.ControlWrites := 0
        this.RefreshTimer := ObjBindMethod(this,"Update"), this.RefreshTimerRunning := false
        this.Window := Gui("-MaximizeBox", "随屏 · 运行状态")
        ; A stable window identity lets the native cache distinguish this GUI
        ; from other scripts using the same portable AutoHotkey executable.
        try FollowStatusWindow.SetAppId(this.Window.Hwnd)
        catch as identityError
            try this.Owner.Log("status window identity unavailable: " . identityError.Message)
        this.Window.BackColor := "F7F9FC"
        this.Window.MarginX := 24, this.Window.MarginY := 20
        this.Window.SetFont("s10 c263445", "Microsoft YaHei UI")
        this.Window.AddText("xm ym w448 h34 c18243A", "随屏  ·  多屏窗口跟随").SetFont("s18 w600")
        this.Window.AddText("xm y+3 w448 h22 c475569", "从哪块屏幕的任务栏唤起应用，就尝试在那块屏幕显示。")
        this.Window.AddText("xm y+15 w448 h1 BackgroundDCE3EC")
        this.StateText := this.Window.AddText("xm y+14 w448 h30", "正在启动…")
        this.StateText.SetFont("s16 w600 cB45309")
        this.Monitors := this.Window.AddText("xm y+7 w216 h24 c334155", "")
        this.Summary := this.Window.AddText("x+16 yp w216 h24 c334155", "")
        this.Window.AddText("xm y+12 w448 h1 BackgroundDCE3EC")
        this.ToggleButton := this.Window.AddButton("xm y+14 w136 h36", "暂停跟随")
        this.ToggleButton.OnEvent("Click", ObjBindMethod(owner, "Toggle"))
        this.Window.AddButton("x+12 yp w152 h36", "收起到托盘").OnEvent("Click", ObjBindMethod(owner, "HideStatus"))
        this.Window.AddButton("x+12 yp w136 h36", "退出程序").OnEvent("Click", (*) => ExitApp())
        this.Window.AddButton("xm y+8 w218 h32", "查看日志").OnEvent("Click", ObjBindMethod(owner, "OpenLog"))
        this.Window.AddButton("x+12 yp w218 h32", "兼容性诊断").OnEvent("Click", ObjBindMethod(owner, "RunDiagnostics"))
        this.Footer := this.Window.AddText("xm y+13 w448 h20 c64748B", "")
        this.Footer.SetFont("s9")
        this.Window.OnEvent("Close", ObjBindMethod(owner, "HideStatus"))
        this.Window.OnEvent("Escape", ObjBindMethod(owner, "HideStatus"))
        this.Window.OnEvent("Size", ObjBindMethod(this,"OnSize"))
    }
    SetRefreshActive(enabled) {
        enabled := enabled && this.Refreshable
        if enabled = this.RefreshTimerRunning
            return
        SetTimer(this.RefreshTimer,enabled ? 1000 : 0)
        this.RefreshTimerRunning := enabled
    }
    OnSize(*) {
        ; Read the current state instead of trusting a queued minimize/restore
        ; notification which may already have been superseded by ShowStatus.
        active := this.Refreshable
        this.SetRefreshActive(active)
        if active
            this.Update()
    }
    SetText(name,text) {
        if this.Displayed.Has(name) && this.Displayed[name] == text
            return
        this.%name%.Text := text
        this.Displayed[name] := text
        this.ControlWrites += 1
    }
    Update(force := false) {
        ; Check before querying monitors, formatting text or touching controls.
        ; The native engine and helper watchdog continue independently.
        if !force && !this.Refreshable {
            this.SetRefreshActive(false)
            return false
        }
        this.RenderCount += 1
        app := this.Owner
        color := "B45309"
        if !app.Enabled
            state := "已暂停"
        else if !app.Started || !app.MappingsReady
            state := "正在启动…"
        else if !app.HelperReady
            state := "正在重连任务栏…"
        else if app.NativeMode && (!IsObject(app.Native) || !app.Native.Ready)
            state := "正在准备原生定位…"
        else
            state := "运行中", color := "15803D"
        this.SetText("StateText","●  " . state)
        if color != this.StateColor {
            this.StateText.SetFont("s16 w600 c" . color)
            this.StateColor := color
            this.ControlWrites += 1
        }
        this.SetText("Monitors","已连接显示器  " . MonitorGetCount() . " 个")
        this.SetText("Summary",(app.NativeMode ? "随屏定位  " : "确认迁移  ") . app.SuccessfulMoves . " 次")
        this.SetText("ToggleButton",app.Enabled ? "暂停跟随" : "启用跟随")
        elapsed := Max(0, Floor((Desktop.Tick() - app.StartTick) / 1000))
        runtime := Format("{:02}:{:02}:{:02}", elapsed // 3600, Mod(elapsed // 60, 60), Mod(elapsed, 60))
        this.SetText("Footer","已运行 " . runtime . "    ·    v0.3.4    ·    Ctrl+Alt+F12 暂停/启用")
        return true
    }
    static AppDirectory {
        get {
            SplitPath(A_LineFile, , &library)
            SplitPath(library, , &root)
            return root
        }
    }
    static IconPath => this.AppDirectory . "\launcher\TaskbarFollow.ico"

    static SetAppId(hwnd) {
        iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
        storePtr := 0
        if DllCall("shell32\SHGetPropertyStoreForWindow","ptr",hwnd,"ptr",iid,"ptr*",&storePtr,"int") < 0 || !storePtr
            throw Error("Cannot obtain the status window property store")
        store := ComValue(13,storePtr,1), key := Buffer(20,0)
        guid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
        DllCall("ntdll\RtlMoveMemory","ptr",key,"ptr",guid,"uptr",16)
        launcher := this.AppDirectory . "\Start.exe"
        ; A source checkout can also be started via Start.cmd before compiling Start.exe.
        command := FileExist(launcher) ? '"' . launcher . '"' : '"' . A_AhkPath . '" "' . this.AppDirectory . '\TaskbarFollow.ahk"'
        ; Explorer reads the relaunch metadata when it is notified of the AppID.
        this.SetAppString(store,key,2,command)                 ; RelaunchCommand
        this.SetAppString(store,key,3,this.IconPath . ",0")   ; RelaunchIconResource
        this.SetAppString(store,key,4,"随屏")                  ; RelaunchDisplayNameResource
        this.SetAppString(store,key,5,"TaskbarFollow.Status") ; AppUserModelID
        ComCall(7,store)
    }
    static SetAppString(store,key,propertyId,string) {
        NumPut("uint",propertyId,key,16)
        value := Buffer(24,0)
        text := DllCall("ole32\CoTaskMemAlloc","uptr",(StrLen(string)+1)*2,"ptr")
        if !text
            throw Error("Cannot allocate the taskbar property")
        NumPut("ushort",31,value,0), NumPut("ptr",text,value,8) ; VT_LPWSTR
        try {
            StrPut(string,text,StrLen(string)+1)
            ComCall(6,store,"ptr",key,"ptr",value)
        } finally DllCall("ole32\PropVariantClear","ptr",value)
    }
    PrepareMonitor(monitor,center := false) {
        Desktop.Physical()
        source := Desktop.MonitorOf(this.Window.Hwnd)
        current := IsObject(monitor) ? Desktop.Monitor(monitor.Handle) : 0
        if !Desktop.Unchanged(current,monitor) || !IsObject(source)
            return false
        if !center && Desktop.SameMonitor(source,current)
            return false
        minimized := Desktop.IsMin(this.Window.Hwnd)
        placement := minimized ? Desktop.Placement(this.Window.Hwnd) : 0
        if minimized && !IsObject(placement)
            return false
        rect := minimized ? Geometry.FromWorkspace(ScreenRect.FromBuffer(placement,28),source) : Desktop.Rect(this.Window.Hwnd)
        if !IsObject(rect) || rect.W <= 0 || rect.H <= 0
            return false
        left := current.Work.L + Max(0,(current.Work.W-rect.W)//2)
        top := current.Work.T + Max(0,(current.Work.H-rect.H)//2)
        if minimized {
            next := ScreenRect(left,top,left+rect.W,top+rect.H)
            Geometry.ToWorkspace(next,current).Write(placement,28)
            ; Prepare the restore rectangle without showing, restoring or
            ; activating this window. Explorer performs its normal action.
            NumPut("uint",7,placement,8) ; SW_SHOWMINNOACTIVE
            return !!DllCall("user32\SetWindowPlacement","ptr",this.Window.Hwnd,"ptr",placement)
        }
        return !!DllCall("user32\SetWindowPos","ptr",this.Window.Hwnd,"ptr",0,
            "int",left,"int",top,"int",0,"int",0,"uint",0x15)
    }
    Show(activate := true) {
        ; Prepare current content before measuring/showing, even if previously
        ; hidden or minimized. Normal Update calls never bypass that gate.
        this.Update(true)
        if !this.Measured {
            this.Window.Show("Hide AutoSize")
            this.Measured := true
        }
        ; Put our own status window on the cursor's monitor, rather than an unattended monitor.
        Desktop.Physical()
        monitor := Desktop.Cursor(&x, &y) ? Desktop.MonitorAt(x, y) : Desktop.MonitorOf(this.Window.Hwnd)
        this.PrepareMonitor(monitor,true)
        if Desktop.IsMin(this.Window.Hwnd)
            ; NoActivate restores without focus; NA alone keeps it minimized.
            this.Window.Show(activate ? "Restore" : "NoActivate")
        this.Window.Show(activate ? "" : "NA")
        this.SetRefreshActive(true)
        this.Update()
        if activate
            WinActivate("ahk_id " . this.Window.Hwnd)
    }
    Hide() {
        this.SetRefreshActive(false)
        this.Window.Hide()
    }
    Refreshable => this.Visible && !Desktop.IsMin(this.Window.Hwnd)
    Visible => DllCall("user32\IsWindowVisible", "ptr", this.Window.Hwnd)
}
