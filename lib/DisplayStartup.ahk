; Installs only the small screen detector at desktop startup. The full engine
; starts later, after a second usable display has been detected.
class DisplayStartup {
    static Path() => A_Startup . "\TaskbarFollow.lnk"
    static Arguments(root) => '"' . root . '\DisplayWatch.ahk"'
    static SamePath(a,b) => StrLower(RTrim(StrReplace(a,"/","\"),"\")) == StrLower(RTrim(StrReplace(b,"/","\"),"\"))
    static Shortcut(root,path := "") {
        if path = ""
            path := this.Path()
        if !FileExist(path)
            return "off"
        try {
            FileGetShortcut(path,&target,&directory,&arguments)
            runtime := root . "\runtime\AutoHotkey64.exe"
            if this.SamePath(target,runtime) && Trim(arguments) = this.Arguments(root)
                return this.SamePath(directory,root) ? "screen" : "legacy"
            if (this.SamePath(target,runtime) && Trim(arguments) = '"' . root . '\TaskbarFollow.ahk"')
                || (this.SamePath(target,root . "\Start.exe") && Trim(arguments) = "")
                return "legacy"
        }
        return "foreign"
    }
    static IsEnabled(root,path := "") => this.Shortcut(root,path) = "screen"
    static Validate(root) {
        for relative in ["runtime\AutoHotkey64.exe","DisplayWatch.ahk","TaskbarFollow.ahk","lib\DisplayAutoStart.ahk"] {
            if !FileExist(root . "\" . relative)
                throw Error("屏幕检测组件不完整：" . relative)
        }
    }
    static Set(enabled,root,path := "",startDetector := true) {
        if path = ""
            path := this.Path()
        prior := this.Shortcut(root,path)
        if prior = "foreign"
            throw Error("同名启动快捷方式指向其他程序，未覆盖：" . path)
        if !enabled {
            if prior != "off"
                FileDelete(path)
            return 0
        }
        this.Validate(root)
        previous := prior = "off" ? 0 : FileRead(path,"RAW")
        try {
            FileCreateShortcut(root . "\runtime\AutoHotkey64.exe",path,root,this.Arguments(root),
                "随屏：检测到第二块屏幕后启动",root . "\Start.exe",,1,7)
            if !this.IsEnabled(root,path)
                throw Error("屏幕检测启动入口核对失败。")
            detectorPid := 0
            if startDetector
                Run('"' . root . '\runtime\AutoHotkey64.exe" "' . root . '\DisplayWatch.ahk"',root,"Hide",&detectorPid)
            return detectorPid
        } catch as installError {
            ; Restore only this managed shortcut if a partial install failed.
            try {
                if IsObject(previous) {
                    file := FileOpen(path,"w")
                    try file.RawWrite(previous)
                    finally file.Close()
                } else if FileExist(path)
                    FileDelete(path)
            } catch as rollbackError {
                throw Error(installError.Message . "；启动入口回滚失败：" . rollbackError.Message)
            }
            throw installError
        }
    }
}
