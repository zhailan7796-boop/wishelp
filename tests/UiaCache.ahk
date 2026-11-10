#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk

; The UIA client and its disposable Win32 fixture run in separate processes.
; The fixture never activates, enters the taskbar or changes a user window.
class UiaCacheChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual,expected,label) => this.Assert(actual == expected,label . " (actual=" . actual . ", expected=" . expected . ")")
    static Find(records,name) {
        for item in records {
            if item.Name == name
                return item
        }
        throw Error("Owned fixture control missing from UIA: " . name)
    }
    static SameRect(actual,expected,label) {
        for field in ["L","T","R","B"]
            this.Equal(actual.%field%,expected.%field%,label . " " . field)
    }
    static WaitWindow(title,pid) {
        deadline := Desktop.Tick()+3000
        while Desktop.Tick() < deadline {
            hwnd := DllCall("user32\FindWindowW","ptr",0,"wstr",title,"ptr")
            ; The fixture creates its controls before showing the window.
            if hwnd && Desktop.Pid(hwnd) = pid && DllCall("user32\IsWindowVisible","ptr",hwnd)
                return hwnd
            Sleep(20)
        }
        throw Error("Owned UIA fixture did not become ready")
    }
    static Mutate(hwnd,command) {
        result := 0
        if !DllCall("user32\SendMessageTimeoutW","ptr",hwnd,"uint",0x8061,
            "uptr",command,"ptr",0,"uint",3,"uint",1000,"ptr*",&result,"ptr") || result != 1
            throw Error("Owned fixture mutation did not complete")
    }
    static CheckMinimal(actual,diagnostic,label) {
        this.Equal(actual.Length,diagnostic.Length,label . " count")
        for number,item in diagnostic {
            minimal := actual[number]
            this.Equal(minimal.Id,item.Id,label . " AutomationId " . number)
            this.Equal(minimal.Name,"",label . " omits name " . number)
            this.Equal(minimal.Peer,"",label . " omits class " . number)
            this.SameRect(minimal.Rect,item.Rect,label . " rect " . number)
        }
    }
}

StartUiaFixture() {
    global FixtureWindow, FixtureFirst, FixtureSecond, FixtureLabel, FixtureParentPid
    FixtureParentPid := Integer(A_Args[2])
    Desktop.Physical()
    MonitorGetWorkArea(1,&left,&top)
    FixtureWindow := Gui("+E0x08000000 +ToolWindow -Caption",A_Args[3])
    FixtureFirst := FixtureWindow.AddButton("x20 y20 w180 h36","UiaCache First")
    FixtureSecond := FixtureWindow.AddButton("x20 y76 w180 h36","UiaCache Second")
    FixtureLabel := FixtureWindow.AddText("x20 y132 w260 h28","UiaCache Label")
    FixtureWindow.OnEvent("Close",(*) => ExitApp())
    OnMessage(0x8061,MutateUiaFixture)
    SetTimer(CheckUiaFixtureParent,100)
    FixtureWindow.Show("NA x" . (left+80) . " y" . (top+80) . " w360 h200")
}
MutateUiaFixture(command,*) {
    global FixtureWindow, FixtureFirst, FixtureSecond, FixtureLabel
    if command = 1 {
        FixtureWindow.GetPos(&left,&top)
        FixtureWindow.Move(left+120,top+70,520,260)
        FixtureFirst.Move(28,24,240,52)
        FixtureFirst.Text := "UiaCache Changed"
        FixtureLabel.Text := "UiaCache Updated Label"
        return 1
    }
    return 0
}
CheckUiaFixtureParent() {
    global FixtureParentPid
    if !ProcessExist(FixtureParentPid)
        ExitApp()
}

if A_Args.Length && A_Args[1] = "--fixture" {
    StartUiaFixture()
    return
}

