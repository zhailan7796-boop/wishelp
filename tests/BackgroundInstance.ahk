#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk

class BackgroundChecks {
    static Count := 0, Children := [], Files := [], Directory := "", Fixture := ""
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Prepare() {
        SplitPath(A_ScriptDir,,&root)
        this.Directory := A_ScriptDir . "\results\background-instance-" . ProcessExist() . "-" . Desktop.Tick()
        DirCreate(this.Directory)
        this.Fixture := this.Directory . "\Fixture.ahk"
        source := FileRead(A_ScriptDir . "\BackgroundInstanceFixture.ahk","UTF-8")
        source := StrReplace(source,"#Include ..\lib\","#Include " . root . "\lib\")
        output := FileOpen(this.Fixture,"w","UTF-8")
        output.Write(source), output.Close()
        this.Files.Push(this.Fixture)
        this.Assert(FollowInstance.MutexName(this.Fixture) != FollowInstance.MutexName(root . "\TaskbarFollow.ahk"),"Fixture has an independent instance identity")
    }
    static Spawn(label,mode) {
        path := this.Directory . "\" . label . ".txt"
        this.Files.Push(path)
        command := '"' . A_AhkPath . '" /ErrorStdOut=UTF-8 "' . this.Fixture . '" "' . path . '" ' . mode . " " . ProcessExist()
        text := Buffer((StrLen(command)+1)*2,0), StrPut(command,text)
        startup := Buffer(104,0), process := Buffer(24,0)
        NumPut("uint",104,startup,0)
        NumPut("uint",1,startup,60), NumPut("ushort",0,startup,64)
        if !DllCall("kernel32\CreateProcessW","wstr",A_AhkPath,"ptr",text,"ptr",0,"ptr",0,
            "int",false,"uint",0x08000000,"ptr",0,"wstr",A_ScriptDir,"ptr",startup,"ptr",process,"int")
            throw Error("Cannot create owned background instance fixture: " . A_LastError)
        child := {Pid:NumGet(process,16,"uint"),Handle:NumGet(process,0,"ptr"),Result:path,Hwnd:0}
        DllCall("kernel32\CloseHandle","ptr",NumGet(process,8,"ptr"))
        this.Children.Push(child)
        return child
    }
    static Alive(child) => DllCall("kernel32\WaitForSingleObject","ptr",child.Handle,"uint",0,"uint") = 0x102
    static Read(child) {
        value := ""
        try value := FileRead(child.Result,"UTF-8")
        fields := StrSplit(value,",")
        if fields.Length != 6
            return 0
        try {
            state := {Pid:Integer(fields[1]),Hwnd:Integer(fields[2]),Requests:Integer(fields[3]),Shows:Integer(fields[4]),Owns:Integer(fields[5]),Visible:Integer(fields[6])}
            if state.Pid != child.Pid
                return 0
            child.Hwnd := state.Hwnd
            return state
        } catch {
            return 0
        }
    }
    static WaitOwner(child,requests := 0,shows := 0) {
        deadline := Desktop.Tick()+3500
        Loop {
            state := this.Read(child)
            if IsObject(state) && state.Requests = requests && state.Shows = shows
                return state
            if !this.Alive(child) || Desktop.Tick()>deadline
                throw Error("Owned background fixture state did not arrive: " . child.Pid)
            Sleep(20)
        }
    }
    static WaitRejected(child,temporaryOwnership := 0) {
        this.Assert(DllCall("kernel32\WaitForSingleObject","ptr",child.Handle,"uint",1500,"uint") = 0,"Existing-owner contender exits promptly")
        code := 0
        this.Assert(DllCall("kernel32\GetExitCodeProcess","ptr",child.Handle,"uint*",&code) && code = 0,"Contender exits without a startup error")
        value := FileRead(child.Result,"UTF-8")
        this.Assert(value == "rejected," . child.Pid . "," . temporaryOwnership,"Contender reports its own acquisition result")
    }
    static MutexOwned() {
        handle := DllCall("kernel32\OpenMutexW","uint",0x100000,"int",false,"wstr",FollowInstance.MutexName(this.Fixture),"ptr")
        this.Assert(handle,"Owner mutex remains available")
        try this.Assert(DllCall("kernel32\WaitForSingleObject","ptr",handle,"uint",0,"uint") = 0x102,"Existing fixture retains ownership")
        finally DllCall("kernel32\CloseHandle","ptr",handle)
    }
    static Close(child) {
        if !this.Alive(child)
            return
        if !child.Hwnd || Desktop.Pid(child.Hwnd) != child.Pid
            throw Error("Owned fixture control window is unavailable")
        this.Assert(DllCall("user32\GetPropW","ptr",child.Hwnd,"wstr","TaskbarFollow.BackgroundFixture","ptr") = 0x42474931,"Cleanup targets only the owned fixture")
        DllCall("user32\PostMessageW","ptr",child.Hwnd,"uint",0x10,"ptr",0,"ptr",0)
        this.Assert(DllCall("kernel32\WaitForSingleObject","ptr",child.Handle,"uint",1000,"uint") = 0,"Owned fixture closes cleanly")
    }
    static Run() {
        this.Prepare()
        owner := this.Spawn("owner","owner")
        initial := this.WaitOwner(owner)
        this.Assert(initial.Owns && !initial.Visible,"Initial owner is hidden and owns the mutex")
        quiet := this.Spawn("quiet-contender","quiet")
        this.WaitRejected(quiet)
        Sleep(80)
        state := this.WaitOwner(owner)
        this.Assert(this.Alive(owner) && state.Pid = initial.Pid,"Quiet contender preserves the owner process")
        this.Assert(state.Requests = 0 && state.Shows = 0,"Quiet contender sends no reveal and schedules no status display")
        this.Assert(state.Hwnd = initial.Hwnd && state.Visible = initial.Visible,"Quiet contender preserves the hidden control window")
        this.Assert(DllCall("user32\GetPropW","ptr",state.Hwnd,"wstr","TaskbarFollow.InstanceMarker","ptr") = FollowInstance.Magic,"Quiet contender preserves the established instance marker")
        this.MutexOwned()

        normal := this.Spawn("normal-contender","normal")
        this.WaitRejected(normal)
        state := this.WaitOwner(owner,1,1)
        this.Assert(state.Pid = owner.Pid && this.Alive(owner),"Normal launch keeps the same owner")
        this.Assert(state.Requests = 1 && state.Shows = 1,"Default launch retains the actual reveal-message behavior")
        this.Close(owner)

        fresh := this.Spawn("fresh-quiet-owner","quiet-owner")
        state := this.WaitOwner(fresh)
        this.Assert(state.Owns && !state.Requests && !state.Shows,"Quiet launch without an existing owner acquires ownership")
        this.Assert(!state.Visible,"Fresh quiet owner does not show a window")
        this.MutexOwned()
        this.Close(fresh)

        marked := this.Spawn("unresponsive-owner","unresponsive")
        original := this.WaitOwner(marked)
        quiet := this.Spawn("quiet-unresponsive-contender","quiet")
        this.WaitRejected(quiet)
        state := this.WaitOwner(marked)
        this.Assert(this.Alive(marked) && state.Pid = original.Pid && state.Hwnd = original.Hwnd,"Quiet launch leaves a marked unresponsive owner untouched")
        this.Assert(!state.Requests && !state.Shows && state.Visible = original.Visible,"Quiet launch does not attempt reveal when an existing marker is sufficient")
        this.MutexOwned()
        this.Close(marked)

        legacy := this.Spawn("legacy-owner","legacy")
        original := this.WaitOwner(legacy)
        this.Assert(!original.Owns && !DllCall("user32\GetPropW","ptr",original.Hwnd,"wstr","TaskbarFollow.InstanceMarker","ptr"),"Legacy fixture has neither a mutex owner nor an instance marker")
        quiet := this.Spawn("quiet-legacy-contender","quiet")
        ; With no pre-existing mutex, this contender temporarily wins election.
        ; It must still leave the older process alone and release its own lock.
        this.WaitRejected(quiet,1)
        state := this.WaitOwner(legacy)
        this.Assert(this.Alive(legacy) && state.Pid = original.Pid && state.Hwnd = original.Hwnd,"Quiet launch never closes or upgrades a legacy fixture")
        this.Assert(!state.Requests && !state.Shows && state.Visible = original.Visible,"Quiet legacy detection has no reveal or visibility side effects")
        handle := DllCall("kernel32\OpenMutexW","uint",0x100000,"int",false,"wstr",FollowInstance.MutexName(this.Fixture),"ptr")
        if handle
            DllCall("kernel32\CloseHandle","ptr",handle)
        this.Assert(!handle,"Rejected quiet legacy launch releases its temporary mutex")
        this.Close(legacy)
    }
    static Cleanup() {
        for child in this.Children {
            if this.Alive(child)
                DllCall("kernel32\TerminateProcess","ptr",child.Handle,"uint",1)
            DllCall("kernel32\CloseHandle","ptr",child.Handle)
        }
        ; The list contains only files created under this run's unique directory.
        for path in this.Files {
            if FileExist(path)
                FileDelete(path)
        }
        if this.Directory != "" && DirExist(this.Directory)
            DirDelete(this.Directory)
    }
}

exitCode := 0
try {
    BackgroundChecks.Run()
    FileAppend("PASS " . BackgroundChecks.Count . " quiet/background instance/ownership/reveal assertions`n","*","UTF-8")
} catch as failure {
    FileAppend("FAIL " . failure.Message . " (line " . failure.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally BackgroundChecks.Cleanup()
ExitApp(exitCode)
