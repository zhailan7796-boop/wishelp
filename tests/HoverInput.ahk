#Requires AutoHotkey v2.0 64-bit
#NoTrayIcon
#Include ..\lib\Native.ahk
#Include ..\lib\UIA.ahk
Desktop.Physical()
two := A_Args.Length && A_Args[1] = "two"
originalCursor := Desktop.Cursor(&originalX,&originalY), originalForeground := Desktop.Foreground()
fixtures := [], appId := "TaskbarFollow.HoverRegression"
Log(text) => FileAppend(text . "`n","*","UTF-8")
SetId(hwnd,id) {
    shell := ComObject("Shell.Application"), storePtr := 0
    iid := Desktop.Guid("{886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99}")
    if DllCall("shell32\SHGetPropertyStoreForWindow","ptr",hwnd,"ptr",iid,"ptr*",&storePtr,"int") < 0
        throw Error("Fixture property store unavailable")
    store := ComValue(13,storePtr,1), key := Buffer(20,0), pv := Buffer(24,0)
    guid := Desktop.Guid("{9F4C2855-9F79-4B39-A8D0-E1D42DE1D5F3}")
    DllCall("ntdll\RtlMoveMemory","ptr",key,"ptr",guid,"uptr",16), NumPut("uint",5,key,16)
    text := Buffer((StrLen(id)+1)*2,0), StrPut(id,text)
    NumPut("ushort",31,pv), NumPut("ptr",text.Ptr,pv,8)
    ComCall(6,store,"ptr",key,"ptr",pv), ComCall(7,store)
}
MovePhysical(x,y) {
    left := DllCall("user32\GetSystemMetrics","int",76), top := DllCall("user32\GetSystemMetrics","int",77)
    width := DllCall("user32\GetSystemMetrics","int",78), height := DllCall("user32\GetSystemMetrics","int",79)
    input := Buffer(40,0)
    NumPut("int",Round((x-left)*65535/(width-1)),"int",Round((y-top)*65535/(height-1)),input,8)
    NumPut("uint",0xC001,input,20)
    if DllCall("user32\SendInput","uint",1,"ptr",input,"int",40,"uint") != 1
        throw Error("Test pointer input failed")
}
Cleanup(*) {
    global fixtures,originalCursor,originalX,originalY,originalForeground
    for item in fixtures
        try item.Gui.Destroy()
    if originalCursor
        DllCall("user32\SetPhysicalCursorPos","int",originalX,"int",originalY)
    if originalForeground
        try WinActivate("ahk_id " . originalForeground)
}
OnExit(Cleanup)
try {
    if !originalCursor
        throw Error("Run on input desktop")
    bar := WinExist("ahk_class Shell_TrayWnd"), target := Desktop.MonitorOf(bar)
    bars := WinGetList("ahk_class Shell_SecondaryTrayWnd")
    if !bars.Length
        throw Error("Need two taskbars")
    source := Desktop.MonitorOf(bars[1]), uia := TaskbarUIA()
    Loop two?2:1 {
        fixtureIndex := A_Index, fixtureGui := Gui(,"TaskbarFollow hover fixture " . fixtureIndex)
        fixtureGui.BackColor := fixtureIndex=1?"D14A56":"3D6ED1"
        fixtureGui.AddText("cFFFFFF","Temporary hover preview fixture " . fixtureIndex)
        SetId(fixtureGui.Hwnd,appId)
        fixtureGui.Show("NA x" . (source.Work.L+120+fixtureIndex*60) . " y" . (source.Work.T+120) . " w640 h420")
        Desktop.Physical()
        DllCall("user32\SetWindowPos","ptr",fixtureGui.Hwnd,"ptr",0,"int",source.Work.L+120+fixtureIndex*60,"int",source.Work.T+120,"int",640,"int",420,"uint",0x14)
        Sleep(250)
        fixtureGui.Minimize()
        fixtures.Push({Gui:fixtureGui,Placement:Desktop.Placement(fixtureGui.Hwnd)})
        Log("fixture=" . fixtureGui.Hwnd . "; source=" . Desktop.MonitorOf(fixtureGui.Hwnd).Device . "; target=" . target.Device . "; eligible=" . Desktop.Eligible(fixtureGui.Hwnd))
    }
    Sleep(1800)
    button := 0
    for item in uia.Buttons(bar) {
        if item.Id = appId && item.Rect.W>0
            button := item
    }
    if !IsObject(button)
        throw Error("Fixture taskbar button missing")
    x := (button.Rect.L+button.Rect.R)//2, y := (button.Rect.T+button.Rect.B)//2
    if uia.Hit(x,y).Id != appId
        throw Error("Fixture taskbar button covered")
    MovePhysical(x,y)
    deadline := Desktop.Tick()+3500, popup := 0
    Loop {
        for preview in Desktop.Thumbnails() {
            if Desktop.SameMonitor(Desktop.MonitorOf(preview),target)
                popup := preview
        }
        if popup || Desktop.Tick()>deadline
            break
        Sleep(50)
    }
    if !popup
        throw Error("Taskbar preview did not open")
    r := Desktop.Rect(popup)
    Loop two?2:1 {
        index := A_Index, x := r.L+Round(r.W*(two?(index=1?0.25:0.75):0.5)), y := r.T+Round(r.H*0.62)
        MovePhysical(x,y), Sleep(200)
        hit := uia.Hit(x,y)
        Log("hover point=" . x . "," . y . "; kind=" . hit.Kind . "; names=" . hit.Names.Length)
        expected := fixtures[1].Gui.Hwnd
        if two {
            dc := DllCall("user32\GetDC","ptr",0,"ptr")
            color := DllCall("gdi32\GetPixel","ptr",dc,"int",x,"int",y,"uint")
            DllCall("user32\ReleaseDC","ptr",0,"ptr",dc)
            red := color&255, blue := (color>>16)&255
            if Abs(red-blue)<25
                throw Error("Cannot identify fixture thumbnail color")
            expected := fixtures[red>blue?1:2].Gui.Hwnd
        }
        deadline := Desktop.Tick()+2200, overlay := 0, actual := 0
        Loop {
            overlay := DllCall("user32\FindWindowW","wstr","TaskbarFollow.HoverPreview","ptr",0,"ptr")
            if overlay && DllCall("user32\IsWindowVisible","ptr",overlay) {
                actual := DllCall("user32\GetPropW","ptr",overlay,"wstr","TaskbarFollow.PeekSource","ptr")
                if actual=expected
                    break
            }
            if Desktop.Tick()>deadline
                throw Error("Hovered fixture did not get the matching live preview; expected=" . expected . "; actual=" . actual)
            Sleep(50)
        }
        if !Desktop.SameMonitor(Desktop.MonitorOf(overlay),target)
            throw Error("Hover overlay on wrong monitor")
        Log("PASS hover tile " . index . "; matched source=" . actual . "; preview monitor=" . target.Device)
    }
    for item in fixtures {
        after := Desktop.Placement(item.Gui.Hwnd)
        if !Desktop.IsMin(item.Gui.Hwnd)
            throw Error("Hover restored the source")
        for coordinate in [28,32,36,40] {
            if NumGet(item.Placement,coordinate,"int") != NumGet(after,coordinate,"int")
                throw Error("Hover changed source restore position")
        }
    }
    MovePhysical(target.Work.L+20,target.Work.T+20)
    Sleep(350)
    if overlay && DllCall("user32\IsWindowVisible","ptr",overlay)
        throw Error("Hover overlay remained after pointer left")
    Log("PASS actual taskbar hover; source positions/minimized state preserved; pointer leave hides preview")
    ExitApp(0)
} catch as e {
    Log("FAIL " . e.Message . "; line=" . e.Line)
    ExitApp(1)
}
