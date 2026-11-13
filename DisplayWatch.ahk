#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include lib\DisplayAutoStart.ahk
#Include lib\DisplayStartup.ahk

if A_LineFile = A_ScriptFullPath {
    try {
        Persistent()
        logonTask := A_Args.Length = 1 && A_Args[1] = "--logon-task"
        ; Separate the old shortcut and its replacement during migration. Task
        ; Scheduler serializes its own launches, and the main mutex protects the engine.
        WatcherLock := DllCall("kernel32\CreateMutexW","ptr",0,"int",false,"wstr",
            DisplayWatcher.MutexName(A_ScriptFullPath) . (logonTask ? ".Logon" : ".Shortcut"),"ptr")
        if A_LastError = 183
            ExitApp(0)
        if !WatcherLock
            throw Error("无法建立屏幕检测实例锁。")
        ScreenWatcher := DisplayWatcher(A_ScriptDir,"",logonTask)
        ScreenWatcher.Start()
    } catch as failure {
        ; A startup detector never opens a modal dialog or steals the desktop.
        try {
            DirCreate(A_ScriptDir . "\logs")
            FileAppend(FormatTime(A_Now,"yyyy-MM-dd HH:mm:ss") . " startup error; " . failure.Message . "`n",
                A_ScriptDir . "\logs\DisplayWatch.log","UTF-8")
        }
        ExitApp(1)
    }
}
