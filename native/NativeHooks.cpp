#define TF_BUILD_DLL
#include "NativeHooks.h"
#include <commctrl.h>
#include <algorithm>
#include <new>
#include <cwchar>
#include <shobjidl.h>
#include <propvarutil.h>
#include <appmodel.h>
#include "PeekPreview.h"
#include <oleacc.h>

namespace {
constexpr DWORD Magic = 0x54464E32;
constexpr UINT_PTR SubclassId = 0x54464E32;
struct Transaction {
    NativeEntry entry;
    MONITORINFOEXW target;
    std::uint64_t monitor, before, released, expires;
    unsigned serial, preview, epoch;
};
struct alignas(8) Shared {
    DWORD magic, ownerPid;
    volatile LONG running, enabled, cacheIndex, cacheSequence, timeoutMs, bringActive;
    volatile LONG txSequence, serial, inputEpoch;
    volatile LONG64 heartbeat, cacheAt, coolUntil, claim;
    volatile LONG64 armed, created, restored, activated, firstShown, cancelled, eventNumber;
    volatile LONG lastKind, lastPid;
    volatile LONG64 lastWindow, latency;
    wchar_t target[32];
    unsigned count[2];
    NativeEntry entries[2][TF_MAX_ENTRIES];
    Transaction tx;
};
struct Mapping { HANDLE handle{}; Shared* data{}; };
HMODULE Module{};
Mapping Controller;
Mapping Payload;
SRWLOCK PayloadLock=SRWLOCK_INIT;
thread_local bool Reentry{};
HANDLE Worker{}, WorkerReady{};
DWORD WorkerId{}, StartupError{}, StartFlags{};
volatile LONG StopRequested{}, ControllerProcess{};
DWORD ShutdownError{};
HMODULE RetainedWorkerModule{};
volatile LONG TestUnhookFailure{};
SRWLOCK LifecycleLock=SRWLOCK_INIT;
struct LifecycleGuard {
    bool held{TryAcquireSRWLockExclusive(&LifecycleLock)!=FALSE};
    ~LifecycleGuard() { if (held) ReleaseSRWLockExclusive(&LifecycleLock); }
};
BOOL StopAndWaitImpl(unsigned timeoutMs);
struct LifecycleTest {
    HANDLE startupGate{}, shutdownGate{}, startupEntered{}, shutdownEntered{};
    DWORD startupError{};
} Lifecycle;
HDESK WorkerDesktop{};
HWND ControllerOwner{};
HHOOK CbtHook{}, CallHook{}, MouseHook{}, KeyboardHook{};
constexpr UINT PeekCommand=WM_APP+71;
constexpr UINT OwnWindowCommand=0x8054, CompatibilityCommand=0x8055;
PeekPreview PeekUi;
volatile LONG PeekEnabled=1, PeekGeneration=0;
struct PeekRequest { HWND source,popup; DWORD pid; POINT point; LONG generation; };
void QueuePeekHide() {
    const LONG generation=InterlockedIncrement(&PeekGeneration);
    if (WorkerId) PostThreadMessageW(WorkerId,PeekCommand,0,generation);
}

std::uint64_t Now() { return GetTickCount64(); }
HWND Window(std::uint64_t value) { return reinterpret_cast<HWND>(static_cast<UINT_PTR>(value)); }
HMONITOR Monitor(std::uint64_t value) { return reinterpret_cast<HMONITOR>(static_cast<UINT_PTR>(value)); }
std::uint64_t Id(const void* value) { return static_cast<std::uint64_t>(reinterpret_cast<UINT_PTR>(value)); }
LONG64 Read64(volatile LONG64& value) { return InterlockedCompareExchange64(&value, 0, 0); }
LONG Read32(volatile LONG& value) { return InterlockedCompareExchange(&value, 0, 0); }
bool ClassIs(HWND hwnd, const wchar_t* name) {
    wchar_t cls[128]{};
    return GetClassNameW(hwnd, cls, 128) && wcscmp(cls, name) == 0;
}
bool ShellBar(HWND hwnd) { return ClassIs(hwnd,L"Shell_TrayWnd") || ClassIs(hwnd,L"Shell_SecondaryTrayWnd"); }
bool Preview(HWND hwnd) { return ClassIs(hwnd,L"TaskListThumbnailWnd"); }
void MappingName(wchar_t* name, size_t length) {
    wchar_t path[2048]{}, desktop[256]{}; DWORD needed{};
    GetModuleFileNameW(Module, path, 2048);
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()), UOI_NAME, desktop, sizeof(desktop), &needed);
    unsigned long long hash = 1469598103934665603ull;
    for (const wchar_t* part : {path,desktop})
        for (; *part; ++part) { hash ^= static_cast<unsigned>(towlower(*part)); hash *= 1099511628211ull; }
    swprintf_s(name, length, L"Local\\TaskbarFollow.Native.%016llx", hash);
}
Shared* GetShared() {
    // The controller's own windows are never positioning targets. Global hook
    // callbacks on its other UI threads must not borrow a view being stopped.
    if (Read32(ControllerProcess)) return nullptr;
    if (!Payload.data) {
        // Initialization uses only kernel mapping APIs; waiting for that bounded
        // initialization avoids dropping a process's very first create callback.
        AcquireSRWLockExclusive(&PayloadLock);
        if (!Payload.data) {
            wchar_t name[128]{}; MappingName(name,128);
            Payload.handle = OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,name);
            if (Payload.handle) {
                Payload.data = static_cast<Shared*>(MapViewOfFile(Payload.handle,FILE_MAP_ALL_ACCESS,0,0,sizeof(Shared)));
                if (!Payload.data) { CloseHandle(Payload.handle); Payload.handle=nullptr; }
            }
        }
        ReleaseSRWLockExclusive(&PayloadLock);
    }
    return Payload.data && Payload.data->magic == Magic ? Payload.data : nullptr;
}
bool Live(Shared* shared) {
    return shared && Read32(shared->running) && Read32(shared->enabled)
        && Now() - static_cast<std::uint64_t>(Read64(shared->heartbeat)) < 2500;
}
void Event(Shared* shared, unsigned kind, HWND hwnd=nullptr, const Transaction* tx=nullptr) {
    InterlockedExchange(&shared->lastPid, static_cast<LONG>(GetCurrentProcessId()));
    InterlockedExchange64(&shared->lastWindow,static_cast<LONG64>(Id(hwnd)));
    if (tx) {
        // Target text is diagnostic only; transaction geometry has its own seqlock.
        wcsncpy_s(shared->target,tx->target.szDevice,_TRUNCATE);
        InterlockedExchange64(&shared->latency,static_cast<LONG64>(Now()-tx->released));
    }
    if (kind==TF_PEEK_SHOW || kind==TF_PEEK_HIDE) {
        InterlockedExchange64(&shared->latency,0);
        if (kind==TF_PEEK_SHOW && PeekUi.Host()) {
            MONITORINFOEXW info{}; info.cbSize=sizeof(info);
            if (GetMonitorInfoW(MonitorFromWindow(PeekUi.Host(),MONITOR_DEFAULTTONEAREST),&info))
                wcsncpy_s(shared->target,info.szDevice,_TRUNCATE);
        }
    }
    InterlockedExchange(&shared->lastKind,static_cast<LONG>(kind));
    InterlockedIncrement64(&shared->eventNumber);
}
void Cancel(Shared* shared, unsigned cooldown=0) {
    // Cancellation can originate in a payload callback, the controller, or input
    // thread. An epoch invalidates work without introducing a second tx writer.
    InterlockedIncrement(&shared->inputEpoch);
    if (cooldown) InterlockedExchange64(&shared->coolUntil,static_cast<LONG64>(Now()+cooldown));
}
bool CancelTransaction(Shared* shared,const Transaction& tx) {
    return InterlockedCompareExchange(&shared->inputEpoch,static_cast<LONG>(tx.epoch+1),
        static_cast<LONG>(tx.epoch))==static_cast<LONG>(tx.epoch);
}
bool Snapshot(Shared* shared, Transaction& tx,bool allowExpired=false) {
    if (!Live(shared) || Now() < static_cast<std::uint64_t>(Read64(shared->coolUntil))) return false;
    LONG sequence=Read32(shared->txSequence);
    if (sequence&1) return false;
    tx=shared->tx;
    MemoryBarrier();
    if (sequence!=Read32(shared->txSequence) || tx.epoch!=static_cast<unsigned>(Read32(shared->inputEpoch)) || !tx.expires || (!allowExpired && Now()>tx.expires)) return false;
    MONITORINFOEXW current{}; current.cbSize=sizeof(current);
    return GetMonitorInfoW(Monitor(tx.monitor),&current)
        && EqualRect(&current.rcMonitor,&tx.target.rcMonitor)
        && EqualRect(&current.rcWork,&tx.target.rcWork)
        && wcscmp(current.szDevice,tx.target.szDevice)==0;
}
bool Candidate(const Transaction& tx, HWND hwnd) {
    DWORD pid{}; GetWindowThreadProcessId(hwnd,&pid);
    for (unsigned i=0; i<tx.entry.count; ++i)
        if (tx.entry.windows[i].hwnd==Id(hwnd) && tx.entry.windows[i].pid==pid) return true;
    return false;
}
bool Claim(Shared* shared,const Transaction& tx, HWND hwnd) {
    const LONG64 empty=static_cast<LONG64>(static_cast<std::uint64_t>(tx.serial)<<32);
    const LONG64 desired=empty | static_cast<unsigned>(reinterpret_cast<UINT_PTR>(hwnd));
    LONG64 old=InterlockedCompareExchange64(&shared->claim,desired,empty);
    return old==empty || old==desired;
}
bool Eligible(HWND hwnd, bool creation=false, const CREATESTRUCTW* cs=nullptr) {
    DWORD pid{}; const DWORD tid=GetWindowThreadProcessId(hwnd,&pid);
    // Cross-bitness hook delivery can occur in the installer. Never subclass there.
    if (pid!=GetCurrentProcessId() || tid!=GetCurrentThreadId()) return false;
    Shared* shared=GetShared();
    if (!shared || pid==shared->ownerPid) return false;
    const LONG_PTR style=creation ? cs->style : GetWindowLongPtrW(hwnd,GWL_STYLE);
    const LONG_PTR ex=creation ? cs->dwExStyle : GetWindowLongPtrW(hwnd,GWL_EXSTYLE);
    if (style&WS_CHILD || ex&(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE)) return false;
    if (!(style&WS_CAPTION)) return false;
    if (creation ? cs->hwndParent!=nullptr : GetWindow(hwnd,GW_OWNER)!=nullptr) return false;
    return true;
}
RECT MapRect(RECT rect,const RECT& source,const RECT& target) {
    const LONG width=std::clamp(rect.right-rect.left,160L,std::max(160L,target.right-target.left));
    const LONG height=std::clamp(rect.bottom-rect.top,100L,std::max(100L,target.bottom-target.top));
    const double fx=source.right-source.left>width ? std::clamp(double(rect.left-source.left)/double(source.right-source.left-width),0.0,1.0) : 0.5;
    const double fy=source.bottom-source.top>height ? std::clamp(double(rect.top-source.top)/double(source.bottom-source.top-height),0.0,1.0) : 0.5;
    LONG x=target.left+static_cast<LONG>(fx*double(target.right-target.left-width)+0.5);
    LONG y=target.top+static_cast<LONG>(fy*double(target.bottom-target.top-height)+0.5);
    return {x,y,x+width,y+height};
}
RECT MaxRect(HWND hwnd,const Transaction& tx) {
    UINT dpi=GetDpiForWindow(hwnd); if (!dpi) dpi=96;
    HMODULE shcore=GetModuleHandleW(L"shcore.dll");
    using GetMonitorDpi=HRESULT(WINAPI*)(HMONITOR,int,UINT*,UINT*);
    auto monitorDpi=shcore ? reinterpret_cast<GetMonitorDpi>(GetProcAddress(shcore,"GetDpiForMonitor")) : nullptr;
    UINT dx=dpi,dy=dpi;
    if (monitorDpi && SUCCEEDED(monitorDpi(Monitor(tx.monitor),0,&dx,&dy))) dpi=dx;
    const int border=GetSystemMetricsForDpi(SM_CXSIZEFRAME,dpi)+GetSystemMetricsForDpi(SM_CXPADDEDBORDER,dpi);
    RECT r=tx.target.rcWork; InflateRect(&r,border,border); return r;
}
struct Placement {
    Transaction tx;
    RECT normal;
    bool wantsMax{}, shown{}, removed{};
    unsigned calls{};
    bool pendingIdentity{};
    bool activationOnly{};
};
bool ExactWindowIdentity(HWND hwnd,const wchar_t* expected) {
    static const PROPERTYKEY key={{0x9f4c2855,0x9f79,0x4b39,{0xa8,0xd0,0xe1,0xd4,0x2d,0xe1,0xd5,0xf3}},5};
    IPropertyStore* store{}; PROPVARIANT value{}; bool hasWindowId=false,match=false;
    if (SUCCEEDED(SHGetPropertyStoreForWindow(hwnd,IID_PPV_ARGS(&store)))) {
        if (SUCCEEDED(store->GetValue(key,&value)) && value.vt==VT_LPWSTR && value.pwszVal && *value.pwszVal) {
            hasWindowId=true; match=wcscmp(value.pwszVal,expected)==0;
        }
        PropVariantClear(&value); store->Release();
    }
    // A window's explicit ID overrides the process identity, including mismatch.
    if (hasWindowId) return match;
    // Tauri and other desktop applications can set only a process-wide AppID.
    // This API is safe here: the hook runs in the target process, not remotely.
    PWSTR explicitId{};
    const HRESULT explicitResult=GetCurrentProcessExplicitAppUserModelID(&explicitId);
    const bool hasProcessId=SUCCEEDED(explicitResult) && explicitId && *explicitId;
    match=hasProcessId && wcscmp(explicitId,expected)==0;
    CoTaskMemFree(explicitId);
    if (hasProcessId) return match;
    wchar_t appId[256]{}; UINT32 length=256;
    return GetApplicationUserModelId(GetCurrentProcess(),&length,appId)==ERROR_SUCCESS && wcscmp(appId,expected)==0;
}
struct PlacementCall {
    Placement* value;
    explicit PlacementCall(Placement* p):value(p) { ++p->calls; }
    ~PlacementCall() { if (--value->calls==0 && value->removed) delete value; }
};
bool StillCurrent(Shared* shared,const Transaction& tx) {
    Transaction current;
    return Snapshot(shared,current) && current.serial==tx.serial;
}
void RemovePlacement(HWND hwnd,Placement* placement);
LRESULT CALLBACK PlacementProc(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam,UINT_PTR,DWORD_PTR reference) {
    auto* placement=reinterpret_cast<Placement*>(reference);
    PlacementCall call(placement);
    Shared* shared=GetShared();
    if (message==WM_NCDESTROY) {
        const LRESULT result=DefSubclassProc(hwnd,message,wparam,lparam);
        RemovePlacement(hwnd,placement); return result;
    }
    if (!StillCurrent(shared,placement->tx)) {
        RemovePlacement(hwnd,placement);
        return DefSubclassProc(hwnd,message,wparam,lparam);
    }
    if (message==WM_TIMER && wparam==SubclassId) return 0;
    const LRESULT result=DefSubclassProc(hwnd,message,wparam,lparam);
    if (placement->removed) return result;
    // Application handlers can pump messages or synchronously ask the
    // controller to cancel/rearm. Never apply old geometry, claim identity,
    // or cancel a newer input epoch after returning from that application.
    if (!StillCurrent(shared,placement->tx)) {
        RemovePlacement(hwnd,placement); return result;
    }
    if (placement->pendingIdentity) {
        // Do not claim on hidden setup geometry: applications may assign a
        // window-specific ID after creation, overriding their process AppID.
        const bool check=(message==WM_SHOWWINDOW && wparam)
            || (message==WM_WINDOWPOSCHANGING && (reinterpret_cast<WINDOWPOS*>(lparam)->flags&SWP_SHOWWINDOW))
            || (message==WM_WINDOWPOSCHANGED && IsWindowVisible(hwnd));
        if (check && ExactWindowIdentity(hwnd,placement->tx.entry.appId) && Claim(shared,placement->tx,hwnd)) {
            placement->pendingIdentity=false;
            InterlockedIncrement64(&shared->created); Event(shared,TF_CREATE,hwnd,&placement->tx);
        } else {
            if (message==WM_WINDOWPOSCHANGED && IsWindowVisible(hwnd) && !IsIconic(hwnd))
                RemovePlacement(hwnd,placement);
            return result;
        }
    }
    if (message==WM_WINDOWPOSCHANGING && !placement->shown
        && (!Reentry || (placement->activationOnly && placement->calls==1))) {
        auto* position=reinterpret_cast<WINDOWPOS*>(lparam);
        if (!(position->flags&SWP_HIDEWINDOW)) {
            const WINDOWPOS original=*position;
            RECT wanted=placement->normal;
            if (placement->wantsMax || IsZoomed(hwnd)) wanted=MaxRect(hwnd,placement->tx);
            else if (!(position->flags&SWP_NOSIZE) && position->cx>=160 && position->cy>=100) {
                wanted.right=wanted.left+std::min<LONG>(position->cx,placement->tx.target.rcWork.right-placement->tx.target.rcWork.left);
                wanted.bottom=wanted.top+std::min<LONG>(position->cy,placement->tx.target.rcWork.bottom-placement->tx.target.rcWork.top);
                OffsetRect(&wanted,std::min(0L,placement->tx.target.rcWork.right-wanted.right),std::min(0L,placement->tx.target.rcWork.bottom-wanted.bottom));
            }
            position->x=wanted.left; position->y=wanted.top;
            position->cx=wanted.right-wanted.left; position->cy=wanted.bottom-wanted.top;
            position->flags&=~(SWP_NOMOVE|SWP_NOSIZE);
            if ((original.flags&(SWP_NOMOVE|SWP_NOSIZE)) || original.x!=position->x || original.y!=position->y
                || original.cx!=position->cx || original.cy!=position->cy) {
                // Applications such as Chromium can suppress an ignored
                // geometry change. Once we force that change it must repaint;
                // copied pixels from the old geometry are not a valid frame.
                position->flags&=~SWP_NOREDRAW;
                position->flags|=SWP_NOCOPYBITS;
            }
        }
    } else if (message==WM_GETMINMAXINFO && placement->wantsMax) {
        auto* info=reinterpret_cast<MINMAXINFO*>(lparam); RECT r=MaxRect(hwnd,placement->tx);
        info->ptMaxPosition={r.left-placement->tx.target.rcMonitor.left,r.top-placement->tx.target.rcMonitor.top};
        info->ptMaxSize={r.right-r.left,r.bottom-r.top};
    } else if (message==WM_WINDOWPOSCHANGED && IsWindowVisible(hwnd) && !IsIconic(hwnd)
        && (!placement->activationOnly || placement->calls==1)) {
        placement->shown=true;
        const bool onTarget=MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==Monitor(placement->tx.monitor);
        if (CancelTransaction(shared,placement->tx) && onTarget) {
            if (placement->activationOnly) {
                InterlockedIncrement64(&shared->activated); Event(shared,TF_ACTIVATE,hwnd,&placement->tx);
            } else {
                InterlockedIncrement64(&shared->firstShown); Event(shared,TF_FIRST_SHOW,hwnd,&placement->tx);
            }
        }
        RemovePlacement(hwnd,placement);
    }
    return result;
}
void RemovePlacement(HWND hwnd,Placement* placement) {
    if (!placement->removed) {
        placement->removed=true;
        RemoveWindowSubclass(hwnd,PlacementProc,SubclassId); KillTimer(hwnd,SubclassId);
    }
}
bool Attach(HWND hwnd,const Transaction& tx,RECT normal,bool wantsMax,bool pendingIdentity=false,bool activationOnly=false) {
    DWORD_PTR previous{};
    if (GetWindowSubclass(hwnd,PlacementProc,SubclassId,&previous)) {
        auto* old=reinterpret_cast<Placement*>(previous);
        if (old->tx.serial==tx.serial && old->tx.epoch==tx.epoch) return true;
        PlacementCall call(old); RemovePlacement(hwnd,old);
    }
    auto* placement=new(std::nothrow) Placement{tx,normal,wantsMax,false};
    if (!placement) return false;
    placement->pendingIdentity=pendingIdentity;
    placement->activationOnly=activationOnly;
    // A window procedure must remain executable after the controller unhooks.
    // Pin only a process which actually receives a temporary placement subclass.
    // Content-addressed DLL filenames allow subsequent builds while that process runs.
    HMODULE held{};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
        reinterpret_cast<LPCWSTR>(&PlacementProc),&held)
        || !SetWindowSubclass(hwnd,PlacementProc,SubclassId,reinterpret_cast<DWORD_PTR>(placement))) {
        delete placement; return false;
    }
    SetTimer(hwnd,SubclassId,100,nullptr); return true;
}
RECT NormalOnTarget(HWND hwnd,const Transaction& tx,WINDOWPLACEMENT& wp) {
    MONITORINFO source{sizeof(source)};
    GetMonitorInfoW(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST),&source);
    RECT normal=wp.rcNormalPosition;
    OffsetRect(&normal,source.rcWork.left-source.rcMonitor.left,source.rcWork.top-source.rcMonitor.top);
    return MapRect(normal,source.rcWork,tx.target.rcWork);
}
bool PrepareRestore(Shared* shared, HWND hwnd,const Transaction& tx) {
    WINDOWPLACEMENT wp{sizeof(wp)};
    if (!GetWindowPlacement(hwnd,&wp)) return false;
    const bool maximized=(wp.flags&WPF_RESTORETOMAXIMIZED)!=0 || wp.showCmd==SW_SHOWMAXIMIZED;
    RECT normal=NormalOnTarget(hwnd,tx,wp);
    if (!Attach(hwnd,tx,normal,maximized)) return false;
    wp.rcNormalPosition=normal;
    OffsetRect(&wp.rcNormalPosition,tx.target.rcMonitor.left-tx.target.rcWork.left,tx.target.rcMonitor.top-tx.target.rcWork.top);
    wp.ptMaxPosition={-1,-1};
    Reentry=true;
    const BOOL changed=SetWindowPlacement(hwnd,&wp); // remains minimized; no restore/maximize round trip
    Reentry=false;
    if (changed && StillCurrent(shared,tx)) { InterlockedIncrement64(&shared->restored); Event(shared,TF_RESTORE,hwnd,&tx); }
    return changed!=FALSE;
}
bool PositionVisible(Shared* shared,HWND hwnd,const Transaction& tx) {
    if (MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==Monitor(tx.monitor)) {
        if (CancelTransaction(shared,tx)) Event(shared,TF_SAME_SCREEN,hwnd,&tx);
        return false;
    }
    MONITORINFO source{sizeof(source)}; GetMonitorInfoW(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST),&source);
    RECT r{}; GetWindowRect(hwnd,&r);
    r=IsZoomed(hwnd) ? MaxRect(hwnd,tx) : MapRect(r,source.rcWork,tx.target.rcWork);
    if (!Attach(hwnd,tx,r,IsZoomed(hwnd)!=FALSE,false,true)) return false;
    Reentry=true;
    const BOOL moved=SetWindowPos(hwnd,nullptr,r.left,r.top,r.right-r.left,r.bottom-r.top,SWP_NOACTIVATE|SWP_NOZORDER|SWP_NOOWNERZORDER);
    Reentry=false;
    const bool onTarget=moved && MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==Monitor(tx.monitor);
    if (!onTarget) {
        DWORD_PTR current{};
        if (GetWindowSubclass(hwnd,PlacementProc,SubclassId,&current)) {
            auto* placement=reinterpret_cast<Placement*>(current);
            PlacementCall call(placement); RemovePlacement(hwnd,placement);
        }
        if (CancelTransaction(shared,tx)) Event(shared,TF_POSITION_REJECTED,hwnd,&tx);
    }
    return onTarget;
}
bool ColdClassMatches(const NativeEntry& entry,HWND hwnd) {
    // Explorer is also the desktop/taskbar host. A folder click must not claim
    // another shell window just because the executable path is the same.
    return wcscmp(entry.appId,L"Microsoft.Windows.Explorer")!=0
        || ClassIs(hwnd,L"CabinetWClass") || ClassIs(hwnd,L"ExploreWClass");
}
bool ColdExistingMatches(const Transaction& tx,HWND hwnd) {
    if (tx.entry.count || !(tx.entry.flags&TF_COLD_START) || (IsWindowVisible(hwnd) && !IsIconic(hwnd))
        || !ColdClassMatches(tx.entry,hwnd)) return false;
    wchar_t path[1024]{}; GetModuleFileNameW(nullptr,path,1024);
    return _wcsicmp(path,tx.entry.path)==0
        && (!(tx.entry.flags&TF_REQUIRE_APP_ID) || ExactWindowIdentity(hwnd,tx.entry.appId));
}
LRESULT CALLBACK Cbt(int code,WPARAM wparam,LPARAM lparam) {
    if (code<0 || Reentry) return CallNextHookEx(nullptr,code,wparam,lparam);
    Shared* shared=GetShared(); Transaction tx;
    if (!Snapshot(shared,tx)) return CallNextHookEx(nullptr,code,wparam,lparam);
    if (tx.entry.flags&TF_COMPATIBILITY) return CallNextHookEx(nullptr,code,wparam,lparam);
    HWND hwnd=reinterpret_cast<HWND>(wparam);
    if (code==HCBT_DESTROYWND && ((tx.preview && Candidate(tx,hwnd))
        || Read64(shared->claim)==(static_cast<LONG64>(static_cast<std::uint64_t>(tx.serial)<<32)|static_cast<unsigned>(reinterpret_cast<UINT_PTR>(hwnd))))) {
        // Closing a preview can activate another group member. It is not a selection.
        if (CancelTransaction(shared,tx)) Event(shared,TF_CANCEL,hwnd,&tx);
    } else if (code==HCBT_CREATEWND && !tx.preview && tx.entry.count==0 && (tx.entry.flags&TF_COLD_START)) {
        auto* create=reinterpret_cast<CBT_CREATEWNDW*>(lparam); CREATESTRUCTW* cs=create->lpcs;
        wchar_t path[1024]{}; GetModuleFileNameW(nullptr,path,1024);
        if (cs && cs->cx>=160 && cs->cy>=100 && Eligible(hwnd,true,cs) && ColdClassMatches(tx.entry,hwnd)
            && _wcsicmp(path,tx.entry.path)==0 && ((tx.entry.flags&TF_REQUIRE_APP_ID) || Claim(shared,tx,hwnd))) {
            RECT original{cs->x,cs->y,cs->x+cs->cx,cs->y+cs->cy};
            if (cs->x==CW_USEDEFAULT || cs->y==CW_USEDEFAULT)
                original={tx.target.rcWork.left+80,tx.target.rcWork.top+80,tx.target.rcWork.left+80+cs->cx,tx.target.rcWork.top+80+cs->cy};
            MONITORINFO source{sizeof(source)}; GetMonitorInfoW(MonitorFromRect(&original,MONITOR_DEFAULTTONEAREST),&source);
            RECT mapped=MapRect(original,source.rcWork,tx.target.rcWork);
            const bool deferred=(tx.entry.flags&TF_REQUIRE_APP_ID)!=0;
            if (Attach(hwnd,tx,mapped,(cs->style&WS_MAXIMIZE)!=0,deferred) && !deferred) {
                cs->x=mapped.left; cs->y=mapped.top; cs->cx=mapped.right-mapped.left; cs->cy=mapped.bottom-mapped.top;
                InterlockedIncrement64(&shared->created); Event(shared,TF_CREATE,hwnd,&tx);
            }
        }
    } else if ((code==HCBT_MINMAX || code==HCBT_ACTIVATE) && Eligible(hwnd)
        && (Candidate(tx,hwnd) || ((code==HCBT_ACTIVATE || LOWORD(lparam)==SW_RESTORE
            || LOWORD(lparam)==SW_SHOWMAXIMIZED || LOWORD(lparam)==SW_SHOWNORMAL || LOWORD(lparam)==SW_SHOW)
            && ColdExistingMatches(tx,hwnd))) && StillCurrent(shared,tx) && Claim(shared,tx,hwnd)) {
        if (code==HCBT_MINMAX) {
            const unsigned show=LOWORD(lparam);
            if ((show==SW_RESTORE || show==SW_SHOWMAXIMIZED || show==SW_SHOWNORMAL || show==SW_SHOW) && IsIconic(hwnd))
                PrepareRestore(shared,hwnd,tx);
            else if ((show==SW_MINIMIZE || show==SW_SHOWMINIMIZED || show==SW_SHOWMINNOACTIVE)
                && Read32(shared->bringActive) && Id(hwnd)==tx.before && MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)!=Monitor(tx.monitor)) {
                if (PositionVisible(shared,hwnd,tx)) { SetForegroundWindow(hwnd); return 1; }
            }
        } else if (!IsIconic(hwnd)) {
            DWORD_PTR placement{};
            if (!GetWindowSubclass(hwnd,PlacementProc,SubclassId,&placement)) PositionVisible(shared,hwnd,tx);
        }
    }
    return CallNextHookEx(nullptr,code,wparam,lparam);
}
LRESULT CALLBACK ObserveMessages(int code,WPARAM wparam,LPARAM lparam) {
    if (code>=0) {
        const auto* message=reinterpret_cast<const CWPSTRUCT*>(lparam);
        if (message->message==WM_SHOWWINDOW && message->wParam) {
            Shared* shared=GetShared(); Transaction tx;
            // A reused hidden window is already visible by HCBT_ACTIVATE.
            // Observe its real show notification while it is still hidden,
            // then protect the following placement before its first paint.
            if (Snapshot(shared,tx) && !(tx.entry.flags&TF_COMPATIBILITY) && !tx.preview
                && Eligible(message->hwnd) && ColdExistingMatches(tx,message->hwnd)
                && StillCurrent(shared,tx) && Claim(shared,tx,message->hwnd)) {
                WINDOWPLACEMENT placement{sizeof(placement)};
                if (GetWindowPlacement(message->hwnd,&placement)) {
                    const RECT normal=NormalOnTarget(message->hwnd,tx,placement);
                    Attach(message->hwnd,tx,normal,IsZoomed(message->hwnd)!=FALSE);
                }
            }
        }
        if (message->message==WM_CLOSE || (message->message==WM_SYSCOMMAND && (message->wParam&0xfff0)==SC_CLOSE)) {
            Shared* shared=GetShared(); Transaction tx;
            if (Snapshot(shared,tx) && tx.preview && Candidate(tx,message->hwnd)) {
                if (CancelTransaction(shared,tx)) Event(shared,TF_CANCEL,message->hwnd,&tx);
            }
        }
    }
    return CallNextHookEx(nullptr,code,wparam,lparam);
}
bool CacheHit(Shared* shared,POINT point,HWND root,NativeEntry& entry) {
    if (Now()-static_cast<std::uint64_t>(Read64(shared->cacheAt))>3000) return false;
    const LONG sequence=Read32(shared->cacheSequence), index=Read32(shared->cacheIndex);
    if (sequence&1) return false;
    for (unsigned i=0;i<shared->count[index];++i) {
        const NativeEntry& item=shared->entries[index][i];
        if (item.taskbar==Id(root) && PtInRect(&item.button,point)) {
            entry=item; MemoryBarrier(); return sequence==Read32(shared->cacheSequence);
        }
    }
    return false;
}
void Arm(Shared* shared,const NativeEntry& entry,HMONITOR monitor,HWND before,bool preview) {
    Transaction tx{}; tx.entry=entry; tx.monitor=Id(monitor); tx.before=Id(before);
    tx.target.cbSize=sizeof(tx.target);
    if (!GetMonitorInfoW(monitor,&tx.target)) return;
    tx.released=Now(); tx.expires=tx.released+(preview ? 1800 : static_cast<unsigned>(Read32(shared->timeoutMs))); tx.preview=preview?1u:0u;
    tx.serial=static_cast<unsigned>(InterlockedIncrement(&shared->serial));
    tx.epoch=static_cast<unsigned>(InterlockedIncrement(&shared->inputEpoch));
    InterlockedIncrement(&shared->txSequence);
    shared->tx=tx;
    InterlockedExchange64(&shared->claim,static_cast<LONG64>(static_cast<std::uint64_t>(tx.serial)<<32));
    MemoryBarrier(); InterlockedIncrement(&shared->txSequence);
    InterlockedIncrement64(&shared->armed); Event(shared,TF_ARMED,nullptr,&tx);
}
struct ClickState {
    NativeEntry entry{}; POINT down{}; HMONITOR monitor{}; HWND before{};
    std::uint64_t downAt{}, hoverAt{}; bool valid{}, preview{}, group{};
    unsigned epoch{};
};
ClickState Click;
SRWLOCK ClickLock=SRWLOCK_INIT;
void SetHoverEntry(const NativeEntry& entry) {
    AcquireSRWLockExclusive(&ClickLock); Click.entry=entry; ReleaseSRWLockExclusive(&ClickLock);
}
void RefreshHoverEntry(Shared* shared) {
    if (!Click.entry.appId[0]) return;
    const LONG sequence=Read32(shared->cacheSequence), index=Read32(shared->cacheIndex);
    if (sequence&1) return;
    for (unsigned i=0;i<shared->count[index];++i) {
        const NativeEntry& entry=shared->entries[index][i];
        if (entry.taskbar==Click.entry.taskbar && wcscmp(entry.appId,Click.entry.appId)==0) {
            NativeEntry copy=entry; MemoryBarrier();
            if (sequence==Read32(shared->cacheSequence)) SetHoverEntry(copy);
            return;
        }
    }
}
bool ReleaseEntry(Shared* shared,const NativeEntry& entry,HMONITOR target,HWND before,bool preview) {
    if (wcscmp(entry.appId,L"TaskbarFollow.Status")==0 && entry.count==1
        && entry.windows[0].pid==shared->ownerPid) {
        HWND window=Window(entry.windows[0].hwnd); DWORD currentPid{};
        GetWindowThreadProcessId(window,&currentPid);
        Cancel(shared);
        return ControllerOwner && currentPid==shared->ownerPid && IsWindow(window)
            && PostMessageW(ControllerOwner,OwnWindowCommand,reinterpret_cast<WPARAM>(target),reinterpret_cast<LPARAM>(window));
    }
    if (entry.count>1 && !preview) {
        Click.group=true; Event(shared,TF_GROUP); return true;
    }
    if (!entry.count && !(entry.flags&TF_COLD_START)) { Event(shared,TF_UNSUPPORTED); return false; }
    Arm(shared,entry,target,before,preview);
    if (entry.flags&TF_COMPATIBILITY) {
        if (!ControllerOwner || !PostMessageW(ControllerOwner,CompatibilityCommand,
            static_cast<WPARAM>(Read32(shared->serial)),reinterpret_cast<LPARAM>(target))) {
            Cancel(shared); Event(shared,TF_UNSUPPORTED); return false;
        }
    }
    return true;
}
bool Modified() {
    for (int key : {VK_SHIFT,VK_CONTROL,VK_MENU,VK_LWIN,VK_RWIN}) if (GetAsyncKeyState(key)&0x8000) return true;
    return false;
}
LRESULT CALLBACK Mouse(int code,WPARAM message,LPARAM pointer) {
    Shared* shared=Controller.data;
    if (code<0 || !Live(shared)) return CallNextHookEx(nullptr,code,message,pointer);
    const auto& input=*reinterpret_cast<MSLLHOOKSTRUCT*>(pointer);
    if (message==WM_MOUSEMOVE) {
        HWND root=GetAncestor(WindowFromPoint(input.pt),GA_ROOT);
        if (PeekUi.Visible() && root!=PeekUi.Popup()) QueuePeekHide();
        if (!Click.valid) {
            NativeEntry entry{};
            if (ShellBar(root) && CacheHit(shared,input.pt,root,entry)) {
                SetHoverEntry(entry); Click.monitor=MonitorFromPoint(input.pt,MONITOR_DEFAULTTONEAREST); Click.hoverAt=Now();
            }
        }
    } else if (message==WM_LBUTTONDOWN) {
        QueuePeekHide();
        Transaction previous; const bool hadPrevious=Snapshot(shared,previous);
        Cancel(shared); Click.valid=false;
        if (hadPrevious) { InterlockedIncrement64(&shared->cancelled); Event(shared,TF_CANCEL,nullptr,&previous); }
        HWND root=GetAncestor(WindowFromPoint(input.pt),GA_ROOT); NativeEntry entry{};
        const bool isPreview=Preview(root);
        if (isPreview) RefreshHoverEntry(shared);
        if (!Modified() && Now()>=static_cast<std::uint64_t>(Read64(shared->coolUntil))
            && ((ShellBar(root) && CacheHit(shared,input.pt,root,entry))
                || (isPreview && Now()-Click.hoverAt<8000 && Click.entry.count>0
                    && MonitorFromPoint(input.pt,MONITOR_DEFAULTTONEAREST)==Click.monitor && (entry=Click.entry,true)))) {
            SetHoverEntry(entry); Click.down=input.pt; Click.downAt=Now(); Click.before=GetForegroundWindow();
            Click.monitor=MonitorFromPoint(input.pt,MONITOR_DEFAULTTONEAREST);
            Click.preview=isPreview; Click.valid=true;
            Click.epoch=static_cast<unsigned>(Read32(shared->inputEpoch));
        }
    } else if (message==WM_LBUTTONUP && Click.valid) {
        Click.valid=false;
        if (!Modified() && Click.epoch==static_cast<unsigned>(Read32(shared->inputEpoch)) && Now()-Click.downAt<=1500
            && abs(input.pt.x-Click.down.x)<=std::max(4,GetSystemMetrics(SM_CXDRAG))
            && abs(input.pt.y-Click.down.y)<=std::max(4,GetSystemMetrics(SM_CYDRAG))) {
            Click.hoverAt=Now();
            ReleaseEntry(shared,Click.entry,Click.monitor,Click.before,Click.preview);
        }
    } else if (message==WM_RBUTTONDOWN || message==WM_MBUTTONDOWN || message==WM_XBUTTONDOWN
        || message==WM_MOUSEWHEEL || message==WM_MOUSEHWHEEL) {
        Transaction previous; const bool hadPrevious=Snapshot(shared,previous);
        QueuePeekHide();
        Click.valid=false; Click.hoverAt=0; Cancel(shared);
        if (hadPrevious) { InterlockedIncrement64(&shared->cancelled); Event(shared,TF_CANCEL,nullptr,&previous); }
    }
    return CallNextHookEx(nullptr,code,message,pointer);
}
LRESULT CALLBACK Keyboard(int code,WPARAM message,LPARAM pointer) {
    if (code>=0 && Controller.data && (message==WM_KEYDOWN || message==WM_SYSKEYDOWN)) {
        QueuePeekHide();
        Transaction previous; const bool hadPrevious=Snapshot(Controller.data,previous);
        Click.valid=false; Click.hoverAt=0; Cancel(Controller.data);
        if (hadPrevious) { InterlockedIncrement64(&Controller.data->cancelled); Event(Controller.data,TF_CANCEL,nullptr,&previous); }
        // Never retain key values.
    }
    return CallNextHookEx(nullptr,code,message,pointer);
}
void TestWait(HANDLE gate,HANDLE entered) {
    if (!(StartFlags&TF_TEST_MODE)) return;
    if (entered) SetEvent(entered);
    if (gate) WaitForSingleObject(gate,INFINITE);
}
void InstallInputHook(int kind,HOOKPROC callback,HHOOK& hook) {
    hook=SetWindowsHookExW(kind,callback,Module,0);
    if (!hook) {
        const DWORD error=GetLastError();
        if (!StartupError) StartupError=error ? error : ERROR_GEN_FAILURE;
    }
}
DWORD ReleaseInputHooks() {
    DWORD firstError{};
    for (HHOOK* hook : {&MouseHook,&KeyboardHook,&CbtHook,&CallHook}) {
        if (!*hook) continue;
        if ((StartFlags&TF_TEST_MODE) && Read32(TestUnhookFailure)) {
            if (!firstError) firstError=ERROR_ACCESS_DENIED;
        } else if (UnhookWindowsHookEx(*hook)) *hook=nullptr;
        else {
            const DWORD error=GetLastError();
            // Windows can remove a hook when its installing thread exits. A
            // retry on that recorded handle then confirms it is already gone.
            if (error==ERROR_INVALID_HOOK_HANDLE) *hook=nullptr;
            else if (!firstError) firstError=error ? error : ERROR_GEN_FAILURE;
        }
    }
    return firstError;
}
DWORD RunInputThread() {
    TestWait(Lifecycle.startupGate,Lifecycle.startupEntered);
    if (Read32(StopRequested)) { StartupError=ERROR_CANCELLED; SetEvent(WorkerReady); return 0; }
    if (!SetThreadDesktop(WorkerDesktop)) { StartupError=GetLastError(); SetEvent(WorkerReady); return 0; }
    MSG message{}; PeekMessageW(&message,nullptr,0,0,PM_NOREMOVE);
    // A stop issued before PeekMessage could not post WM_QUIT. The independent
    // signal survives that race; after this check a message queue always exists.
    if (Read32(StopRequested)) { StartupError=ERROR_CANCELLED; SetEvent(WorkerReady); return 0; }
    if ((StartFlags&TF_TEST_MODE) && Lifecycle.startupError) {
        StartupError=Lifecycle.startupError; SetEvent(WorkerReady); return 0;
    }
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    PeekUi.Initialize(Module);
    InstallInputHook(WH_CBT,Cbt,CbtHook);
    InstallInputHook(WH_CALLWNDPROC,ObserveMessages,CallHook);
    if (!(StartFlags&TF_TEST_MODE)) {
        InstallInputHook(WH_MOUSE_LL,Mouse,MouseHook);
        InstallInputHook(WH_KEYBOARD_LL,Keyboard,KeyboardHook);
    }
    if (!StartupError) InterlockedExchange(&Controller.data->running,1);
    // Pair with StopRequested-before-running=0 in StopAndWait. A late startup
    // cannot leave the controller running after cancellation.
    if (Read32(StopRequested)) InterlockedExchange(&Controller.data->running,0);
    SetTimer(nullptr,1,200,nullptr); SetEvent(WorkerReady);
    while (!Read32(StopRequested) && GetMessageW(&message,nullptr,0,0)>0) {
        if (Read32(StopRequested)) break;
        InterlockedExchange64(&Controller.data->heartbeat,static_cast<LONG64>(Now()));
        if (message.message==WM_TIMER) {
            POINT point{}; GetPhysicalCursorPos(&point);
            HWND root=GetAncestor(WindowFromPoint(point),GA_ROOT);
            if (Preview(root)) RefreshHoverEntry(Controller.data);
            if (Preview(root) && Click.entry.count && MonitorFromPoint(point,MONITOR_DEFAULTTONEAREST)==Click.monitor)
                Click.hoverAt=Now();
            if (PeekUi.Visible() && (!Live(Controller.data) || root!=PeekUi.Popup() || !IsWindow(PeekUi.Source()))) {
                PeekUi.Hide(); Event(Controller.data,TF_PEEK_HIDE);
            }
            Transaction tx;
            if (Snapshot(Controller.data,tx,true) && Now()>tx.expires) {
                if (CancelTransaction(Controller.data,tx)) Event(Controller.data,TF_EXPIRED,nullptr,&tx);
            }
        }
        if (message.message==PeekCommand) {
            const bool wasVisible=PeekUi.Visible();
            if (!message.wParam) {
                if (static_cast<LONG>(message.lParam)==Read32(PeekGeneration)) {
                    PeekUi.Hide(); if (wasVisible) Event(Controller.data,TF_PEEK_HIDE);
                }
            } else {
                auto* request=reinterpret_cast<PeekRequest*>(message.lParam);
                POINT point{}; GetPhysicalCursorPos(&point);
                HWND root=GetAncestor(WindowFromPoint(point),GA_ROOT);
                RefreshHoverEntry(Controller.data);
                bool matched=false;
                Transaction active;
                for (unsigned i=0;i<Click.entry.count;++i)
                    if (Click.entry.windows[i].hwnd==Id(request->source) && Click.entry.windows[i].pid==request->pid) matched=true;
                if (Read32(PeekEnabled) && request->generation==Read32(PeekGeneration) && Live(Controller.data)
                    && root==request->popup && Preview(root) && matched && !Click.valid && !Snapshot(Controller.data,active)
                    && abs(point.x-request->point.x)<=8 && abs(point.y-request->point.y)<=8
                    && !(GetAsyncKeyState(VK_LBUTTON)&0x8000) && !Modified()
                    && MonitorFromWindow(request->source,MONITOR_DEFAULTTONEAREST)!=MonitorFromPoint(point,MONITOR_DEFAULTTONEAREST)) {
                    const HWND before=PeekUi.Source();
                    if (PeekUi.Show(request->source,request->pid,root,MonitorFromPoint(point,MONITOR_DEFAULTTONEAREST))) {
                        Click.hoverAt=Now();
                        if (!wasVisible || before!=request->source) Event(Controller.data,TF_PEEK_SHOW,request->source);
                    }
                } else if (request->generation==Read32(PeekGeneration)) {
                    PeekUi.Hide(); if (wasVisible) Event(Controller.data,TF_PEEK_HIDE);
                }
                delete request;
            }
            continue;
        }
        TranslateMessage(&message); DispatchMessageW(&message);
    }
    PeekUi.Shutdown();
    while (PeekMessageW(&message,nullptr,PeekCommand,PeekCommand,PM_REMOVE))
        if (message.wParam) delete reinterpret_cast<PeekRequest*>(message.lParam);
    ShutdownError=ReleaseInputHooks();
    return 0;
}
DWORD WINAPI InputThread(void* module) {
    const DWORD result=RunInputThread();
    TestWait(Lifecycle.shutdownGate,Lifecycle.shutdownEntered);
    if (ShutdownError) {
        // Unhook failure outlives the thread. Keep its loader reference until
        // StopAndWait can remove the remaining hooks and release it safely.
        RetainedWorkerModule=static_cast<HMODULE>(module);
        return result;
    }
    // This must be the last operation: releasing the last reference followed by
    // a normal C++ return would execute instructions from an unloaded DLL.
    FreeLibraryAndExitThread(static_cast<HMODULE>(module),result);
}
void ResetLifecycleTest() {
    for (HANDLE handle : {Lifecycle.startupGate,Lifecycle.shutdownGate,Lifecycle.startupEntered,Lifecycle.shutdownEntered})
        if (handle) CloseHandle(handle);
    Lifecycle={};
}
}

