; Registers only the screen detector. The full engine still waits for a second
; usable display. Existing Startup folder entries can be migrated explicitly.
class DisplayStartup {
    static Path() => A_Startup . "\TaskbarFollow.lnk"
    static Arguments(root) => '"' . root . '\DisplayWatch.ahk"'
    static LogonArguments(root) => this.Arguments(root) . " --logon-task"
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
    static IsEnabled(root,path := "") {
        if path != ""
            return this.Shortcut(root,path) = "screen"
        try {
            state := DisplayLogonTask(root).Status()
            if state = "screen"
                return true
        }
        return this.Shortcut(root) = "screen"
    }
    static Validate(root) {
        for relative in ["runtime\AutoHotkey64.exe","DisplayWatch.ahk","TaskbarFollow.ahk","lib\DisplayAutoStart.ahk"] {
            if !FileExist(root . "\" . relative)
                throw Error("屏幕检测组件不完整：" . relative)
        }
    }
    static Set(enabled,root,path := "",startDetector := true) {
        if path = ""
            return this.SetLogonTask(enabled,root,startDetector)
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
    static SetLogonTask(enabled,root,startDetector) {
        logon := DisplayLogonTask(root)
        path := this.Path(), oldEntry := this.Shortcut(root,path)
        managedShortcut := oldEntry = "screen" || oldEntry = "legacy"
        if !enabled {
            logon.Remove()
            if managedShortcut
                FileDelete(path)
            return 0
        }
        this.Validate(root)
        previous := logon.Get()
        previousXml := IsObject(previous) ? previous.Xml : ""
        task := logon.Register(previous)
        try {
            if logon.Status(task) != "screen"
                throw Error("登录任务回读核对失败。")
            instance := startDetector ? task.Run(0).InstanceGuid : 0
            if managedShortcut
                FileDelete(path)
            return instance
        } catch as failure {
            if previousXml = ""
                logon.Remove()
            else
                logon.Restore(previousXml)
            throw failure
        }
    }
}

class DisplayLogonTask {
    static Source := "TaskbarFollow.DisplayWatch"
    __New(root, name := "") {
        this.Root := root
        this.Account := ComObject("WScript.Network").UserDomain . "\" . A_UserName
        this.User := this.Sid(this.Account)
        if this.User = ""
            throw Error("无法识别当前 Windows 用户。")
        hash := 2166136261
        Loop Parse this.User
            hash := ((hash ^ Ord(A_LoopField)) * 16777619) & 0xffffffff
        this.Name := name != "" ? name : "TaskbarFollow-DisplayWatch-" . Format("{:08X}",hash)
        this.Service := ComObject("Schedule.Service")
        this.Service.Connect()
        this.Folder := this.Service.GetFolder("\")
    }
    Sid(account) {
        if RegExMatch(account,"^S-1-[0-9-]+$")
            return account
        bytes := 0, chars := 0, use := 0
        DllCall("advapi32\LookupAccountNameW","ptr",0,"wstr",account,"ptr",0,"uint*",&bytes,"ptr",0,"uint*",&chars,"uint*",&use)
        if !bytes || !chars
            return ""
        sid := Buffer(bytes), domain := Buffer(chars*2), value := 0
        if !DllCall("advapi32\LookupAccountNameW","ptr",0,"wstr",account,"ptr",sid,"uint*",&bytes,
            "ptr",domain,"uint*",&chars,"uint*",&use) || !DllCall("advapi32\ConvertSidToStringSidW","ptr",sid,"ptr*",&value)
            return ""
        try return StrGet(value)
        finally DllCall("kernel32\LocalFree","ptr",value,"ptr")
    }
    Get() {
        try return this.Folder.GetTask(this.Name)
        catch Error as failure {
            if InStr(failure.Message,"0x80070002") ; IDispatch COM errors expose the HRESULT in Message.
                return 0
            throw failure
        }
    }
    Status(task := unset) {
        if !IsSet(task)
            task := this.Get()
        if !IsObject(task)
            return "off"
        definition := task.Definition
        if definition.RegistrationInfo.Source != DisplayLogonTask.Source
            || definition.Actions.Count != 1 || definition.Triggers.Count != 1
            || definition.Principal.LogonType != 3 || definition.Principal.RunLevel != 0
            return "foreign"
        action := definition.Actions.Item(1), trigger := definition.Triggers.Item(1)
        if action.Type != 0 || trigger.Type != 9
            return "foreign"
        for user in [definition.Principal.UserId,trigger.UserId] {
            if user = "" || (user != this.User && user != this.Account && user != A_UserName && this.Sid(user) != this.User)
                return "foreign"
        }
        if !DisplayStartup.SamePath(action.Path,this.Root . "\runtime\AutoHotkey64.exe")
            || !DisplayStartup.SamePath(action.WorkingDirectory,this.Root)
            || Trim(action.Arguments) != DisplayStartup.LogonArguments(this.Root)
            return "foreign"
        return task.Enabled && trigger.Enabled ? "screen" : "disabled"
    }
    Register(previous := unset) {
        if !IsSet(previous)
            previous := this.Get()
        if this.Status(previous) = "foreign"
            throw Error("登录任务已被其他程序使用。")
        definition := this.Service.NewTask(0)
        definition.RegistrationInfo.Source := DisplayLogonTask.Source
        definition.RegistrationInfo.Description := "随屏：登录后检测显示器，第二块屏幕就绪时启动。"
        definition.Principal.UserId := this.User
        definition.Principal.LogonType := 3 ; TASK_LOGON_INTERACTIVE_TOKEN
        definition.Principal.RunLevel := 0 ; TASK_RUNLEVEL_LUA
        trigger := definition.Triggers.Create(9) ; TASK_TRIGGER_LOGON
        trigger.UserId := this.User
        settings := definition.Settings
        settings.ExecutionTimeLimit := "PT0S"
        settings.DisallowStartIfOnBatteries := false
        settings.StopIfGoingOnBatteries := false
        settings.MultipleInstances := 2 ; TASK_INSTANCES_IGNORE_NEW
        action := definition.Actions.Create(0) ; TASK_ACTION_EXEC
        action.Path := this.Root . "\runtime\AutoHotkey64.exe"
        action.Arguments := DisplayStartup.LogonArguments(this.Root)
        action.WorkingDirectory := this.Root
        return this.Folder.RegisterTaskDefinition(this.Name,definition,IsObject(previous) ? 4 : 2,this.User,ComValue(0,0),3)
    }
    Restore(xml) => this.Folder.RegisterTask(this.Name,xml,4,this.User,ComValue(0,0),3)
    Remove() {
        task := this.Get()
        if !IsObject(task)
            return
        if this.Status(task) = "foreign"
            throw Error("登录任务已被其他程序使用。")
        this.Folder.DeleteTask(this.Name,0)
    }
}
