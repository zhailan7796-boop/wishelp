#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include lib\Native.ahk
#Include lib\UIA.ahk
#Include lib\NativeEngine.ahk
Desktop.Physical()
report := "随屏 TaskbarFollow · 只读兼容性诊断`r`n"
report .= "Windows build: " . A_OSVersion . "`r`n"
report .= "AutoHotkey: " . A_AhkVersion . " (64-bit)`r`n"
report .= "不会点击、激活或移动任何窗口；不更改显示设置；不记录用户窗口标题。`r`n`r`n"
identity := WindowIdentity(A_ScriptDir . "\settings.ini")
report .= "Shortcut AppID mappings: " . identity.ShortcutCount . "`r`n"
total := 0, hits := 0, bars := 0, exclusions := 0, checks := 0
try {
    uia := TaskbarUIA()
    Loop MonitorGetCount() {
        MonitorGet(A_Index, &ml, &mt, &mr, &mb)
        monitor := Desktop.MonitorAt((ml + mr) // 2, (mt + mb) // 2)
        report .= monitor.Device . " bounds=" . ml . "," . mt . "," . mr . "," . mb
            . " work=" . monitor.Work.L . "," . monitor.Work.T . "," . monitor.Work.R . "," . monitor.Work.B . "`r`n"
    }
    for cls in ["Shell_TrayWnd", "Shell_SecondaryTrayWnd"] {
        for hwnd in WinGetList("ahk_class " . cls) {
            bars += 1
            report .= "`r`nTaskbar: " . cls . "`r`n"
            for button in uia.Buttons(hwnd, false) {
                r := button.Rect
                if button.Peer != "Taskbar.TaskListButtonAutomationPeer" {
                    if button.Id = "StartButton" || button.Id = "SearchButton" || button.Id = "TaskViewButton"
                        || button.Id = "WidgetsButton" || button.Id = "SystemTrayIcon" {
                        checks += 1
                        nonApp := uia.Hit((r.L + r.R) // 2, (r.T + r.B) // 2)
                        rejected := nonApp.Kind = "none"
                        if rejected
                            exclusions += 1
                        report .= "  " . (rejected ? "[EXCLUDED OK] " : "[CHECK REQUIRED] ") . button.Id . "`r`n"
                    }
                    continue
                }
                total += 1
                hit := uia.Hit((r.L + r.R) // 2, (r.T + r.B) // 2)
                same := hit.Kind = "app" && hit.Id = button.Id
                if same
                    hits += 1
                report .= "  " . (same ? "[HIT OK] " : "[OCCLUDED/UNSUPPORTED] ") . button.Id . "`r`n"
                matches := 0
                for candidate in WinGetList() {
                    if !Desktop.Eligible(candidate)
                        continue
                    data := identity.Get(candidate)
                    if identity.Match(button.Id, data) {
                        matches += 1
                        report .= "    match pid=" . data.Pid . " exe=" . data.Exe . "`r`n"
                    }
                }
                launch := NativeEngine.ResolveEntry(button.Id,[],identity)
                report .= "    matching eligible windows=" . matches . "`r`n"
                report .= "    native cold-start=" . ((launch.Flags & 1) ? "verified executable" : "no verified executable")
                    . ((launch.Flags & 2) ? "; exact window/process AppID required" : "") . "`r`n"
            }
        }
    }
    report .= "`r`nTaskbars=" . bars . "; app buttons=" . total . "; point hit tests passed=" . hits . "`r`n"
    report .= "Non-app controls excluded=" . exclusions . "/" . checks . "`r`n"
    report .= "注意：0 个匹配也可能是固定但未启动的应用；它并不等于该应用不受支持。`r`n"
    report .= "这不是点击/激活端到端测试，也不证明所有应用、缩略图或系统版本均兼容。`r`n"
} catch as e {
    report .= "`r`nERROR: " . e.Message . " (line " . e.Line . ")`r`n"
}
path := A_ScriptDir . "\diagnostics.txt"
stream := FileOpen(path, "w", "UTF-8")
stream.Write(report), stream.Close()
if A_Args.Length && A_Args[1] = "--stdout"
    FileAppend(report, "*", "UTF-8")
else
    Run('notepad.exe "' . path . '"')
ExitApp()


