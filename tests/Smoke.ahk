#Requires AutoHotkey v2.0 64-bit
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk
Desktop.Physical()
m := Desktop.MonitorAt(0, 0)
FileAppend("monitor=" . m.Device . " work=" . m.Work.W . "x" . m.Work.H . "`n", "*", "UTF-8")
try {
    u := TaskbarUIA()
    FileAppend("uia=ready`n", "*", "UTF-8")
} catch as e {
    FileAppend("uia=" . e.Message . "`n", "*", "UTF-8")
    ExitApp(1)
}
ExitApp(0)

