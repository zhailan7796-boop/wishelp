#Requires AutoHotkey v2.0 64-bit
#Include ..\TaskbarFollow.ahk
#Include ..\lib\UIA.ahk

class Spec {
    static Count := 0
    static ProbeCount := 0
    static ProbeSerial := 0
    static ProbePoint := 0
    static ReceiveProbe(serial, point, *) {
        this.ProbeCount += 1, this.ProbeSerial := serial, this.ProbePoint := point
    }
    static Assert(condition, label) {
        if !condition
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual, expected, label) => this.Assert(actual = expected, label . " (actual=" . actual . ", expected=" . expected . ")")
    static Intent() => FollowIntent(10, 2, 1000, 200, 300, 0, 55, 66, false, 0)
    static CopyPayload(text, bytesOverride := 0) {
        data := Buffer((StrLen(text) + 1) * 2, 0)
        StrPut(text, data)
        cds := Buffer(24, 0)
        NumPut("uptr", 0x54424631, cds, 0)
        NumPut("uint", bytesOverride ? bytesOverride : data.Size, cds, 8)
        NumPut("ptr", data.Ptr, cds, 16)
        return {Data: data, Cds: cds}
    }
}
try {
    ; UIA confirmation and release are both mandatory, irrespective of foreground/mouse movement.
    intent := Spec.Intent()
    Spec.Equal(FollowPolicy.Gate(0, 1000, 10, 2, true), "empty", "No click means no work")
    Spec.Equal(FollowPolicy.Gate(intent, 1100, 10, 2, true), "wait", "No UIA confirmation")
    Spec.Equal(FollowPolicy.Gate(intent, 2201, 10, 2, true), "probe-timeout", "Bounded UIA wait")
    Spec.Equal(FollowPolicy.Gate(intent, 1100, 11, 2, true), "cancel", "Reject stale click serial")
    Spec.Equal(FollowPolicy.Gate(intent, 1100, 10, 3, true), "cancel", "Reject display topology change")
    Spec.Equal(FollowPolicy.Gate(intent, 1100, 10, 2, false), "cancel", "Pause cancels pending work")
    intent.Probed := true
    Spec.Equal(FollowPolicy.Gate(intent, 1100, 10, 2, true), "wait", "Do not move on mouse down")
    Spec.Equal(FollowPolicy.Gate(intent, 2600, 10, 2, true), "drag-or-hold", "Long press does not arm follow")
    Spec.Assert(!intent.Release(220, 300, 1120, 4, 4, 8000), "Taskbar drag must not move a window")
    Spec.Assert(intent.Release(202, 302, 1120, 4, 4, 8000), "Real release is accepted")
    Spec.Equal(FollowPolicy.Gate(intent, 1121, 10, 2, true), "ready", "Explicit confirmed click is ready")
    Spec.Equal(FollowPolicy.Gate(intent, 9120, 10, 2, true), "expired", "Activation TTL is strict")
    deferred := Spec.Intent(), deferred.ProbeSent := true, deferred.ProbeAt := 4000, deferred.Expires := 9000
    Spec.Equal(FollowPolicy.Gate(deferred, 4100, 10, 2, true), "wait", "Startup wait does not consume the UIA watchdog")
    Spec.Equal(FollowPolicy.Gate(deferred, 5201, 10, 2, true), "probe-timeout", "Submitted UIA work still has a bounded watchdog")
    Spec.Equal(FollowPolicy.Gate(deferred, 9000, 10, 2, true), "expired", "Deferred recognition does not extend the click TTL")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 2, false, true, false, 1200, 180), "Unrelated foreground rejected")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 2, true, false, false, 1200, 180), "Tool/fullscreen/dialog rejected")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 2, true, true, true, 1200, 180), "Native minimization not mistaken for activation")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 2, true, true, false, 1200, 180), "Candidate must settle")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 2, true, true, false, 1379, 180), "Stable delay not elapsed")
    Spec.Assert(FollowPolicy.Candidate(intent, 1, 2, true, true, false, 1380, 180), "Matching stable HWND accepted")
    Spec.Assert(!FollowPolicy.Candidate(intent, 1, 3, true, true, false, 1400, 180), "PID change resets stability")
    intent.MovedHwnd := 1, intent.MovedPid := 3, intent.MovedAt := 1400, intent.LastAttempt := 1400, intent.Attempts := 1
    Spec.Assert(!FollowPolicy.MaySettle(intent, 1700, 1, 3), "No aggressive repeated moves")
    Spec.Assert(FollowPolicy.MaySettle(intent, 1800, 1, 3), "Brief bounded settle allowed")
    Spec.Assert(!FollowPolicy.MaySettle(intent, 1800, 2, 3), "Focus change cancels settling")
    Spec.Assert(!FollowPolicy.MaySettle(intent, 1800, 1, 4), "No recycled-HWND settling")
    Spec.Assert(!FollowPolicy.MaySettle(intent, 2801, 1, 3), "No permanent fight with OS/app restoration")
    intent.Attempts := 3
    Spec.Assert(!FollowPolicy.MaySettle(intent, 1800, 1, 3), "At most three move requests")

    ; Geometry: negative monitor positions, unequal resolutions, left/top taskbars, oversized windows.
    source := ScreenRect(0, 0, 1920, 1040), target := ScreenRect(-2560, -300, 0, 1100)
    rect := Geometry.Map(ScreenRect(460, 260, 1460, 780), source, target)
    Spec.Assert(rect.L >= target.L && rect.R <= target.R && rect.T >= target.T && rect.B <= target.B, "Mapped window within negative-coordinate work area")
    Spec.Equal(rect.W, 1000, "Do not gratuitously resize a normal window")
    Spec.Equal(rect.H, 520, "Retain normal height when space permits")
    rect := Geometry.Map(ScreenRect(-1000, -1000, 4000, 3000), source, ScreenRect(0,0,800,600))
    Spec.Equal(rect.W, 800, "Oversized width clamped")
    Spec.Equal(rect.H, 600, "Oversized height clamped")
    Spec.Equal(rect.L, 0, "Oversized window remains visible")
    monitor := {Handle: 1, Device: "test", Bounds: ScreenRect(-1920, 0, 0, 1080), Work: ScreenRect(-1840, 40, 0, 1080)}
    original := ScreenRect(-1700, 100, -800, 700), workspace := Geometry.ToWorkspace(original, monitor)
    Spec.Equal(workspace.L, -1780, "Left taskbar screen-to-workspace conversion")
    Spec.Equal(workspace.T, 60, "Top taskbar screen-to-workspace conversion")
    restored := Geometry.FromWorkspace(workspace, monitor)
    for property in ["L", "T", "R", "B"]
        Spec.Equal(restored.%property%, original.%property%, "Workspace round-trip " . property)
    Spec.Assert(Desktop.Unchanged(monitor, monitor), "Unchanged target accepted")
    changed := {Handle: 1, Device: "test", Bounds: monitor.Bounds, Work: ScreenRect(-1840, 50, 0, 1080)}
    Spec.Assert(!Desktop.Unchanged(monitor, changed), "Work-area change cancels an old click")
    Spec.Equal(Desktop.Point(-200, -300) << 32 >> 32, -200, "Negative X survives IPC packing")
    Spec.Equal(Desktop.Point(-200, -300) >> 32, -300, "Negative Y survives IPC packing")

    ; Identity: never infer an application from a partial title or an arbitrary foreground event.
    ids := WindowIdentity("", false)
    pwa := WindowIdentity.ParsePwaShortcut("C:\Edge\msedge_proxy.exe"," --profile-directory=Default --app-id=hmjcdonmhijmnefklekckjkeoknbiipb --app-url=https://chat.deepseek.com/")
    Spec.Assert(IsObject(pwa),"Edge PWA launcher recognized separately")
    Spec.Equal(pwa.Host,"C:\Edge\msedge.exe","PWA real browser host path")
    Spec.Equal(pwa.App,"hmjcdonmhijmnefklekckjkeoknbiipb","PWA app identity preserved")
    Spec.Assert(!IsObject(WindowIdentity.ParsePwaShortcut("C:\Other\launcher.exe","--app-id=hmjcdonmhijmnefklekckjkeoknbiipb")),"Unknown launcher is not Edge PWA")
    Spec.Assert(!IsObject(WindowIdentity.ParsePwaShortcut("C:\Edge\msedge_proxy.exe","--app-id=bad")),"Invalid PWA app identity rejected")
    chrome := {AppId: "Chrome", Path: "C:\Browser\chrome.exe", Exe: "chrome.exe"}
    Spec.Assert(ids.Match("Chrome", chrome), "Exact explicit AppID")
    Spec.Assert(!ids.Match("chrome", chrome), "Opaque AppIDs are compared exactly, not normalized like file paths")
    chrome.AppId := "Chrome.Profile.Other"
    Spec.Assert(!ids.Match("Chrome", chrome), "Explicit browser profile mismatch has no process-name fallback")
    chrome.AppId := ""
    Spec.Assert(ids.Match("Chrome", chrome), "Auditable known process fallback")
    Spec.Assert(!ids.Match("unknown.chrome", chrome), "Unknown IDs fail closed")
    Spec.Assert(!ids.Match("", chrome), "Empty identity never matches")
    Spec.Assert(ids.Match("c:\browser\CHROME.EXE", chrome), "Full executable identity")
    Spec.Assert(!ids.Match("C:\Other\chrome.exe", chrome), "Same basename in another directory is not a full-path match")
    ids.Mappings["Local.Test"] := "D:\Tools\test.exe"
    Spec.Assert(ids.Match("Local.Test", {AppId: "", Path: "D:\Tools\test.exe", Exe: "test.exe"}), "Shortcut/manual exact path mapping")
    Spec.Assert(!ids.Match("Local.Test", {AppId: "", Path: "D:\Other\test.exe", Exe: "test.exe"}), "Mapping is not fuzzy")
    Spec.Equal(WindowIdentity.ExpandIdPath("unrecognized-id"), "unrecognized-id", "Unknown folder ID unchanged")
    expanded := WindowIdentity.ExpandIdPath("{6D809377-6AF0-444B-8957-A3773F02200E}\Vendor\test.exe")
    Spec.Assert(InStr(expanded, ":\") && !InStr(expanded, "{"), "Known-folder path expansion")
    Spec.Assert(Desktop.IsTaskbar("Shell_SecondaryTrayWnd"), "Secondary taskbar recognized")
    Spec.Assert(!Desktop.IsTaskbar("TrayNotifyWnd"), "Notification area is not itself an app button")
    Spec.Assert(Desktop.IsThumbnail("TaskListThumbnailWnd"), "Native preview popup recognized")
    Spec.Equal(TaskbarUIA.Field("hello`r`nworld"), "hello  world", "IPC fields cannot add records")

    ; Regression: CCSwitch exposes a process-only desktop AppID. Before a
    ; window exists, its verified shortcut must still arm native cold positioning.
    launchIds := WindowIdentity("",false)
    launchIds.Mappings["com.ccswitch.desktop"] := A_AhkPath
    launchIds.NativePaths["com.ccswitch.desktop"] := A_AhkPath
    coldEntry := NativeEngine.ResolveEntry("com.ccswitch.desktop",[],launchIds)
    Spec.Assert(IsObject(coldEntry),"CCSwitch no-window taskbar button is not silently dropped")
    Spec.Assert(coldEntry.Flags & 1,"Verified CCSwitch shortcut enables native cold start without an app whitelist")
    Spec.Equal(coldEntry.Candidates.Length,0,"Cold start does not invent a window candidate")
    Spec.Equal(coldEntry.Path,A_AhkPath,"Cold start retains the verified full executable path")

    Spec.Equal(coldEntry.Flags,1,"Unique executable path does not require a window AppID")
    launchIds.Mappings["Local.OtherProfile"] := A_AhkPath
    sharedEntry := NativeEngine.ResolveEntry("com.ccswitch.desktop",[],launchIds)
    Spec.Equal(sharedEntry.Flags,3,"Shared executable requires exact native window/process AppID")
    launchIds.Mappings.Delete("Local.OtherProfile")
    launchIds.NativePaths["com.CCSwitch.desktop"] := A_AhkPath
    Spec.Equal(NativeEngine.ResolveEntry("com.ccswitch.desktop",[],launchIds).Flags,3,"Case-distinct opaque AppIDs sharing a path still require exact identity")
    launchIds.NativePaths.Delete("com.CCSwitch.desktop")
    launchIds.Pwas["Local.Pwa"] := {Host:A_AhkPath,App:"fixture",Profile:"Default"}
    Spec.Equal(NativeEngine.ResolveEntry("com.ccswitch.desktop",[],launchIds).Flags,3,"A PWA sharing the host prevents executable-only cold matching")
    Spec.Equal(NativeEngine.ResolveEntry("Local.Pwa",[],launchIds).Flags,3,"PWA retains exact AppID requirement")
    launchIds.Pwas.Clear()
    noIdentity := NativeEngine.ResolveEntry("Local.Unknown",[],launchIds)
    Spec.Assert(IsObject(noIdentity) && noIdentity.Flags = 0 && noIdentity.Candidates.Length = 0,"Unsupported button remains cached for explicit status feedback")
    launchIds.Mappings["Local.Missing"] := "C:\TaskbarFollow.Nonexistent\missing.exe"
    Spec.Equal(NativeEngine.ResolveEntry("Local.Missing",[],launchIds).Flags,0,"Missing executable never enables native cold start")
    Spec.Equal(launchIds.NativePath(A_AhkPath),A_AhkPath,"Full executable taskbar ID is a verified launch path")
    Spec.Assert(NativeEngine.ResolveEntry(A_AhkPath,[],launchIds).Flags & 1,"Full-path taskbar identity works without a named-app whitelist")
    warmWindow := {Hwnd:123,Data:{Pid:456,AppId:"com.ccswitch.desktop",Path:A_AhkPath,Exe:"AutoHotkey64.exe"}}
    warmEntry := NativeEngine.ResolveEntry("com.ccswitch.desktop",[warmWindow],launchIds)
    Spec.Equal(warmEntry.Candidates.Length,1,"Existing CCSwitch window remains a warm-start candidate")
    Spec.Equal(warmEntry.Candidates[1].Data.Pid,456,"Warm candidate retains verified PID")
    wrongWindow := {Hwnd:124,Data:{Pid:457,AppId:"Local.Different",Path:A_AhkPath,Exe:"AutoHotkey64.exe"}}
    Spec.Equal(NativeEngine.ResolveEntry("com.ccswitch.desktop",[wrongWindow],launchIds).Candidates.Length,0,"Explicit mismatching AppID cannot borrow a matching executable")
    secondPath := {Hwnd:125,Data:{Pid:458,AppId:"com.ccswitch.desktop",Path:"D:\Other\AutoHotkey64.exe",Exe:"AutoHotkey64.exe"}}
    ambiguousEntry := NativeEngine.ResolveEntry("com.ccswitch.desktop",[warmWindow,secondPath],launchIds)
    Spec.Assert(ambiguousEntry.Candidates.Length = 2 && ambiguousEntry.Path = "" && ambiguousEntry.Flags = 0,"Conflicting verified paths retain HWND candidates but do not guess a cold executable")

    ; Verify the controller discards stale IPC responses, and cannot cancel a newer transaction.
    app := TaskbarFollow(true)
    early := Spec.Intent(), early.Created := Desktop.Tick(), early.Expires := early.Created + 8000
    app.Pending := early, app.Serial := 10, app.Generation := 2, app.Enabled := true
    app.PumpCore(early)
    Spec.Assert(app.Pending = early, "Click survives while startup is incomplete")
    app.ProbePending()
    Spec.Assert(!early.ProbeSent, "A missing helper cannot consume the one probe request")
    receiveProbe := ObjBindMethod(Spec, "ReceiveProbe")
    OnMessage(0x8050, receiveProbe)
    app.HelperHwnd := A_ScriptHwnd, app.HelperReady := true
    app.ProbePending()
    Spec.Assert(!early.ProbeSent, "Do not send a UIA reply into a controller still loading shell mappings")
    app.MappingsReady := true
    app.ProbePending(), app.ProbePending()
    Critical("Off")
    Sleep(-1)
    Spec.Equal(Spec.ProbeCount, 1, "A queued startup click is submitted exactly once when the helper is ready")
    Spec.Equal(Spec.ProbeSerial, early.Serial, "Deferred work keeps the original transaction")
    Spec.Equal(Spec.ProbePoint, Desktop.Point(early.X, early.Y), "Deferred work keeps the original click location")
    OnMessage(0x8050, receiveProbe, 0)
    app.MappingsReady := false
    early.Expires := Desktop.Tick()
    app.PumpCore(early)
    Spec.Assert(!IsObject(app.Pending) && InStr(app.LastActivity, "等待时限"), "Startup wait expires with visible feedback")
    current := Spec.Intent(), app.Pending := current, app.Serial := 10, app.Generation := 2
    app.HelperHwnd := 123, app.HelperReady := true
    payload := Spec.CopyPayload("10`napp`nLocal.Test`nTest app")
    Spec.Equal(app.HelperReply(999, payload.Cds.Ptr), 0, "Untrusted sender rejected")
    Spec.Assert(!current.Probed, "Untrusted sender has no effect")
    Spec.Equal(app.HelperReply(123, payload.Cds.Ptr), 1, "Valid helper result accepted")
    Spec.Assert(current.Probed && current.AppId = "Local.Test", "Confirmed identity stored")
    old := Spec.Intent(), old.Serial := 9
    app.Cancel("old transaction", old)
    Spec.Assert(app.Pending = current && app.Serial = 10, "Old cancellation cannot erase new click")
    stale := Spec.CopyPayload("9`nnone`n`n")
    app.HelperReply(123, stale.Cds.Ptr)
    Spec.Assert(app.Pending = current, "Stale result cannot erase new click")
    malformed := Spec.CopyPayload("10`napp`nTest`n", 1)
    Spec.Equal(app.HelperReply(123, malformed.Cds.Ptr), 0, "Odd byte length rejected")
    Spec.Assert(app.Pending = current, "Malformed IPC has no side effects")
    FileAppend("PASS " . Spec.Count . " policy/geometry/identity/IPC assertions`n", "*", "UTF-8")
    ExitApp(0)
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n", "*", "UTF-8")
    ExitApp(1)
}

