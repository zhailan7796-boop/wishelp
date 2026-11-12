#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\lib\Native.ahk
#Include ..\lib\NativeEngine.ahk

; Identity-only checks: no hooks, UIA, user input or application windows.
class AppIdentityChecks {
    static Count := 0
    static Assert(value, label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static Equal(actual, expected, label) => this.Assert(actual == expected,
        label . " (actual=" . actual . ", expected=" . expected . ")")
    static Window(number, appId, path) {
        SplitPath(path, &exe)
        return {Hwnd:number, Data:{Pid:number+1000, AppId:appId, Path:path, Exe:exe}}
    }
}

config := A_Temp . "\TaskbarFollow-AppIdentity-" . DllCall("kernel32\GetCurrentProcessId", "uint") . ".ini"
nonImage := config . ".exe"
aliasConfig := config . ".alias.ini"
packageRoot := config . ".package"
packageImage := packageRoot . "\app\Fixture.exe"
escapedImage := config . ".outside.exe"
manifest := packageRoot . "\AppxManifest.xml"
exitCode := 0
try {
    id := "Microsoft.Windows.Explorer", systemPath := A_WinDir . "\explorer.exe"
    ids := WindowIdentity("", false)
    AppIdentityChecks.Equal(ids.NativePath(id), systemPath, "Explorer resolves to the Windows system image without an open window")
    cold := NativeEngine.ResolveEntry(id, [], ids)
    AppIdentityChecks.Equal(cold.Path, systemPath, "Cold Explorer button retains the verified system path")
    AppIdentityChecks.Equal(cold.Candidates.Length, 0, "Cold Explorer resolution does not invent a window")
    AppIdentityChecks.Equal(cold.Flags, 1, "Cold Explorer is eligible without requiring an absent explicit AppID")

    matching := AppIdentityChecks.Window(1, "", systemPath)
    otherInstallation := AppIdentityChecks.Window(2, "", A_Temp . "\Other\explorer.exe")
    mismatched := AppIdentityChecks.Window(3, "Other.Explicit.App", systemPath)
    exact := AppIdentityChecks.Window(4, id, systemPath)
    AppIdentityChecks.Assert(ids.Match(id, matching.Data), "Explorer without an explicit AppID matches its exact system image")
    AppIdentityChecks.Assert(!ids.Match(id, otherInstallation.Data), "Explorer filename elsewhere is not the Windows shell identity")
    AppIdentityChecks.Assert(!ids.Match(id, mismatched.Data), "An explicit foreign AppID still overrides the system path")
    AppIdentityChecks.Assert(!ids.Match("microsoft.windows.explorer", exact.Data), "Opaque Explorer AppIDs remain case-sensitive")
    warm := NativeEngine.ResolveEntry(id, [matching, otherInstallation, mismatched, exact], ids)
    AppIdentityChecks.Equal(warm.Candidates.Length, 2, "Indexed Explorer resolver preserves exact AppID and exact path safety")
    AppIdentityChecks.Assert(warm.Candidates[1] = matching && warm.Candidates[2] = exact,
        "Indexed Explorer candidates keep the matching windows and their order")
    AppIdentityChecks.Equal(ids.NativePath("microsoft.windows.explorer"), "", "A different-case unknown ID has no inferred launch path")

    IniWrite("explorer.exe", config, "AppIdMap", id)
    configured := WindowIdentity(config, false)
    AppIdentityChecks.Equal(configured.NativePath(id), systemPath, "The existing default INI mapping resolves the system image")
    AppIdentityChecks.Assert(!configured.Match(id, otherInstallation.Data), "The existing default INI mapping cannot match another explorer.exe")
    IniWrite(A_AhkPath, config, "AppIdMap", id)
    configured := WindowIdentity(config, false)
    AppIdentityChecks.Equal(configured.NativePath(id), A_AhkPath, "An explicit different full-path mapping remains honored")
    IniWrite("TaskbarFollow-Missing-Identity.exe", config, "AppIdMap", id)
    configured := WindowIdentity(config, false)
    AppIdentityChecks.Equal(configured.NativePath(id), "", "A different user executable mapping does not borrow the system Explorer path")

    SplitPath(A_ScriptDir,, &root)
    x86Path := root . "\runtime\AutoHotkey32.exe", x64Path := root . "\runtime\AutoHotkey64.exe"
    architecture := NativeIdentityIndex([], ids)
    AppIdentityChecks.Equal(architecture.BinaryType(x86Path), 0, "A real 32-bit image is verified from its binary header")
    AppIdentityChecks.Equal(architecture.BinaryType(x64Path), 6, "A real 64-bit image stays on the native route")
    architecture.BinaryType(StrUpper(x86Path))
    AppIdentityChecks.Equal(architecture.BinaryTypes.Count, 2, "Binary type queries share a case-insensitive path cache per publish")
    AppIdentityChecks.Equal(NativeEngine.ResolveEntry(x86Path, [], ids).Flags, 5, "A verified 32-bit path opts into compatibility")
    AppIdentityChecks.Equal(NativeEngine.ResolveEntry(x64Path, [], ids).Flags, 1, "A verified 64-bit path retains native cold positioning")
    FileAppend("Inert executable-existence fixture; never executed", nonImage, "UTF-8")
    AppIdentityChecks.Equal(architecture.BinaryType(nonImage . ".missing"), -1, "A failed binary query remains an unknown architecture")
    AppIdentityChecks.Assert(architecture.BinaryType(nonImage) != 0, "An inert text fixture is not classified as a 32-bit Windows image")
    AppIdentityChecks.Equal(NativeEngine.ResolveEntry(nonImage, [], ids).Flags, 1, "An existing non-image does not get a guessed 32-bit compatibility flag")

    ; A package may expose multiple app IDs and share an image between them.
    DirCreate(packageRoot . "\app")
    FileCopy(x64Path,packageImage)
    FileCopy(x64Path,escapedImage)
    SplitPath(escapedImage,&escapedLeaf)
    FileAppend('<Package xmlns="http://schemas.microsoft.com/appx/manifest/foundation/windows10"><Applications>'
        . '<Application Id="Entry" Executable="app/Fixture.exe"/><Application Id="Secondary" Executable="app/Fixture.exe"/>'
        . '<Application Id="Outside" Executable="../' . escapedLeaf . '"/>'
        . '</Applications></Package>',manifest,"UTF-8")
    AppIdentityChecks.Equal(WindowIdentity.ManifestExecutable(packageRoot,"Entry"),packageImage,
        "The exact manifest entry resolves its relative executable")
    AppIdentityChecks.Equal(WindowIdentity.ManifestExecutable(packageRoot,"entry"),"","Package app IDs remain case-sensitive")
    AppIdentityChecks.Equal(WindowIdentity.ManifestExecutable(packageRoot,"Missing"),"","An absent app cannot borrow a sibling's image")
    AppIdentityChecks.Equal(WindowIdentity.ManifestExecutable(packageRoot,"Outside"),"","A package entry cannot escape the installed directory")
    packagedId := "TaskbarFollow.IdentityFixture_0000000000000!Entry"
    AppIdentityChecks.Equal(NativeEngine.ResolveEntry(packagedId, [], ids).Flags,0,"An unregistered package is not a verified launch identity")
    ids.Mappings[packagedId] := packageImage
    packaged := NativeEngine.ResolveEntry(packagedId, [], ids)
    AppIdentityChecks.Equal(packaged.Flags,11,"A packaged cold launch has an exact-ID native route and bounded after-show fallback")
    warmPackage := NativeEngine.ResolveEntry(packagedId,[AppIdentityChecks.Window(6,packagedId,packageImage)],ids)
    AppIdentityChecks.Equal(warmPackage.Flags,3,"A known packaged window stays on the existing native route")
    AppIdentityChecks.Assert(!ids.Match(packagedId,{AppId:"TaskbarFollow.IdentityFixture_0000000000000!Secondary",
        Path:packageImage,Exe:"Fixture.exe"}),"A different entry sharing a package image cannot match")

    videoId := "TencentVideo.QQLive.v1"
    IniWrite(x86Path, aliasConfig, "AppIdAlias", videoId)
    aliased := WindowIdentity(aliasConfig, false)
    AppIdentityChecks.Equal(aliased.NativePath(videoId), x86Path, "An explicit alias alone supplies its verified full-path mapping")
    AppIdentityChecks.Equal(aliased.CanonicalId(videoId), StrLower(x86Path), "An opaque alias resolves to its exact executable identity")
    AppIdentityChecks.Equal(aliased.CanonicalId(StrUpper(x86Path)), StrLower(x86Path), "Canonical path identity is case-insensitive")
    namedCold := NativeEngine.ResolveEntry(videoId, [], aliased)
    pathCold := NativeEngine.ResolveEntry(StrUpper(x86Path), [], aliased)
    AppIdentityChecks.Equal(namedCold.Flags, 5, "The explicit 32-bit runtime AppID uses compatibility without inventing a shared host")
    AppIdentityChecks.Equal(pathCold.Flags, 5, "The pinned executable identity remains compatible rather than requiring a missing AppID")
    AppIdentityChecks.Equal(namedCold.Path, x86Path, "The runtime AppID retains its verified cold path")
    videoWindow := AppIdentityChecks.Window(11, videoId, x86Path)
    plainWindow := AppIdentityChecks.Window(12, "", x86Path)
    foreignWindow := AppIdentityChecks.Window(13, "Foreign.Explicit.App", x86Path)
    otherInstall := AppIdentityChecks.Window(14, videoId, A_Temp . "\Other\AutoHotkey32.exe")
    AppIdentityChecks.Assert(aliased.Match(StrUpper(x86Path), videoWindow.Data), "A pin matches its explicitly declared runtime AppID alias")
    AppIdentityChecks.Assert(aliased.Match(videoId, plainWindow.Data), "A declared alias can match the same exact path without a remote AppID")
    AppIdentityChecks.Assert(!aliased.Match(x86Path, foreignWindow.Data), "Unrelated explicit AppIDs still cannot borrow a configured alias path")
    AppIdentityChecks.Assert(!aliased.Match(videoId, otherInstall.Data), "A reused runtime AppID from another installation is rejected")
    AppIdentityChecks.Assert(!aliased.Match(StrLower(videoId), videoWindow.Data), "Opaque alias keys remain case-sensitive")
    for buttonId in [videoId, x86Path, StrUpper(x86Path)] {
        entry := NativeEngine.ResolveEntry(buttonId, [videoWindow, plainWindow, foreignWindow, otherInstall], aliased)
        AppIdentityChecks.Equal(entry.Candidates.Length, 2, "Both alias forms find the same eligible warm candidates")
        AppIdentityChecks.Assert(entry.Candidates[1] = videoWindow && entry.Candidates[2] = plainWindow,
            "Alias indexing preserves matching window order and excludes foreign identities")
        AppIdentityChecks.Equal(entry.Flags, 5, "Warm alias forms retain one verified compatibility identity")
    }
    aliased.Mappings["Other.Shared.App"] := x86Path
    aliasIndex := NativeIdentityIndex([], aliased)
    for buttonId in [videoId, x86Path, StrUpper(x86Path)] {
        AppIdentityChecks.Assert(aliased.NativeRequiresAppId(buttonId, x86Path), "Another identity sharing the host still requires an AppID")
        AppIdentityChecks.Assert(aliasIndex.RequiresAppId(buttonId, x86Path), "Indexed shared-host checks preserve the exact-ID requirement")
    }
    IniWrite(x64Path, aliasConfig, "AppIdMap", videoId)
    conflict := WindowIdentity(aliasConfig, false)
    AppIdentityChecks.Assert(!conflict.Aliases.Has(videoId), "A conflicting explicit full-path mapping rejects the alias")
    AppIdentityChecks.Equal(conflict.NativePath(videoId), x64Path, "Rejected aliases do not overwrite explicit mappings")
    rejected := WindowIdentity("", false)
    rejected.LoadAliases("Missing.Image=" . config . ".missing.exe`nNot.PE=" . nonImage
        . "`nChain.A=Chain.B`nChain.B=Chain.A`n" . x64Path . "=" . x86Path
        . "`n{6D809377-6AF0-444B-8957-A3773F02200E}\KnownFolder.exe=" . x86Path)
    AppIdentityChecks.Equal(rejected.Aliases.Count, 0, "Missing/non-PE images, alias cycles, absolute and known-folder path redirection fail closed")
    rejected.Pwas["Fixture.Pwa"] := {Host:x86Path,App:"Fixture",Profile:"Default"}
    rejected.LoadAliases("Fixture.Pwa=" . x86Path)
    AppIdentityChecks.Assert(!rejected.Aliases.Has("Fixture.Pwa"), "A PWA launch identity is not reduced to its shared executable")

    FileAppend("PASS app-identity assertions=" . AppIdentityChecks.Count . "`n", "*", "UTF-8")
} catch as e {
    FileAppend("FAIL " . e.Message . "; line=" . e.Line . "`n", "*", "UTF-8")
    exitCode := 1
} finally {
    if FileExist(config)
        FileDelete(config)
    if FileExist(nonImage)
        FileDelete(nonImage)
    if FileExist(aliasConfig)
        FileDelete(aliasConfig)
    for fixtureFile in [manifest,packageImage,escapedImage] {
        if FileExist(fixtureFile)
            FileDelete(fixtureFile)
    }
    if DirExist(packageRoot . "\app")
        DirDelete(packageRoot . "\app")
    if DirExist(packageRoot)
        DirDelete(packageRoot)
}
ExitApp(exitCode)
