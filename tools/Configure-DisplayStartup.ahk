#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\DisplayStartup.ahk

try {
    SplitPath(A_ScriptDir,,&root)
    command := A_Args.Length = 1 ? A_Args[1] : "status"
    if command != "enable" && command != "disable" && command != "status"
        throw Error("Use enable, disable, or status")
    detectorPid := 0
    if command != "status"
        detectorPid := DisplayStartup.Set(command = "enable",root)
    FileAppend("display-startup=" . DisplayStartup.Shortcut(root) . "; watcher-pid=" . detectorPid
        . "; shortcut=" . DisplayStartup.Path() . "`n","*","UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL display startup: " . e.Message . "`n","*","UTF-8")
    ExitApp(1)
}
