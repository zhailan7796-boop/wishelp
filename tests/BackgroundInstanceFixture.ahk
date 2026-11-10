#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk

; The driver copies this file to a unique path before launching it. It cannot
; share an instance identity with the real engine or another test run.
if A_Args.Length != 3
    ExitApp(2)
resultPath := A_Args[1], mode := A_Args[2], parentPid := Integer(A_Args[3])
DllCall("user32\SetPropW","ptr",A_ScriptHwnd,"wstr","TaskbarFollow.BackgroundFixture","ptr",0x42474931)
try {
    acquired := mode = "legacy" ? true : (mode = "quiet" || mode = "quiet-owner" ? FollowInstance.Acquire(false) : FollowInstance.Acquire())
    if !acquired {
        output := FileOpen(resultPath,"w","UTF-8")
        output.Write("rejected," . ProcessExist() . "," . (FollowInstance.OwnsMutex?1:0)), output.Close()
        ExitApp(0)
    }
    Follow := BackgroundFixtureOwner(resultPath)
    ; Observe the actual reveal message, then call the real library callback.
    ; No test window is shown and no foreground state is changed.
    if mode != "legacy"
        OnMessage(0x8053,FollowInstance.Reveal,0)
    if mode != "unresponsive"
        OnMessage(0x8053,ObserveFixtureReveal)
    Follow.Write()
    SetTimer(CheckFixtureParent,100)
    SetTimer(() => ExitApp(),-12000)
    Persistent
} catch as failure {
    FileAppend("background fixture FAIL: " . failure.Message . " (line " . failure.Line . ")`n","*","UTF-8")
    ExitApp(1)
}

ObserveFixtureReveal(wparam,lparam,message,hwnd) {
    global Follow
    Follow.Requests += 1
    Follow.Write()
    return FollowInstance.Reveal(wparam,lparam,message,hwnd)
}
CheckFixtureParent() {
    global parentPid
    if !ProcessExist(parentPid)
        ExitApp()
}
class BackgroundFixtureOwner {
    __New(path) {
        this.Path := path, this.Requests := 0, this.Shows := 0
    }
    ShowStatus(*) {
        this.Shows += 1
        this.Write()
    }
    Write() {
        output := FileOpen(this.Path,"w","UTF-8")
        output.Write(ProcessExist() . "," . A_ScriptHwnd . "," . this.Requests . "," . this.Shows
            . "," . (FollowInstance.OwnsMutex?1:0) . "," . DllCall("user32\IsWindowVisible","ptr",A_ScriptHwnd,"int"))
        output.Close()
    }
}
