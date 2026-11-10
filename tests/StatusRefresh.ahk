#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\TaskbarFollow.ahk

class RefreshChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Exercise(panel,label) {
        renders := panel.RenderCount, writes := panel.ControlWrites
        DllCall("kernel32\QueryPerformanceFrequency","int64*",&frequency := 0)
        DllCall("kernel32\QueryPerformanceCounter","int64*",&started := 0)
        Loop 1000
            panel.Update()
        DllCall("kernel32\QueryPerformanceCounter","int64*",&finished := 0)
        renderDelta := panel.RenderCount-renders, writeDelta := panel.ControlWrites-writes
        FileAppend("PERF " . label . ": requests=1000; render-passes=" . renderDelta
            . "; control-writes=" . writeDelta . "; elapsed-ms=" . Round((finished-started)*1000/frequency,3) . "`n","*","UTF-8")
        return {Renders:renderDelta,Writes:writeDelta}
    }
}
class StatusPanelSpy {
    Calls := 0
    Update(*) => this.Calls += 1
}
class StatusNativeSpy {
    Ready := true, NextReady := true, CacheCount := 26, NextMoves := 0, Calls := 0, EmitEvent := false
    __New(owner) => this.Owner := owner
    Poll() {
        this.Calls += 1
        this.Ready := this.NextReady
        this.Owner.SuccessfulMoves := this.NextMoves
        if this.EmitEvent {
            this.EmitEvent := false
            this.Owner.ReportActivity("native-event-still-reported")
        }
    }
}

panel := 0
try {
    app := TaskbarFollow(true)
    app.Enabled := true, app.Started := true, app.HelperReady := true, app.MappingsReady := true
    ; Freeze the displayed runtime during the unchanged-content checks.
    app.StartTick := Desktop.Tick()+60000
    app.ShowStatus()
    panel := app.Panel
    RefreshChecks.Assert(panel.Visible && !Desktop.IsMin(panel.Window.Hwnd),"Owned fixture is visible without activating user applications")
    app.HideStatus()
    previous := panel.Summary.Text
    app.SuccessfulMoves := 12
    app.UpdateStatus()
    RefreshChecks.Assert(panel.Summary.Text == previous,"Hidden status window defers control writes")
    RefreshChecks.Assert(!panel.RefreshTimerRunning,"Hidden status window stops its clock timer")
    result := RefreshChecks.Exercise(panel,"hidden")
    RefreshChecks.Assert(result.Renders = 0 && result.Writes = 0,"Hidden refresh requests perform no rendering or control writes")
    renders := panel.RenderCount
    Sleep(1150)
    RefreshChecks.Assert(panel.RenderCount = renders,"Hidden window performs no periodic rendering")

    app.ShowStatus()
    RefreshChecks.Assert(InStr(panel.Summary.Text,"12 次"),"Reveal immediately presents the latest move count")
    RefreshChecks.Assert(panel.RefreshTimerRunning,"Visible window enables one clock timer")
    result := RefreshChecks.Exercise(panel,"visible-unchanged")
    RefreshChecks.Assert(result.Writes = 0,"Unchanged visible content does not rewrite controls or fonts")
    writes := panel.ControlWrites
    app.SuccessfulMoves := 13
    app.UpdateStatus()
    RefreshChecks.Assert(panel.ControlWrites = writes+1 && InStr(panel.Summary.Text,"13 次"),"Only the changed move count control is written")
    app.UpdateStatus()
    RefreshChecks.Assert(panel.ControlWrites = writes+1,"Repeated status notification is a no-op for controls")

    panel.SetRefreshActive(false)
    app.StartTick := Desktop.Tick()-10000
    panel.Update()
    previous := panel.Footer.Text
    panel.SetRefreshActive(true)
    Sleep(1200)
    RefreshChecks.Assert(panel.Footer.Text != previous,"Visible runtime continues ticking once per second")
    panel.Window.Minimize()
    Sleep(40)
    RefreshChecks.Assert(Desktop.IsMin(panel.Window.Hwnd),"Owned status fixture minimizes")
    RefreshChecks.Assert(!panel.RefreshTimerRunning,"Minimize stops the clock timer")
    previous := panel.StateText.Text
    app.Enabled := false
    app.UpdateStatus()
    RefreshChecks.Assert(panel.StateText.Text == previous,"Minimized window defers state changes")
    result := RefreshChecks.Exercise(panel,"minimized")
    RefreshChecks.Assert(result.Renders = 0 && result.Writes = 0,"Minimized requests perform no rendering or control writes")
    renders := panel.RenderCount
    Sleep(1150)
    RefreshChecks.Assert(panel.RenderCount = renders,"Minimized window performs no periodic rendering")
    ; Restore through Windows/Gui, not the application's ShowStatus wrapper.
    panel.Window.Show("NA Restore")
    Sleep(40)
    RefreshChecks.Assert(panel.RefreshTimerRunning,"System restore resumes the visible clock timer")
    RefreshChecks.Assert(InStr(panel.StateText.Text,"已暂停") && panel.ToggleButton.Text == "启用跟随","System restore immediately applies deferred state and action")
    app.Enabled := true
    app.UpdateStatus()
    RefreshChecks.Assert(InStr(panel.StateText.Text,"运行中"),"Visible state changes still update immediately")
    app.SuccessfulMoves += 1
    app.UpdateStatus()
    RefreshChecks.Assert(InStr(panel.Summary.Text,app.SuccessfulMoves . " 次"),"Visible move count updates immediately")
    app.HelperReady := false
    app.UpdateStatus()
    RefreshChecks.Assert(InStr(panel.StateText.Text,"正在重连"),"Helper failure remains visible immediately")
    app.HelperReady := true
    app.UpdateStatus()
    RefreshChecks.Assert(InStr(panel.StateText.Text,"运行中"),"Helper reconnect remains visible immediately")

    panel.Hide()
    spy := StatusPanelSpy(), native := StatusNativeSpy(app)
    app.Panel := spy, app.Native := native, app.SuccessfulMoves := 0
    Loop 100
        app.PollNative()
    RefreshChecks.Assert(native.Calls = 100,"Native health/status polling is not reduced")
    RefreshChecks.Assert(spy.Calls = 0,"Unchanged native polls do not trigger UI refresh")
    native.NextReady := false
    app.PollNative()
    RefreshChecks.Assert(spy.Calls = 1,"Loss of native readiness still triggers immediate UI refresh")
    native.NextReady := true
    app.PollNative()
    RefreshChecks.Assert(spy.Calls = 2,"Native readiness recovery still triggers immediate UI refresh")
    native.NextMoves := 5
    app.PollNative()
    RefreshChecks.Assert(spy.Calls = 3,"Native move counter changes still trigger immediate UI refresh")
    native.EmitEvent := true
    app.PollNative()
    RefreshChecks.Assert(spy.Calls = 4 && app.LastActivity == "native-event-still-reported","Native activity events remain immediately visible")
    panel.SetRefreshActive(false)
    panel.Window.Destroy()
    panel := 0
    FileAppend("PASS " . RefreshChecks.Count . " status refresh/timer/deferred-state/native-poll assertions`n","*","UTF-8")
    ExitApp(0)
} catch as e {
    if IsObject(panel) {
        try panel.SetRefreshActive(false)
        try panel.Window.Destroy()
    }
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    ExitApp(1)
}
