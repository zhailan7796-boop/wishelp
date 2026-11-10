#Requires AutoHotkey v2.0 64-bit
#SingleInstance Off
#NoTrayIcon
#Warn VarUnset, StdOut
#Include ..\TaskbarFollow.ahk

; Exercise the controller's real constructor, shutdown and DLL reference
; handling. Native worker fault injection is covered by the C++ lifecycle suite.
; These callbacks install no hooks and operate only on a copied, owned module.
class ShutdownChecks {
    static Count := 0, StartCalls := 0, StopCalls := 0, LastTimeout := 0
    static StartError := 0, StopAllowed := true, StopFailureError := 1460, BindMissing := false
    static StartCallback := 0, StopCallback := 0, Last := 0
    static Objects := []
    static Assert(value,label) {
        if !value
            throw Error(label)
        this.Count += 1
    }
    static NativeStart(hwnd,flags) {
        this.StartCalls += 1
        DllCall("kernel32\SetLastError","uint",this.StartError)
        return this.StartError = 0
    }
    static NativeStop(timeout) {
        this.StopCalls += 1, this.LastTimeout := timeout
        DllCall("kernel32\SetLastError","uint",this.StopAllowed ? 0 : this.StopFailureError)
        return this.StopAllowed
    }
    static Reset() {
        this.StartCalls := 0, this.StopCalls := 0, this.LastTimeout := 0
        this.StartError := 0, this.StopAllowed := true, this.StopFailureError := 1460, this.BindMissing := false, this.Last := 0
    }
    static Loaded(path) => DllCall("kernel32\GetModuleHandleW","wstr",path,"ptr")
    static ExpectFailure(owner,path,label) {
        failed := false
        try ShutdownFixture(owner,path)
        catch as failure {
            failed := true
            this.Assert(failure.Message != "",label . ": original error is retained")
        }
        this.Assert(failed,label . ": constructor reports failure")
        return this.Last
    }
}
class ShutdownOwner {
    Timeout := 8000, BringActive := true, Enabled := true, FollowPeek := true
    Messages := [], FailComponentLog := false, FailAllLogs := false
    Log(text) {
        if this.FailAllLogs || (this.FailComponentLog && InStr(text,"native component="))
            throw Error("Expected owned logging failure")
        this.Messages.Push(text)
    }
}
class ShutdownFixture extends NativeEngine {
    BindExports() {
        ShutdownChecks.Last := this
        ShutdownChecks.Objects.Push(this)
        if ShutdownChecks.BindMissing {
            missing := DllCall("kernel32\GetProcAddress","ptr",this.Handle,"astr","TF_IntentionallyMissingShutdownExport","ptr")
            if !missing
                throw Error("Expected missing native export")
        }
        super.BindExports()
        this.StartFn := ShutdownChecks.StartCallback
        this.StopAndWaitFn := ShutdownChecks.StopCallback
    }
}
class ShutdownExitProbe extends TaskbarFollow {
    __New(native) {
        this.Native := native, this.Pending := 1, this.Panel := 0
        this.Hook := 0, this.Callback := 0, this.CleanedHelper := false, this.Messages := [], this.FailLogs := false
    }
    Log(text) {
        if this.FailLogs
            throw Error("Expected owned controller logging failure")
        this.Messages.Push(text)
    }
    StopHelper() => this.CleanedHelper := true
}
class ShutdownThrowingNative {
    Stop(*) {
        throw Error("Expected owned shutdown exception")
    }
}

