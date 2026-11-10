#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk

Desktop.Physical()
DetectHiddenWindows(true)
Log(line) => FileAppend(line . "`n", "*", "UTF-8")
class Acceptance {
    static Uia := 0, Pointer := false, X := 0, Y := 0, Focus := 0
    static CheckPointer() {
        if this.Pointer && (!Desktop.Cursor(&x,&y) || Abs(x-this.X)>8 || Abs(y-this.Y)>8)
            throw Error("Other pointer input detected; stopped test")
    }
    static Click(x,y) {
        this.CheckPointer()
        if !DllCall("user32\SetPhysicalCursorPos","int",x,"int",y)
            throw Error("Cannot position test pointer")
        this.X := x, this.Y := y, this.Pointer := true
        SendLevel(1)
        SendEvent("{LButton down}")
        Sleep(60)
        SendEvent("{LButton up}")
    }
    static Button(bar,id) {
        for item in this.Uia.Buttons(bar) {
            if item.Id == id
                return item
        }
        throw Error("Taskbar button unavailable: " . id)
    }
    static Select(bar,id,hwnd) {
        this.CheckPointer()
        b := this.Button(bar,id), x := (b.Rect.L+b.Rect.R)//2, y := (b.Rect.T+b.Rect.B)//2
        hit := this.Uia.Hit(x,y)
        if hit.Kind != "app" || !(hit.Id == id)
            throw Error("Taskbar button is covered or changed")
        this.Click(x,y)
        title := Desktop.Title(hwnd), deadline := Desktop.Tick()+3500
        while Desktop.Tick()<deadline {
            this.CheckPointer()
            if !Desktop.IsMin(hwnd) && Desktop.Foreground()=hwnd
                return
            for popup in Desktop.Thumbnails() {
                for item in this.Uia.Buttons(popup,false) {
                    if item.Name == title && item.Rect.W>25 && item.Rect.H>20 {
                        tx := (item.Rect.L+item.Rect.R)//2, ty := (item.Rect.T+item.Rect.B)//2
                        th := this.Uia.Hit(tx,ty)
                        if th.Kind="thumbnail" {
                            this.Click(tx,ty)
                            return
                        }
                    }
                }
                r := Desktop.Rect(popup)
                if !IsObject(r)
                    continue
                Loop 20 {
                    tx := r.L+Round(r.W*(A_Index-0.5)/20), ty := r.T+r.H//2
                    th := this.Uia.Hit(tx,ty)
                    for name in th.Names {
                        if th.Kind="thumbnail" && name == title {
                            this.Click(tx,ty)
                            return
                        }
                    }
                }
            }
            Sleep(80)
        }
    }
    static Restore(hwnd,id,source,bar,label) {
        this.CheckPointer()
        Log("setup " . label . "; hwnd=" . hwnd . "; move=" . WindowMover.Move(hwnd,source,true))
        Sleep(400)
        DllCall("user32\ShowWindow","ptr",hwnd,"int",7)
        WinActivate("ahk_id " . this.Focus.Hwnd)
        Sleep(1600)
        if !Desktop.IsMin(hwnd) {
            DllCall("user32\ShowWindow","ptr",hwnd,"int",7)
            Sleep(300)
        }
        if !Desktop.IsMin(hwnd)
            throw Error(label . " did not minimize")
        target := Desktop.MonitorOf(bar), start := Desktop.Tick(), stable := 0
        this.Select(bar,id,hwnd)
        while Desktop.Tick()-start<7000 {
            this.CheckPointer()
            if !Desktop.IsMin(hwnd) && Desktop.SameMonitor(Desktop.MonitorOf(hwnd),target) {
                if !stable
                    stable := Desktop.Tick()
                if Desktop.Tick()-stable>=1200 {
                    Log("PASS " . label . "; target=" . target.Device . "; stable-ms=" . (Desktop.Tick()-stable))
                    return
                }
            } else stable := 0
            Sleep(80)
        }
        throw Error(label . " did not restore on target; min=" . Desktop.IsMin(hwnd) . "; final=" . Desktop.MonitorOf(hwnd).Device)
    }
}
root := A_ScriptDir . "\..", originalForeground := Desktop.Foreground()
testCase := A_Args.Length ? A_Args[1] : "status"
if testCase="--check" {
    Log("PASS manual acceptance script parse; no window or input operations")
    ExitApp(0)
}
if A_Args.Length>1 || (testCase!="status" && testCase!="explorer" && testCase!="video")
    ExitApp(2)