BOOL WINAPI DllMain(HINSTANCE instance,DWORD reason,void*) {
    if (reason==DLL_PROCESS_ATTACH) Module=instance;
    else if (reason==DLL_PROCESS_DETACH) {
        if (Payload.data) UnmapViewOfFile(Payload.data);
        if (Payload.handle) CloseHandle(Payload.handle);
    }
    return TRUE;
}
BOOL TF_Start(HWND owner,unsigned flags) {
    LifecycleGuard guard;
    if (!guard.held) { SetLastError(ERROR_BUSY); return FALSE; }
    if (Controller.data || Worker) { SetLastError(ERROR_ALREADY_INITIALIZED); return FALSE; }
    InterlockedExchange(&ControllerProcess,1);
    InterlockedExchange(&StopRequested,0);
    DWORD ownerPid{};
    if (owner) GetWindowThreadProcessId(owner,&ownerPid);
    ControllerOwner=ownerPid==GetCurrentProcessId() ? owner : nullptr;
    wchar_t name[128]{}; MappingName(name,128);
    Controller.handle=CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,sizeof(Shared),name);
    if (!Controller.handle) return FALSE;
    const bool existed=GetLastError()==ERROR_ALREADY_EXISTS;
    Controller.data=static_cast<Shared*>(MapViewOfFile(Controller.handle,FILE_MAP_ALL_ACCESS,0,0,sizeof(Shared)));
    if (!Controller.data) {
        const DWORD error=GetLastError(); CloseHandle(Controller.handle); Controller={};
        SetLastError(error); return FALSE;
    }
    auto* shared=Controller.data;
    if (existed && shared->magic==Magic && Read32(shared->running) && Now()-static_cast<std::uint64_t>(Read64(shared->heartbeat))<2500) {
        UnmapViewOfFile(shared); CloseHandle(Controller.handle); Controller={}; SetLastError(ERROR_ALREADY_EXISTS); return FALSE;
    }
    if (!existed) ZeroMemory(shared,sizeof(*shared));
    else {
        InterlockedExchange(&shared->running,0); InterlockedExchange(&shared->enabled,0); Cancel(shared);
        shared->count[0]=shared->count[1]=0;
        InterlockedExchange64(&shared->armed,0); InterlockedExchange64(&shared->created,0);
        InterlockedExchange64(&shared->restored,0); InterlockedExchange64(&shared->activated,0);
        InterlockedExchange64(&shared->firstShown,0); InterlockedExchange64(&shared->cancelled,0);
        InterlockedExchange64(&shared->eventNumber,0); InterlockedExchange(&shared->lastKind,0);
    }
    shared->magic=Magic; shared->ownerPid=GetCurrentProcessId(); shared->enabled=1; shared->timeoutMs=8000; shared->bringActive=1;
    shared->heartbeat=static_cast<LONG64>(Now());
    StartFlags=flags; StartupError=ShutdownError=0; WorkerDesktop=GetThreadDesktop(GetCurrentThreadId());
    WorkerReady=CreateEventW(nullptr,TRUE,FALSE,nullptr);
    if (!WorkerReady) {
        const DWORD error=GetLastError(); StopAndWaitImpl(3000); SetLastError(error); return FALSE;
    }
    HMODULE workerModule{};
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS,reinterpret_cast<LPCWSTR>(Module),&workerModule)) {
        const DWORD error=GetLastError(); StopAndWaitImpl(3000); SetLastError(error); return FALSE;
    }
    Worker=CreateThread(nullptr,0,InputThread,workerModule,0,&WorkerId);
    if (!Worker) {
        const DWORD error=GetLastError(); FreeLibrary(workerModule); StopAndWaitImpl(3000); SetLastError(error); return FALSE;
    }
    const DWORD ready=WaitForSingleObject(WorkerReady,3000);
    if (ready!=WAIT_OBJECT_0 || StartupError) {
        const DWORD error=ready==WAIT_TIMEOUT ? ERROR_TIMEOUT : (ready==WAIT_FAILED ? GetLastError() : StartupError);
        StopAndWaitImpl(3000); SetLastError(error); return FALSE;
    }
    return TRUE;
}
void TF_Stop() {
    (void)TF_StopAndWait(3000);
}
namespace {
BOOL StopAndWaitImpl(unsigned timeoutMs) {
    InterlockedExchange(&StopRequested,1);
    if (Controller.data) { InterlockedExchange(&Controller.data->enabled,0); InterlockedExchange(&Controller.data->running,0); Cancel(Controller.data); }
    if (Worker) {
        PostThreadMessageW(WorkerId,WM_QUIT,0,0);
        const DWORD result=WaitForSingleObject(Worker,timeoutMs);
        if (result!=WAIT_OBJECT_0) {
            SetLastError(result==WAIT_TIMEOUT ? ERROR_TIMEOUT : GetLastError());
            return FALSE;
        }
    }
    // A failed unhook leaves its handle intact. A completed worker may need a
    // later caller to retry, while its extra module reference remains held.
    ShutdownError=ReleaseInputHooks();
    if (ShutdownError) { SetLastError(ShutdownError); return FALSE; }
    if (Worker) { CloseHandle(Worker); Worker=nullptr; }
    if (WorkerReady) { CloseHandle(WorkerReady); WorkerReady=nullptr; }
    if (Controller.data) UnmapViewOfFile(Controller.data);
    if (Controller.handle) CloseHandle(Controller.handle);
    Controller={};
    WorkerId=0; StartFlags=0; StartupError=0;
    ControllerOwner=nullptr;
    InterlockedExchange(&TestUnhookFailure,0);
    Click={}; ResetLifecycleTest();
    const HMODULE retained=RetainedWorkerModule; RetainedWorkerModule=nullptr;
    if (retained) FreeLibrary(retained); // caller still owns its loader reference
    SetLastError(ERROR_SUCCESS); return TRUE;
}
}
BOOL TF_StopAndWait(unsigned timeoutMs) {
    LifecycleGuard guard;
    if (!guard.held) { SetLastError(ERROR_BUSY); return FALSE; }
    return StopAndWaitImpl(timeoutMs);
}
BOOL TF_TestLifecycle(HANDLE startupGate,HANDLE shutdownGate,HANDLE startupEntered,HANDLE shutdownEntered,DWORD startupError) {
    LifecycleGuard guard;
    if (!guard.held) { SetLastError(ERROR_BUSY); return FALSE; }
    if (Controller.data || Worker) { SetLastError(ERROR_ALREADY_INITIALIZED); return FALSE; }
    LifecycleTest next{}; const HANDLE process=GetCurrentProcess();
    const HANDLE sources[]={startupGate,shutdownGate,startupEntered,shutdownEntered};
    HANDLE* targets[]={&next.startupGate,&next.shutdownGate,&next.startupEntered,&next.shutdownEntered};
    for (unsigned i=0;i<4;++i) {
        if (sources[i] && !DuplicateHandle(process,sources[i],process,targets[i],0,FALSE,DUPLICATE_SAME_ACCESS)) {
            const DWORD error=GetLastError();
            for (HANDLE handle : {next.startupGate,next.shutdownGate,next.startupEntered,next.shutdownEntered}) if (handle) CloseHandle(handle);
            SetLastError(error); return FALSE;
        }
    }
    ResetLifecycleTest(); Lifecycle=next; Lifecycle.startupError=startupError;
    SetLastError(ERROR_SUCCESS); return TRUE;
}
BOOL TF_TestSetUnhookFailure(BOOL enabled) {
    LifecycleGuard guard;
    if (!guard.held) { SetLastError(ERROR_BUSY); return FALSE; }
    if (!Controller.data || !(StartFlags&TF_TEST_MODE)) { SetLastError(ERROR_ACCESS_DENIED); return FALSE; }
    InterlockedExchange(&TestUnhookFailure,enabled?1:0);
    SetLastError(ERROR_SUCCESS); return TRUE;
}
void TF_SetEnabled(BOOL enabled) {
    if (Controller.data) { InterlockedExchange(&Controller.data->enabled,enabled?1:0); if (!enabled) { Cancel(Controller.data); QueuePeekHide(); } }
}
void TF_Configure(unsigned timeoutMs,BOOL bringActive) {
    if (Controller.data) {
        InterlockedExchange(&Controller.data->timeoutMs,static_cast<LONG>(std::clamp(timeoutMs,1000u,15000u)));
        InterlockedExchange(&Controller.data->bringActive,bringActive?1:0);
    }
}
void TF_Cancel(unsigned cooldown) { if (Controller.data) { Cancel(Controller.data,cooldown); QueuePeekHide(); } }
BOOL TF_PublishCache(const NativeEntry* entries,unsigned count,unsigned stride) {
    if (!Controller.data || stride!=sizeof(NativeEntry) || count>TF_MAX_ENTRIES || (count&&!entries)) return FALSE;
    for (unsigned i=0;i<count;++i)
        if (entries[i].count>TF_MAX_WINDOWS || entries[i].path[1023] || entries[i].appId[255]) return FALSE;
    auto* shared=Controller.data; const LONG next=1-Read32(shared->cacheIndex);
    InterlockedIncrement(&shared->cacheSequence);
    if (count) memcpy(shared->entries[next],entries,count*sizeof(NativeEntry));
    shared->count[next]=count; InterlockedExchange(&shared->cacheIndex,next);
    InterlockedExchange64(&shared->cacheAt,static_cast<LONG64>(Now()));
    MemoryBarrier(); InterlockedIncrement(&shared->cacheSequence); return TRUE;
}
BOOL TF_Status(NativeStatus* status,unsigned bytes) {
    if (!Controller.data || !status || bytes!=sizeof(NativeStatus)) return FALSE;
    auto* shared=Controller.data; ZeroMemory(status,sizeof(*status)); status->size=sizeof(*status);
    status->running=static_cast<unsigned>(Read32(shared->running)); status->enabled=static_cast<unsigned>(Read32(shared->enabled));
    status->cacheCount=shared->count[Read32(shared->cacheIndex)];
    status->cacheAge=Now()-static_cast<std::uint64_t>(Read64(shared->cacheAt));
    status->armed=Read64(shared->armed); status->created=Read64(shared->created); status->restored=Read64(shared->restored);
    status->activated=Read64(shared->activated); status->firstShown=Read64(shared->firstShown); status->cancelled=Read64(shared->cancelled);
    status->lastKind=static_cast<unsigned>(Read32(shared->lastKind)); status->lastPid=static_cast<unsigned>(Read32(shared->lastPid));
    status->lastWindow=Read64(shared->lastWindow); status->latency=Read64(shared->latency); status->eventNumber=Read64(shared->eventNumber);
    wcsncpy_s(status->target,shared->target,_TRUNCATE); return TRUE;
}
BOOL TF_CompatibilityIntent(unsigned serial,NativeIntent* intent,unsigned bytes) {
    if (!Controller.data || !intent || bytes!=sizeof(*intent)) return FALSE;
    Transaction tx;
    if (!Snapshot(Controller.data,tx) || tx.serial!=serial || !(tx.entry.flags&TF_COMPATIBILITY)) return FALSE;
    ZeroMemory(intent,sizeof(*intent));
    intent->entry=tx.entry; intent->monitor=tx.monitor; intent->released=tx.released;
    intent->expires=tx.expires; intent->serial=tx.serial; return TRUE;
}
BOOL TF_CancelCompatibility(unsigned serial) {
    if (!Controller.data) return FALSE;
    Transaction tx;
    return Snapshot(Controller.data,tx) && tx.serial==serial && (tx.entry.flags&TF_COMPATIBILITY)
        && CancelTransaction(Controller.data,tx);
}
BOOL TF_TestReleaseEntry(const NativeEntry* entry,HMONITOR target,BOOL preview) {
    if (!Controller.data || !(StartFlags&TF_TEST_MODE) || !entry || !target || entry->count>TF_MAX_WINDOWS
        || entry->path[1023] || entry->appId[255]) return FALSE;
    wchar_t own[1024]{}; GetModuleFileNameW(nullptr,own,1024);
    if (_wcsicmp(own,entry->path)!=0) return FALSE;
    for (unsigned i=0;i<entry->count;++i) {
        DWORD pid{}; GetWindowThreadProcessId(Window(entry->windows[i].hwnd),&pid);
        if (pid!=entry->windows[i].pid) return FALSE;
        HANDLE process=OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION,FALSE,pid);
        if (!process) return FALSE;
        wchar_t path[1024]{}; DWORD chars=1024;
        const bool matches=QueryFullProcessImageNameW(process,0,path,&chars) && _wcsicmp(path,own)==0;
        CloseHandle(process); if (!matches) return FALSE;
    }
    MONITORINFO info{sizeof(info)};
    if (!GetMonitorInfoW(target,&info) || !Live(Controller.data)) return FALSE;
    return ReleaseEntry(Controller.data,*entry,target,nullptr,preview!=FALSE) ? TRUE : FALSE;
}
BOOL TF_TestArm(const wchar_t* path,HWND window,HMONITOR target) {
    if (!Controller.data || !(StartFlags&TF_TEST_MODE) || !path || !target) return FALSE;
    wchar_t own[1024]{}; GetModuleFileNameW(nullptr,own,1024);
    if (_wcsicmp(path,own)!=0) return FALSE;
    NativeEntry entry{}; wcsncpy_s(entry.path,path,_TRUNCATE); entry.flags=TF_COLD_START;
    if (window) { DWORD pid{}; GetWindowThreadProcessId(window,&pid); entry.count=1; entry.windows[0]={Id(window),pid,0}; }
    Arm(Controller.data,entry,target,nullptr,false); return TRUE;
}
BOOL TF_TestArmIdentity(const wchar_t* path,const wchar_t* appId,HMONITOR target) {
    if (!TF_TestArm(path,nullptr,target) || !appId || wcslen(appId)>=256) return FALSE;
    NativeEntry entry{}; wcsncpy_s(entry.path,path,_TRUNCATE); wcsncpy_s(entry.appId,appId,_TRUNCATE);
    entry.flags=TF_COLD_START|TF_REQUIRE_APP_ID;
    Arm(Controller.data,entry,target,nullptr,false); return TRUE;
}
void TF_SetPeekEnabled(BOOL enabled) { InterlockedExchange(&PeekEnabled,enabled?1:0); if (!enabled) QueuePeekHide(); }
void TF_HidePeek() { QueuePeekHide(); }
BOOL TF_ShowPeek(HWND source,DWORD pid,HWND popup,int x,int y) {
    if (!Controller.data || !Live(Controller.data) || !Read32(PeekEnabled)) return FALSE;
    auto* request=new(std::nothrow) PeekRequest{source,popup,pid,{x,y},InterlockedIncrement(&PeekGeneration)};
    if (!request) return FALSE;
    if (!PostThreadMessageW(WorkerId,PeekCommand,1,reinterpret_cast<LPARAM>(request))) { delete request; return FALSE; }
    return TRUE;
}
HWND TF_TestPeek(HWND source,HWND popup,HMONITOR target,BOOL show) {
    if (!Controller.data || !(StartFlags&TF_TEST_MODE)) return nullptr;
    // The test has its own desktop and source process; no input callback is used.
    static PeekPreview testPeek;
    testPeek.Initialize(Module);
    if (!show) { testPeek.Shutdown(); return nullptr; }
    DWORD pid{}; GetWindowThreadProcessId(source,&pid);
    return testPeek.Show(source,pid,popup,target) ? testPeek.Host() : nullptr;
}
unsigned TF_HoverCandidates(NativeCandidate* candidates,unsigned capacity) {
    if (!Controller.data || !candidates || capacity<TF_MAX_WINDOWS) return 0;
    if (!TryAcquireSRWLockShared(&ClickLock)) return 0;
    unsigned count=Click.entry.count;
    if (count<=TF_MAX_WINDOWS) memcpy(candidates,Click.entry.windows,count*sizeof(NativeCandidate));
    else count=0;
    ReleaseSRWLockShared(&ClickLock); return count;
}
BOOL TF_AccessibleName(int x,int y,wchar_t* name,unsigned capacity) {
    if (!name || capacity<2 || capacity>32768) return FALSE;
    name[0]=0;
    IAccessible* accessible{}; VARIANT child{}; BSTR text{};
    if (FAILED(AccessibleObjectFromPoint({x,y},&accessible,&child)) || !accessible) return FALSE;
    const HRESULT result=accessible->get_accName(child,&text);
    if (SUCCEEDED(result) && text) wcsncpy_s(name,capacity,text,_TRUNCATE);
    SysFreeString(text); VariantClear(&child); accessible->Release(); return name[0]!=0;
}
