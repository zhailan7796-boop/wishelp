#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Include lib\Native.ahk
#Include lib\UIA.ahk
Persistent
if A_Args.Length < 2 || A_Args.Length > 3
    ExitApp(2)
ParentHwnd := Integer(A_Args[1]), ParentPid := Integer(A_Args[2])
Desktop.Physical()
try Uia := TaskbarUIA()
catch {
    DllCall("user32\PostMessageW", "ptr", ParentHwnd, "uint", 0x8051, "uptr", A_ScriptHwnd, "ptr", 0)
    ExitApp(3)
}
OnMessage(0x8050, RequestHit)
SetTimer(CheckParent, 1000)
DllCall("user32\PostMessageW", "ptr", ParentHwnd, "uint", 0x8051, "uptr", A_ScriptHwnd, "ptr", ProcessExist())
if A_Args.Length = 3 && A_Args[3] = "--native" {
    SetTimer(EmitCache,750)
    SetTimer(EmitHover,100)
    EmitCache()
}
EmitHover() {
    global Uia
    static wasPreview := false, busy := false
    if busy
        return
    busy := true
    try {
        Desktop.Physical()
        popup := 0
        if Desktop.Cursor(&x,&y)
            popup := Desktop.RootAt(x,y)
        if popup && Desktop.IsThumbnail(Desktop.Class(popup)) {
            hit := Uia.Hit(x,y)
            if hit.Kind = "thumbnail" {
                payload := x . "`n" . y . "`n" . popup
                for name in hit.Names
                    payload .= "`n" . name
                SendResult(payload,0x54424634)
                wasPreview := true
                return
            }
        }
        if wasPreview {
            SendResult("hide",0x54424634)
            wasPreview := false
        }
    } catch {
        if wasPreview {
            SendResult("hide",0x54424634)
            wasPreview := false
        }
    } finally busy := false
}

EmitCache() {
    global Uia
    static busy := false
    if busy
        return
    busy := true
    try {
        rows := ""
        bars := WinGetList("ahk_class Shell_TrayWnd")
        for hwnd in WinGetList("ahk_class Shell_SecondaryTrayWnd")
            bars.Push(hwnd)
        for hwnd in bars {
            for item in Uia.Buttons(hwnd,true,false) {
                if item.Id = "" || InStr(item.Id,"`t")
                    continue
                r := item.Rect
                rows .= hwnd . "`t" . r.L . "`t" . r.T . "`t" . r.R . "`t" . r.B . "`t" . item.Id . "`n"
            }
        }
        SendResult(rows,0x54424633)
    } catch {
        ; A failed refresh must not make an old layout appear freshly verified.
    } finally busy := false
}

RequestHit(serial, point, *) {
    global Uia, ParentHwnd
    x := point << 32 >> 32, y := point >> 32
    ; UIA executes outside SendMessage/low-level input callbacks.
    SetTimer(DoHit.Bind(serial, x, y), -1)
}
DoHit(serial, x, y) {
    global Uia, ParentHwnd
    try result := Uia.Hit(x, y)
    catch as e {
        SendResult(serial . "`nerror`n" . TaskbarUIA.Field(e.Message))
        return
    }
    payload := serial . "`n" . result.Kind . "`n" . result.Id . "`n" . result.Name
    for name in result.Names
        payload .= "`n" . name
    SendResult(payload)
}
SendResult(text, magic := 0x54424631) {
    global ParentHwnd
    data := Buffer((StrLen(text) + 1) * 2, 0)
    StrPut(text, data)
    cds := Buffer(A_PtrSize * 3, 0)
    NumPut("uptr", magic, cds, 0)
    NumPut("uint", data.Size, cds, A_PtrSize)
    NumPut("ptr", data.Ptr, cds, A_PtrSize * 2)
    ignored := 0
    DllCall("user32\SendMessageTimeoutW", "ptr", ParentHwnd, "uint", 0x4A,
        "uptr", A_ScriptHwnd, "ptr", cds, "uint", 3, "uint", 150, "ptr*", &ignored, "ptr")
}
CheckParent() {
    global ParentHwnd, ParentPid
    if Desktop.Pid(ParentHwnd) != ParentPid
        ExitApp()
}

