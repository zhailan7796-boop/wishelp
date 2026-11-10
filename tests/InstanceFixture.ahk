#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk
if A_Args.Length < 1
    ExitApp(2)
mode := A_Args.Length > 1 ? A_Args[2] : ""
if mode = "burst" {
    DllCall("user32\SetPropW", "ptr", A_ScriptHwnd, "wstr", "TaskbarFollow.Starting", "ptr", 1)
    Sleep(Max(1, Integer(A_Args[3]) - Desktop.Tick()))
}
if mode != "legacy" && !FollowInstance.Acquire()
    ExitApp(0)
Follow := InstanceTestOwner(A_Args[1])
Follow.ShowStatus()
SetTimer(() => ExitApp(), -12000)
Persistent
class InstanceTestOwner {
    __New(path) {
        this.Path := path, this.Count := 0
    }
    ShowStatus(*) {
        this.Count += 1
        output := FileOpen(this.Path, "w", "UTF-8")
        output.Write(ProcessExist() . "," . this.Count), output.Close()
    }
}
