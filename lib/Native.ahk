; TaskbarFollow - Windows primitives. All geometry is physical screen coordinates unless noted.
class ScreenRect {
    __New(l, t, r, b) {
        this.L := l, this.T := t, this.R := r, this.B := b
    }
    W => this.R - this.L
    H => this.B - this.T
    static FromBuffer(b, offset := 0) {
        return ScreenRect(NumGet(b, offset, "int"), NumGet(b, offset + 4, "int"),
            NumGet(b, offset + 8, "int"), NumGet(b, offset + 12, "int"))
    }
    Write(b, offset := 0) {
        NumPut("int", this.L, "int", this.T, "int", this.R, "int", this.B, b, offset)
    }
}

class Desktop {
    static Physical() => DllCall("user32\SetThreadDpiAwarenessContext", "ptr", -4, "ptr")
    static Tick() => DllCall("kernel32\GetTickCount64", "uint64")
    static Cursor(&x, &y) {
        ; MouseGetPos defaults to foreground-client coordinates. The foreground
        ; changes during a taskbar click, so never use it for hit tests or drags.
        point := Buffer(8, 0)
        if !DllCall("user32\GetPhysicalCursorPos", "ptr", point) {
            x := 0, y := 0
            return false
        }
        x := NumGet(point, 0, "int"), y := NumGet(point, 4, "int")
        return true
    }
    static Point(x, y) => (x & 0xffffffff) | (y << 32)
    static RootAt(x, y) {
        hwnd := DllCall("user32\WindowFromPoint", "int64", this.Point(x, y), "ptr")
        return hwnd ? DllCall("user32\GetAncestor", "ptr", hwnd, "uint", 2, "ptr") : 0
    }
    static Class(hwnd) {
        b := Buffer(512, 0)
        return DllCall("user32\GetClassNameW", "ptr", hwnd, "ptr", b, "int", 256)
            ? StrGet(b) : ""
    }
    static Title(hwnd) {
        b := Buffer(4096, 0)
        DllCall("user32\GetWindowTextW", "ptr", hwnd, "ptr", b, "int", 2048)
        return StrGet(b)
    }
    static Foreground() => DllCall("user32\GetForegroundWindow", "ptr")
    static IsMin(hwnd) => DllCall("user32\IsIconic", "ptr", hwnd)
    static Pid(hwnd) {
        pid := 0
        DllCall("user32\GetWindowThreadProcessId", "ptr", hwnd, "uint*", &pid)
        return pid
    }
    static Rect(hwnd) {
        b := Buffer(16, 0)
        return DllCall("user32\GetWindowRect", "ptr", hwnd, "ptr", b) ? ScreenRect.FromBuffer(b) : 0
    }
    static MonitorAt(x, y) => this.Monitor(DllCall("user32\MonitorFromPoint", "int64", this.Point(x, y), "uint", 2, "ptr"))
    static MonitorOf(hwnd) => this.Monitor(DllCall("user32\MonitorFromWindow", "ptr", hwnd, "uint", 2, "ptr"))
    static Monitor(handle) {
        b := Buffer(104, 0)
        NumPut("uint", 104, b)
        if !handle || !DllCall("user32\GetMonitorInfoW", "ptr", handle, "ptr", b)
            return 0
        return {Handle: handle, Bounds: ScreenRect.FromBuffer(b, 4), Work: ScreenRect.FromBuffer(b, 20),
            Device: StrGet(b.Ptr + 40, 32)}
    }
    static SameMonitor(a, b) => IsObject(a) && IsObject(b) && a.Handle = b.Handle && a.Device = b.Device
    static Unchanged(a, b) {
        if !this.SameMonitor(a, b)
            return false
        for property in ["L", "T", "R", "B"] {
            if a.Bounds.%property% != b.Bounds.%property% || a.Work.%property% != b.Work.%property%
                return false
        }
        return true
    }
    static IsTaskbar(className) => className = "Shell_TrayWnd" || className = "Shell_SecondaryTrayWnd"
    static IsThumbnail(className) => className = "TaskListThumbnailWnd"
    static Thumbnails() {
        ; Explorer's popup can be absent from EnumWindows/WinGetList even while
        ; WindowFromPoint and FindWindowEx can see it. Enumerate the class directly.
        result := [], after := 0
        Loop 64 {
            hwnd := DllCall("user32\FindWindowExW", "ptr", 0, "ptr", after,
                "wstr", "TaskListThumbnailWnd", "ptr", 0, "ptr")
            if !hwnd || hwnd = after
                break
            after := hwnd
            if DllCall("user32\IsWindowVisible", "ptr", hwnd)
                result.Push(hwnd)
        }
        return result
    }
    static IsShell(hwnd) {
        c := this.Class(hwnd)
        return !hwnd || this.IsTaskbar(c) || this.IsThumbnail(c)
            || c = "Progman" || c = "WorkerW" || c = "Windows.UI.Core.CoreWindow"
    }
    static Eligible(hwnd) {
        if !hwnd || !DllCall("user32\IsWindow", "ptr", hwnd) || this.IsShell(hwnd)
            return false
        if !DllCall("user32\IsWindowVisible", "ptr", hwnd) || !DllCall("user32\IsWindowEnabled", "ptr", hwnd)
            return false
        ex := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -20, "ptr")
        style := DllCall("user32\GetWindowLongPtrW", "ptr", hwnd, "int", -16, "ptr")
        if (ex & 0x08000080) || (style & 0x40000000) ; NOACTIVATE, TOOLWINDOW, CHILD
            return false
        if DllCall("user32\GetWindow", "ptr", hwnd, "uint", 4, "ptr") && !(ex & 0x40000)
            return false ; owned dialogs are not independent taskbar windows
        monitor := this.MonitorOf(hwnd), rect := this.Rect(hwnd)
        if IsObject(monitor) && IsObject(rect) && !(style & 0x00C00000)
            && rect.L <= monitor.Bounds.L && rect.T <= monitor.Bounds.T
            && rect.R >= monitor.Bounds.R && rect.B >= monitor.Bounds.B
            return false ; do not attempt to migrate borderless/exclusive full-screen applications
        cloaked := 0
        DllCall("dwmapi\DwmGetWindowAttribute", "ptr", hwnd, "uint", 14, "uint*", &cloaked, "uint", 4)
        if cloaked || DllCall("user32\IsHungAppWindow", "ptr", hwnd)
            return false
        p := this.Placement(hwnd)
        return IsObject(p) && ScreenRect.FromBuffer(p, 28).W >= 160 && ScreenRect.FromBuffer(p, 28).H >= 100
    }
    static Placement(hwnd) {
        p := Buffer(44, 0)
        NumPut("uint", 44, p)
        return DllCall("user32\GetWindowPlacement", "ptr", hwnd, "ptr", p) ? p : 0
    }
    static Guid(value) {
        b := Buffer(16, 0)
        if DllCall("ole32\CLSIDFromString", "wstr", value, "ptr", b, "int") < 0
            throw Error("Invalid GUID")
        return b
    }
}

