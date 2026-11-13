; A display connection policy and its lightweight desktop watcher. This file
; deliberately has no UIA client, positioning DLL, input hook or window moves.
class DisplayStartPolicy {
    __New(stableMs := 1500) {
        this.StableMs := Max(0,stableMs)
        this.Reset()
    }
    Reset() {
        this.Qualifying := false, this.Fired := false, this.Since := 0
    }
    Observe(count,now) {
        if count < 2 {
            this.Reset()
            return false
        }
        if !this.Qualifying {
            this.Qualifying := true, this.Since := now
        }
        if this.Fired
            return false
        if now < this.Since {
            this.Since := now
            return false
        }
        if now-this.Since < this.StableMs
            return false
        ; Consume this connection cycle even when the caller finds an existing
        ; engine or the launch fails. Closing the engine must remain effective.
        this.Fired := true
        return true
    }
}

class DisplayWatcher {
    __New(root,startupPath := "", logonTask := false) {
        this.Root := RTrim(root,"\")
        this.MainScript := this.Root . "\TaskbarFollow.ahk"
        this.WatchScript := this.Root . "\DisplayWatch.ahk"
        this.Runtime := this.Root . "\runtime\AutoHotkey64.exe"
        this.StartupPath := startupPath != "" ? startupPath : A_Startup . "\TaskbarFollow.lnk"
        this.LogonTask := logonTask, this.TaskCheckedAt := -10000, this.TaskEnabled := false
        this.Policy := DisplayStartPolicy()
        this.State := "waiting", this.LastReport := "", this.LastLaunchPid := 0
        this.Started := false, this.Stopped := false, this.Busy := false, this.DisconnectSeen := false
        this.CheckCallback := ObjBindMethod(this,"Check")
        this.ChangeCallback := ObjBindMethod(this,"Changed")
        this.EventCallback := ObjBindMethod(this,"Check")
        this.ExitCallback := ObjBindMethod(this,"Dispose")
    }
    Start() {
        if this.Started || this.Stopped
            return
        this.Started := true
        OnMessage(0x7E,this.ChangeCallback) ; WM_DISPLAYCHANGE
        OnMessage(0x219,this.ChangeCallback) ; WM_DEVICECHANGE
        OnMessage(0x218,this.ChangeCallback) ; WM_POWERBROADCAST
        OnExit(this.ExitCallback)
        ; Notifications give prompt updates; this low-frequency check also
        ; covers devices/providers which omit a useful display notification.
        SetTimer(this.CheckCallback,2000)
        this.Check()
    }
    Changed(*) {
        if !this.Started || this.Stopped
            return
        ; Remember a brief drop to one display even if the next notification
        ; reschedules Check after Windows has already restored the second display.
        try {
            if this.Count() < 2
                this.DisconnectSeen := true
        }
        SetTimer(this.EventCallback,-200)
    }
    Count() => SysGet(80) ; SM_CMONITORS: displays participating in the desktop
    Now() => DllCall("kernel32\GetTickCount64","uint64")
    Installed() {
        if this.LogonTask {
            now := this.Now()
            if now-this.TaskCheckedAt >= 10000 {
                if !HasProp(this,"TaskRegistration")
                    this.TaskRegistration := DisplayLogonTask(this.Root)
                this.TaskEnabled := this.TaskRegistration.Status() = "screen"
                this.TaskCheckedAt := now
            }
            return this.TaskEnabled
        }
        if !FileExist(this.StartupPath)
            return false
        try {
            FileGetShortcut(this.StartupPath,&target,&directory,&arguments)
            expected := '"' . this.WatchScript . '"'
            return target = this.Runtime && RTrim(directory,"\") = this.Root && Trim(arguments) = expected
        } catch {
            return false
        }
    }
    static MutexName(path) {
        ; Same identity as FollowInstance, without loading its UI/engine code.
        hash := 2166136261
        Loop Parse StrLower(path)
            hash := ((hash ^ Ord(A_LoopField)) * 16777619) & 0xffffffff
        return "Local\TaskbarFollow_" . Format("{:08X}",hash)
    }
    MainRunning() {
        ; Opening an existing object neither creates it nor takes ownership.
        ; Do not use the main program's Reveal handshake from the detector.
        handle := DllCall("kernel32\OpenMutexW","uint",0x100000,"int",false,
            "wstr",DisplayWatcher.MutexName(this.MainScript),"ptr")
        if handle {
            DllCall("kernel32\CloseHandle","ptr",handle)
            return true
        }
        errorCode := A_LastError
        if errorCode = 2 ; ERROR_FILE_NOT_FOUND
            return false
        if errorCode = 5 ; ERROR_ACCESS_DENIED: conservatively avoid a duplicate
            return true
        throw Error("Cannot inspect existing engine mutex: " . errorCode)
    }
    Launch() {
        if !FileExist(this.Runtime) || !FileExist(this.MainScript)
            throw Error("Portable runtime or main script is missing")
        Run('"' . this.Runtime . '" /ErrorStdOut=UTF-8 "' . this.MainScript . '" --background',
            this.Root,"Hide",&childPid)
        return childPid
    }
    Check(*) {
        if this.Stopped
            return "disabled"
        if this.Busy
            return this.State
        this.Busy := true
        try {
            if !this.Installed() {
                this.Report("disabled",-1,"startup shortcut removed or changed")
                this.Stop()
                return "disabled"
            }
            count := this.Count(), now := this.Now()
            if this.DisconnectSeen {
                this.DisconnectSeen := false
                this.Policy.Reset()
            }
            fire := this.Policy.Observe(count,now)
            if count < 2
                return this.Report("waiting",count)
            if !fire {
                if this.Policy.Fired
                    return this.State
                return this.Report("settling",count)
            }
            if this.MainRunning()
                return this.Report("already-running",count,"existing engine left untouched")
            this.LastLaunchPid := this.Launch()
            if !this.LastLaunchPid
                throw Error("Launch did not return a process identifier")
            return this.Report("launched",count,"pid=" . this.LastLaunchPid)
        } catch as failure {
            return this.Report("error",-1,failure.Message)
        } finally this.Busy := false
    }
    Report(state,count,detail := "") {
        this.State := state
        report := state . "; monitors=" . count . (detail != "" ? "; " . detail : "")
        if !(report == this.LastReport) {
            this.LastReport := report
            ; Log errors cannot disable screen detection or trigger repeated
            ; launch attempts. Record only state changes, not every poll.
            try this.Log(report)
        }
        return state
    }
    Log(text) {
        DirCreate(this.Root . "\logs")
        FileAppend(FormatTime(A_Now,"yyyy-MM-dd HH:mm:ss") . " " . text . "`n",
            this.Root . "\logs\DisplayWatch.log","UTF-8")
    }
    Dispose(*) {
        this.Stopped := true
        if !this.Started
            return
        this.Started := false
        SetTimer(this.CheckCallback,0)
        SetTimer(this.EventCallback,0)
        OnMessage(0x7E,this.ChangeCallback,0)
        OnMessage(0x219,this.ChangeCallback,0)
        OnMessage(0x218,this.ChangeCallback,0)
    }
    Stop(*) {
        this.Dispose()
        ExitApp(0)
    }
}
