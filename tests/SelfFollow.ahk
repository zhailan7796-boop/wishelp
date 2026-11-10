#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\TaskbarFollow.ahk

; Tests only this process's status GUI. No taskbar input, native hooks,
; foreground activation, cursor movement or user application changes.
class SelfChecks {
    static Count := 0, Observe := false, Hwnd := 0, FirstMonitor := 0, Activations := 0, Messages := 0, App := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual,expected,label) => this.Assert(actual == expected,label . " (actual=" . actual . ", expected=" . expected . ")")
    static SameRect(actual,expected,label) {
        for field in ["L","T","R","B"]
            this.Equal(actual.%field%,expected.%field%,label . " " . field)
    }
    static SamePlacement(actual,expected,label) {
        for offset in [4,8,12,16,20,24,28,32,36,40]
            this.Equal(NumGet(actual,offset,"int"),NumGet(expected,offset,"int"),label . " offset=" . offset)
    }
    static Inside(rect,work,label) => this.Assert(rect.L >= work.L && rect.T >= work.T && rect.R <= work.R && rect.B <= work.B,label)
    static Minimize(panel) {
        ; Use Windows' minimize transition without activating another window.
        DllCall("user32\ShowWindow","ptr",panel.Window.Hwnd,"int",7) ; SW_SHOWMINNOACTIVE
        Sleep(20)
    }
    static RouteClick(monitor,hwnd,*) {
        this.Messages += 1
        return this.App.OwnTaskbarClick(monitor,hwnd)
    }
    static WaitMessages(expected) {
        deadline := Desktop.Tick()+1000
        while this.Messages < expected && Desktop.Tick() < deadline
            Sleep(10)
        this.Equal(this.Messages,expected,"Posted bridge message was actually dispatched")
    }
    static ObserveActivation(wparam,lparam,message,hwnd) {
        if hwnd = this.Hwnd && (wparam & 0xFFFF)
            this.Activations += 1
    }
    static ObserveVisible(wparam,lparam,message,hwnd) {
        if this.Observe && hwnd = this.Hwnd && !this.FirstMonitor
            && DllCall("user32\IsWindowVisible","ptr",hwnd) && !Desktop.IsMin(hwnd)
            this.FirstMonitor := Desktop.MonitorOf(hwnd).Handle
    }
    static Monitor(number) {
        MonitorGet(number,&left,&top,&right,&bottom)
        return Desktop.MonitorAt((left+right)//2,(top+bottom)//2)
    }
}