class Geometry {
    static Clamp(v, low, high) => Max(low, Min(v, high))
    static Map(rect, sourceWork, targetWork) {
        w := Min(rect.W, targetWork.W), h := Min(rect.H, targetWork.H)
        fx := sourceWork.W > rect.W ? this.Clamp((rect.L - sourceWork.L) / (sourceWork.W - rect.W), 0, 1) : 0.5
        fy := sourceWork.H > rect.H ? this.Clamp((rect.T - sourceWork.T) / (sourceWork.H - rect.H), 0, 1) : 0.5
        x := Round(targetWork.L + fx * (targetWork.W - w))
        y := Round(targetWork.T + fy * (targetWork.H - h))
        return ScreenRect(x, y, x + w, y + h)
    }
    ; WINDOWPLACEMENT uses workspace coordinates for ordinary top-level windows.
    static FromWorkspace(rect, monitor) {
        dx := monitor.Work.L - monitor.Bounds.L, dy := monitor.Work.T - monitor.Bounds.T
        return ScreenRect(rect.L + dx, rect.T + dy, rect.R + dx, rect.B + dy)
    }
    static ToWorkspace(rect, monitor) {
        dx := monitor.Work.L - monitor.Bounds.L, dy := monitor.Work.T - monitor.Bounds.T
        return ScreenRect(rect.L - dx, rect.T - dy, rect.R - dx, rect.B - dy)
    }
}