modulePath := "", priorReference := 0, exitCode := 0
try {
    SplitPath(A_ScriptDir,,&root)
    dllName := IniRead(root . "\native\bin\runtime.ini","Native","Dll")
    modulePath := A_ScriptDir . "\results\NativeShutdown-" . DllCall("kernel32\GetCurrentProcessId","uint") . ".dll"
    DirCreate(A_ScriptDir . "\results")
    FileCopy(root . "\native\bin\" . dllName,modulePath,true)
    ShutdownChecks.StartCallback := CallbackCreate(ObjBindMethod(ShutdownChecks,"NativeStart"),,2)
    ShutdownChecks.StopCallback := CallbackCreate(ObjBindMethod(ShutdownChecks,"NativeStop"),,1)
    ShutdownChecks.Assert(!ShutdownChecks.Loaded(modulePath),"Owned module is initially unloaded")

    ShutdownChecks.Reset()
    owner := ShutdownOwner(), engine := ShutdownFixture(owner,modulePath)
    ShutdownChecks.Assert(ShutdownChecks.StartCalls = 1,"Constructor starts its native runtime once")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"A successful constructor owns a real loader reference")
    ShutdownChecks.StopAllowed := false
    ShutdownChecks.Assert(!engine.Stop(7),"A native timeout is returned as failure")
    ShutdownChecks.Assert(engine.StopError = 1460 && ShutdownChecks.LastTimeout = 7,"Stop preserves the native error and explicit wait budget")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"Timed-out worker keeps the DLL loaded")
    ShutdownChecks.Assert(!engine.Ready,"A stopped or stopping runtime is not reported ready")
    ShutdownChecks.Assert(owner.Messages.Length >= 2 && InStr(owner.Messages[owner.Messages.Length],"retained DLL="),"Shutdown failure logs its retained loader reference")
    ShutdownChecks.StopFailureError := 170
    ShutdownChecks.Assert(!engine.Stop(8) && engine.StopError = 170,"A busy lifecycle stop also returns its native error")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"A busy lifecycle stop cannot release the DLL")
    ShutdownChecks.StopFailureError := 1460
    owner.FailAllLogs := true
    ShutdownChecks.Assert(!engine.Stop(9),"A log failure cannot throw out of a failed Stop")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"Repeated failure still retains the loader reference")
    owner.FailAllLogs := false
    ShutdownChecks.StopAllowed := true
    ShutdownChecks.Assert(engine.Stop(11),"A later confirmed stop succeeds")
    ShutdownChecks.Assert(!engine.Handle && !ShutdownChecks.Loaded(modulePath) && !engine.StopError,"Confirmed stop releases the DLL reference")
    previousStops := ShutdownChecks.StopCalls
    ShutdownChecks.Assert(engine.Stop() && ShutdownChecks.StopCalls = previousStops,"Repeated stop after cleanup is a no-op success")

    ShutdownChecks.Reset()
    ShutdownChecks.BindMissing := true
    failed := ShutdownChecks.ExpectFailure(ShutdownOwner(),modulePath,"Missing export")
    ShutdownChecks.Assert(!ShutdownChecks.StartCalls && !ShutdownChecks.StopCalls,"Missing exports cannot start or stop a worker")
    ShutdownChecks.Assert(!failed.Handle && !ShutdownChecks.Loaded(modulePath),"Pre-start failure releases its loader reference")

    ShutdownChecks.Reset()
    ShutdownChecks.StartError := 5
    failed := ShutdownChecks.ExpectFailure(ShutdownOwner(),modulePath,"Start failure")
    ShutdownChecks.Assert(failed.StartError = 5,"Startup retains the original native error across rollback")
    ShutdownChecks.Assert(ShutdownChecks.StopCalls = 1,"Failed startup asks native code to confirm cleanup")
    ShutdownChecks.Assert(!failed.Handle && !ShutdownChecks.Loaded(modulePath),"Confirmed startup rollback releases the DLL")

    ShutdownChecks.Reset()
    ShutdownChecks.StartError := 5, ShutdownChecks.StopAllowed := false
    failed := ShutdownChecks.ExpectFailure(ShutdownOwner(),modulePath,"Start rollback timeout")
    ShutdownChecks.Assert(failed.StartError = 5 && failed.StopError = 1460,"Rollback timeout does not overwrite the original startup error")
    ShutdownChecks.Assert(failed.Handle && ShutdownChecks.Loaded(modulePath),"Unconfirmed startup rollback retains the DLL")
    ShutdownChecks.StopAllowed := true
    ShutdownChecks.Assert(failed.Stop(0) && !ShutdownChecks.Loaded(modulePath),"Failed startup remains safe to retry cleanup")

    for ownershipError in [1247,170] {
        ShutdownChecks.Reset()
        priorReference := DllCall("kernel32\LoadLibraryExW","wstr",modulePath,"ptr",0,"uint",0x1100,"ptr")
        ShutdownChecks.Assert(priorReference,"An existing lifecycle owner can hold its own module reference")
        ShutdownChecks.StartError := ownershipError
        failed := ShutdownChecks.ExpectFailure(ShutdownOwner(),modulePath,"Existing lifecycle owner " . ownershipError)
        ShutdownChecks.Assert(!ShutdownChecks.StopCalls,"ALREADY_INITIALIZED/BUSY never stops the other lifecycle owner")
        ShutdownChecks.Assert(!failed.Handle && ShutdownChecks.Loaded(modulePath),"A rejected new owner drops only its own loader reference")
        DllCall("kernel32\FreeLibrary","ptr",priorReference), priorReference := 0
        ShutdownChecks.Assert(!ShutdownChecks.Loaded(modulePath),"The prior owner's reference remains independently releasable")
    }

    ShutdownChecks.Reset()
    owner := ShutdownOwner(), owner.FailComponentLog := true
    failed := ShutdownChecks.ExpectFailure(owner,modulePath,"Post-start initialization failure")
    ShutdownChecks.Assert(ShutdownChecks.StartCalls = 1 && ShutdownChecks.StopCalls = 1,"Errors after Start still perform confirmed rollback")
    ShutdownChecks.Assert(!failed.Handle && !ShutdownChecks.Loaded(modulePath),"Post-start rollback releases only after native confirmation")

    ShutdownChecks.Reset()
    engine := ShutdownFixture(ShutdownOwner(),modulePath)
    ShutdownChecks.StopAllowed := false
    controller := ShutdownExitProbe(engine)
    controller.Exit()
    ShutdownChecks.Assert(controller.CleanedHelper && !controller.Pending,"Native timeout does not skip remaining controller cleanup")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"Controller exit does not unload an unconfirmed worker")
    ShutdownChecks.Assert(controller.Messages.Length = 1,"Controller records incomplete native shutdown")
    controller := ShutdownExitProbe(engine), controller.FailLogs := true
    controller.Exit()
    ShutdownChecks.Assert(controller.CleanedHelper && !controller.Pending,"A failed timeout log still permits remaining controller cleanup")
    ShutdownChecks.Assert(engine.Handle && ShutdownChecks.Loaded(modulePath),"A failed timeout log cannot release an unconfirmed worker's DLL")
    ShutdownChecks.StopAllowed := true
    ShutdownChecks.Assert(engine.Stop(),"Owned timeout fixture can finish cleanup after Exit")
    controller := ShutdownExitProbe(ShutdownThrowingNative())
    controller.Exit()
    ShutdownChecks.Assert(controller.CleanedHelper && controller.Messages.Length = 1,"Unexpected native exceptions also preserve remaining controller cleanup")
    controller := ShutdownExitProbe(ShutdownThrowingNative()), controller.FailLogs := true
    controller.Exit()
    ShutdownChecks.Assert(controller.CleanedHelper && !controller.Pending,"A failed native-exception log still permits remaining controller cleanup")

    FileAppend("PASS " . ShutdownChecks.Count . " native shutdown/loader-reference/startup-rollback/controller-cleanup assertions`n","*","UTF-8")
} catch as failure {
    FileAppend("FAIL " . failure.Message . " (line " . failure.Line . ")`n","*","UTF-8")
    exitCode := 1
} finally {
    ShutdownChecks.StopAllowed := true
    for engine in ShutdownChecks.Objects {
        if engine.Handle {
            if engine.StartAttempted && engine.StartError != 1247 && engine.StartError != 170
                engine.Stop(0)
            else
                engine.ReleaseLibrary()
        }
    }
    if priorReference
        DllCall("kernel32\FreeLibrary","ptr",priorReference)
    if ShutdownChecks.StartCallback
        CallbackFree(ShutdownChecks.StartCallback)
    if ShutdownChecks.StopCallback
        CallbackFree(ShutdownChecks.StopCallback)
    if modulePath != "" && FileExist(modulePath)
        FileDelete(modulePath)
}
ExitApp(exitCode)
