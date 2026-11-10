; Single-instance handoff: repeated launches reveal the running status window instead of restarting it.
; Automated tests are explicitly excluded from this protocol and cannot stop the user's running copy.
class FollowInstance {
    static Handle := 0
    static OwnsMutex := false
    static Magic := 0x54424632
    static Acquire(reveal := true) {
        ; Mark candidates before election so the winner never mistakes a simultaneous
        ; new launch for the legacy tray-only process and closes it as an upgrade.
        DllCall("user32\SetPropW", "ptr", A_ScriptHwnd, "wstr", "TaskbarFollow.Starting", "ptr", 1)
        this.Handle := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", true,
            "wstr", this.MutexName(A_ScriptFullPath), "ptr")
        exists := A_LastError = 183
        if !this.Handle
            throw Error("无法创建运行实例锁。")
        this.OwnsMutex := !exists
        OnExit(FollowInstance.Release)
        deadline := Desktop.Tick() + 5000
        while !this.OwnsMutex {
            existing := this.FindExisting()
            if existing {
                if !reveal
                    return false
                DllCall("user32\AllowSetForegroundWindow", "uint", Desktop.Pid(existing))
                reply := 0
                delivered := DllCall("user32\SendMessageTimeoutW", "ptr", existing, "uint", 0x8053,
                    "uptr", 0, "ptr", 0, "uint", 3, "uint", 250, "ptr*", &reply, "ptr")
                if delivered && reply = this.Magic
                    return false
                if DllCall("user32\GetPropW", "ptr", existing, "wstr", "TaskbarFollow.InstanceMarker", "ptr") {
                    MsgBox("随屏已在运行，但状态窗口暂未响应。请稍后再次点击快捷方式。", "随屏", "Icon!")
                    return false
                }
            }
            ; Recover if the elected process exits during startup. A live owner is
            ; never replaced merely because its window has not appeared yet.
            waitResult := DllCall("kernel32\WaitForSingleObject", "ptr", this.Handle, "uint", 0, "uint")
            if waitResult = 0 || waitResult = 0x80 {
                this.OwnsMutex := true
                break
            }
            if waitResult != 0x102
                throw Error("无法检查运行实例锁。")
            if Desktop.Tick() >= deadline {
                if !reveal
                    return false
                MsgBox("随屏正在启动，请稍候再点击快捷方式。", "随屏", "Iconi")
                return false
            }
            Sleep(50)
        }
        ; Only the elected owner can replace an older tray-only version.
        existing := this.FindExisting()
        if existing {
            if !reveal
                return false
            if DllCall("user32\GetPropW", "ptr", existing, "wstr", "TaskbarFollow.InstanceMarker", "ptr")
                throw Error("随屏已有实例正在退出，请稍后重试。")
            DllCall("user32\PostMessageW", "ptr", existing, "uint", 0x10, "uptr", 0, "ptr", 0)
            Loop 40 {
                if !DllCall("user32\IsWindow", "ptr", existing)
                    break
                Sleep(50)
            }
            if DllCall("user32\IsWindow", "ptr", existing)
                throw Error("旧版随屏暂未退出，请先从托盘退出旧版再启动。")
        }
        OnMessage(0x8053, FollowInstance.Reveal)
        DllCall("user32\SetPropW", "ptr", A_ScriptHwnd, "wstr", "TaskbarFollow.InstanceMarker", "ptr", this.Magic)
        return true
    }
    static MutexName(path) {
        hash := 2166136261
        Loop Parse StrLower(path)
            hash := ((hash ^ Ord(A_LoopField)) * 16777619) & 0xffffffff
        return "Local\TaskbarFollow_" . Format("{:08X}", hash)
    }
    static FindExisting() {
        previous := DetectHiddenWindows(true)
        try {
            prefix := StrLower(A_ScriptFullPath . " - AutoHotkey")
            for hwnd in WinGetList("ahk_class AutoHotkey") {
                if hwnd = A_ScriptHwnd || DllCall("user32\GetPropW", "ptr", hwnd, "wstr", "TaskbarFollow.TestOnly", "ptr")
                    continue
                if DllCall("user32\GetPropW", "ptr", hwnd, "wstr", "TaskbarFollow.Starting", "ptr")
                    && !DllCall("user32\GetPropW", "ptr", hwnd, "wstr", "TaskbarFollow.InstanceMarker", "ptr")
                    continue
                if SubStr(StrLower(Desktop.Title(hwnd)), 1, StrLen(prefix)) = prefix
                    return hwnd
            }
            return 0
        } finally {
            DetectHiddenWindows(previous)
        }
    }
    static Reveal(*) {
        global Follow
        if IsSet(Follow) && IsObject(Follow)
            SetTimer(ObjBindMethod(Follow, "ShowStatus"), -1)
        return FollowInstance.Magic
    }
    static Release(*) {
        if FollowInstance.Handle {
            if FollowInstance.OwnsMutex
                DllCall("kernel32\ReleaseMutex", "ptr", FollowInstance.Handle)
            DllCall("kernel32\CloseHandle", "ptr", FollowInstance.Handle)
            FollowInstance.Handle := 0
            FollowInstance.OwnsMutex := false
        }
    }
}