class WindowIdentity {
    __New(configPath := "", loadShortcuts := true) {
        this.Mappings := Map(), this.Mappings.CaseSense := true
        this.NativePaths := Map(), this.NativePaths.CaseSense := true
        this.PackagePaths := Map(), this.PackagePaths.CaseSense := true
        this.Pwas := Map(), this.Pwas.CaseSense := true
        this.Aliases := Map(), this.Aliases.CaseSense := true
        this.AliasPaths := Map()
        this.Cache := Map()
        ; These are explicit, auditable fallbacks, not fuzzy title matching.
        ; Explorer is the Windows shell host, not an App Paths registration.
        ; Bind its known identity to the system image for cold starts as well.
        this.Mappings["Microsoft.Windows.Explorer"] := A_WinDir . "\explorer.exe"
        this.Mappings["Chrome"] := "chrome.exe"
        this.Mappings["MSEdge"] := "msedge.exe"
        this.ShortcutCount := 0
        if loadShortcuts {
            try this.LoadShortcuts()
        }
        if configPath != "" {
            section := IniRead(configPath, "AppIdMap", , "")
            for line in StrSplit(section, "`n", "`r") {
                parts := StrSplit(line, "=", , 2)
                if parts.Length = 2 && Trim(parts[1]) != "" && Trim(parts[2]) != "" {
                    id := Trim(parts[1]), target := Trim(parts[2])
                    ; Keep existing default configurations bound to Windows,
                    ; while preserving an explicitly different user mapping.
                    if id == "Microsoft.Windows.Explorer" && StrLower(target) = "explorer.exe"
                        target := A_WinDir . "\explorer.exe"
                    this.Mappings[id] := target
                }
            }
            this.LoadAliases(IniRead(configPath,"AppIdAlias",,""))
        }
    }
    LoadAliases(section) {
        ; Explicit, single-hop identity equivalence only. An executable path is
        ; the canonical identity; neither titles nor executable names infer it.
        for line in StrSplit(section,"`n","`r") {
            parts := StrSplit(line,"=",,2)
            if parts.Length != 2
                continue
            id := Trim(parts[1]), path := WindowIdentity.VerifiedAliasPath(Trim(parts[2]))
            if id = "" || StrLen(id) >= 256 || path = "" || this.Pwas.Has(id)
                continue
            ; A path cannot be redirected to a different installation.
            if InStr(id,":\") || SubStr(id,1,2) = "\\" || RegExMatch(id,"^\{[0-9A-Fa-f-]{36}\}\\")
                continue
            if this.Mappings.Has(id) {
                mapped := WindowIdentity.VerifiedAliasPath(this.Mappings[id])
                if mapped = "" || StrLower(mapped) != StrLower(path)
                    continue
            }
            this.Mappings[id] := path
            canonical := StrLower(path)
            this.Aliases[id] := canonical
            this.AliasPaths[canonical] := true
        }
    }
    static VerifiedAliasPath(path) {
        if !RegExMatch(path,"i)^[a-z]:\\.*\.exe$")
            return ""
        pathBuffer := Buffer(32768*2,0)
        length := DllCall("kernel32\GetFullPathNameW","wstr",path,"uint",32768,"ptr",pathBuffer,"ptr",0,"uint")
        if !length || length >= 1024
            return ""
        path := StrGet(pathBuffer,length), attributes := FileExist(path), binaryType := 0
        if attributes = "" || InStr(attributes,"D") || !DllCall("kernel32\GetBinaryTypeW","wstr",path,"uint*",&binaryType)
            return ""
        return binaryType = 0 || binaryType = 6 ? path : ""
    }
    CanonicalId(id) {
        if this.Aliases.Has(id)
            return this.Aliases[id]
        normalized := StrLower(id)
        return this.AliasPaths.Has(normalized) ? normalized : id
    }
    ExplicitMatch(id,data) {
        canonical := this.CanonicalId(id)
        if !(canonical == this.CanonicalId(data.AppId))
            return false
        ; A configured executable alias also binds explicit IDs to that exact
        ; image, including when another installation reuses the same AppID.
        return !this.AliasPaths.Has(canonical) || (data.Path != "" && StrLower(data.Path) = canonical)
    }
    LoadShortcuts() {
        ; Process-level desktop AppIDs have no universal supported remote query. Read the shell's
        ; actual AppID -> executable associations instead of guessing from localized button names.
        wsh := ComObject("WScript.Shell"), shellApp := ComObject("Shell.Application")
        folders := Map(), associations := Map(), ambiguous := Map(), seen := 0
        associations.CaseSense := true, ambiguous.CaseSense := true
        pinned := A_AppData . "\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        for entry in [{Path: pinned, Mode: "F"}, {Path: A_Programs, Mode: "FR"}, {Path: A_ProgramsCommon, Mode: "FR"}] {
            Loop Files entry.Path . "\*.lnk", entry.Mode {
                seen += 1
                if seen > 1500
                    break
                try {
                    SplitPath(A_LoopFileFullPath, &leaf, &directory)
                    if !folders.Has(directory)
                        folders[directory] := shellApp.NameSpace(directory)
                    item := folders[directory].ParseName(leaf)
                    id := item.ExtendedProperty("System.AppUserModel.ID")
                    if id = ""
                        continue
                    shortcut := wsh.CreateShortcut(A_LoopFileFullPath)
                    target := shortcut.TargetPath
                    pwa := WindowIdentity.ParsePwaShortcut(target,shortcut.Arguments)
                    if IsObject(pwa) && FileExist(pwa.Host) {
                        if this.Pwas.Has(id) && (this.Pwas[id].Host != pwa.Host || this.Pwas[id].App != pwa.App || this.Pwas[id].Profile != pwa.Profile)
                            ambiguous[id] := true
                        else
                            this.Pwas[id] := pwa
                        continue
                    }
                    ; Other argument-bearing launchers are still not executable mappings.
                    if shortcut.Arguments != "" || !RegExMatch(target, "i)^[a-z]:\\.*\.exe$") || !FileExist(target)
                        continue
                    if associations.Has(id) && StrLower(associations[id]) != StrLower(target)
                        ambiguous[id] := true
                    else
                        associations[id] := target
                }
            }
        }
        for id, target in associations {
            if !ambiguous.Has(id) {
                this.Mappings[id] := target
                this.NativePaths[id] := target
                this.ShortcutCount += 1
            }
        }
        for id in ambiguous {
            if this.Pwas.Has(id)
                this.Pwas.Delete(id)
        }
    }
    static ParsePwaShortcut(target,arguments) {
        if !RegExMatch(target,"i)^(.*\\)msedge(?:_proxy)?\.exe$",&host)
            return 0
        if !RegExMatch(arguments,'(?:^|\s)--app-id=(?:"([a-p]{32})"|([a-p]{32}))(?=\s|$)',&app)
            return 0
        profile := "Default"
        if RegExMatch(arguments,'(?:^|\s)--profile-directory=(?:"([^"\\/]+)"|([^\s"\\/]+))(?=\s|$)',&match)
            profile := match[1] != "" ? match[1] : match[2]
        return {Host: host[1] . "msedge.exe",App: app[1] != "" ? app[1] : app[2],Profile: profile}
    }
    NativePath(id,expanded := unset) {
        if !IsSet(expanded)
            expanded := WindowIdentity.ExpandIdPath(id)
        if RegExMatch(expanded,"i)^[a-z]:\\.*\.exe$")
            return FileExist(expanded) ? expanded : ""
        if this.Pwas.Has(id)
            return this.Pwas[id].Host
        mapped := this.Mappings.Has(id) ? this.Mappings[id] : ""
        if mapped = "" && IsObject(package := WindowIdentity.PackageId(id))
            return this.PackagedPath(id,package)
        if InStr(mapped, "\")
            return FileExist(mapped) && RegExMatch(mapped,"i)^[a-z]:\\.*\.exe$") ? mapped : ""
        if this.NativePaths.Has(id) {
            path := this.NativePaths[id]
            SplitPath(path,&exe)
            if FileExist(path) && (mapped = "" || StrLower(mapped) = StrLower(exe))
                return path
        }
        if RegExMatch(mapped,"i)^[a-z0-9_. -]+\.exe$") {
            for registry in ["HKCU\Software\Microsoft\Windows\CurrentVersion\App Paths\", "HKLM\Software\Microsoft\Windows\CurrentVersion\App Paths\"] {
                try {
                    path := Trim(RegRead(registry . mapped), '"')
                    if FileExist(path) && RegExMatch(path,"i)^[a-z]:\\.*\.exe$")
                        return path
                }
            }
        }
        return ""
    }
    static PackageId(id) => RegExMatch(id,"i)^([a-z0-9.-]+_[a-z0-9]{13})!([a-z0-9.-]+)$",&parts) ? parts : 0
    PackagedPath(id,package) {
        now := Desktop.Tick()
        if this.PackagePaths.Has(id) {
            cached := this.PackagePaths[id]
            if now - cached.At < 10000 && (cached.Path = "" || FileExist(cached.Path))
                return cached.Path
        }
        path := ""
        try path := WindowIdentity.RegisteredPackageExecutable(package[1],package[2])
        this.PackagePaths[id] := {Path:path,At:now}
        return path
    }
    static RegisteredPackageExecutable(family,appId) {
        count := 0, chars := 0
        code := DllCall("kernel32\GetPackagesByPackageFamily","wstr",family,"uint*",&count,"ptr",0,
            "uint*",&chars,"ptr",0,"int")
        if code != 122 || !count || !chars
            return ""
        names := Buffer(count*A_PtrSize), text := Buffer(chars*2)
        if DllCall("kernel32\GetPackagesByPackageFamily","wstr",family,"uint*",&count,"ptr",names,
            "uint*",&chars,"ptr",text,"int") != 0
            return ""
        path := ""
        Loop count {
            name := StrGet(NumGet(names,(A_Index-1)*A_PtrSize,"ptr"))
            chars := 1024, root := Buffer(chars*2)
            if DllCall("kernel32\GetPackagePathByFullName","wstr",name,"uint*",&chars,"ptr",root,"int") != 0
                continue
            candidate := WindowIdentity.ManifestExecutable(StrGet(root),appId)
            if candidate = ""
                continue
            if path != "" && StrLower(candidate) != StrLower(path)
                return "" ; conflicting installed launch paths cannot identify a unique image
            path := candidate
        }
        return path
    }
    static ManifestExecutable(root,appId) {
        manifest := ComObject("Msxml2.DOMDocument.6.0")
        manifest.async := false
        manifest.resolveExternals := false
        manifest.setProperty("ProhibitDTD",true)
        directory := RTrim(root,"\") . "\"
        if !manifest.load(directory . "AppxManifest.xml")
            return ""
        for app in manifest.selectNodes("/*[local-name()='Package']/*[local-name()='Applications']/*[local-name()='Application']") {
            if !(app.getAttribute("Id") == appId)
                continue
            relative := app.getAttribute("Executable")
            if Type(relative) != "String" || relative = ""
                return ""
            path := WindowIdentity.VerifiedAliasPath(directory . StrReplace(relative,"/","\"))
            return InStr(path,directory) = 1 ? path : ""
        }
        return ""
    }
    NativeRequiresAppId(id,path) {
        ; A shared host is not a unique launch identity (browser profiles/PWAs,
        ; multiple shortcuts for one executable). Resolve it inside the payload
        ; using the real window/process AppID, never the executable name alone.
        if this.Pwas.Has(id) || WindowIdentity.PackageId(id)
            return true
        canonical := this.CanonicalId(id)
        for other,pwa in this.Pwas {
            if !(this.CanonicalId(other) == canonical) && StrLower(pwa.Host) = StrLower(path)
                return true
        }
        for other,known in this.NativePaths {
            if !(this.CanonicalId(other) == canonical) && StrLower(known) = StrLower(path)
                return true
        }
        SplitPath(path,&exe)
        for other,mapped in this.Mappings {
            if this.CanonicalId(other) == canonical
                continue
            if InStr(mapped,"\") {
                if StrLower(mapped) = StrLower(path)
                    return true
            } else if StrLower(mapped) = StrLower(exe) {
                if !this.NativePaths.Has(other) || StrLower(this.NativePaths[other]) = StrLower(path)
                    return true
            }
        }
        return false
    }
    static WindowAppId(hwnd) => this.WindowAppProperty(hwnd, 5)
    static WindowAppProperty(hwnd, propertyId) {
        store := 0
        iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
        hr := DllCall("shell32\SHGetPropertyStoreForWindow", "ptr", hwnd, "ptr", iid, "ptr*", &store, "int")
        if hr < 0 || !store
            return ""
        obj := ComValue(13, store, 1)
        key := Buffer(20, 0)
        guid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
        DllCall("ntdll\RtlMoveMemory", "ptr", key, "ptr", guid, "uptr", 16)
        NumPut("uint", propertyId, key, 16)
        pv := Buffer(24, 0)
        try {
            ComCall(5, obj, "ptr", key, "ptr", pv)
            vt := NumGet(pv, "ushort")
            return (vt = 31 || vt = 8) && NumGet(pv, 8, "ptr") ? StrGet(NumGet(pv, 8, "ptr")) : ""
        } finally {
            DllCall("ole32\PropVariantClear", "ptr", pv)
        }
    }
    Get(hwnd) {
        pid := Desktop.Pid(hwnd)
        if !pid
            return {Pid: 0, AppId: "", Path: "", Exe: ""}
        ; Cache only process data, never window AppIDs (a HWND can be reused).
        if !this.Cache.Has(pid) || Desktop.Tick() - this.Cache[pid].At > 1500 {
            path := "", appId := ""
            process := DllCall("kernel32\OpenProcess", "uint", 0x1000, "int", false, "uint", pid, "ptr")
            if process {
                try {
                    chars := 32768, b := Buffer(chars * 2, 0)
                    if DllCall("kernel32\QueryFullProcessImageNameW", "ptr", process, "uint", 0, "ptr", b, "uint*", &chars)
                        path := StrGet(b, chars)
                    length := 0
                    code := DllCall("kernel32\GetApplicationUserModelId", "ptr", process, "uint*", &length, "ptr", 0, "int")
                    if code = 122 && length > 0 && length < 32768 {
                        b := Buffer(length * 2, 0)
                        if DllCall("kernel32\GetApplicationUserModelId", "ptr", process, "uint*", &length, "ptr", b, "int") = 0
                            appId := StrGet(b)
                    }
                } finally {
                    DllCall("kernel32\CloseHandle", "ptr", process)
                }
            }
            SplitPath(path, &exe)
            this.Cache[pid] := {Path: path, Exe: exe, AppId: appId, At: Desktop.Tick()}
            if this.Cache.Count > 512
                this.Cache.Clear()
        }
        ; A cache reset must not invalidate the result of this call.
        if !this.Cache.Has(pid)
            return this.Get(hwnd)
        data := this.Cache[pid]
        explicitId := ""
        try explicitId := WindowIdentity.WindowAppId(hwnd)
        return {Pid: pid, AppId: explicitId != "" ? explicitId : data.AppId, Path: data.Path, Exe: data.Exe}
    }
    static ExpandIdPath(id) {
        ; Explorer may express a shortcut path using a known-folder GUID.
        if RegExMatch(id, "^\{[0-9A-Fa-f-]{36}\}\\", &m) {
            ptr := 0
            try {
                guid := Desktop.Guid(SubStr(id, 1, 38))
                if DllCall("shell32\SHGetKnownFolderPath", "ptr", guid, "uint", 0, "ptr", 0, "ptr*", &ptr, "int") >= 0 && ptr
                    return RTrim(StrGet(ptr), "\") . SubStr(id, 39)
            } finally {
                if ptr
                    DllCall("ole32\CoTaskMemFree", "ptr", ptr)
            }
        }
        return id
    }
    Match(appId, data) {
        if appId = ""
            return false
        if data.AppId != ""
            return this.ExplicitMatch(appId,data) ; unknown opaque IDs remain exact and never fall back to a process name
        expanded := WindowIdentity.ExpandIdPath(appId)
        if InStr(expanded, ":\") || SubStr(expanded, 1, 2) = "\\"
            return data.Path != "" && StrLower(expanded) = StrLower(data.Path)
        if this.Mappings.Has(appId) {
            mapped := this.Mappings[appId]
            return InStr(mapped, "\") ? StrLower(mapped) = StrLower(data.Path) : StrLower(mapped) = StrLower(data.Exe)
        }
        return false
    }
}

; A single native cache publish owns this snapshot. Explicit AppIDs are opaque;
; only windows without one enter the case-insensitive path/executable indexes.
class NativeIdentityIndex {
    __New(windows,identity) {
        this.Identity := identity
        this.ByAppId := Map(), this.ByAppId.CaseSense := true
        this.ByPath := Map(), this.ByExe := Map()
        this.Normalized := Map(), this.Normalized.CaseSense := true
        this.Expanded := Map(), this.Expanded.CaseSense := true
        this.Executables := Map(), this.BinaryTypes := Map()
        this.PathOwners := Map(), this.ExeOwners := Map()
        for order,item in windows {
            entry := {Order:order,Item:item}, data := item.Data
            if data.AppId != "" {
                canonical := identity.CanonicalId(data.AppId)
                if !identity.AliasPaths.Has(canonical) || (data.Path != "" && this.Normalize(data.Path) = canonical)
                    NativeIdentityIndex.AddWindow(this.ByAppId,canonical,entry)
            }
            else {
                if data.Path != ""
                    NativeIdentityIndex.AddWindow(this.ByPath,this.Normalize(data.Path),entry)
                NativeIdentityIndex.AddWindow(this.ByExe,this.Normalize(data.Exe),entry)
            }
            ; Candidate path ambiguity is still evaluated across all matches.
            this.Normalize(data.Path)
        }
        for id,pwa in identity.Pwas
            NativeIdentityIndex.AddOwner(this.PathOwners,this.Normalize(pwa.Host),identity.CanonicalId(id))
        for id,path in identity.NativePaths
            NativeIdentityIndex.AddOwner(this.PathOwners,this.Normalize(path),identity.CanonicalId(id))
        for id,mapped in identity.Mappings {
            if InStr(mapped,"\")
                NativeIdentityIndex.AddOwner(this.PathOwners,this.Normalize(mapped),identity.CanonicalId(id))
            else if !identity.NativePaths.Has(id)
                NativeIdentityIndex.AddOwner(this.ExeOwners,this.Normalize(mapped),identity.CanonicalId(id))
            ; A bare-exe mapping with a known path is already in PathOwners.
            ; It must not make another installation of that exe a shared host.
        }
    }
    static AddWindow(index,key,entry) {
        if !index.Has(key)
            index[key] := []
        index[key].Push(entry)
    }
    static AddOwner(index,key,id) {
        if !index.Has(key)
            index[key] := {Id:id,Shared:false}
        else if !(index[key].Id == id)
            index[key].Shared := true
    }
    static HasOtherOwner(index,key,id) {
        return index.Has(key) && (index[key].Shared || !(index[key].Id == id))
    }
    Normalize(path) {
        if !this.Normalized.Has(path)
            this.Normalized[path] := StrLower(path)
        return this.Normalized[path]
    }
    ExpandIdPath(id) {
        if !this.Expanded.Has(id)
            this.Expanded[id] := WindowIdentity.ExpandIdPath(id)
        return this.Expanded[id]
    }
    Matches(id) {
        if id = ""
            return []
        canonical := this.Identity.CanonicalId(id)
        exact := this.ByAppId.Has(canonical) ? this.ByAppId[canonical] : []
        ; With no fallback windows the old matcher only compared opaque IDs.
        ; Do not interpret a GUID-looking explicit ID as a known-folder path.
        fallback := [], expanded := this.ByExe.Count ? this.ExpandIdPath(id) : ""
        if InStr(expanded,":\") || SubStr(expanded,1,2) = "\\" {
            key := this.Normalize(expanded)
            if this.ByPath.Has(key)
                fallback := this.ByPath[key]
        } else if this.Identity.Mappings.Has(id) {
            mapped := this.Identity.Mappings[id]
            index := InStr(mapped,"\") ? this.ByPath : this.ByExe
            key := this.Normalize(mapped)
            if index.Has(key)
                fallback := index[key]
        }
        ; Merge two disjoint, ordered buckets to preserve WinGetList priority.
        result := [], a := 1, b := 1
        while a <= exact.Length || b <= fallback.Length {
            if b > fallback.Length || (a <= exact.Length && exact[a].Order < fallback[b].Order)
                result.Push(exact[a++].Item)
            else
                result.Push(fallback[b++].Item)
        }
        return result
    }
    IsExecutable(path) {
        key := this.Normalize(path)
        if !this.Executables.Has(key)
            this.Executables[key] := !!(FileExist(path) && RegExMatch(path,"i)^[a-z]:\\.*\.exe$"))
        return this.Executables[key]
    }
    BinaryType(path) {
        key := this.Normalize(path)
        if !this.BinaryTypes.Has(key) {
            binaryType := 0
            ; Unknown or unreadable images must never opt into compatibility.
            this.BinaryTypes[key] := DllCall("kernel32\GetBinaryTypeW", "wstr", path,
                "uint*", &binaryType) ? binaryType : -1
        }
        return this.BinaryTypes[key]
    }
    RequiresAppId(id,path) {
        if this.Identity.Pwas.Has(id) || WindowIdentity.PackageId(id)
            return true
        canonical := this.Identity.CanonicalId(id)
        if NativeIdentityIndex.HasOtherOwner(this.PathOwners,this.Normalize(path),canonical)
            return true
        SplitPath(path,&exe)
        return NativeIdentityIndex.HasOtherOwner(this.ExeOwners,this.Normalize(exe),canonical)
    }
}

class WindowMover {
    static Move(hwnd, destination, restoreMinimized := false) {
        Desktop.Physical()
        source := Desktop.MonitorOf(hwnd)
        target := Desktop.Monitor(destination.Handle)
        if !Desktop.Unchanged(target, destination) || !IsObject(source)
            return "monitor-changed"
        if Desktop.SameMonitor(source, target)
            return "already-there"
        p := Desktop.Placement(hwnd)
        if !IsObject(p)
            return "placement-failed"
        wasMin := Desktop.IsMin(hwnd)
        if wasMin && !restoreMinimized
            return "minimized"
        show := NumGet(p, 8, "uint")
        wasMax := show = 3 || (wasMin && (NumGet(p, 4, "uint") & 2))
        normal := Geometry.FromWorkspace(ScreenRect.FromBuffer(p, 28), source)
        if !wasMax && !wasMin
            normal := Desktop.Rect(hwnd)
        if !IsObject(normal)
            return "rect-failed"
        next := Geometry.Map(normal, source.Work, target.Work)
        ; SetWindowPlacement keeps normal/maximized state and its own coordinate system.
        Geometry.ToWorkspace(next, target).Write(p, 28)
        NumPut("uint", 4, p, 4) ; WPF_ASYNCWINDOWPLACEMENT: do not block on a foreign UI thread
        NumPut("uint", wasMax ? 3 : (wasMin ? 9 : 4), p, 8)
        NumPut("int", -1, "int", -1, p, 20) ; let Windows calculate the destination's maximize position
        if wasMax {
            ; Updating only rcNormalPosition while maximized does NOT move the visible window.
            ; Queue restore-on-destination then maximize, in order, without a Sleep or keystrokes.
            NumPut("uint", 4, p, 8) ; SW_SHOWNOACTIVATE
            if !DllCall("user32\SetWindowPlacement", "ptr", hwnd, "ptr", p)
                return "restore-placement-failed:" A_LastError
            NumPut("uint", 3, p, 8)
        }
        if !DllCall("user32\SetWindowPlacement", "ptr", hwnd, "ptr", p)
            return "set-placement-failed:" A_LastError
        return "requested"
    }
}


