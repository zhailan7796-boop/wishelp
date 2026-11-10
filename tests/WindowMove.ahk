#Requires AutoHotkey v2.0 64-bit
#Include ..\lib\Native.ahk
Desktop.Physical()
Log(text) => FileAppend(text . "`n", "*", "UTF-8")
try {
    if MonitorGetCount() < 2
        throw Error("Need two monitors")
    MonitorGet(1, &l1, &t1, &r1, &b1), MonitorGet(2, &l2, &t2, &r2, &b2)
    one := Desktop.MonitorAt((l1+r1)//2, (t1+b1)//2)
    two := Desktop.MonitorAt((l2+r2)//2, (t2+b2)//2)
    g := Gui("+E0x08000000 +ToolWindow", "TaskbarFollow isolated movement test")
    g.AddText(, "Automated test fixture; no user application is touched.")
    g.Show("NA x" . (one.Work.L + 100) . " y" . (one.Work.T + 100) . " w640 h400")
    Sleep(100)
    shellCom := ComObject("Shell.Application") ; initialize COM before using the shell's native property store
    storePtr := 0
    iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
    if DllCall("shell32\SHGetPropertyStoreForWindow", "ptr", g.Hwnd, "ptr", iid, "ptr*", &storePtr, "int") < 0
        throw Error("Fixture property store unavailable")
    store := ComValue(13, storePtr, 1), key := Buffer(20, 0), pv := Buffer(24, 0)
    appGuid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
    DllCall("ntdll\RtlMoveMemory", "ptr", key, "ptr", appGuid, "uptr", 16)
    NumPut("uint", 5, key, 16)
    appText := "TaskbarFollow.NativeTest"
    appTextPtr := DllCall("ole32\CoTaskMemAlloc", "uptr", (StrLen(appText) + 1) * 2, "ptr")
    if !appTextPtr
        throw Error("Fixture AppID allocation failed")
    StrPut(appText, appTextPtr, StrLen(appText) + 1)
    NumPut("ushort", 31, pv)
    NumPut("ptr", appTextPtr, pv, 8) ; VT_LPWSTR owned and released by PropVariantClear
    try {
        ComCall(6, store, "ptr", key, "ptr", pv)
        ComCall(7, store)
    } finally {
        DllCall("ole32\PropVariantClear", "ptr", pv)
    }
    id := WindowIdentity.WindowAppId(g.Hwnd)
    Log("window-appid=" . id)
    if id != "TaskbarFollow.NativeTest"
        throw Error("Window AppID round-trip failed")
    identity := WindowIdentity().Get(g.Hwnd)
    Log("identity-path=" . identity.Path)
    Log("normal-before=" . Desktop.MonitorOf(g.Hwnd).Device)
    Log("normal-result=" . WindowMover.Move(g.Hwnd, two))
    Sleep(350)
    Log("normal-after=" . Desktop.MonitorOf(g.Hwnd).Device)
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), two)
        throw Error("Normal move failed")
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 3)
    Sleep(150)
    Log("max-before=" . Desktop.MonitorOf(g.Hwnd).Device)
    Log("max-result=" . WindowMover.Move(g.Hwnd, one))
    Sleep(350)
    Log("max-after=" . Desktop.MonitorOf(g.Hwnd).Device . " max-state=" . NumGet(Desktop.Placement(g.Hwnd), 8, "uint"))
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), one) || NumGet(Desktop.Placement(g.Hwnd), 8, "uint") != 3
        throw Error("Maximized move failed")
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 6)
    Sleep(100)
    if !Desktop.IsMin(g.Hwnd) || WindowMover.Move(g.Hwnd, two, false) != "minimized"
        throw Error("A native minimized window was unexpectedly restored")
    Log("minimized-max-result=" . WindowMover.Move(g.Hwnd, two, true))
    Sleep(300)
    if !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), two) || NumGet(Desktop.Placement(g.Hwnd), 8, "uint") != 3
        throw Error("Minimized maximized state was not preserved")
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 9)
    Sleep(100)
    DllCall("user32\ShowWindow", "ptr", g.Hwnd, "int", 6)
    Sleep(100)
    Log("minimized-normal-result=" . WindowMover.Move(g.Hwnd, one, true))
    Sleep(300)
    if Desktop.IsMin(g.Hwnd) || !Desktop.SameMonitor(Desktop.MonitorOf(g.Hwnd), one)
        throw Error("Minimized normal window did not restore on destination")
    if NumGet(Desktop.Placement(g.Hwnd), 8, "uint") = 3
        throw Error("A normal window unexpectedly became maximized")
    if WindowMover.Move(g.Hwnd, one) != "already-there"
        throw Error("Same-screen operation was not a no-op")
    if Desktop.Eligible(g.Hwnd)
        throw Error("NOACTIVATE/tool test fixture must not be automatically eligible")
    changed := {Handle: two.Handle, Device: two.Device, Bounds: two.Bounds, Work: ScreenRect(two.Work.L, two.Work.T + 1, two.Work.R, two.Work.B)}
    if WindowMover.Move(g.Hwnd, changed) != "monitor-changed"
        throw Error("A stale work-area snapshot was accepted")
    Log("PASS normal/maximized/minimized/no-op/stale-monitor native cases")
    g.Destroy()
    ExitApp(0)
} catch as e {
    Log("FAIL " . e.Message . " at " . e.Line)
    try g.Destroy()
    ExitApp(1)
}



