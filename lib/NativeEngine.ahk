; Native hooks own input capture and before-show positioning for 64-bit apps.
; A verified 32-bit click has a separate, bounded after-show compatibility path.
class NativeEngine {
    static Exports() => ["Start", "StopAndWait", "Configure", "SetEnabled", "Cancel", "PublishCache", "Status",
        "SetPeekEnabled", "ShowPeek", "HidePeek", "HoverCandidates", "AccessibleName", "CompatibilityIntent", "CancelCompatibility"]
    static DllPath() {
        dllName := IniRead(A_ScriptDir . "\native\bin\runtime.ini", "Native", "Dll")
        if !RegExMatch(dllName, "^NativeHooks-[a-f0-9]+-x64\.dll$")
            throw Error("原生定位组件配置无效。")
        return A_ScriptDir . "\native\bin\" . dllName
    }
    static CheckRuntime() {
        module := DllCall("kernel32\LoadLibraryExW", "wstr", this.DllPath(), "ptr", 0, "uint", 0x1100, "ptr")
        if !module
            throw Error("原生定位组件缺失或无法加载：" . A_LastError)
        try {
            for name in this.Exports() {
                if !DllCall("kernel32\GetProcAddress", "ptr", module, "astr", "TF_" . name, "ptr")
                    throw Error("原生定位组件版本不匹配。")
            }
        } finally DllCall("kernel32\FreeLibrary", "ptr", module)
    }
    __New(owner,path := "") {
        this.Owner := owner, this.Handle := 0, this.EventNumber := 0, this.CacheCount := 0, this.Ready := false, this.CacheAge := 0
        this.HoverState := "", this.UnsupportedApps := ""
        this.StopError := 0, this.StartAttempted := false, this.StartError := 0
        this.Compatibility := 0, this.CompatibilityMoves := 0
        this.CompatibilityTimer := ObjBindMethod(this,"CompatibilityTick")
        this.Initialize(path != "" ? path : NativeEngine.DllPath())
    }
    Initialize(path) {
        this.Handle := DllCall("kernel32\LoadLibraryExW", "wstr", path, "ptr", 0, "uint", 0x1100, "ptr")
        if !this.Handle
            throw Error("无法加载原生定位组件：" . A_LastError)
        try {
            this.BindExports()
            this.StartAttempted := true
            if !DllCall(this.StartFn, "ptr", A_ScriptHwnd, "uint", 0, "int") {
                this.StartError := A_LastError
                throw Error("原生定位钩子启动失败：" . this.StartError)
            }
            DllCall(this.ConfigureFn,"uint",this.Owner.Timeout,"int",this.Owner.BringActive)
            SplitPath(path,&component)
            this.Owner.Log("native component=" . component)
            this.SetEnabled(this.Owner.Enabled)
            this.SetPeekEnabled(this.Owner.FollowPeek)
        } catch as startupError {
            ; A failed start may still own a worker finishing asynchronously.
            ; ALREADY_INITIALIZED or BUSY belongs to another same-process
            ; lifecycle owner; this loader reference must never stop it.
            if this.StartAttempted && this.StartError != 1247 && this.StartError != 170
                this.Stop()
            else
                this.ReleaseLibrary()
            throw startupError
        }
    }
    BindExports() {
        for name in NativeEngine.Exports() {
            address := DllCall("kernel32\GetProcAddress", "ptr", this.Handle, "astr", "TF_" . name, "ptr")
            if !address
                throw Error("原生定位组件版本不匹配。")
            this.DefineProp(name . "Fn", {Value: address})
        }
    }
    SetEnabled(enabled) {
        if !enabled
            this.StopCompatibility()
        return DllCall(this.SetEnabledFn, "int", enabled)
    }
    SetPeekEnabled(enabled) => DllCall(this.SetPeekEnabledFn,"int",enabled)
    Hover(text) {
        if text = "hide" || !this.Owner.Enabled {
            DllCall(this.HidePeekFn)
            return
        }
        fields := StrSplit(text,"`n")
        if fields.Length < 3
            return
        try {
            x := Integer(fields[1]), y := Integer(fields[2]), popup := Integer(fields[3])
            list := Buffer(32*16,0)
            count := DllCall(this.HoverCandidatesFn,"ptr",list,"uint",32,"uint")
            accessibleName := ""
            if count > 1 {
                nameBuffer := Buffer(2048,0)
                if DllCall(this.AccessibleNameFn,"int",x,"int",y,"ptr",nameBuffer,"uint",1024,"int")
                    accessibleName := TaskbarUIAField(StrGet(nameBuffer))
            }
            matches := []
            Loop count {
                hwnd := NumGet(list,(A_Index-1)*16,"uint64"), pid := NumGet(list,(A_Index-1)*16+8,"uint")
                if Desktop.Pid(hwnd) != pid
                    continue
                title := TaskbarUIAField(Desktop.Title(hwnd))
                found := count = 1 || (title != "" && accessibleName == title)
                Loop fields.Length-3 {
                    if fields[A_Index+3] == title && title != ""
                        found := true
                }
                if found
                    matches.Push({Hwnd:hwnd,Pid:pid})
            }
            state := count . ":" . matches.Length . ":" . popup
            if state != this.HoverState {
                this.HoverState := state
                this.Owner.Log("hover resolve; candidates=" . count . "; matches=" . matches.Length . "; popup=" . popup)
            }
            if matches.Length = 1
                DllCall(this.ShowPeekFn,"ptr",matches[1].Hwnd,"uint",matches[1].Pid,"ptr",popup,"int",x,"int",y,"int")
            else
                DllCall(this.HidePeekFn)
        } catch as e {
            this.Owner.Log("hover resolution error: " . e.Message . "; " . e.Extra . "; line=" . e.Line)
            DllCall(this.HidePeekFn)
        }
    }
    Cancel(cooldown := 0) {
        this.StopCompatibility()
        return this.CancelNativeIntent(cooldown)
    }
    CancelNativeIntent(cooldown := 0) => DllCall(this.CancelFn, "uint", cooldown)
    CancelCompatibilityIntent(serial) => DllCall(this.CancelCompatibilityFn,"uint",serial,"int")
    BeginCompatibility(serial,monitorHandle) {
        if !this.Handle || !this.Owner.Enabled
            return false
        intent := this.ReadCompatibilityIntent(serial), now := this.CompatibilityNow()
        if !IsObject(intent) || intent.Serial != serial || intent.Monitor != monitorHandle || !(intent.Flags & 4) || now >= intent.Expires
            return false
        target := this.CompatibilityMonitor(intent.Monitor)
        if !IsObject(target)
            return false
        previousCritical := A_IsCritical
        Critical("On")
        try {
            ; Monitor queries stay outside the short state commit. A delayed
            ; bridge message must not replace a newer compatibility operation.
            fresh := this.ReadCompatibilityIntent(serial)
            if !this.Handle || !this.Owner.Enabled || !IsObject(fresh) || fresh.Serial != serial
                || fresh.Monitor != monitorHandle || !(fresh.Flags & 4) || this.CompatibilityNow() >= fresh.Expires
                return false
            if IsObject(this.Compatibility) && this.Compatibility.Serial = serial
                return true
            this.StopCompatibility()
            this.Compatibility := {Serial:serial,Target:target,Expires:fresh.Expires,Hwnd:0,Pid:0,Since:0,
                Requested:false,RequestedAt:0}
            this.CompatibilitySchedule(true)
        } finally Critical(previousCritical ? previousCritical : "Off")
        this.Owner.ReportActivity("已接到32位应用的任务栏点击，正在等待所选窗口显示后进行兼容定位。")
        return true
    }
    ReadCompatibilityIntent(serial) {
        snapshot := Buffer(3136,0)
        if !DllCall(this.CompatibilityIntentFn,"uint",serial,"ptr",snapshot,"uint",snapshot.Size,"int")
            return 0
        count := NumGet(snapshot,28,"uint"), candidates := []
        if count > 32
            return 0
        Loop count
            candidates.Push({Hwnd:NumGet(snapshot,2592+(A_Index-1)*16,"uint64"),
                Pid:NumGet(snapshot,2600+(A_Index-1)*16,"uint")})
        return {Id:StrGet(snapshot.Ptr+32,256),Path:StrGet(snapshot.Ptr+544,1024),
            Flags:NumGet(snapshot,24,"uint"),Candidates:candidates,Monitor:NumGet(snapshot,3104,"uint64"),
            Released:NumGet(snapshot,3112,"uint64"),Expires:NumGet(snapshot,3120,"uint64"),
            Serial:NumGet(snapshot,3128,"uint")}
    }
    CompatibilityNow() => Desktop.Tick()
    CompatibilityMonitor(handle) => Desktop.Monitor(handle)
    CompatibilitySchedule(enabled) => SetTimer(this.CompatibilityTimer,enabled ? 50 : 0)
    CompatibilityForeground() {
        hwnd := Desktop.Foreground()
        if !hwnd
            return 0
        return {Hwnd:hwnd,Data:this.Owner.Identity.Get(hwnd),Eligible:Desktop.Eligible(hwnd),
            Visible:DllCall("user32\IsWindowVisible","ptr",hwnd),Minimized:Desktop.IsMin(hwnd),
            Monitor:Desktop.MonitorOf(hwnd)}
    }
    CompatibilityMove(hwnd,target) => WindowMover.Move(hwnd,target)
    CompatibilityMatches(intent,window) {
        if !IsObject(window) || !window.Hwnd || !window.Data.Pid || !window.Visible || window.Minimized || !window.Eligible
            return false
        if intent.Path = "" || window.Data.Path = "" || StrLower(intent.Path) != StrLower(window.Data.Path)
            return false
        if (intent.Flags & 2) && !(window.Data.AppId != "" && window.Data.AppId == intent.Id)
            return false
        if !this.Owner.Identity.Match(intent.Id,window.Data)
            return false
        if !intent.Candidates.Length
            return !!(intent.Flags & 1)
        for candidate in intent.Candidates {
            if candidate.Hwnd = window.Hwnd && candidate.Pid = window.Data.Pid
                return true
        }
        return false
    }
    CompatibilityCurrent(state) => IsObject(this.Compatibility) && this.Compatibility = state && this.Handle && this.Owner.Enabled
    StopCompatibility(expected := 0) {
        if IsObject(expected) && this.Compatibility != expected
            return false
        this.CompatibilitySchedule(false)
        this.Compatibility := 0
        return true
    }
    EndCompatibility(state,text := "",success := false) {
        previousCritical := A_IsCritical
        Critical("On")
        try {
            if !this.CompatibilityCurrent(state)
                return
            current := this.ReadCompatibilityIntent(state.Serial)
            if !this.CompatibilityCurrent(state)
                return
            if !IsObject(current) || current.Serial != state.Serial {
                this.StopCompatibility(state)
                return
            }
            ; Native input runs on another thread even during AHK Critical.
            ; Its compare-and-cancel must succeed before counting or reporting.
            cancelled := this.CancelCompatibilityIntent(state.Serial)
            if !this.CompatibilityCurrent(state)
                return
            this.StopCompatibility(state)
            if !cancelled
                return
            if success {
                this.CompatibilityMoves += 1
                this.Owner.SuccessfulMoves += 1
            }
        } finally Critical(previousCritical ? previousCritical : "Off")
        if text != ""
            this.Owner.ReportActivity(text)
    }
    CompatibilityTick() {
        state := this.Compatibility
        if !IsObject(state)
            return
        try {
            if !this.Handle || !this.Owner.Enabled {
                this.StopCompatibility(state)
                return
            }
            intent := this.ReadCompatibilityIntent(state.Serial), now := this.CompatibilityNow()
            if !this.CompatibilityCurrent(state)
                return
            if !IsObject(intent) || intent.Serial != state.Serial || !(intent.Flags & 4) || now >= intent.Expires {
                this.StopCompatibility(state)
                if now >= state.Expires
                    this.Owner.ReportActivity("32位兼容定位等待已结束，尚未确认所选窗口到达目标屏幕。")
                return
            }
            if !Desktop.Unchanged(state.Target,this.CompatibilityMonitor(intent.Monitor)) {
                this.EndCompatibility(state)
                return
            }
            window := this.CompatibilityForeground()
            if !this.CompatibilityMatches(intent,window) {
                if state.Requested
                    this.EndCompatibility(state,"32位兼容定位已结束，所选窗口已隐藏、最小化或切换焦点。")
                else
                    state.Hwnd := 0, state.Pid := 0, state.Since := 0
                return
            }
            if state.Requested {
                if window.Hwnd != state.Hwnd || window.Data.Pid != state.Pid {
                    this.EndCompatibility(state,"32位兼容定位已结束，所选窗口已发生变化。")
                    return
                }
                if Desktop.SameMonitor(window.Monitor,state.Target)
                    this.EndCompatibility(state,"已完成32位兼容定位：已显示的所选窗口现已位于点击的屏幕。",true)
                else if now-state.RequestedAt >= 1000
                    this.EndCompatibility(state,"32位兼容定位未能确认目标位置，已停止继续尝试。")
                return
            }
            if state.Hwnd != window.Hwnd || state.Pid != window.Data.Pid {
                state.Hwnd := window.Hwnd, state.Pid := window.Data.Pid, state.Since := now
                return
            }
            if now-state.Since < 80
                return
            if Desktop.SameMonitor(window.Monitor,state.Target) {
                this.EndCompatibility(state,"32位应用的所选窗口已在点击的屏幕上，保留系统行为。")
                return
            }
            ; Window identity queries can dispatch messages. Finish those before
            ; entering the short, final state/epoch check and move request.
            selected := this.CompatibilityForeground()
            if !this.CompatibilityMatches(intent,selected) || selected.Hwnd != state.Hwnd || selected.Data.Pid != state.Pid {
                state.Hwnd := 0, state.Pid := 0, state.Since := 0
                return
            }
            previousCritical := A_IsCritical
            Critical("On")
            try {
                if !this.CompatibilityCurrent(state) {
                    this.StopCompatibility(state)
                    return
                }
                fresh := this.ReadCompatibilityIntent(state.Serial)
                if !this.CompatibilityCurrent(state)
                    return
                if !IsObject(fresh) || fresh.Serial != state.Serial || fresh.Monitor != state.Target.Handle
                    || !(fresh.Flags & 4) || this.CompatibilityNow() >= fresh.Expires {
                    this.StopCompatibility(state)
                    return
                }
                if !this.CompatibilityMatches(fresh,selected)
                    return
                result := this.CompatibilityMove(state.Hwnd,state.Target)
                if result = "requested"
                    state.Requested := true, state.RequestedAt := now
            } finally Critical(previousCritical ? previousCritical : "Off")
            if result != "requested" {
                this.EndCompatibility(state,result = "already-there"
                    ? "32位应用的所选窗口已在点击的屏幕上，保留系统行为。"
                    : "32位兼容定位请求未完成，已保留系统行为。")
                return
            }
            this.Owner.Log("32-bit compatibility requested; pid=" . state.Pid . "; hwnd=" . state.Hwnd . "; target=" . state.Target.Device)
        } catch as e {
            this.StopCompatibility(state)
            try this.Owner.Log("32-bit compatibility error: " . e.Message . "; line=" . e.Line)
        }
    }
    Stop(timeoutMs := 3000) {
        this.StopCompatibility()
        this.Ready := false
        if !this.Handle {
            this.StopError := 0
            return true
        }
        try {
            if !DllCall(this.StopAndWaitFn,"uint",timeoutMs,"int") {
                this.StopError := A_LastError
                this.StopFailed("shutdown not confirmed")
                return false
            }
        } catch as stopError {
            this.StopError := A_LastError
            this.StopFailed("stop call failed: " . stopError.Message)
            return false
        }
        return this.ReleaseLibrary()
    }
    ReleaseLibrary() {
        if !this.Handle
            return true
        if !DllCall("kernel32\FreeLibrary","ptr",this.Handle,"int") {
            this.StopError := A_LastError
            this.StopFailed("DLL release failed")
            return false
        }
        this.Handle := 0, this.StopError := 0
        return true
    }
    StopFailed(reason) {
        ; Logging must not turn a bounded shutdown failure into an exception
        ; that skips the controller's remaining helper/hook cleanup.
        try this.Owner.Log("native shutdown incomplete; " . reason . "; Win32=" . this.StopError . "; retained DLL=" . this.Handle)
    }
    Publish(text) {
        if !this.Owner.MappingsReady
            return
        windows := []
        for hwnd in WinGetList() {
            if Desktop.Eligible(hwnd) {
                data := this.Owner.Identity.Get(hwnd)
                windows.Push({Hwnd: hwnd, Data: data})
            }
        }
        buttons := []
        for line in StrSplit(text, "`n") {
            fields := StrSplit(line, "`t")
            if fields.Length != 6 || fields[6] = "" || StrLen(fields[6]) >= 256
                continue
            try {
                bar := Integer(fields[1]), rect := ScreenRect(Integer(fields[2]),Integer(fields[3]),Integer(fields[4]),Integer(fields[5]))
                if !Desktop.IsTaskbar(Desktop.Class(bar)) || rect.W <= 0 || rect.H <= 0
                    continue
                buttons.Push({Id:fields[6],Bar:bar,Rect:rect})
            } catch {
                continue
            }
        }
        records := NativeEngine.ResolveButtons(buttons,windows,this.Owner.Identity)
        unsupported := Map(), unsupported.CaseSense := true
        cacheBuffer := Buffer(Max(1,records.Length) * 3104, 0)
        for index, record in records {
            if !record.Candidates.Length && !record.Flags
                unsupported[record.Id] := true
            offset := (index-1)*3104
            NumPut("uint64",record.Bar,cacheBuffer,offset)
            record.Rect.Write(cacheBuffer,offset+8)
            NumPut("uint",record.Flags,"uint",record.Candidates.Length,cacheBuffer,offset+24)
            StrPut(record.Id,cacheBuffer.Ptr+offset+32,256)
            StrPut(record.Path,cacheBuffer.Ptr+offset+544,1024)
            for number,item in record.Candidates
                NumPut("uint64",item.Hwnd,"uint",item.Data.Pid,cacheBuffer,offset+2592+(number-1)*16)
        }
        if !DllCall(this.PublishCacheFn,"ptr",cacheBuffer,"uint",records.Length,"uint",3104,"int")
            throw Error("原生任务栏缓存提交失败。")
        ; A publish can run between the poll and watchdog timers. Clear the old
        ; age before exposing the new count, so startup is not misread as stale.
        this.CacheAge := 0
        this.CacheCount := records.Length
        unavailable := ""
        for id in unsupported
            unavailable .= (unavailable = "" ? "" : "; ") . id
        if unavailable != this.UnsupportedApps {
            this.UnsupportedApps := unavailable
            this.Owner.Log("native buttons without verified launch/window identity=" . (unavailable = "" ? "none" : unavailable))
        }
    }
    static ResolveButtons(buttons,windows,identity) {
        ; Scope all reuse to this publish: window identities, launch files and
        ; mappings must be checked afresh when the next UIA snapshot arrives.
        index := NativeIdentityIndex(windows,identity)
        resolved := Map(), resolved.CaseSense := true
        records := []
        for button in buttons {
            try {
                if !resolved.Has(button.Id) {
                    ; A failing identity must not repeat the same slow query for
                    ; its other taskbar buttons during this publish.
                    resolved[button.Id] := 0
                    resolved[button.Id] := NativeEngine.ResolveEntry(button.Id,windows,identity,index)
                }
                entry := resolved[button.Id]
                if !IsObject(entry)
                    continue
                ; Never attach geometry to the shared identity object. The same
                ; application can have a different button on every taskbar.
                records.Push({Id:entry.Id,Path:entry.Path,Flags:entry.Flags,Candidates:entry.Candidates,
                    Bar:button.Bar,Rect:button.Rect})
            } catch {
                continue
            }
            if records.Length >= 64
                break
        }
        return records
    }
    ; Resolve launch eligibility outside the input callback. Keep this independent
    ; of UIA/geometry so a no-window (cold-start) button is regression-testable.
    static ResolveEntry(id,windows,identity,index := 0) {
        if !IsObject(index)
            index := NativeIdentityIndex(windows,identity)
        candidates := [], paths := Map()
        for item in index.Matches(id) {
            if candidates.Length < 32
                candidates.Push(item)
            ; Inspect every match, including those beyond the native HWND cap.
            if item.Data.Path != ""
                paths[index.Normalize(item.Data.Path)] := item.Data.Path
        }
        path := ""
        if paths.Count = 1 {
            for pathKey,pathValue in paths {
                path := pathValue
                break
            }
        }
        ; Multiple executable paths for one ID are not a cold-start identity.
        if !paths.Count
            path := identity.NativePath(id,index.ExpandIdPath(id))
        if StrLen(path) >= 1024
            path := ""
        cold := path != "" && index.IsExecutable(path)
        requireId := cold && index.RequiresAppId(id,path)
        compatibility := cold && index.BinaryType(path) = 0
        ; Retain unsupported buttons too: an explicit click should report why it
        ; was skipped, not vanish from the cache without any status/log feedback.
        return {Id:id,Path:path,Candidates:candidates,Flags:(cold?1:0)|(requireId?2:0)|(compatibility?4:0)}
    }
    Poll() {
        status := Buffer(168,0)
        if !DllCall(this.StatusFn,"ptr",status,"uint",status.Size,"int")
            return
        this.CacheCount := NumGet(status,12,"uint")
        this.CacheAge := NumGet(status,16,"uint64")
        this.Ready := NumGet(status,4,"uint") && this.CacheCount && this.CacheAge <= 3000
        this.Owner.SuccessfulMoves := NumGet(status,56,"uint64") + NumGet(status,48,"uint64") + this.CompatibilityMoves
        eventNumber := NumGet(status,96,"uint64")
        if eventNumber = this.EventNumber
            return
        this.EventNumber := eventNumber
        ; See NativeStatus's explicit ABI: lastKind=72, lastPid=76,
        ; lastWindow=80, latency=88, eventNumber=96, target=104.
        kind := NumGet(status,72,"uint"), pid := NumGet(status,76,"uint"), hwnd := NumGet(status,80,"uint64")
        latency := NumGet(status,88,"uint64"), target := StrGet(status.Ptr+104,32)
        this.Owner.Log("native event=" . kind . "; pid=" . pid . "; hwnd=" . hwnd . "; target=" . target . "; since-release-ms=" . latency)
        static messages := Map(1,"已接到任务栏点击，等待 Windows 创建或恢复对应窗口。",
            2,"已在窗口创建时指定点击的屏幕，等待首次显示。",
            3,"已在窗口恢复显示前准备好目标位置。",
            4,"已在窗口激活前直接定位，保持当前窗口状态。",
            5,"已确认：窗口首次显示时已位于目标屏幕。",
            6,"你开始了其他操作，已取消尚未完成的定位。",
            7,"任务栏已展开多个窗口，请选择需要唤起的那个。",
            8,"此应用暂不支持原生定位，本次保留系统行为。",
            9,"窗口已在点击的屏幕上，保留系统行为。",
            10,"本次未能确认所选窗口完成定位，已结束等待并保留系统位置。",
            12,"正在当前屏幕显示悬停预览，移开鼠标即关闭；原窗口保持原位。",
            13,"悬停预览已关闭，原窗口位置和最小化状态保持不变。",
            16,"应用未接受目标位置，本次未确认定位成功。")
        if kind = 1 && IsObject(this.Compatibility)
            this.Owner.ReportActivity("已接到32位应用的任务栏点击，正在等待所选窗口显示后进行兼容定位。")
        else if messages.Has(kind)
            this.Owner.ReportActivity(messages[kind])
    }
}
TaskbarUIAField(text) => SubStr(StrReplace(StrReplace(text,"`n"," "),"`r"," "),1,1024)
