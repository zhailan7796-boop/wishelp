#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\TaskbarFollow.ahk

; Pure cache fixtures: no hooks, UIA, mouse input or application windows.
class IdentityCacheSpy extends WindowIdentity {
    MatchCalls := 0, NativePathCalls := 0
    Match(id,data) {
        this.MatchCalls += 1
        return super.Match(id,data)
    }
    NativePath(id,expanded := unset) {
        this.NativePathCalls += 1
        return IsSet(expanded) ? super.NativePath(id,expanded) : super.NativePath(id)
    }
    ResetCounts() => (this.MatchCalls := 0, this.NativePathCalls := 0)
}

class FailingIdentityCacheSpy extends IdentityCacheSpy {
    __New() {
        super.__New("",false)
        this.Mappings.Clear()
        this.PathCallsById := Map(), this.PathCallsById.CaseSense := true
    }
    NativePath(id,expanded := unset) {
        this.PathCallsById[id] := this.PathCallsById.Has(id) ? this.PathCallsById[id]+1 : 1
        if id == "Local.Failure" {
            this.NativePathCalls += 1
            throw Error("Expected fixture identity failure")
        }
        return IsSet(expanded) ? super.NativePath(id,expanded) : super.NativePath(id)
    }
}

class IdentityCacheChecks {
    static Count := 0
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual,expected,label) => this.Assert(actual == expected,label . " (actual=" . actual . ", expected=" . expected . ")")
    static Identity(spy := false) {
        ids := spy ? IdentityCacheSpy("",false) : WindowIdentity("",false)
        ids.Mappings.Clear()
        return ids
    }
    static Window(number,id,path) {
        SplitPath(path,&exe)
        return {Hwnd:number,Data:{Pid:1000+number,AppId:id,Path:path,Exe:exe}}
    }
    static SameWindows(actual,expected,label) {
        this.Equal(actual.Length,expected.Length,label . ": candidate count")
        for number,item in expected
            this.Assert(actual[number] = item,label . ": original object and order " . number)
    }
    static LegacyMatches(id,windows,identity) {
        matches := []
        for item in windows {
            if identity.Match(id,item.Data)
                matches.Push(item)
        }
        return matches
    }
    ; Preserve the pre-optimization resolver as an independent equivalence oracle.
    static LegacyEntry(id,windows,identity) {
        candidates := [], paths := Map()
        for item in windows {
            if identity.Match(id,item.Data) {
                if candidates.Length < 32
                    candidates.Push(item)
                if item.Data.Path != ""
                    paths[StrLower(item.Data.Path)] := item.Data.Path
            }
        }
        path := ""
        if paths.Count = 1 {
            for pathKey,pathValue in paths {
                path := pathValue
                break
            }
        }
        if !paths.Count
            path := identity.NativePath(id)
        if StrLen(path) >= 1024
            path := ""
        cold := path != "" && FileExist(path) && RegExMatch(path,"i)^[a-z]:\\.*\.exe$")
        requireId := cold && identity.NativeRequiresAppId(id,path)
        binaryType := 0
        compatibility := cold && DllCall("kernel32\GetBinaryTypeW","wstr",path,"uint*",&binaryType) && binaryType = 0
        return {Id:id,Path:path,Candidates:candidates,Flags:(cold?1:0)|(requireId?2:0)|(compatibility?4:0)}
    }
    static LegacyButtons(buttons,windows,identity) {
        records := []
        for button in buttons {
            entry := this.LegacyEntry(button.Id,windows,identity)
            entry.Bar := button.Bar, entry.Rect := button.Rect
            records.Push(entry)
        }
        return records
    }
    static SameEntry(actual,expected,label) {
        this.Equal(actual.Id,expected.Id,label . ": exact AppID")
        this.Equal(actual.Path,expected.Path,label . ": launch path")
        this.Equal(actual.Flags,expected.Flags,label . ": launch flags")
        this.SameWindows(actual.Candidates,expected.Candidates,label)
    }
    static CheckRequires(identity,id,path,label) {
        index := NativeIdentityIndex([],identity)
        this.Equal(!!index.RequiresAppId(id,path),!!identity.NativeRequiresAppId(id,path),label)
    }
    static Now() {
        DllCall("kernel32\QueryPerformanceCounter","int64*",&counter := 0)
        return counter
    }
    static Benchmark(path,idCount,openIds,windowsPerId,rounds,label) {
        identity := this.Identity(true), windows := [], buttons := []
        ; Fixed synthetic windows; each identity is repeated on two taskbars.
        Loop idCount {
            number := A_Index, id := "Benchmark.App." . number
            identity.Mappings[id] := path
            identity.NativePaths[id] := path
            buttons.Push({Id:id,Bar:11,Rect:ScreenRect(number*40,1000,number*40+36,1040)})
            buttons.Push({Id:id,Bar:22,Rect:ScreenRect(number*40-1920,1000,number*40-1884,1040)})
            if number <= openIds {
                Loop windowsPerId
                    windows.Push(this.Window(number*100+A_Index,id,path))
            }
        }
        expected := this.LegacyButtons(buttons,windows,identity)
        actual := NativeEngine.ResolveButtons(buttons,windows,identity)
        this.Equal(actual.Length,expected.Length,"Benchmark fixture keeps every button")
        for number,entry in expected
            this.SameEntry(actual[number],entry,"Benchmark equivalence " . number)

        DllCall("kernel32\QueryPerformanceFrequency","int64*",&frequency := 0)
        identity.ResetCounts()
        started := this.Now()
        Loop rounds
            this.LegacyButtons(buttons,windows,identity)
        legacyMs := (this.Now()-started)*1000/frequency
        legacyMatches := identity.MatchCalls, legacyPaths := identity.NativePathCalls
        identity.ResetCounts()
        started := this.Now()
        Loop rounds
            NativeEngine.ResolveButtons(buttons,windows,identity)
        indexedMs := (this.Now()-started)*1000/frequency
        indexedMatches := identity.MatchCalls, indexedPaths := identity.NativePathCalls
        this.Assert(indexedMatches < legacyMatches,"Indexed rounds avoid repeated window Match calls")
        this.Equal(indexedPaths*2,legacyPaths,"Two taskbars perform one cold identity path lookup per round")
        FileAppend("PERF identity-cache synthetic-" . label . ": rounds=" . rounds . "; buttons=" . buttons.Length . "; windows=" . windows.Length
            . "; legacy-ms=" . Round(legacyMs,3) . "; indexed-ms=" . Round(indexedMs,3)
            . "; legacy-match-calls=" . legacyMatches . "; indexed-match-calls=" . indexedMatches
            . "; legacy-native-path-calls=" . legacyPaths . "; indexed-native-path-calls=" . indexedPaths . "`n","*","UTF-8")
    }
}

