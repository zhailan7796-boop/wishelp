; Small, native UI Automation client. Vtable indices are from Microsoft's UIAutomationClient.h.
; Loaded ONLY in the disposable helper process, never in the mouse/foreground event handlers.
class TaskbarUIA {
    __New() {
        this.Client := ComObject("{E22AD333-B25F-460C-83D0-0581107395C9}",
            "{34723AFF-0C9D-49D0-9896-7AB52DF8CD8A}") ; CUIAutomation8 / IUIAutomation2
        ComCall(61, this.Client, "uint", 180) ; connection timeout
        ComCall(63, this.Client, "uint", 180) ; transaction timeout (watchdog is still necessary)
        ; Hit testing needs names/types and live parent traversal. Background
        ; scanning only needs IDs and physical rectangles, with no live proxies.
        this.Cache := this.NewCache([30003,30005,30011,30012])
        this.ScanCache := this.NewCache([30001,30011],true)
        this.DiagnosticCache := this.NewCache([30001,30005,30011,30012],true)
        this.AppCondition := this.AppButtonCondition()
        ptr := 0
        ComCall(21,this.Client,"ptr*",&ptr)
        this.AllCondition := ComValue(13,ptr,1)
        ptr := 0
        ComCall(16, this.Client, "ptr*", &ptr) ; RawViewWalker
        this.Walker := ComValue(13, ptr, 1)
    }
    NewCache(properties,cachedOnly := false) {
        ptr := 0
        ComCall(20,this.Client,"ptr*",&ptr)
        cache := ComValue(13,ptr,1)
        ComCall(7,cache,"int",1) ; TreeScope_Element
        if cachedOnly
            ComCall(11,cache,"int",0) ; AutomationElementMode_None
        for property in properties
            ComCall(3,cache,"int",property)
        return cache
    }
    AppButtonCondition() {
        ; Preserve the old case-insensitive class comparison. Do not add a
        ; control-type restriction: Buttons previously filtered by peer alone.
        value := Buffer(24,0) ; x64 VARIANT, VT_BSTR
        text := DllCall("oleaut32\SysAllocString","wstr","Taskbar.TaskListButtonAutomationPeer","ptr")
        if !text
            throw Error("Unable to allocate UIA class condition")
        try {
            NumPut("ushort",8,value,0)
            NumPut("ptr",text,value,8)
            ptr := 0
            ComCall(24,this.Client,"int",30012,"ptr",value,"int",1,"ptr*",&ptr) ; IgnoreCase
            return ComValue(13,ptr,1)
        } finally DllCall("oleaut32\SysFreeString","ptr",text)
    }
    static Text(element, method) {
        ptr := 0
        ComCall(method, element, "ptr*", &ptr)
        try return ptr ? StrGet(ptr) : ""
        finally {
            if ptr
                DllCall("oleaut32\SysFreeString", "ptr", ptr)
        }
    }
    Buttons(hwnd, appOnly := true, diagnostics := true) {
        ptr := 0
        ComCall(6, this.Client, "ptr", hwnd, "ptr*", &ptr) ; ElementFromHandle
        if !ptr
            throw Error("UIA root is unavailable")
        root := ComValue(13, ptr, 1)
        condition := appOnly ? this.AppCondition : this.AllCondition
        cache := diagnostics ? this.DiagnosticCache : this.ScanCache
        ptr := 0
        ; A new FindAllBuildCache on every call refreshes geometry. Reuse only
        ; the request configuration, never elements from a previous scan.
        ComCall(8, root, "int", 4, "ptr", condition, "ptr", cache, "ptr*", &ptr)
        if !ptr
            return []
        elements := ComValue(13, ptr, 1), count := 0, result := []
        ComCall(3, elements, "int*", &count)
        Loop Min(count, 300) {
            ptr := 0
            ComCall(4, elements, "int", A_Index - 1, "ptr*", &ptr)
            element := ComValue(13, ptr, 1)
            peer := diagnostics ? TaskbarUIA.Text(element,62) : (appOnly ? "Taskbar.TaskListButtonAutomationPeer" : "")
            name := diagnostics ? TaskbarUIA.Text(element,55) : ""
            rect := Buffer(16, 0)
            ComCall(75, element, "ptr", rect) ; CachedBoundingRectangle, physical RECT
            result.Push({Id: TaskbarUIA.Text(element,61), Name:name, Peer:peer, Rect:ScreenRect.FromBuffer(rect)})
        }
        return result
    }
    static Field(text) => SubStr(StrReplace(StrReplace(text, "`n", " "), "`r", " "), 1, 1024)
    Hit(x, y) {
        Desktop.Physical()
        root := Desktop.RootAt(x, y), className := Desktop.Class(root)
        if !Desktop.IsTaskbar(className) && !Desktop.IsThumbnail(className)
            return {Kind: "none", Id: "", Name: "", Names: []}
        ptr := 0
        ComCall(11, this.Client, "int64", Desktop.Point(x, y), "ptr", this.Cache, "ptr*", &ptr)
        if !ptr
            return {Kind: "none", Id: "", Name: "", Names: []}
        element := ComValue(13, ptr, 1), names := [], isThumb := Desktop.IsThumbnail(className)
        Loop 9 {
            cls := TaskbarUIA.Text(element, 62), id := TaskbarUIA.Text(element, 61), name := TaskbarUIA.Text(element, 55)
            controlType := 0
            ComCall(53, element, "int*", &controlType)
            if isThumb {
                ; Never interpret a thumbnail's close/dismiss button as selecting a window.
                if RegExMatch(cls . " " . id, "i)close|dismiss")
                    return {Kind: "none", Id: "", Name: "", Names: []}
                if name != ""
                    names.Push(TaskbarUIA.Field(name))
            } else if controlType = 50000 && cls = "Taskbar.TaskListButtonAutomationPeer" && id != "" {
                ; This peer is observed on Windows 11, NOT a stable, documented shell contract.
                return {Kind: "app", Id: TaskbarUIA.Field(id), Name: TaskbarUIA.Field(name), Names: []}
            }
            if cls = className
                break
            ptr := 0
            ComCall(9, this.Walker, "ptr", element, "ptr", this.Cache, "ptr*", &ptr)
            if !ptr
                break
            element := ComValue(13, ptr, 1)
        }
        return {Kind: isThumb ? "thumbnail" : "none", Id: "", Name: "", Names: names}
    }
}


