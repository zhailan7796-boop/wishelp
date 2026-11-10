#Requires AutoHotkey v2.0 64-bit
#SingleInstance Ignore
#NoTrayIcon
#Warn VarUnset, StdOut
#Include lib\DisplayAutoStart.ahk

if A_LineFile = A_ScriptFullPath {
    try {
        Persistent()
        ScreenWatcher := DisplayWatcher(A_ScriptDir)
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