fixtureDirectory := A_Temp . "\TaskbarFollow-identity-" . DllCall("kernel32\GetCurrentProcessId","uint") . "-" . Desktop.Tick()
firstPath := fixtureDirectory . "\fixture.exe", secondPath := fixtureDirectory . "\other.exe"
exitCode := 0
try {
    DirCreate(fixtureDirectory)
    ; These are inert text files used only by FileExist; they are never executed.
    FileAppend("Identity cache file-existence fixture",firstPath,"UTF-8")
    FileAppend("Identity cache alternate fixture",secondPath,"UTF-8")
    ids := IdentityCacheChecks.Identity()
    ids.Mappings["Local.Mixed"] := firstPath
    ids.Mappings["local.mixed"] := secondPath
    ids.Mappings["Local.ByExe"] := "fixture.exe"
    ids.Mappings["Local.ByPath"] := firstPath
    folderId := "{6D809377-6AF0-444B-8957-A3773F02200E}\Vendor\fixture.exe"
    windows := [IdentityCacheChecks.Window(1,"Local.Mixed",firstPath),
        IdentityCacheChecks.Window(2,"",firstPath),
        IdentityCacheChecks.Window(3,"Local.Other",firstPath),
        IdentityCacheChecks.Window(4,"local.mixed",firstPath),
        IdentityCacheChecks.Window(5,"",secondPath),
        IdentityCacheChecks.Window(6,"Local.Mixed",secondPath),
        IdentityCacheChecks.Window(7,"",""),
        IdentityCacheChecks.Window(8,"","\\server\share\fixture.exe"),
        IdentityCacheChecks.Window(9,"",WindowIdentity.ExpandIdPath(folderId))]
    index := NativeIdentityIndex(windows,ids)
    for id in ["Local.Mixed","local.mixed","Local.Other","Local.ByExe","Local.ByPath","Unknown","",StrUpper(firstPath),"\\SERVER\SHARE\FIXTURE.EXE",folderId] {
        IdentityCacheChecks.SameWindows(index.Matches(id),IdentityCacheChecks.LegacyMatches(id,windows,ids),"Indexed matches " . id)
        IdentityCacheChecks.SameEntry(NativeEngine.ResolveEntry(id,windows,ids,index),IdentityCacheChecks.LegacyEntry(id,windows,ids),"Indexed resolver " . id)
    }
    IdentityCacheChecks.SameWindows(index.Matches("Local.Mixed"),[windows[1],windows[2],windows[6]],"Exact and fallback candidates merge in enumeration order")
    IdentityCacheChecks.SameWindows(index.Matches("local.mixed"),[windows[4],windows[5]],"Case-distinct AppIDs keep separate fallback mappings")

    aliasIds := IdentityCacheChecks.Identity()
    aliasPath := A_ScriptDir . "\..\runtime\AutoHotkey32.exe"
    aliasIds.LoadAliases("TencentVideo.QQLive.v1=" . aliasPath)
    aliasPath := aliasIds.NativePath("TencentVideo.QQLive.v1")
    aliasWindows := [IdentityCacheChecks.Window(70,"TencentVideo.QQLive.v1",aliasPath),
        IdentityCacheChecks.Window(71,"",StrUpper(aliasPath)),
        IdentityCacheChecks.Window(72,"Other.Explicit.App",aliasPath),
        IdentityCacheChecks.Window(73,"TencentVideo.QQLive.v1",firstPath),
        IdentityCacheChecks.Window(74,StrUpper(aliasPath),aliasPath),
        IdentityCacheChecks.Window(75,"tencentvideo.qqlive.v1",aliasPath)]
    aliasIndex := NativeIdentityIndex(aliasWindows,aliasIds)
    for id in ["TencentVideo.QQLive.v1",aliasPath,StrUpper(aliasPath),"tencentvideo.qqlive.v1","Other.Explicit.App"] {
        IdentityCacheChecks.SameWindows(aliasIndex.Matches(id),IdentityCacheChecks.LegacyMatches(id,aliasWindows,aliasIds),"Explicit alias matcher equivalence " . id)
        IdentityCacheChecks.SameEntry(NativeEngine.ResolveEntry(id,aliasWindows,aliasIds,aliasIndex),
            IdentityCacheChecks.LegacyEntry(id,aliasWindows,aliasIds),"Explicit alias resolver equivalence " . id)
        IdentityCacheChecks.CheckRequires(aliasIds,id,aliasPath,"Explicit alias shared-owner equivalence " . id)
    }
    aliasIds.Mappings["Other.Shared.App"] := aliasPath
    for id in ["TencentVideo.QQLive.v1",aliasPath,StrUpper(aliasPath)] {
        IdentityCacheChecks.CheckRequires(aliasIds,id,aliasPath,"Another shared owner preserves alias requirements " . id)
        IdentityCacheChecks.Assert(NativeIdentityIndex([],aliasIds).RequiresAppId(id,aliasPath),"A distinct shared host still requires the exact AppID")
    }

    opaqueId := "{------------------------------------}\app"
    opaqueWindows := [IdentityCacheChecks.Window(99,opaqueId,firstPath)]
    opaqueEntry := NativeEngine.ResolveEntry(opaqueId,opaqueWindows,ids)
    IdentityCacheChecks.Equal(opaqueEntry.Candidates.Length,1,"Explicit opaque AppID is matched without attempting invalid GUID path expansion")
    IdentityCacheChecks.SameEntry(opaqueEntry,IdentityCacheChecks.LegacyEntry(opaqueId,opaqueWindows,ids),"Opaque GUID-shaped ID preserves explicit match")
    opaqueRecords := NativeEngine.ResolveButtons([{Id:opaqueId,Bar:101,Rect:ScreenRect(0,0,40,40)}],opaqueWindows,ids)
    IdentityCacheChecks.Equal(opaqueRecords.Length,1,"A GUID-shaped exact AppID is not silently dropped from buttons")

    ; A candidate beyond the ABI limit must still invalidate an ambiguous path.
    many := []
    Loop 33
        many.Push(IdentityCacheChecks.Window(A_Index,"Local.Many",A_Index = 33 ? secondPath : firstPath))
    manyIndex := NativeIdentityIndex(many,ids)
    manyEntry := NativeEngine.ResolveEntry("Local.Many",many,ids,manyIndex)
    IdentityCacheChecks.Equal(manyEntry.Candidates.Length,32,"Candidate ABI remains capped at 32")
    IdentityCacheChecks.Equal(manyEntry.Candidates[32].Hwnd,32,"Candidate cap retains first windows")
    IdentityCacheChecks.Assert(manyEntry.Path = "" && manyEntry.Flags = 0,"The 33rd path prevents ambiguous cold launch")
    IdentityCacheChecks.SameEntry(manyEntry,IdentityCacheChecks.LegacyEntry("Local.Many",many,ids),"Full path ambiguity beyond candidate cap")

    shared := IdentityCacheChecks.Identity()
    shared.Mappings["Local.Other"] := "fixture.exe"
    shared.NativePaths["Local.Other"] := fixtureDirectory . "\elsewhere\fixture.exe"
    IdentityCacheChecks.CheckRequires(shared,"Local.Self",firstPath,"Bare executable mapped to another full path is not a shared host")
    IdentityCacheChecks.Assert(!NativeIdentityIndex([],shared).RequiresAppId("Local.Self",firstPath),"Known different path does not require AppID")
    shared.NativePaths.Delete("Local.Other")
    IdentityCacheChecks.CheckRequires(shared,"Local.Self",firstPath,"Bare executable without known path is a shared host")
    IdentityCacheChecks.Assert(NativeIdentityIndex([],shared).RequiresAppId("Local.Self",firstPath),"Unknown bare-executable path requires AppID")
    shared.Mappings.Clear()
    shared.Mappings["Local.Self"] := firstPath
    IdentityCacheChecks.CheckRequires(shared,"Local.Self",firstPath,"An identity sharing only with itself is not ambiguous")
    IdentityCacheChecks.Assert(!NativeIdentityIndex([],shared).RequiresAppId("Local.Self",firstPath),"Own path association alone does not require AppID")
    shared.NativePaths["local.self"] := StrUpper(firstPath)
    IdentityCacheChecks.CheckRequires(shared,"Local.Self",firstPath,"Case-distinct identities with case-insensitive equal paths share a host")
    IdentityCacheChecks.Assert(NativeIdentityIndex([],shared).RequiresAppId("Local.Self",firstPath),"Case-distinct AppID requires exact native identity")
    shared.NativePaths.Clear()
    shared.Pwas["Local.Pwa"] := {Host:firstPath,App:"fixture",Profile:"Default"}
    IdentityCacheChecks.CheckRequires(shared,"Local.Self",firstPath,"A separate PWA shares its host")
    IdentityCacheChecks.CheckRequires(shared,"Local.Pwa",secondPath,"PWA's own identity always requires AppID")

    cold := IdentityCacheChecks.Identity(true)
    cold.Mappings["Local.Cold"] := firstPath
    buttons := [{Id:"Local.Cold",Bar:101,Rect:ScreenRect(10,1000,50,1040)},
        {Id:"Local.Cold",Bar:202,Rect:ScreenRect(-1910,1000,-1870,1040)}]
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records.Length,2,"Both taskbar buttons remain in the cache")
    IdentityCacheChecks.Equal(cold.NativePathCalls,1,"Repeated exact AppID resolves its cold launch path once")
    IdentityCacheChecks.Assert(records[1] != records[2],"Each taskbar button has a distinct record")
    IdentityCacheChecks.Assert(records[1].Candidates = records[2].Candidates,"Buttons reuse their resolved candidate array")
    IdentityCacheChecks.Assert(records[1].Bar = 101 && records[2].Bar = 202,"Buttons retain independent taskbar handles")
    IdentityCacheChecks.Assert(records[1].Rect.L = 10 && records[2].Rect.L = -1910,"Buttons retain independent physical rectangles")
    records[2].Bar := 303
    records[2].Rect.L := -1900
    IdentityCacheChecks.Assert(records[1].Bar = 101 && records[1].Rect.L = 10,"Changing one button cannot overwrite another button geometry")
    cold.ResetCounts()
    NativeEngine.ResolveButtons([buttons[1],{Id:"local.cold",Bar:404,Rect:ScreenRect(20,0,60,40)}],[],cold)
    IdentityCacheChecks.Equal(cold.NativePathCalls,2,"Case-distinct button IDs are resolved separately")

    warm := [IdentityCacheChecks.Window(500,"Local.Cold",firstPath)]
    records := NativeEngine.ResolveButtons(buttons,warm,cold)
    IdentityCacheChecks.Equal(records[1].Candidates.Length,1,"A new round sees an opened window")
    IdentityCacheChecks.Assert(records[1].Candidates = records[2].Candidates,"Warm candidates are also shared across taskbars")
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records[1].Candidates.Length,0,"A new round discards a closed window")
    cold.Mappings["Local.Cold"] := secondPath
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records[1].Path,secondPath,"A new round observes mapping changes")
    FileDelete(secondPath)
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records[1].Flags,0,"A new round does not reuse a deleted executable's launch eligibility")
    FileAppend("Identity cache alternate fixture",secondPath,"UTF-8")
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Assert(records[1].Flags & 1,"A recreated executable is eligible in the next round")
    cold.Mappings["Local.Alias"] := secondPath
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records[1].Flags,3,"A new round rebuilds shared-host associations")
    cold.Mappings.Delete("Local.Alias")
    records := NativeEngine.ResolveButtons(buttons,[],cold)
    IdentityCacheChecks.Equal(records[1].Flags,1,"Removing a shared-host alias takes effect next round")

    failing := FailingIdentityCacheSpy()
    failing.Mappings["Local.Working"] := firstPath
    failureButtons := [{Id:"Local.Failure",Bar:101,Rect:ScreenRect(0,0,40,40)},
        {Id:"Local.Failure",Bar:202,Rect:ScreenRect(-1920,0,-1880,40)},
        {Id:"Local.Working",Bar:101,Rect:ScreenRect(40,0,80,40)}]
    records := NativeEngine.ResolveButtons(failureButtons,[],failing)
    IdentityCacheChecks.Equal(failing.PathCallsById["Local.Failure"],1,"A failing identity is queried only once per round")
    IdentityCacheChecks.Equal(records.Length,1,"A failing identity does not discard a later healthy button")
    IdentityCacheChecks.Equal(records[1].Id,"Local.Working","The later healthy identity remains in the cache")
    IdentityCacheChecks.Assert(records[1].Flags & 1,"The later healthy identity retains launch eligibility")

    capped := FailingIdentityCacheSpy()
    capButtons := [failureButtons[1],failureButtons[2]]
    Loop 65 {
        id := "Local.Cap." . A_Index
        capped.Mappings[id] := firstPath
        capButtons.Push({Id:id,Bar:101,Rect:ScreenRect(A_Index*40,0,A_Index*40+36,40)})
    }
    records := NativeEngine.ResolveButtons(capButtons,[],capped)
    IdentityCacheChecks.Equal(records.Length,64,"The native button cache accepts at most 64 successful records")
    IdentityCacheChecks.Equal(records[1].Id,"Local.Cap.1","Earlier failed buttons do not consume the successful-record budget")
    IdentityCacheChecks.Equal(records[64].Id,"Local.Cap.64","The 64th successful button is retained")
    IdentityCacheChecks.Equal(capped.PathCallsById["Local.Failure"],1,"Repeated failed buttons remain deduplicated before the cache fills")
    IdentityCacheChecks.Assert(!capped.PathCallsById.Has("Local.Cap.65"),"The 65th successful identity's path is not queried after the cache fills")
    IdentityCacheChecks.Equal(capped.NativePathCalls,65,"Only one failed and 64 successful identities are resolved")

    IdentityCacheChecks.Benchmark(firstPath,12,8,3,30,"typical")
    IdentityCacheChecks.Benchmark(firstPath,24,16,8,30,"large")
    FileAppend("PASS " . IdentityCacheChecks.Count . " identity-cache assertions`n","*","UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . " (line " . e.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally {
    ; Delete only the two owned files, then the now-empty owned directory.
    if FileExist(firstPath)
        FileDelete(firstPath)
    if FileExist(secondPath)
        FileDelete(secondPath)
    if DirExist(fixtureDirectory)
        DirDelete(fixtureDirectory)
}
ExitApp(exitCode)
