#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\NativeEngine.ahk

; Inject OS observations and the native snapshot only. Exercise the production
; click gate, candidate selection, bounded move and confirmation code without
; hooks, timers, input or application windows.
class CompatibilityChecks {
    static Count := 0
    static StopEngine := 0, StoppedTimerFirst := false, AbiCount := 2
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Monitor(handle) => {Handle:handle,Device:"Fixture" . handle,
        Bounds:ScreenRect((handle-1)*1920,0,handle*1920,1080),
        Work:ScreenRect((handle-1)*1920,0,handle*1920,1040)}
    static Window(hwnd := 11,pid := 101) {
        SplitPath(A_AhkPath,&exe)
        return {Hwnd:hwnd,Data:{Pid:pid,AppId:"",Path:A_AhkPath,Exe:exe},
            Eligible:true,Visible:true,Minimized:false,Monitor:this.Monitor(1)}
    }
    static Stable(fixture) {
        fixture.CompatibilityTick()
        fixture.Now += 50, fixture.CompatibilityTick()
        fixture.Now += 50, fixture.CompatibilityTick()
    }
    static NoRequest(fixture,label) {
        this.Stable(fixture)
        this.Assert(fixture.Requests.Length = 0,label)
    }
    static NativeStop(timeout) {
        this.StoppedTimerFirst := !this.StopEngine.Scheduled
        return 1
    }
    static NativeStatus(status,bytes) {
        if bytes != 168
            return 0
        NumPut("uint64",3,status,48)
        NumPut("uint64",4,status,56)
        return 1
    }
    static NativeIntent(serial,snapshot,bytes) {
        if serial != 7 || bytes != 3136
            return 0
        NumPut("uint",5,"uint",this.AbiCount,snapshot,24)
        StrPut("Fixture.App",snapshot+32,256)
        StrPut(A_AhkPath,snapshot+544,1024)
        NumPut("uint64",11,"uint",101,snapshot,2592)
        NumPut("uint64",12,"uint",102,snapshot,2608)
        NumPut("uint64",2,"uint64",900,"uint64",9000,"uint",7,snapshot,3104)
        return 1
    }
}
class CompatibilityOwner {
    Enabled := true, SuccessfulMoves := 0, Messages := [], Logs := []
    __New() {
        this.Identity := WindowIdentity("",false)
        this.Identity.Mappings["Fixture.App"] := A_AhkPath
    }
    ReportActivity(text) => this.Messages.Push(text)
    Log(text) => this.Logs.Push(text)
}
class CompatibilityFixture extends NativeEngine {
    __New(warm := true) {
        this.Owner := CompatibilityOwner(), this.Handle := 1, this.Compatibility := 0, this.CompatibilityMoves := 0
        this.Now := 1000, this.Valid := true, this.Selected := CompatibilityChecks.Window()
        this.Intent := {Serial:7,Flags:5,Id:"Fixture.App",Path:A_AhkPath,Monitor:2,Released:900,Expires:9000,
            Candidates:warm ? [{Hwnd:11,Pid:101}] : []}
        this.Requests := [], this.Scheduled := false, this.ScheduleStarts := 0, this.NativeCancels := 0
        this.MoveResult := "requested", this.IntentReads := 0, this.CancelAtRead := 0
        this.ForegroundReads := 0, this.InterruptAtForeground := 0, this.InterruptKind := ""
        this.ReplaceAtRead := 0, this.ReplaceDuringCompare := false, this.ReplaceNativeOnlyDuringCompare := false
        this.CompareCritical := 0, this.MoveCritical := 0
    }
    ReadCompatibilityIntent(serial) {
        this.IntentReads += 1
        if this.ReplaceAtRead && this.IntentReads = this.ReplaceAtRead {
            previous := this.Intent
            this.ReplaceAtRead := 0
            this.ReplaceIntent()
            return previous
        }
        if this.CancelAtRead && this.IntentReads = this.CancelAtRead {
            this.Valid := false
            return 0
        }
        return this.Valid && serial = this.Intent.Serial ? this.Intent : 0
    }
    CompatibilityNow() => this.Now
    CompatibilityMonitor(handle) => CompatibilityChecks.Monitor(handle)
    CompatibilitySchedule(enabled) {
        this.Scheduled := enabled
        if enabled
            this.ScheduleStarts += 1
    }
    CompatibilityForeground() {
        this.ForegroundReads += 1
        if this.InterruptAtForeground && this.ForegroundReads = this.InterruptAtForeground {
            switch this.InterruptKind {
                case "cancel": this.Cancel()
                case "pause": this.Owner.Enabled := false
                case "stop": this.Handle := 0, this.StopCompatibility()
                case "replace": this.ReplaceIntent()
                case "replace-throw":
                    this.ReplaceIntent()
                    throw Error("Expected replaced observation failure")
            }
        }
        return this.Selected
    }
    ReplaceIntent() {
        this.Intent := this.Intent.Clone()
        this.Intent.Serial := 8
        this.Valid := true
        this.BeginCompatibility(8,2)
    }
    CompatibilityMove(hwnd,target) {
        this.Requests.Push({Hwnd:hwnd,Target:target})
        this.MoveCritical := A_IsCritical
        return this.MoveResult
    }
    CancelNativeIntent(cooldown := 0) => (this.NativeCancels += 1,this.Valid := false)
    CancelCompatibilityIntent(serial) {
        this.CompareCritical := A_IsCritical
        if this.ReplaceNativeOnlyDuringCompare {
            this.Intent := this.Intent.Clone()
            this.Intent.Serial := 8
            return false
        }
        if this.ReplaceDuringCompare {
            this.ReplaceDuringCompare := false
            this.ReplaceIntent()
        }
        if !this.Valid || serial != this.Intent.Serial
            return false
        this.NativeCancels += 1, this.Valid := false
        return true
    }
    ReleaseLibrary() => (this.Handle := 0,this.StopError := 0,true)
}

