#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk

; Explicit live-desktop test. Never called by the isolated automatic test runner.
; Clicks only the named taskbar application and its selected thumbnail.
if A_Args.Length != 1 || (A_Args[1] != "edge" && A_Args[1] != "code" && A_Args[1] != "cursor")
    ExitApp(2)
Desktop.Physical()
CoordMode("Mouse", "Screen")
originalCursor := Desktop.Cursor(&originalX, &originalY)
originalForeground := Desktop.Foreground()
Log(text) => FileAppend(text . "`n", "*", "UTF-8")
ClickPhysical(x, y) {
    if !DllCall("user32\SetPhysicalCursorPos", "int", x, "int", y)
        throw Error("Could not place test cursor")
    Sleep(100)
    SendLevel(1)
    SendEvent("{LButton down}")
    Sleep(60)
    SendEvent("{LButton up}")
}
try {
    if !originalCursor
        throw Error("This test must run on the actual input desktop")
    if A_Args[1] = "cursor" {
        CoordMode("Mouse", "Client")
        first := Gui("+ToolWindow", "TaskbarFollow coordinate regression A")
        second := Gui("+ToolWindow", "TaskbarFollow coordinate regression B")
        first.Show("x150 y150 w400 h200")
        WinActivate("ahk_id " . first.Hwnd)
        Sleep(100)
        Desktop.Cursor(&ax, &ay), MouseGetPos(&legacyAx, &legacyAy)
        second.Show("x750 y350 w400 h200")
        WinActivate("ahk_id " . second.Hwnd)
        Sleep(100)
        Desktop.Cursor(&bx, &by), MouseGetPos(&legacyBx, &legacyBy)
        Log("legacy-client-delta=" . (legacyBx - legacyAx) . "," . (legacyBy - legacyAy))
        Log("physical-cursor-delta=" . (bx - ax) . "," . (by - ay))
        first.Destroy(), second.Destroy()
        if ax != bx || ay != by
            throw Error("Cursor moved during coordinate regression")
        if legacyAx = legacyBx && legacyAy = legacyBy
            throw Error("Client coordinate regression was not exercised")
        if originalForeground
            try WinActivate("ahk_id " . originalForeground)
        Log("PASS stationary physical cursor survives foreground-client origin changes")
        ExitApp(0)
    }
    ids := WindowIdentity(A_ScriptDir . "\..\settings.ini"), uia := TaskbarUIA()
    appId := A_Args[1] = "edge" ? "MSEdge" : "Microsoft.VisualStudioCode"
    bars := WinGetList("ahk_class Shell_SecondaryTrayWnd")
    if !bars.Length
        throw Error("Secondary Windows taskbar not found")
    bar := bars[1], destination := Desktop.MonitorOf(bar)
    primaryBar := WinExist("ahk_class Shell_TrayWnd"), source := Desktop.MonitorOf(primaryBar)
    Log("app=" . appId . "; source=" . source.Device . "; target=" . destination.Device)
    button := 0
    for item in uia.Buttons(bar) {
        if item.Id = appId {
            button := item
            break
        }
    }
    if !IsObject(button)
        throw Error("Target application taskbar button not found")
    targetHwnd := 0, beforeCount := 0, originalWindows := Map()
    for hwnd in WinGetList() {
        if Desktop.Eligible(hwnd) && ids.Match(appId, ids.Get(hwnd)) {
            beforeCount += 1
            originalWindows[hwnd] := Desktop.Placement(hwnd)
            if !targetHwnd || Desktop.SameMonitor(Desktop.MonitorOf(hwnd), source)
                targetHwnd := hwnd
        }
    }
    Log("eligible-before=" . beforeCount)
    if A_Args[1] = "code" {
        if !targetHwnd
            throw Error("No existing VS Code window available")
        ; A grouped button can restore a different last-active Code window.
        ; Put every eligible candidate into the same minimized source state so
        ; whichever Windows restores really exercises this regression.
        for hwnd, placement in originalWindows {
            if !Desktop.SameMonitor(Desktop.MonitorOf(hwnd), source) {
                Log("setup-move-to-primary=" . WindowMover.Move(hwnd, source, true))
                Sleep(350)
            }
            WinMinimize("ahk_id " . hwnd)
        }
        WinActivate("ahk_id " . targetHwnd)
        Sleep(150)
        WinMinimize("ahk_id " . targetHwnd)
        Sleep(250)
        if !Desktop.IsMin(targetHwnd)
            throw Error("VS Code did not minimize during setup")
        ; API-minimizing a foreign foreground window can leave it reported as
        ; foreground. Give Explorer a normal foreground to activate away from.
        focusPanel := Gui("+ToolWindow", "TaskbarFollow live restore test")
        focusPanel.AddText(, "Checking the actual secondary taskbar restore path.")
        focusPanel.Show("x" . (source.Work.L + 150) . " y" . (source.Work.T + 150) . " w420 h100")
        WinActivate("ahk_id " . focusPanel.Hwnd)
        Sleep(200)
        Log("setup-code-minimized-on=" . Desktop.MonitorOf(targetHwnd).Device)
    } else if beforeCount {
        throw Error("Edge has an existing eligible window; cold-launch test would not be valid")
    }
    x := (button.Rect.L + button.Rect.R) // 2, y := (button.Rect.T + button.Rect.B) // 2
    hit := uia.Hit(x, y)
    if hit.Kind != "app" || hit.Id != appId
        throw Error("Taskbar button is occluded or identity changed")
    Log("physical-click=" . x . "," . y)
    ClickPhysical(x, y)
    deadline := Desktop.Tick() + 12000, selected := false, arrivedAt := 0, reported := Map()
    Loop {
        if Desktop.Cursor(&currentX, &currentY) && !selected
            && (Abs(currentX - x) > 8 || Abs(currentY - y) > 8)
            throw Error("Live test interrupted by other pointer input; original Code placements will be restored")
        if A_Args[1] = "code" && !selected {
            title := Desktop.Title(targetHwnd)
            previews := Desktop.Thumbnails()
            for preview in previews {
                for item in uia.Buttons(preview, false) {
                    r := item.Rect
                    if item.Name == title && r.W > 20 && r.H > 10 {
                        thumbX := (r.L + r.R) // 2, thumbY := (r.T + r.B) // 2
                        thumbHit := uia.Hit(thumbX, thumbY)
                        if thumbHit.Kind = "thumbnail" {
                            Log("select-exact-code-thumbnail=" . thumbX . "," . thumbY)
                            ClickPhysical(thumbX, thumbY)
                            selected := true
                            break
                        }
                    }
                }
                ; Some Explorer overlay windows expose their titles only through
                ; ElementFromPoint, without enumerable accessibility descendants.
                ; This test samples the popup body, then clicks only an exact title match.
                if !selected {
                    r := Desktop.Rect(preview)
                    if IsObject(r) && r.W > 40 && r.H > 40 {
                        Loop 16 {
                            thumbX := r.L + Round(r.W * (A_Index - 0.5) / 16), thumbY := r.T + r.H // 2
                            thumbHit := uia.Hit(thumbX, thumbY)
                            for name in thumbHit.Names {
                                if thumbHit.Kind = "thumbnail" && name == title {
                                    Log("select-exact-code-thumbnail=" . thumbX . "," . thumbY)
                                    ClickPhysical(thumbX, thumbY)
                                    selected := true
                                    break
                                }
                            }
                            if selected
                                break
                        }
                    }
                }
                if selected
                    break
            }
        }
        candidates := WinGetList()
        found := false
        for hwnd in candidates {
            data := ids.Get(hwnd)
            if !Desktop.Eligible(hwnd) || !ids.Match(appId, data)
                continue
            if !reported.Has(hwnd) {
                Log("activated-candidate hwnd=" . hwnd . "; pid=" . data.Pid . "; appid=" . data.AppId . "; monitor=" . Desktop.MonitorOf(hwnd).Device . "; minimized=" . Desktop.IsMin(hwnd))
                reported[hwnd] := true
            }
            if !Desktop.IsMin(hwnd) && Desktop.SameMonitor(Desktop.MonitorOf(hwnd), destination) {
                found := true
                if !arrivedAt
                    arrivedAt := Desktop.Tick()
                if Desktop.Tick() - arrivedAt >= 1700 {
                    Log("PASS actual taskbar " . (A_Args[1] = "code" ? "minimized-restore" : "cold-launch") . "; window=" . hwnd . "; pid=" . data.Pid . "; final=" . destination.Device)
                    for other, placement in originalWindows {
                        if IsObject(placement)
                            DllCall("user32\SetWindowPlacement", "ptr", other, "ptr", placement)
                    }
                    if IsSet(focusPanel)
                        focusPanel.Destroy()
                    if originalCursor
                        DllCall("user32\SetPhysicalCursorPos", "int", originalX, "int", originalY)
                    if originalForeground
                        try WinActivate("ahk_id " . originalForeground)
                    ExitApp(0)
                }
            }
        }
        if !found
            arrivedAt := 0
        if Desktop.Tick() > deadline
            throw Error("Actual taskbar activation did not leave the window on the secondary monitor")
        Sleep(100)
    }
} catch as exception {
    if IsSet(originalWindows) {
        for hwnd, placement in originalWindows {
            if IsObject(placement)
                DllCall("user32\SetWindowPlacement", "ptr", hwnd, "ptr", placement)
        }
    }
    if originalCursor
        DllCall("user32\SetPhysicalCursorPos", "int", originalX, "int", originalY)
    if IsSet(focusPanel)
        focusPanel.Destroy()
    if originalForeground
        try WinActivate("ahk_id " . originalForeground)
    Log("FAIL " . exception.Message . "; line=" . exception.Line)
    ExitApp(1)
}