originalCursor := Desktop.Cursor(&originalX,&originalY)
status := 0, folder := 0, video := 0, videoPlacement := 0, code := 0
try {
    if !originalCursor
        throw Error("Actual input desktop unavailable")
    primary := WinExist("ahk_class Shell_TrayWnd"), bars := WinGetList("ahk_class Shell_SecondaryTrayWnd")
    if !primary || !bars.Length
        throw Error("Two taskbars required")
    secondary := bars[1], first := Desktop.MonitorOf(primary), second := Desktop.MonitorOf(secondary)
    Acceptance.Uia := TaskbarUIA()
    Acceptance.Focus := Gui("+ToolWindow","随屏临时验收")
    Acceptance.Focus.AddText(,"正在测试任务栏跨屏恢复，稍后自动关闭。")
    Acceptance.Focus.Show("x" . (first.Work.L+80) . " y" . (first.Work.T+80) . " w360 h100")

    if testCase="status" {
    Run('"' . root . '\Start.exe"',root)
    deadline := Desktop.Tick()+3000
    while !status && Desktop.Tick()<deadline {
        for hwnd in WinGetList() {
            if WindowIdentity.WindowAppId(hwnd) == "TaskbarFollow.Status" {
                status := hwnd
                break
            }
        }
        Sleep(50)
    }
    if !status
        throw Error("Status window did not appear")
    Acceptance.Restore(status,"TaskbarFollow.Status",first,secondary,"status 1->2")
    Acceptance.Restore(status,"TaskbarFollow.Status",second,primary,"status 2->1")
    DllCall("user32\ShowWindow","ptr",status,"int",0)
    }

    if testCase="explorer" {
    before := Map()
    for hwnd in WinGetList("ahk_exe explorer.exe")
        before[hwnd] := true
    fixturePath := A_ScriptDir . "\results\随屏临时验收-" . A_TickCount
    DirCreate(fixturePath)
    shell := ComObject("Shell.Application"), shell.Explore(fixturePath)
    deadline := Desktop.Tick()+5000
    while !folder && Desktop.Tick()<deadline {
        for view in shell.Windows {
            try {
                candidate := view.HWND
                if !before.Has(candidate) && view.Document.Folder.Self.Path = fixturePath {
                    folder := candidate
                    break
                }
            }
        }
        Sleep(80)
    }
    if !folder
        throw Error("Cannot identify a separate temporary Explorer window")
    Sleep(1200)
    Acceptance.Restore(folder,"Microsoft.Windows.Explorer",first,secondary,"Explorer 1->2")
    Acceptance.Restore(folder,"Microsoft.Windows.Explorer",second,primary,"Explorer 2->1")
    WinClose("ahk_id " . folder), folder := 0
    }

    if testCase="video" {
    ids := WindowIdentity(root . "\settings.ini"), videoId := "TencentVideo.QQLive.v1"
    for hwnd in WinGetList("ahk_exe QQLive.exe") {
        if Desktop.Eligible(hwnd) {
            if video
                throw Error("Multiple existing Tencent windows; no automatic selection")
            video := hwnd, videoPlacement := Desktop.Placement(hwnd)
        }
    }
    if !video {
        b := Acceptance.Button(primary,ids.NativePath(videoId))
        x := (b.Rect.L+b.Rect.R)//2, y := (b.Rect.T+b.Rect.B)//2
        h := Acceptance.Uia.Hit(x,y)
        if h.Kind!="app" || h.Id!=b.Id
            throw Error("Tencent launch button is covered")
        Acceptance.Click(x,y)
        deadline := Desktop.Tick()+6500
        while !video && Desktop.Tick()<deadline {
            Acceptance.CheckPointer()
            for hwnd in WinGetList("ahk_exe QQLive.exe") {
                if Desktop.Eligible(hwnd) {
                    video := hwnd
                    break
                }
            }
            Sleep(80)
        }
    }
    if !video
        throw Error("Tencent has no enabled independent window; a dialog may be blocking it")
    Sleep(1600)
    try Acceptance.Button(secondary,videoId)
    catch
        videoId := ids.NativePath(videoId)
    Log("Tencent restore button identity=" . videoId)
    Acceptance.Restore(video,videoId,first,secondary,"Tencent 1->2")
    Acceptance.Restore(video,videoId,second,primary,"Tencent 2->1")
    }
} catch as e {
    Log("FAIL " . e.Message . "; line=" . e.Line)
    code := 1
} finally {
    if folder && DllCall("user32\IsWindow","ptr",folder)
        try WinClose("ahk_id " . folder)
    if video && DllCall("user32\IsWindow","ptr",video) {
        if IsObject(videoPlacement)
            DllCall("user32\SetWindowPlacement","ptr",video,"ptr",videoPlacement)
        else
            try WinClose("ahk_id " . video)
    }
    if status
        DllCall("user32\ShowWindow","ptr",status,"int",0)
    if IsObject(Acceptance.Focus)
        Acceptance.Focus.Destroy()
    if originalCursor
        DllCall("user32\SetPhysicalCursorPos","int",originalX,"int",originalY)
    if originalForeground
        try WinActivate("ahk_id " . originalForeground)
    Log("cleanup complete; pointer and original focus restored")
}
ExitApp(code)