callbacks := []
try {
    fixture := CompatibilityFixture()
    CompatibilityChecks.NoRequest(fixture,"A foreground window without a taskbar click never moves")
    CompatibilityChecks.Assert(!fixture.Scheduled,"No click creates no periodic compatibility work")
    fixture.Valid := false
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,2) && !fixture.Scheduled,"A cancelled native intent cannot start compatibility")
    fixture := CompatibilityFixture(), fixture.Intent.Flags := 1
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,2),"An ordinary 64-bit native click cannot start compatibility")
    fixture := CompatibilityFixture()
    CompatibilityChecks.Assert(!fixture.BeginCompatibility(7,3) && !fixture.Scheduled,
        "A delayed message with a different monitor payload cannot start compatibility")

    fixture := CompatibilityFixture(), fixture.Selected.Data.Pid := 202
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A recycled HWND with a different PID is rejected")
    fixture := CompatibilityFixture(), fixture.Selected.Hwnd := 12
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A same-process window outside the warm snapshot is rejected")
    fixture := CompatibilityFixture(false), fixture.Selected.Data.Path := "C:\Other\AutoHotkey64.exe"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"Cold identity requires the exact verified executable path")
    fixture := CompatibilityFixture(false), fixture.Selected.Data.AppId := "Fixture.Other"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An explicit foreign AppID cannot borrow the matching path")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A shared host requiring an AppID rejects a missing remote AppID")
    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7, fixture.Selected.Data.AppId := "fixture.app"
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"A required AppID is compared case-sensitively")

    for field in ["Visible","Minimized","Eligible"] {
        fixture := CompatibilityFixture()
        fixture.Selected.%field% := field = "Minimized"
        fixture.BeginCompatibility(7,2)
        CompatibilityChecks.NoRequest(fixture,"A hidden, minimized or ineligible selected window is not restored: " . field)
    }
    fixture := CompatibilityFixture(), fixture.Selected := 0
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.NoRequest(fixture,"An absent foreground window is not replaced by another candidate")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.CompatibilityTick(), fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Requests.Length,"A selected window must remain stable for at least 80 ms")
    fixture.Selected := CompatibilityChecks.Window(12,102)
    fixture.Intent.Candidates.Push({Hwnd:12,Pid:102})
    fixture.Now += 50, fixture.CompatibilityTick()
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Requests.Length,"Selecting another group member restarts the stability interval")
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.Requests[1].Hwnd = 12,
        "Only the currently selected stable group member receives a move request")
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 0 && fixture.Owner.SuccessfulMoves = 0,
        "Submitting a move request does not count as confirmed success")
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.CompatibilityMoves = 1 && fixture.Owner.SuccessfulMoves = 1,
        "Verified destination increments compatibility and displayed totals once")
    CompatibilityChecks.Assert(!fixture.Scheduled && !IsObject(fixture.Compatibility) && fixture.NativeCancels = 1,
        "Confirmed success cancels its native transaction and bounded timer")
    fixture.CompatibilityTick()
    CompatibilityChecks.Assert(fixture.Requests.Length = 1 && fixture.CompatibilityMoves = 1,
        "A completed compatibility click never repeats a move or count")
    CompatibilityChecks.Assert(InStr(fixture.Owner.Messages[fixture.Owner.Messages.Length],"32位兼容定位"),
        "Successful feedback explicitly identifies after-show 32-bit compatibility")

    fixture := CompatibilityFixture(false), fixture.Intent.Flags := 7, fixture.Selected.Data.AppId := "Fixture.App"
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(fixture.Requests.Length = 1,"Cold shared-host selection accepts its exact visible AppID")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Assert(fixture.ScheduleStarts = 1,"Duplicate delivery of one valid serial does not restart its timer")
    fixture.Valid := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.NativeCancels,"New input stops observation without cancelling a replacement native transaction")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Intent.Serial := 8, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.NativeCancels,"A replacement click serial cannot inherit the previous compatibility operation")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Owner.Enabled := false, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,"Pause stops compatibility before any move")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Now := fixture.Intent.Expires, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,"Expiry stops the bounded timer")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.Cancel()
    CompatibilityChecks.Assert(!fixture.Scheduled && fixture.NativeCancels = 1,"Explicit cancellation clears the compatibility timer before cancelling native work")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    fixture.CompatibilityTick(), fixture.Now += 50, fixture.CompatibilityTick()
    fixture.CancelAtRead := fixture.IntentReads+2
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length,
        "Native cancellation detected by the immediate pre-move snapshot prevents the request")

    for interruption in ["cancel","pause","stop"] {
        fixture := CompatibilityFixture(), fixture.InterruptAtForeground := 4, fixture.InterruptKind := interruption
        fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
        CompatibilityChecks.Assert(!fixture.Requests.Length && !fixture.Scheduled,
            "An interrupt during final foreground identity reading prevents the resumed move: " . interruption)
    }
    for interruption in ["replace","replace-throw"] {
        fixture := CompatibilityFixture(), fixture.InterruptAtForeground := 4, fixture.InterruptKind := interruption
        fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
        CompatibilityChecks.Assert(!fixture.Requests.Length && fixture.Scheduled && fixture.Compatibility.Serial = 8,
            "An old observation cannot move or clear a replacement click, including exception cleanup: " . interruption)
    }
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceAtRead := fixture.IntentReads+2
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Scheduled && fixture.Compatibility.Serial = 8,
        "Replacement during End's intent read cannot cancel, count or stop the newer operation")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceDuringCompare := true
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Scheduled && fixture.Compatibility.Serial = 8,
        "A failed native compare-cancel preserves a newly armed serial and does not count the old move")
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.ReplaceNativeOnlyDuringCompare := true
    fixture.Now += 50, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.CompatibilityMoves && !fixture.NativeCancels && fixture.Valid && !fixture.Scheduled
        && fixture.BeginCompatibility(8,2),
        "A worker-only replacement makes compare-cancel fail without counting, and its pending message can start normally")
    previousCritical := A_IsCritical
    Critical(23)
    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.Now += 50, fixture.CompatibilityTick()
    restoredCritical := A_IsCritical
    Critical(previousCritical ? previousCritical : "Off")
    CompatibilityChecks.Assert(fixture.MoveCritical && fixture.CompareCritical && restoredCritical = 23,
        "The short move and compare-cancel sections restore the caller's previous critical interval")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.Stable(fixture)
    fixture.Now += 1000, fixture.CompatibilityTick()
    CompatibilityChecks.Assert(!fixture.Scheduled && fixture.CompatibilityMoves = 0 && fixture.Requests.Length = 1,
        "Unconfirmed positioning stops after one request and the one-second confirmation bound")
    fixture := CompatibilityFixture(), fixture.MoveResult := "set-placement-failed:5"
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.CompatibilityMoves,"A failed move clears the timer without counting success")
    fixture := CompatibilityFixture(), fixture.Selected.Monitor := CompatibilityChecks.Monitor(2)
    fixture.BeginCompatibility(7,2), CompatibilityChecks.Stable(fixture)
    CompatibilityChecks.Assert(!fixture.Scheduled && !fixture.Requests.Length && !fixture.CompatibilityMoves,
        "A selected window already on the destination is left in place and is not counted as a move")

    fixture := CompatibilityFixture(), fixture.BeginCompatibility(7,2)
    CompatibilityChecks.StopEngine := fixture
    stopCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeStop"),,1)
    callbacks.Push(stopCallback), fixture.StopAndWaitFn := stopCallback
    CompatibilityChecks.Assert(fixture.Stop() && CompatibilityChecks.StoppedTimerFirst && !fixture.Handle,
        "Stopping the engine clears compatibility polling before native shutdown or module release")
    fixture := CompatibilityFixture(), fixture.CompatibilityMoves := 2, fixture.EventNumber := 0
    statusCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeStatus"),,2)
    callbacks.Push(statusCallback), fixture.StatusFn := statusCallback
    fixture.Poll()
    CompatibilityChecks.Assert(fixture.Owner.SuccessfulMoves = 9,
        "Status polling preserves confirmed compatibility moves while adding native counters")

    intentCallback := CallbackCreate(ObjBindMethod(CompatibilityChecks,"NativeIntent"),,3)
    callbacks.Push(intentCallback)
    decoder := {base:NativeEngine.Prototype,CompatibilityIntentFn:intentCallback}
    decoded := decoder.ReadCompatibilityIntent(7)
    CompatibilityChecks.Assert(decoded.Serial = 7 && decoded.Monitor = 2 && decoded.Released = 900 && decoded.Expires = 9000,
        "The real compatibility decoder reads native transaction fields from the agreed ABI offsets")
    CompatibilityChecks.Assert(decoded.Flags = 5 && decoded.Id == "Fixture.App" && decoded.Path == A_AhkPath,
        "The real compatibility decoder preserves launch path and opaque identity")
    CompatibilityChecks.Assert(decoded.Candidates.Length = 2 && decoded.Candidates[2].Hwnd = 12 && decoded.Candidates[2].Pid = 102,
        "The real compatibility decoder reads the HWND/PID candidate stride")
    CompatibilityChecks.Assert(!IsObject(decoder.ReadCompatibilityIntent(8)),"A failed native serial read never returns an invented intent")
    CompatibilityChecks.AbiCount := 33
    CompatibilityChecks.Assert(!IsObject(decoder.ReadCompatibilityIntent(7)),"A malformed over-capacity native candidate count is rejected")

    FileAppend("PASS compatibility-follow assertions=" . CompatibilityChecks.Count . "`n", "*", "UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    for callback in callbacks
        CallbackFree(callback)
}
ExitApp(IsSet(exitCode) ? exitCode : 0)
