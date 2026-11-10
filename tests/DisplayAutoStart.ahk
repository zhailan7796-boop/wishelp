#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\Instance.ahk
#Include ..\lib\DisplayAutoStart.ahk
#Include ..\lib\DisplayStartup.ahk

; All connection changes below are simulated. No monitor settings, startup
; folders, input hooks, real engine instance or user windows are touched.
class DisplayStartChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual,expected,label) => this.Assert(actual == expected,label . " (actual=" . actual . ", expected=" . expected . ")")
}

class DisplayWatcherFixture extends DisplayWatcher {
    __New() {
        this.TestCount := 1, this.TestNow := 0, this.TestInstalled := true, this.TestRunning := false
        this.TestFailCount := false, this.TestFailRunning := false, this.TestFailLaunch := false, this.TestFailLogs := false
        this.TestCountReads := 0, this.TestRunningReads := 0, this.TestLaunches := 0, this.TestStops := 0
        this.TestLogs := []
        super.__New(A_ScriptDir,A_ScriptDir . "\results\unused-display-startup.lnk")
    }
    Installed() => this.TestInstalled
    Count() {
        this.TestCountReads += 1
        if this.TestFailCount
            throw Error("Expected owned monitor-read failure")
        return this.TestCount
    }
    Now() => this.TestNow
    MainRunning() {
        this.TestRunningReads += 1
        if this.TestFailRunning
            throw Error("Expected owned instance-check failure")
        return this.TestRunning
    }
    Launch() {
        this.TestLaunches += 1
        if this.TestFailLaunch
            throw Error("Expected owned launch failure")
        return true
    }
    Stop() => this.TestStops += 1
    Log(text) {
        if this.TestFailLogs
            throw Error("Expected owned log-write failure")
        this.TestLogs.Push(text)
    }
}

