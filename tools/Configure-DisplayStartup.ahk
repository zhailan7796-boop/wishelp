#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\DisplayStartup.ahk

try {
    SplitPath(A_ScriptDir,,&root)
    command := A_Args.Length = 1 ? A_Args[1] : "status"
    if command != "enable" && command != "disable" && command != "status"
        throw Error("Use enable, disable, or status")
    instance := 0
    if command != "status"
        instance := DisplayStartup.Set(command = "enable",root)
    logon := DisplayLogonTask(root)
    FileAppend("display-startup=" . (DisplayStartup.IsEnabled(root) ? "screen" : "off")
        . "; logon-task=" . logon.Status() . "; instance=" . instance . "; legacy-shortcut=" . DisplayStartup.Shortcut(root) . "`n","*","UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL display startup: " . e.Message . "`n","*","UTF-8")
    ExitApp(1)
}