fixturePid := 0, fixtureHandle := 0, fixtureHwnd := 0, exitCode := 0
try {
    Desktop.Physical()
    title := "TaskbarFollow.UIACache." . DllCall("kernel32\GetCurrentProcessId","uint") . "." . Desktop.Tick()
    command := '"' . A_AhkPath . '" /ErrorStdOut=UTF-8 "' . A_ScriptFullPath . '" --fixture '
        . DllCall("kernel32\GetCurrentProcessId","uint") . ' "' . title . '"'
    Run(command,A_ScriptDir,"Hide",&fixturePid)
    ; Keep a handle so cleanup can only terminate the exact process we started.
    fixtureHandle := DllCall("kernel32\OpenProcess","uint",0x101001,"int",false,"uint",fixturePid,"ptr")
    if !fixtureHandle
        throw Error("Cannot retain owned UIA fixture process handle")
    fixtureHwnd := UiaCacheChecks.WaitWindow(title,fixturePid)
    firstHwnd := DllCall("user32\FindWindowExW","ptr",fixtureHwnd,"ptr",0,"wstr","Button","wstr","UiaCache First","ptr")
    secondHwnd := DllCall("user32\FindWindowExW","ptr",fixtureHwnd,"ptr",0,"wstr","Button","wstr","UiaCache Second","ptr")
    UiaCacheChecks.Assert(firstHwnd && secondHwnd,"Owned native buttons are available")

    uia := TaskbarUIA()
    initial := uia.Buttons(fixtureHwnd,false)
    UiaCacheChecks.Assert(initial.Length >= 3,"Diagnostic scan returns owned descendants")
    first := UiaCacheChecks.Find(initial,"UiaCache First")
    second := UiaCacheChecks.Find(initial,"UiaCache Second")
    UiaCacheChecks.Find(initial,"UiaCache Label")
    UiaCacheChecks.Equal(first.Peer,"Button","Diagnostic scan preserves cached class name")
    UiaCacheChecks.SameRect(first.Rect,Desktop.Rect(firstHwnd),"Initial first cached rectangle matches physical Win32 geometry")
    UiaCacheChecks.SameRect(second.Rect,Desktop.Rect(secondHwnd),"Initial second cached rectangle matches physical Win32 geometry")
    oldRect := ScreenRect(first.Rect.L,first.Rect.T,first.Rect.R,first.Rect.B)
    UiaCacheChecks.Equal(uia.Buttons(fixtureHwnd).Length,0,"App-only query excludes ordinary Win32 buttons")
    UiaCacheChecks.Equal(uia.Buttons(fixtureHwnd,true,false).Length,0,"Minimal app-only query also excludes non-taskbar controls")
    UiaCacheChecks.Equal(uia.Buttons(firstHwnd,false).Length,0,"A valid leaf returns an empty descendants snapshot")
    UiaCacheChecks.CheckMinimal(uia.Buttons(fixtureHwnd,false,false),initial,"Minimal cache preserves identity and geometry")

    UiaCacheChecks.Mutate(fixtureHwnd,1)
    changed := uia.Buttons(fixtureHwnd,false)
    nextFirst := UiaCacheChecks.Find(changed,"UiaCache Changed")
    nextSecond := UiaCacheChecks.Find(changed,"UiaCache Second")
    UiaCacheChecks.Find(changed,"UiaCache Updated Label")
    UiaCacheChecks.Equal(nextFirst.Id,first.Id,"Rebuilt snapshot retains the same native control identity")
    UiaCacheChecks.SameRect(nextFirst.Rect,Desktop.Rect(firstHwnd),"Refreshed first cached rectangle matches moved and resized native control")
    UiaCacheChecks.SameRect(nextSecond.Rect,Desktop.Rect(secondHwnd),"Refreshed second cached rectangle follows the moved fixture")
    UiaCacheChecks.Assert(nextFirst.Rect.L != oldRect.L && nextFirst.Rect.T != oldRect.T,"A new scan sees changed physical position")
    UiaCacheChecks.Assert(nextFirst.Rect.W != oldRect.W && nextFirst.Rect.H != oldRect.H,"A new scan sees changed dimensions")
    UiaCacheChecks.Equal(first.Name,"UiaCache First","An old snapshot retains its original name")
    UiaCacheChecks.SameRect(first.Rect,oldRect,"An old snapshot retains its original rectangle")
    UiaCacheChecks.CheckMinimal(uia.Buttons(fixtureHwnd,false,false),changed,"Minimal cache is also rebuilt after geometry changes")
    UiaCacheChecks.Equal(uia.Buttons(fixtureHwnd).Length,0,"Diagnostic scans do not contaminate the app-only condition")

    DllCall("user32\PostMessageW","ptr",fixtureHwnd,"uint",0x10,"ptr",0,"ptr",0)
    UiaCacheChecks.Equal(DllCall("kernel32\WaitForSingleObject","ptr",fixtureHandle,"uint",2000,"uint"),0,"Owned GUI fixture closes cleanly")
    closed := [], rejected := false
    try closed := uia.Buttons(fixtureHwnd,false)
    catch
        rejected := true
    UiaCacheChecks.Assert(rejected || !closed.Length,"A destroyed root cannot return a previous snapshot")
    FileAppend("PASS " . UiaCacheChecks.Count . " UIA cache/filter/physical-geometry/freshness assertions`n","*","UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally {
    if fixtureHandle {
        if DllCall("kernel32\WaitForSingleObject","ptr",fixtureHandle,"uint",0,"uint") = 258 {
            if fixtureHwnd && Desktop.Pid(fixtureHwnd) = fixturePid
                DllCall("user32\PostMessageW","ptr",fixtureHwnd,"uint",0x10,"ptr",0,"ptr",0)
            if DllCall("kernel32\WaitForSingleObject","ptr",fixtureHandle,"uint",500,"uint") = 258
                DllCall("kernel32\TerminateProcess","ptr",fixtureHandle,"uint",1)
        }
        DllCall("kernel32\CloseHandle","ptr",fixtureHandle)
    }
}
ExitApp(exitCode)
