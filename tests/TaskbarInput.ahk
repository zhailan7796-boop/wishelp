#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk
; Live input-desktop regression using only our own uniquely identified window.
Desktop.Physical()
originalCursor := Desktop.Cursor(&originalX, &originalY)
originalForeground := Desktop.Foreground()
checkingRestore := false, observedWindow := 0, firstRestoreMonitor := 0
ObserveRestore(wparam,lparam,message,hwnd) {
    global checkingRestore, observedWindow, firstRestoreMonitor
    if checkingRestore && hwnd = observedWindow && !firstRestoreMonitor && !Desktop.IsMin(hwnd)
        && DllCall("user32\IsWindowVisible","ptr",hwnd)
        firstRestoreMonitor := Desktop.MonitorOf(hwnd).Handle
}
OnMessage(0x47,ObserveRestore)
Log(text) => FileAppend(text . "`n", "*", "UTF-8")
try {
    if !originalCursor
        throw Error("Run this regression on the actual input desktop")
    appId := "TaskbarFollow.InputRegression"
    DllCall("shell32\SetCurrentProcessExplicitAppUserModelID", "wstr", appId)
    bars := WinGetList("ahk_class Shell_SecondaryTrayWnd")
    if !bars.Length
        throw Error("Secondary taskbar not found")
    target := Desktop.MonitorOf(bars[1])
    source := Desktop.MonitorOf(WinExist("ahk_class Shell_TrayWnd"))
    fixture := Gui(, "TaskbarFollow taskbar input regression")
    observedWindow := fixture.Hwnd
    fixture.AddText(, "Temporary test window. No documents are opened.")
    shellCom := ComObject("Shell.Application")
    storePtr := 0, iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
    if DllCall("shell32\SHGetPropertyStoreForWindow", "ptr", fixture.Hwnd, "ptr", iid, "ptr*", &storePtr, "int") < 0
        throw Error("Fixture property store unavailable")
    store := ComValue(13, storePtr, 1), key := Buffer(20, 0), pv := Buffer(24, 0)
    guid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
    DllCall("ntdll\RtlMoveMemory", "ptr", key, "ptr", guid, "uptr", 16)
    NumPut("uint", 5, key, 16)
    idPtr := DllCall("ole32\CoTaskMemAlloc", "uptr", (StrLen(appId) + 1) * 2, "ptr")
    StrPut(appId, idPtr, StrLen(appId) + 1)
    NumPut("ushort", 31, pv), NumPut("ptr", idPtr, pv, 8)
    try {
        ComCall(6, store, "ptr", key, "ptr", pv)
        ComCall(7, store)
    } finally DllCall("ole32\PropVariantClear", "ptr", pv)
    fixture.Show("x" . (source.Work.L + 240) . " y" . (source.Work.T + 180) . " w640 h400")
    Sleep(300)
    fixture.Minimize()
    focus := Gui("+ToolWindow", "TaskbarFollow input test controller")
    focus.AddText(, "Waiting for a real taskbar restore.")
    focus.Show("x" . (source.Work.L + 80) . " y" . (source.Work.T + 80) . " w360 h100")
    uia := TaskbarUIA(), button := 0, deadline := Desktop.Tick() + 4000
    Loop {
        for item in uia.Buttons(bars[1]) {
            if item.Id = appId {
                button := item
                break
            }
        }
        if IsObject(button)
            break
        if Desktop.Tick() > deadline
            throw Error("Fixture did not get its unique taskbar button")
        Sleep(100)
    }
    Log("fixture=" . fixture.Hwnd . "; appid=" . WindowIdentity.WindowAppId(fixture.Hwnd) . "; minimized=" . Desktop.IsMin(fixture.Hwnd))
    Log("source=" . source.Device . "; target=" . target.Device)
    ; Native mode resolves a click from the pre-warmed semantic cache. A newly
    ; created test taskbar button must be allowed two cache refreshes first.
    Sleep(1600)
    for item in uia.Buttons(bars[1]) {
        if item.Id = appId {
            button := item
            break
        }
    }
    x := (button.Rect.L + button.Rect.R) // 2, y := (button.Rect.T + button.Rect.B) // 2
    hit := uia.Hit(x,y)
    if hit.Id != appId
        throw Error("Fixture button is occluded; point=" . x . "," . y . "; root=" . Desktop.Class(Desktop.RootAt(x,y)) . "; hit=" . hit.Kind . "; id=" . hit.Id)
    DllCall("user32\SetPhysicalCursorPos", "int", x, "int", y)
    checkingRestore := true
    SendLevel(1)
    SendEvent("{LButton down}")
    Sleep(60)
    SendEvent("{LButton up}")
    deadline := Desktop.Tick() + 8000, arrivedAt := 0
    Loop {
        if !Desktop.IsMin(fixture.Hwnd) && Desktop.SameMonitor(Desktop.MonitorOf(fixture.Hwnd), target) {
            if !arrivedAt
                arrivedAt := Desktop.Tick()
            if Desktop.Tick() - arrivedAt > 1700
                break
        } else arrivedAt := 0
        if Desktop.Tick() > deadline
            throw Error("Taskbar restore failed; minimized=" . Desktop.IsMin(fixture.Hwnd) . "; final=" . Desktop.MonitorOf(fixture.Hwnd).Device)
        Sleep(50)
    }
    if IniRead(A_ScriptDir . "\..\settings.ini","General","Engine","native") = "native" {
        if firstRestoreMonitor != target.Handle
            throw Error("Native restore first became visible on the wrong monitor; first=" . firstRestoreMonitor . "; expected=" . target.Handle)
        Log("PASS native actual secondary taskbar click -> first visible restore already on target; stable >1700ms")
    } else
        Log("PASS actual secondary taskbar click -> own minimized window restored and moved; stable >1700ms")
    fixture.Destroy(), focus.Destroy()
    if originalCursor
        DllCall("user32\SetPhysicalCursorPos", "int", originalX, "int", originalY)
    if originalForeground
        try WinActivate("ahk_id " . originalForeground)
    ExitApp(0)
} catch as exception {
    if originalCursor
        DllCall("user32\SetPhysicalCursorPos", "int", originalX, "int", originalY)
    Log("FAIL " . exception.Message . "; line=" . exception.Line)
    ExitApp(1)
}