ownedRoot := A_ScriptDir . "\results\DisplayAutoStart-" . DllCall("kernel32\GetCurrentProcessId","uint") . "-" . Desktop.Tick()
ownedShortcut := ownedRoot . "\startup.lnk", ownedMutex := 0, exitCode := 0
try {
    ; Real boundaries: zero is a valid tick, and settling is elapsed time,
    ; independent of the number or frequency of display notifications.
    policy := DisplayStartPolicy(1500)
    DisplayStartChecks.Assert(!policy.Observe(1,0),"Initial single screen does not start the engine")
    DisplayStartChecks.Assert(!policy.Observe(1,60000),"A long single-screen session remains idle")
    DisplayStartChecks.Assert(!policy.Observe(2,60010),"A newly connected second screen waits for stability")
    DisplayStartChecks.Assert(!policy.Observe(2,61509),"The stability window is not rounded early")
    DisplayStartChecks.Assert(policy.Observe(2,61510),"The stable second screen starts once at the boundary")
    repeated := 0
    Loop 100
        repeated += policy.Observe(2,62000+A_Index*20) ? 1 : 0
    DisplayStartChecks.Equal(repeated,0,"Repeated unchanged notifications do not relaunch")
    DisplayStartChecks.Assert(!policy.Observe(3,65000),"Adding another screen within the same multi-screen cycle does not duplicate launch")
    DisplayStartChecks.Assert(!policy.Observe(1,66000),"Disconnecting down to one screen rearms without starting")
    DisplayStartChecks.Assert(!policy.Observe(2,67000),"Reconnection starts a new stability window")
    DisplayStartChecks.Assert(policy.Observe(2,68500),"A later stable reconnection may start again")
    DisplayStartChecks.Assert(!policy.Observe(0,69000),"No available screen is treated as disconnected")
    DisplayStartChecks.Assert(!policy.Observe(2,70000),"Recovery from no screens settles again")
    DisplayStartChecks.Assert(policy.Observe(2,71500),"A stable multi-screen recovery may start")

    policy := DisplayStartPolicy(1500)
    DisplayStartChecks.Assert(!policy.Observe(2,0),"Already-connected screens at startup settle from tick zero")
    DisplayStartChecks.Assert(!policy.Observe(3,1499),"The initial stability period survives a second qualified count")
    DisplayStartChecks.Assert(policy.Observe(2,1500),"Already-connected screens start without requiring a physical replug")
    DisplayStartChecks.Assert(!policy.Observe(2,50000),"Startup detection fires only once in that connection cycle")

    policy := DisplayStartPolicy(1500)
    for point in [{Count:1,At:0},{Count:2,At:100},{Count:1,At:1000},{Count:2,At:1100},
        {Count:1,At:2500},{Count:2,At:2600},{Count:0,At:3900},{Count:2,At:4000},{Count:2,At:5499}]
        DisplayStartChecks.Assert(!policy.Observe(point.Count,point.At),"Transient display changes do not start at tick " . point.At)
    DisplayStartChecks.Assert(policy.Observe(2,5500),"Only the final uninterrupted connection starts")

    watcher := DisplayWatcherFixture()
    DisplayStartChecks.Equal(watcher.Check(),"waiting","Watcher waits while only one screen is available")
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"Single-screen watcher creates no main process")
    DisplayStartChecks.Equal(watcher.TestRunningReads,0,"Single-screen watcher does not query the engine mutex")
    watcher.TestCount := 2
    DisplayStartChecks.Equal(watcher.Check(),"settling","The real watcher waits for a stable connection")
    watcher.TestNow := 1499
    watcher.Check()
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"Display events cannot bypass the stability window")
    watcher.TestNow := 1500
    DisplayStartChecks.Equal(watcher.Check(),"launched","Stable connection reaches the real launch branch")
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"The launch callback is invoked once")
    Loop 100 {
        watcher.TestNow += 2000
        watcher.Check()
    }
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"An unchanged connection never repeatedly launches")

    ; The watcher consumes an already-running connection without sending a
    ; reveal message. A manual exit is respected until a fresh connection.
    watcher := DisplayWatcherFixture(), watcher.TestCount := 2, watcher.TestRunning := true
    watcher.Check()
    watcher.TestNow := 1500
    DisplayStartChecks.Equal(watcher.Check(),"already-running","An existing main instance is recognized")
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"An existing main instance is neither duplicated nor revealed")
    DisplayStartChecks.Equal(watcher.TestRunningReads,1,"The instance check occurs only when the connection is ready")
    watcher.TestRunning := false, watcher.TestNow := 50000
    watcher.Check()
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"Manual engine exit in the same connection cycle is respected")
    watcher.TestCount := 1, watcher.TestNow := 51000
    watcher.Check()
    watcher.TestCount := 2, watcher.TestNow := 52000
    watcher.Check()
    watcher.TestNow := 53500
    DisplayStartChecks.Equal(watcher.Check(),"launched","A fresh reconnection may launch after a manual exit")
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"A fresh reconnection invokes one launch")

    ; Failed launch is bounded to one attempt in a connection cycle. A later
    ; reconnection offers a retry without an uncontrolled background loop.
    watcher := DisplayWatcherFixture(), watcher.TestCount := 2, watcher.TestFailLaunch := true
    watcher.Check()
    watcher.TestNow := 1500
    DisplayStartChecks.Equal(watcher.Check(),"error","Launch failure is reported")
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"The failed launch was attempted exactly once")
    DisplayStartChecks.Assert(watcher.TestLogs.Length>0,"Launch failure is recorded")
    Loop 100 {
        watcher.TestNow += 5000
        watcher.Check()
    }
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"Failed launch cannot become an infinite same-cycle retry")
    watcher.TestCount := 1
    watcher.Check()
    watcher.TestCount := 2, watcher.TestNow += 100
    watcher.Check()
    watcher.TestNow += 1500
    DisplayStartChecks.Equal(watcher.Check(),"error","A reconnection permits a new bounded attempt")
    DisplayStartChecks.Equal(watcher.TestLaunches,2,"Exactly one retry occurs in the second connection cycle")

    watcher := DisplayWatcherFixture(), watcher.TestInstalled := false
    DisplayStartChecks.Equal(watcher.Check(),"disabled","Removing the managed startup entry disables detection")
    DisplayStartChecks.Equal(watcher.TestStops,1,"A disabled watcher stops itself")
    DisplayStartChecks.Equal(watcher.TestCountReads,0,"Disabled detection does not continue querying displays")
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"Disabled detection cannot launch the main process")
    watcher := DisplayWatcherFixture(), watcher.TestFailCount := true
    DisplayStartChecks.Equal(watcher.Check(),"error","Monitor query failure is reported without launching")
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"Unavailable monitor information fails closed")
    watcher := DisplayWatcherFixture(), watcher.TestCount := 2, watcher.TestFailRunning := true
    watcher.Check()
    watcher.TestNow := 1500
    DisplayStartChecks.Equal(watcher.Check(),"error","An uncertain instance query is reported")
    DisplayStartChecks.Equal(watcher.TestLaunches,0,"An uncertain instance query never duplicates the engine")
    watcher := DisplayWatcherFixture(), watcher.TestCount := 2, watcher.TestFailLaunch := true, watcher.TestFailLogs := true
    watcher.Check()
    watcher.TestNow := 1500
    DisplayStartChecks.Equal(watcher.Check(),"error","A log failure cannot escape a failed launch report")
    DisplayStartChecks.Equal(watcher.TestLaunches,1,"A launch with unavailable logging is still bounded")
    watcher.TestInstalled := false
    DisplayStartChecks.Equal(watcher.Check(),"disabled","Logging failure cannot block disabling the watcher")
    DisplayStartChecks.Equal(watcher.TestStops,1,"Disabled watcher stops even if its log cannot be written")

    ; Real named-mutex probing on an isolated, unique engine path. A probe must
    ; not create a mutex or retain an extra handle to one that already exists.
    for path in [A_ScriptDir . "\TaskbarFollow.ahk",StrUpper(A_ScriptDir . "\TaskbarFollow.ahk"),"D:\Owned test 路径\TaskbarFollow.ahk"]
        DisplayStartChecks.Equal(DisplayWatcher.MutexName(path),FollowInstance.MutexName(path),"Detector agrees with the existing engine mutex identity for " . path)
    DirCreate(ownedRoot)
    DirCreate(ownedRoot . "\runtime")
    FileAppend("; Inert test placeholder, never executed",ownedRoot . "\TaskbarFollow.ahk","UTF-8")
    FileAppend("; Inert watcher placeholder, never executed",ownedRoot . "\DisplayWatch.ahk","UTF-8")
    FileAppend("Inert file, never executed",ownedRoot . "\runtime\AutoHotkey64.exe","UTF-8")
    probe := DisplayWatcher(ownedRoot,ownedShortcut)
    mutexName := FollowInstance.MutexName(ownedRoot . "\TaskbarFollow.ahk")
    DisplayStartChecks.Assert(!probe.MainRunning(),"An absent isolated engine is not reported running")
    absent := DllCall("kernel32\OpenMutexW","uint",0x100000,"int",false,"wstr",mutexName,"ptr")
    DisplayStartChecks.Assert(!absent && A_LastError = 2,"The running probe does not create a mutex")
    ownedMutex := DllCall("kernel32\CreateMutexW","ptr",0,"int",false,"wstr",mutexName,"ptr")
    DisplayStartChecks.Assert(ownedMutex && A_LastError != 183,"The fixture owns a unique named mutex")
    DisplayStartChecks.Assert(probe.MainRunning(),"An existing isolated engine mutex is recognized")
    DllCall("kernel32\CloseHandle","ptr",ownedMutex), ownedMutex := 0
    DisplayStartChecks.Assert(!probe.MainRunning(),"Running checks do not leak a handle that keeps a dead engine alive")

    ; Only a shortcut to this watcher is an enabled connection detector. All
    ; files are in the owned workspace fixture, not the Windows Startup folder.
    DisplayStartChecks.Assert(!probe.Installed(),"An absent startup entry is disabled")
    runtimePath := ownedRoot . "\runtime\AutoHotkey64.exe"
    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot,'"' . ownedRoot . '\DisplayWatch.ahk"')
    DisplayStartChecks.Assert(probe.Installed(),"The exact owned watcher shortcut is accepted")
    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot,'"' . ownedRoot . '\TaskbarFollow.ahk"')
    DisplayStartChecks.Assert(!probe.Installed(),"A legacy unconditional-engine shortcut does not enable the watcher")
    FileCreateShortcut(A_WinDir . "\System32\notepad.exe",ownedShortcut,ownedRoot,'"' . ownedRoot . '\DisplayWatch.ahk"')
    DisplayStartChecks.Assert(!probe.Installed(),"A different executable cannot masquerade as the detector")
    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot,'"' . ownedRoot . '\DisplayWatch.ahk" extra')
    DisplayStartChecks.Assert(!probe.Installed(),"Unexpected shortcut arguments do not enable detection")
    FileDelete(ownedShortcut)
    FileAppend("This is not a shell shortcut",ownedShortcut,"UTF-8")
    DisplayStartChecks.Assert(!probe.Installed(),"A damaged startup shortcut is rejected")

    ; Installation is exercised only against the same owned local shortcut.
    ; startDetector=false is essential: the inert executable is never run.
    FileDelete(ownedShortcut)
    DirCreate(ownedRoot . "\lib")
    FileAppend("; Inert dependency, never executed",ownedRoot . "\lib\DisplayAutoStart.ahk","UTF-8")
    FileAppend("Inert icon placeholder, never executed",ownedRoot . "\Start.exe","UTF-8")
    DisplayStartChecks.Equal(DisplayStartup.Set(true,ownedRoot,ownedShortcut,false),0,"Installation without detector launch returns no PID")
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"Installer writes an enabled connection detector")
    FileGetShortcut(ownedShortcut,&installedTarget,&installedDirectory,&installedArguments)
    DisplayStartChecks.Assert(DisplayStartup.SamePath(installedTarget,runtimePath),"Installed shortcut targets only the portable runtime")
    DisplayStartChecks.Assert(DisplayStartup.SamePath(installedDirectory,ownedRoot),"Installed shortcut retains its intended working directory")
    DisplayStartChecks.Equal(installedArguments,'"' . ownedRoot . '\DisplayWatch.ahk"',"Installed shortcut runs the detector rather than the full engine")
    DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
    shortcutCount := 0
    Loop Files ownedRoot . "\*.lnk", "F"
        shortcutCount += 1
    DisplayStartChecks.Equal(shortcutCount,1,"Repeated enable does not create duplicate startup entries")
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"Repeated enable preserves the managed entry")
    unrelatedShortcut := ownedRoot . "\unrelated.lnk"
    FileCreateShortcut(A_WinDir . "\System32\notepad.exe",unrelatedShortcut,ownedRoot,"Owned unrelated sentinel")
    DisplayStartup.Set(false,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(!FileExist(ownedShortcut),"Disable removes the managed detector entry")
    DisplayStartChecks.Assert(FileExist(unrelatedShortcut),"Disable leaves other startup entries alone")
    DisplayStartup.Set(false,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(!FileExist(ownedShortcut),"Repeated disable is harmless")

    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot,'"' . ownedRoot . '\TaskbarFollow.ahk"')
    DisplayStartChecks.Equal(DisplayStartup.Shortcut(ownedRoot,ownedShortcut),"legacy","A prior direct-main entry is recognized as legacy")
    DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"A direct-main entry migrates to the connection detector")
    DisplayStartChecks.Assert(probe.Installed(),"Installer and running watcher agree on the migrated entry")
    DisplayStartup.Set(false,ownedRoot,ownedShortcut,false)
    FileCreateShortcut(ownedRoot . "\Start.exe",ownedShortcut,ownedRoot)
    DisplayStartChecks.Equal(DisplayStartup.Shortcut(ownedRoot,ownedShortcut),"legacy","A prior launcher entry is recognized as legacy")
    DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"A launcher entry migrates to the connection detector")
    DisplayStartup.Set(false,ownedRoot,ownedShortcut,false)

    FileCreateShortcut(A_WinDir . "\System32\notepad.exe",ownedShortcut,ownedRoot,"Owned foreign sentinel")
    FileGetShortcut(ownedShortcut,&foreignTarget,&foreignDirectory,&foreignArguments)
    for enabled in [true,false] {
        refused := false
        try DisplayStartup.Set(enabled,ownedRoot,ownedShortcut,false)
        catch
            refused := true
        DisplayStartChecks.Assert(refused,"A same-name foreign entry is never overwritten or deleted")
        FileGetShortcut(ownedShortcut,&afterTarget,&afterDirectory,&afterArguments)
        DisplayStartChecks.Equal(afterTarget,foreignTarget,"Foreign shortcut target is preserved")
        DisplayStartChecks.Equal(afterDirectory,foreignDirectory,"Foreign shortcut working directory is preserved")
        DisplayStartChecks.Equal(afterArguments,foreignArguments,"Foreign shortcut arguments are preserved")
    }
    FileDelete(ownedShortcut)

    for relative in ["runtime\AutoHotkey64.exe","DisplayWatch.ahk","TaskbarFollow.ahk","lib\DisplayAutoStart.ahk"] {
        component := ownedRoot . "\" . relative, backup := component . ".bak"
        FileCopy(component,backup)
        FileDelete(component)
        refused := false, refusedInstall := false
        try DisplayStartup.Validate(ownedRoot)
        catch
            refused := true
        try DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
        catch
            refusedInstall := true
        FileMove(backup,component)
        DisplayStartChecks.Assert(refused,"Missing component is rejected: " . relative)
        DisplayStartChecks.Assert(refusedInstall && !FileExist(ownedShortcut),"Failed validation leaves no partial startup entry: " . relative)
    }
    DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"Repaired components can be installed normally")
    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot,'"' . ownedRoot . '\DisplayWatch.ahk" extra')
    DisplayStartChecks.Assert(!DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"Installer status rejects unexpected arguments")
    FileCreateShortcut(runtimePath,ownedShortcut,ownedRoot . "\runtime",'"' . ownedRoot . '\DisplayWatch.ahk"')
    DisplayStartChecks.Assert(!DisplayStartup.IsEnabled(ownedRoot,ownedShortcut),"Installer status rejects an unintended working directory")
    DisplayStartChecks.Assert(!probe.Installed(),"Watcher agrees that an unintended working directory is disabled")
    DisplayStartup.Set(true,ownedRoot,ownedShortcut,false)
    DisplayStartChecks.Assert(DisplayStartup.IsEnabled(ownedRoot,ownedShortcut) && probe.Installed(),"The managed entry with a wrong working directory can be repaired")

    FileAppend("PASS " . DisplayStartChecks.Count . " display-connection startup/debounce/ownership/disabled-state assertions`n","*","UTF-8")
} catch as failure {
    FileAppend("FAIL " . failure.Message . " (line " . failure.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally {
    if ownedMutex
        DllCall("kernel32\CloseHandle","ptr",ownedMutex)
    for path in [ownedShortcut,ownedRoot . "\unrelated.lnk",ownedRoot . "\Start.exe",ownedRoot . "\runtime\AutoHotkey64.exe",ownedRoot . "\TaskbarFollow.ahk",ownedRoot . "\DisplayWatch.ahk",ownedRoot . "\lib\DisplayAutoStart.ahk",
        ownedRoot . "\runtime\AutoHotkey64.exe.bak",ownedRoot . "\TaskbarFollow.ahk.bak",ownedRoot . "\DisplayWatch.ahk.bak",ownedRoot . "\lib\DisplayAutoStart.ahk.bak"] {
        if FileExist(path)
            FileDelete(path)
    }
    if DirExist(ownedRoot . "\runtime")
        DirDelete(ownedRoot . "\runtime")
    if DirExist(ownedRoot . "\lib")
        DirDelete(ownedRoot . "\lib")
    if DirExist(ownedRoot)
        DirDelete(ownedRoot)
}
ExitApp(exitCode)
