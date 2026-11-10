#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk

class InstanceChecks {
    static Children := []
    static Lock := 0
    static Path := A_ScriptDir . "\InstanceFixture.ahk"
    static Result := A_ScriptDir . "\results\instance-state.txt"
    static Spawn(options := "") {
        command := '"' . A_AhkPath . '" /ErrorStdOut=UTF-8 "' . this.Path . '" "' . this.Result . '" ' . options
        Run(command, A_ScriptDir, "Hide", &pid)
        handle := DllCall("kernel32\OpenProcess", "uint", 0x100001, "int", false, "uint", pid, "ptr")
        if !handle
            throw Error("Could not open fixture process")
        child := {Pid: pid, Handle: handle}
        this.Children.Push(child)
        return child
    }
    static Alive(child) => DllCall("kernel32\WaitForSingleObject", "ptr", child.Handle, "uint", 0, "uint") = 0x102
    static WaitState(pid, count := 1) {
        deadline := Desktop.Tick() + 3500
        Loop {
            value := ""
            try value := FileRead(this.Result, "UTF-8")
            if value = pid . "," . count
                return
            if Desktop.Tick() > deadline
                throw Error("Fixture state did not arrive: " . value . "; expected " . pid . "," . count)
            Sleep(30)
        }
    }
    static Close(child) {
        previous := DetectHiddenWindows(true)
        try target := WinExist("ahk_pid " . child.Pid . " ahk_class AutoHotkey")
        finally DetectHiddenWindows(previous)
        if !target
            throw Error("Fixture control window missing")
        DllCall("user32\PostMessageW", "ptr", target, "uint", 0x10, "uptr", 0, "ptr", 0)
        if DllCall("kernel32\WaitForSingleObject", "ptr", child.Handle, "uint", 1000, "uint") != 0
            throw Error("Fixture did not exit gracefully")
    }
    static Reset() {
        output := FileOpen(this.Result, "w", "UTF-8")
        output.Write("starting"), output.Close()
    }
    static Cleanup() {
        if this.Lock {
            DllCall("kernel32\ReleaseMutex", "ptr", this.Lock)
            DllCall("kernel32\CloseHandle", "ptr", this.Lock)
            this.Lock := 0
        }
        for child in this.Children {
            if this.Alive(child)
                DllCall("kernel32\TerminateProcess", "ptr", child.Handle, "uint", 1)
            DllCall("kernel32\CloseHandle", "ptr", child.Handle)
        }
    }
    static Run() {
        DirCreate(A_ScriptDir . "\results")
        this.Reset()
        first := this.Spawn()
        this.WaitState(first.Pid)
        second := this.Spawn()
        this.WaitState(first.Pid, 2)
        if DllCall("kernel32\WaitForSingleObject", "ptr", second.Handle, "uint", 1000, "uint") != 0
            throw Error("Repeated launch remained alive")
        this.Close(first)

        ; Simulate a creator exiting before publishing its control window.
        this.Reset()
        this.Lock := DllCall("kernel32\CreateMutexW", "ptr", 0, "int", true,
            "wstr", FollowInstance.MutexName(this.Path), "ptr")
        if !this.Lock || A_LastError = 183
            throw Error("Could not create isolated startup lock")
        successor := this.Spawn()
        Sleep(250)
        DllCall("kernel32\ReleaseMutex", "ptr", this.Lock)
        DllCall("kernel32\CloseHandle", "ptr", this.Lock)
        this.Lock := 0
        this.WaitState(successor.Pid)
        this.Close(successor)

        ; Several candidates enter election together. Exactly one engine survives.
        this.Reset()
        burst := [], startAt := Desktop.Tick() + 500
        Loop 4
            burst.Push(this.Spawn("burst " . startAt))
        deadline := Desktop.Tick() + 3500
        Loop {
            survivors := []
            for child in burst {
                if this.Alive(child)
                    survivors.Push(child)
            }
            value := ""
            try value := FileRead(this.Result, "UTF-8")
            if survivors.Length = 1 && InStr(value, survivors[1].Pid . ",") = 1
                break
            if Desktop.Tick() > deadline
                throw Error("Concurrent launches did not elect one live instance; alive=" . survivors.Length)
            Sleep(30)
        }
        this.Close(survivors[1])

        ; Upgrade a real legacy fixture without the mutex or instance marker.
        this.Reset()
        legacy := this.Spawn("legacy")
        this.WaitState(legacy.Pid)
        upgraded := this.Spawn()
        this.WaitState(upgraded.Pid)
        if this.Alive(legacy)
            throw Error("Legacy instance was not closed")
        this.Close(upgraded)
    }
}

try {
    InstanceChecks.Run()
    InstanceChecks.Cleanup()
    FileAppend("single instance repeat-launch/same-PID/startup-takeover/concurrent-election/legacy-upgrade PASS`n", "*", "UTF-8")
    ExitApp(0)
} catch as exception {
    FileAppend("instance FAIL: " . exception.Message . " (line " . exception.Line . ")`n", "*", "UTF-8")
    InstanceChecks.Cleanup()
    ExitApp(1)
}