panel := 0, other := 0, clickHandler := 0, visibleHandler := 0, activationHandler := 0, exitCode := 0
try {
    Desktop.Physical()
    if MonitorGetCount() < 2
        throw Error("Two monitors are required for the owned status-window regression")
    source := SelfChecks.Monitor(1), target := SelfChecks.Monitor(2)
    app := TaskbarFollow(true,true)
    app.Enabled := true, app.Started := true, app.NativeMode := true
    app.HelperReady := true, app.MappingsReady := true, app.Native := {Ready:true}
    panel := FollowStatusWindow(app), app.Panel := panel
    SelfChecks.Hwnd := panel.Window.Hwnd
    SelfChecks.Assert(!panel.Visible,"Status GUI starts hidden before its first show")
    SelfChecks.Equal(WindowIdentity.WindowAppId(panel.Window.Hwnd),"TaskbarFollow.Status","Owned status GUI has a stable explicit AppID before its first show")
    SplitPath(A_ScriptDir, , &appRoot)
    launcher := appRoot . "\Start.exe"
    command := FileExist(launcher) ? '"' . launcher . '"' : '"' . A_AhkPath . '" "' . appRoot . '\TaskbarFollow.ahk"'
    SelfChecks.Equal(WindowIdentity.WindowAppProperty(panel.Window.Hwnd,2),command,"Taskbar relaunch uses the application entry point and quoted paths")
    SelfChecks.Equal(WindowIdentity.WindowAppProperty(panel.Window.Hwnd,3),appRoot . "\launcher\TaskbarFollow.ico,0","Taskbar pin uses the application icon")
    SelfChecks.Assert(FileExist(appRoot . "\launcher\TaskbarFollow.ico"),"Pinned icon exists")
    SelfChecks.Equal(WindowIdentity.WindowAppProperty(panel.Window.Hwnd,4),"随屏","Taskbar pin uses the application name")
    SelfChecks.App := app
    clickHandler := ObjBindMethod(SelfChecks,"RouteClick")
    visibleHandler := ObjBindMethod(SelfChecks,"ObserveVisible")
    activationHandler := ObjBindMethod(SelfChecks,"ObserveActivation")
    OnMessage(0x8054,clickHandler)
    OnMessage(0x47,visibleHandler)
    OnMessage(0xF,visibleHandler)
    OnMessage(0x6,activationHandler)
    foreground := Desktop.Foreground()
    panel.Show(false)
    SelfChecks.Assert(panel.Visible,"Owned status GUI is available")
    SelfChecks.Equal(Desktop.Foreground(),foreground,"First nonactivating reveal keeps the foreground window")
    other := Gui("+ToolWindow +E0x08000000","SelfFollow unrelated owned fixture")
    other.Show("NA x10 y10 w180 h100")
    stale := Gui("+ToolWindow","SelfFollow stale HWND fixture"), staleHwnd := stale.Hwnd
    stale.Destroy()

    panel.PrepareMonitor(source,true)
    before := Desktop.Rect(panel.Window.Hwnd), foreground := Desktop.Foreground()
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,other.Hwnd),0,"Another HWND cannot target the status GUI")
    SelfChecks.SameRect(Desktop.Rect(panel.Window.Hwnd),before,"Unrelated HWND does not move status")
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,staleHwnd),0,"A destroyed HWND cannot target the status GUI")
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,0),0,"A missing HWND cannot target the status GUI")
    SelfChecks.Equal(app.OwnTaskbarClick(0,panel.Window.Hwnd),0,"An invalid monitor cannot move status")
    SelfChecks.SameRect(Desktop.Rect(panel.Window.Hwnd),before,"Invalid monitor leaves status in place")
    app.Enabled := false
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,panel.Window.Hwnd),0,"Paused follow rejects the own-window route")
    app.Enabled := true, app.NativeMode := false
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,panel.Window.Hwnd),0,"Compatibility mode does not accept a native bridge message")
    app.NativeMode := true, app.Started := false
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,panel.Window.Hwnd),0,"An unstarted controller rejects the bridge")
    app.Started := true
    SelfChecks.SameRect(Desktop.Rect(panel.Window.Hwnd),before,"Rejected bridge states do not move status")

    panel.Hide()
    SelfChecks.Equal(app.OwnTaskbarClick(target.Handle,panel.Window.Hwnd),0,"A stale click cannot reopen a hidden status GUI")
    DllCall("user32\PostMessageW","ptr",A_ScriptHwnd,"uint",0x8054,"uptr",target.Handle,"ptr",panel.Window.Hwnd)
    SelfChecks.WaitMessages(1)
    SelfChecks.Assert(!panel.Visible && !panel.RefreshTimerRunning,"Hidden status stays hidden with its timer stopped")
    panel.Show(false), panel.PrepareMonitor(source,true)
    before := Desktop.Rect(panel.Window.Hwnd)
    SelfChecks.Equal(app.OwnTaskbarClick(source.Handle,panel.Window.Hwnd),0,"Same-screen clicks retain the normal Windows action")
    SelfChecks.SameRect(Desktop.Rect(panel.Window.Hwnd),before,"Same-screen clicks neither recenter nor move status")
    SelfChecks.Assert(!Desktop.IsMin(panel.Window.Hwnd),"Same-screen preparation does not itself minimize or restore")
    SelfChecks.Minimize(panel)
    placement := Desktop.Placement(panel.Window.Hwnd), foreground := Desktop.Foreground()
    SelfChecks.Equal(app.OwnTaskbarClick(source.Handle,panel.Window.Hwnd),0,"A same-screen minimized click retains the normal Windows action")
    SelfChecks.Assert(Desktop.IsMin(panel.Window.Hwnd),"A same-screen minimized click does not restore the GUI")
    SelfChecks.SamePlacement(Desktop.Placement(panel.Window.Hwnd),placement,"A same-screen minimized click leaves all placement fields unchanged")
    SelfChecks.Equal(Desktop.Foreground(),foreground,"A same-screen minimized click keeps the foreground window")
    panel.Window.Show("NoActivate")
    Sleep(20)

    for pair in [{From:source,To:target},{From:target,To:source}] {
        panel.PrepareMonitor(pair.From,true)
        foreground := Desktop.Foreground()
        SelfChecks.Equal(app.OwnTaskbarClick(pair.To.Handle,panel.Window.Hwnd),1,"A verified cross-screen click prepares a visible own GUI")
        SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,pair.To.Handle,"Visible own GUI reaches the clicked monitor")
        SelfChecks.Inside(Desktop.Rect(panel.Window.Hwnd),pair.To.Work,"Visible own GUI stays within the target work area")
        SelfChecks.Equal(Desktop.Foreground(),foreground,"Preparing a visible own GUI does not steal foreground")
        SelfChecks.Assert(!IsObject(app.Pending),"Self-follow does not arm a compatibility activation transaction")

        panel.PrepareMonitor(pair.From,true)
        SelfChecks.Minimize(panel)
        SelfChecks.Assert(Desktop.IsMin(panel.Window.Hwnd),"Owned GUI reaches the minimized setup state")
        SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,pair.From.Handle,"Minimized setup retains its actual source monitor")
        foreground := Desktop.Foreground()
        SelfChecks.Equal(app.OwnTaskbarClick(pair.To.Handle,panel.Window.Hwnd),1,"A verified cross-screen click prepares the restore rectangle")
        SelfChecks.Assert(Desktop.IsMin(panel.Window.Hwnd),"Preparation leaves the GUI minimized for Explorer to restore")
        SelfChecks.Equal(Desktop.Foreground(),foreground,"Minimized preparation does not steal foreground")
        placement := Desktop.Placement(panel.Window.Hwnd)
        restoreRect := Geometry.FromWorkspace(ScreenRect.FromBuffer(placement,28),pair.To)
        SelfChecks.Inside(restoreRect,pair.To.Work,"Prepared restore rectangle is in the clicked monitor work area")
        SelfChecks.FirstMonitor := 0, SelfChecks.Observe := true
        panel.Window.Show("NoActivate")
        Sleep(30)
        SelfChecks.Observe := false
        SelfChecks.Equal(SelfChecks.FirstMonitor,pair.To.Handle,"First observed visible restore state is already on target")
        SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,pair.To.Handle,"Restored own GUI remains on target")
        SelfChecks.Equal(Desktop.Foreground(),foreground,"The prepared nonactivating restore keeps the foreground window")
        SelfChecks.Assert(panel.RefreshTimerRunning,"A restored own GUI resumes its status clock")
    }

    ; A normal programmatic restore has no bridge intent and keeps its normal
    ; placement. Merely becoming visible is not treated as a taskbar click.
    panel.PrepareMonitor(source,true), SelfChecks.Minimize(panel)
    panel.Window.Show("NoActivate")
    Sleep(20)
    SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,source.Handle,"A restore without explicit click intent does not follow the cursor")
    before := Desktop.Rect(panel.Window.Hwnd), unrelatedBefore := Desktop.Rect(other.Hwnd)
    ; Deliver the same foreground notifications produced by Alt+Tab without
    ; sending keyboard input or activating a user window.
    app.OnForeground(other.Hwnd), app.OnForeground(panel.Window.Hwnd)
    Sleep(20)
    SelfChecks.SameRect(Desktop.Rect(panel.Window.Hwnd),before,"Foreground notifications without a taskbar intent do not move status")
    SelfChecks.SameRect(Desktop.Rect(other.Hwnd),unrelatedBefore,"Foreground notifications do not move the unrelated fixture")
    DllCall("user32\PostMessageW","ptr",A_ScriptHwnd,"uint",0x8054,"uptr",target.Handle,"ptr",panel.Window.Hwnd)
    SelfChecks.WaitMessages(2)
    SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,target.Handle,"The real posted-message bridge reaches the owned GUI")

    SelfChecks.Minimize(panel)
    panel.Show(false)
    SelfChecks.Assert(panel.Visible && !Desktop.IsMin(panel.Window.Hwnd),"Explicit manual reveal still restores the GUI without activation")
    if Desktop.Cursor(&cursorX,&cursorY)
        SelfChecks.Equal(Desktop.MonitorOf(panel.Window.Hwnd).Handle,Desktop.MonitorAt(cursorX,cursorY).Handle,"Manual reveal retains the cursor-monitor rule")
    SelfChecks.Assert(panel.RefreshTimerRunning,"Manual reveal leaves one visible status clock active")
    SelfChecks.Equal(SelfChecks.Activations,0,"No tested preparation, reveal or restore activated the owned status GUI")
    SelfChecks.Equal(app.SuccessfulMoves,0,"Self-follow leaves the native application move counter unchanged")
    SelfChecks.Equal(WindowIdentity.WindowAppId(panel.Window.Hwnd),"TaskbarFollow.Status","Explicit status AppID survives minimize, restore and reveal")
    panel.Hide()
    SelfChecks.Assert(!panel.Visible && !panel.RefreshTimerRunning,"Final hide stops the GUI clock")
    FileAppend("PASS " . SelfChecks.Count . " owned status identity/taskbar-intent/restore/geometry/quiet-reveal assertions`n","*","UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally {
    SelfChecks.Observe := false
    if clickHandler
        OnMessage(0x8054,clickHandler,0)
    if visibleHandler {
        OnMessage(0x47,visibleHandler,0)
        OnMessage(0xF,visibleHandler,0)
    }
    if activationHandler
        OnMessage(0x6,activationHandler,0)
    if IsObject(panel) {
        try panel.SetRefreshActive(false)
        try panel.Window.Destroy()
    }
    if IsObject(other)
        try other.Destroy()
}
ExitApp(exitCode)
