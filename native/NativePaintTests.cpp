#include "NativeHooks.h"
#include <cstdio>
#include <string>
#include <stdexcept>
#include <vector>

// A real child process on an owned desktop supplies the application's window
// procedure. Its WM_WINDOWPOSCHANGING handler suppresses an unwanted position
// change, as an application may do during restore/activation. If the placement subclass
// overrides that decision, the resulting move/resize must still repaint.
// No input hooks, user windows, forced invalidation, or delayed redraw are used.
namespace {
constexpr UINT PlacementMessage=WM_APP+41;
constexpr UINT InterruptMessage=WM_APP+42;
constexpr int ActivationCase=0, NormalRestoreCase=1, MaximizedRestoreCase=2;
constexpr COLORREF InitialColor=RGB(28,73,132);
constexpr COLORREF RestoredColor=RGB(31,137,91);
struct FixtureState {
    std::uint64_t hwnd, paintMonitor, controller;
    LONG initialPaints, initialColor, suppressions, sizes, paints;
    LONG sizeWidth, sizeHeight, paintWidth, paintHeight, paintedColor;
    LONG clientWidth, clientHeight, iconic, maximized, finalFlags, activeBefore, activeAfter;
    LONG interruptMode, interruptions, interruptSucceeded;
    RECT before, after;
};
FixtureState* Fixture{};
HANDLE Observed{};
bool Checking{};
bool VisibleActivation{};
HWND Anchor{};
using ArmFn=BOOL(*)(const wchar_t*,HWND,HMONITOR);
using CancelFn=void(*)(unsigned);
ArmFn ControllerArm{};
CancelFn ControllerCancel{};
FixtureState* ControllerFixture{};
HMONITOR ControllerTarget{};
std::wstring Executable();

LRESULT CALLBACK ControllerProc(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
    if (message==InterruptMessage && ControllerFixture
        && reinterpret_cast<UINT_PTR>(reinterpret_cast<HWND>(lparam))==ControllerFixture->hwnd) {
        ControllerCancel(0);
        return wparam==2?ControllerArm(Executable().c_str(),reinterpret_cast<HWND>(lparam),ControllerTarget):TRUE;
    }
    return DefWindowProcW(hwnd,message,wparam,lparam);
}

void Check(bool condition,const char* label) {
    if (!condition) throw std::runtime_error(label);
}
void DrainMessages() {
    MSG message{};
    while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) {
        TranslateMessage(&message); DispatchMessageW(&message);
    }
}
void WaitForFixture(HANDLE event,HANDLE process,const char* label) {
    const ULONGLONG until=GetTickCount64()+5000;
    HANDLE handles[]={event,process};
    for (;;) {
        const ULONGLONG now=GetTickCount64();
        Check(now<until,label);
        const DWORD result=MsgWaitForMultipleObjects(2,handles,FALSE,static_cast<DWORD>(until-now),QS_ALLINPUT);
        if (result==WAIT_OBJECT_0) return;
        Check(result==WAIT_OBJECT_0+2,label);
        DrainMessages();
    }
}
LRESULT CALLBACK FixtureProc(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
    if (message==PlacementMessage) {
        GetWindowRect(hwnd,&Fixture->before);
        Fixture->paints=Fixture->sizes=0;
        Checking=true;
        if (VisibleActivation) {
            if (GetActiveWindow()==hwnd) SetActiveWindow(Anchor);
            SetActiveWindow(hwnd);
            Fixture->activeAfter=GetActiveWindow()==hwnd?1:0;
        } else ShowWindow(hwnd,SW_RESTORE);
        // PeekMessage generates pending WM_PAINT before reporting an empty
        // queue. This observes ordinary invalidation from the placement itself;
        // UpdateWindow/InvalidateRect here would conceal the regression.
        DrainMessages();
        RECT client{}; GetClientRect(hwnd,&client); GetWindowRect(hwnd,&Fixture->after);
        Fixture->clientWidth=client.right; Fixture->clientHeight=client.bottom;
        Fixture->iconic=IsIconic(hwnd); Fixture->maximized=IsZoomed(hwnd);
        SetEvent(Observed); return 0;
    }
    if (message==WM_WINDOWPOSCHANGING) {
        const LRESULT result=DefWindowProcW(hwnd,message,wparam,lparam);
        if (Checking) {
            auto* position=reinterpret_cast<WINDOWPOS*>(lparam);
            position->flags|=SWP_NOMOVE|SWP_NOSIZE|SWP_NOREDRAW;
            ++Fixture->suppressions;
            if (Fixture->interruptMode && !Fixture->interruptions) {
                ++Fixture->interruptions;
                Fixture->interruptSucceeded=static_cast<LONG>(SendMessageW(
                    reinterpret_cast<HWND>(static_cast<UINT_PTR>(Fixture->controller)),InterruptMessage,
                    static_cast<WPARAM>(Fixture->interruptMode),reinterpret_cast<LPARAM>(hwnd)));
            }
        }
        return result;
    }
    if (message==WM_WINDOWPOSCHANGED && Checking)
        Fixture->finalFlags=static_cast<LONG>(reinterpret_cast<WINDOWPOS*>(lparam)->flags);
    if (message==WM_SIZE && wparam!=SIZE_MINIMIZED) {
        if (Checking) ++Fixture->sizes;
        Fixture->sizeWidth=LOWORD(lparam); Fixture->sizeHeight=HIWORD(lparam);
    }
    if (message==WM_PAINT) {
        PAINTSTRUCT paint{}; HDC dc=BeginPaint(hwnd,&paint);
        RECT client{}; GetClientRect(hwnd,&client);
        HBRUSH brush=CreateSolidBrush(Checking?RestoredColor:InitialColor);
        FillRect(dc,&client,brush); DeleteObject(brush);
        // Read the pixels painted into the real window DC, including on the
        // owned inactive desktop. A counter alone would miss a blank paint.
        const COLORREF color=GetPixel(dc,client.right/2,client.bottom/2);
        EndPaint(hwnd,&paint);
        if (Checking && IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
            ++Fixture->paints; Fixture->paintWidth=client.right; Fixture->paintHeight=client.bottom;
            Fixture->paintedColor=static_cast<LONG>(color);
            Fixture->paintMonitor=reinterpret_cast<UINT_PTR>(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST));
        } else if (!Checking && IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
            ++Fixture->initialPaints; Fixture->initialColor=static_cast<LONG>(color);
        }
        return 0;
    }
    if (message==WM_CLOSE) { DestroyWindow(hwnd); return 0; }
    if (message==WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd,message,wparam,lparam);
}
int RunFixture(int argc,wchar_t** argv) {
    if (argc!=6) return 2;
    HANDLE mapping=OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,argv[2]);
    if (!mapping) return 3;
    Fixture=static_cast<FixtureState*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(FixtureState)));
    if (!Fixture) { CloseHandle(mapping); return 4; }
    const std::wstring readyName=std::wstring(argv[2])+L".ready";
    const std::wstring observedName=std::wstring(argv[2])+L".observed";
    HANDLE ready=OpenEventW(EVENT_MODIFY_STATE,FALSE,readyName.c_str());
    Observed=OpenEventW(EVENT_MODIFY_STATE,FALSE,observedName.c_str());
    if (!ready || !Observed) return 5;
    WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=FixtureProc;
    cls.lpszClassName=L"TaskbarFollow.NativePaintFixture";
    cls.hbrBackground=reinterpret_cast<HBRUSH>(COLOR_WINDOW+1);
    if (!RegisterClassW(&cls)) return 6;
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,L"TaskbarFollow owned repaint fixture",
        WS_OVERLAPPEDWINDOW,_wtoi(argv[3]),_wtoi(argv[4]),640,400,
        nullptr,nullptr,cls.hInstance,nullptr);
    if (!hwnd) return 7;
    Fixture->hwnd=reinterpret_cast<UINT_PTR>(hwnd);
    const int scenario=_wtoi(argv[5]);
    VisibleActivation=scenario==ActivationCase;
    ShowWindow(hwnd,scenario==MaximizedRestoreCase?SW_SHOWMAXIMIZED:SW_SHOWNORMAL);
    UpdateWindow(hwnd); DrainMessages();
    if (VisibleActivation) {
        // A second owned top-level window gives SetActiveWindow a genuine
        // activation transition. It uses DefWindowProc, so it cannot update
        // the measured fixture's paints or client-size observations.
        WNDCLASSW anchorClass=cls; anchorClass.lpfnWndProc=DefWindowProcW;
        anchorClass.lpszClassName=L"TaskbarFollow.NativePaintAnchor";
        if (!RegisterClassW(&anchorClass)) return 8;
        Anchor=CreateWindowExW(0,anchorClass.lpszClassName,L"TaskbarFollow owned activation anchor",
            WS_OVERLAPPEDWINDOW,_wtoi(argv[3])+10,_wtoi(argv[4])+10,220,120,
            nullptr,nullptr,cls.hInstance,nullptr);
        if (!Anchor) return 9;
        ShowWindow(Anchor,SW_SHOWNORMAL); UpdateWindow(Anchor); SetActiveWindow(Anchor);
        DrainMessages(); Fixture->activeBefore=GetActiveWindow()==Anchor?1:0;
    } else { ShowWindow(hwnd,SW_MINIMIZE); DrainMessages(); }
    SetEvent(ready);
    SetTimer(hwnd,91,15000,nullptr);
    MSG message{};
    while (GetMessageW(&message,nullptr,0,0)>0) {
        if (message.message==WM_TIMER && message.wParam==91) break;
        TranslateMessage(&message); DispatchMessageW(&message);
    }
    if (Anchor && IsWindow(Anchor)) DestroyWindow(Anchor);
    CloseHandle(ready); CloseHandle(Observed);
    UnmapViewOfFile(Fixture); CloseHandle(mapping); return 0;
}
std::wstring Executable() {
    wchar_t path[32768]{}; GetModuleFileNameW(nullptr,path,32768); return path;
}
struct Child {
    HANDLE process{}, mapping{}, ready{}, observed{};
    FixtureState* state{};
    ~Child() {
        if (state && state->hwnd)
            PostMessageW(reinterpret_cast<HWND>(static_cast<UINT_PTR>(state->hwnd)),WM_CLOSE,0,0);
        if (process) {
            if (WaitForSingleObject(process,1500)!=WAIT_OBJECT_0) {
                TerminateProcess(process,99); WaitForSingleObject(process,1500);
            }
            CloseHandle(process);
        }
        if (state) UnmapViewOfFile(state);
        if (mapping) CloseHandle(mapping);
        if (ready) CloseHandle(ready);
        if (observed) CloseHandle(observed);
    }
    HWND Window() const { return reinterpret_cast<HWND>(static_cast<UINT_PTR>(state->hwnd)); }
    void Spawn(const std::wstring& name,const std::wstring& desktop,const MONITORINFO& source,int scenario) {
        mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,sizeof(FixtureState),name.c_str());
        Check(mapping!=nullptr,"fixture mapping creation");
        state=static_cast<FixtureState*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(FixtureState)));
        Check(state!=nullptr,"fixture mapping view"); ZeroMemory(state,sizeof(*state));
        ready=CreateEventW(nullptr,TRUE,FALSE,(name+L".ready").c_str());
        observed=CreateEventW(nullptr,TRUE,FALSE,(name+L".observed").c_str());
        Check(ready && observed,"fixture event creation");
        std::wstring command=L"\""+Executable()+L"\" --fixture "+name+L" "+std::to_wstring(source.rcWork.left+100)
            +L" "+std::to_wstring(source.rcWork.top+80)+L" "+std::to_wstring(scenario);
        std::wstring fullDesktop=L"winsta0\\"+desktop;
        STARTUPINFOW startup{sizeof(startup)}; startup.lpDesktop=fullDesktop.data(); PROCESS_INFORMATION child{};
        Check(CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&child)!=FALSE,
            "fixture process creation");
        process=child.hProcess; CloseHandle(child.hThread);
        WaitForFixture(ready,process,"fixture initial paint/state handshake");
        printf("native paint initial paints=%ld color=%06lx\n",state->initialPaints,state->initialColor);
        Check(state->initialPaints>0 && state->initialColor==static_cast<LONG>(InitialColor),"fixture initially painted real colored content");
        if (scenario==ActivationCase) {
            Check(IsWindowVisible(Window()) && !IsIconic(Window()),"activation fixture initially visible");
            Check(state->activeBefore!=0,"owned anchor became active on the private desktop");
        } else Check(IsIconic(Window())!=FALSE,"fixture initially minimized");
    }
};
BOOL CALLBACK Collect(HMONITOR monitor,HDC,LPRECT,LPARAM pointer) {
    reinterpret_cast<std::vector<HMONITOR>*>(pointer)->push_back(monitor); return TRUE;
}
using StartFn=BOOL(*)(HWND,unsigned);
using StopFn=BOOL(*)(unsigned);
using StatusFn=BOOL(*)(NativeStatus*,unsigned);
bool WaitForActivation(StatusFn status,NativeStatus& after,std::uint64_t before) {
    const ULONGLONG until=GetTickCount64()+2000;
    do {
        if (status(&after,sizeof(after)) && after.activated>before) return true;
        DrainMessages(); Sleep(10);
    } while (GetTickCount64()<until);
    return false;
}
}
int wmain(int argc,wchar_t** argv) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc>1 && wcscmp(argv[1],L"--fixture")==0) return RunFixture(argc,argv);
    const std::wstring desktopName=L"TaskbarFollow.NativePaintTests."+std::to_wstring(GetCurrentProcessId());
    HDESK original=GetThreadDesktop(GetCurrentThreadId());
    HDESK desktop=CreateDesktopW(desktopName.c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) { fprintf(stderr,"FAIL paint test desktop: %lu\n",GetLastError()); return 1; }
    HMODULE dll{}; StopFn Stop{}; HWND controller{};
    int exitCode=1;
    try {
        Check(argc==2,"pass the native hook DLL path");
        dll=LoadLibraryW(argv[1]); Check(dll!=nullptr,"native paint DLL load");
        auto Start=reinterpret_cast<StartFn>(GetProcAddress(dll,"TF_Start"));
        Stop=reinterpret_cast<StopFn>(GetProcAddress(dll,"TF_StopAndWait"));
        auto Arm=reinterpret_cast<ArmFn>(GetProcAddress(dll,"TF_TestArm"));
        ControllerCancel=reinterpret_cast<CancelFn>(GetProcAddress(dll,"TF_Cancel")); ControllerArm=Arm;
        auto Status=reinterpret_cast<StatusFn>(GetProcAddress(dll,"TF_Status"));
        Check(Start && Stop && Arm && Status && ControllerCancel,"native paint ABI");
        WNDCLASSW controllerClass{}; controllerClass.hInstance=GetModuleHandleW(nullptr);
        controllerClass.lpfnWndProc=ControllerProc; controllerClass.lpszClassName=L"TaskbarFollow.NativePaintController";
        Check(RegisterClassW(&controllerClass)!=0,"register owned paint controller");
        controller=CreateWindowExW(0,controllerClass.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,controllerClass.hInstance,nullptr);
        Check(controller!=nullptr,"create owned paint controller");
        std::vector<HMONITOR> monitors; EnumDisplayMonitors(nullptr,nullptr,Collect,reinterpret_cast<LPARAM>(&monitors));
        Check(monitors.size()>=2,"paint regression requires two monitors");
        MONITORINFO source{sizeof(source)}; Check(GetMonitorInfoW(monitors[0],&source)!=FALSE,"source monitor info");
        ControllerTarget=monitors[1];
        Check(Start(nullptr,TF_TEST_MODE)!=FALSE,"native paint controller startup");
        for (int scenario=ActivationCase;scenario<=4;++scenario) {
            const int interruption=scenario>=3?scenario-2:0;
            const bool activation=scenario==ActivationCase || interruption, maximized=scenario==MaximizedRestoreCase;
            Child child;
            child.Spawn(L"Local\\TaskbarFollow.NativePaint."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(scenario),
                desktopName,source,interruption?ActivationCase:scenario);
            ControllerFixture=child.state;
            child.state->controller=reinterpret_cast<UINT_PTR>(controller); child.state->interruptMode=interruption;
            NativeStatus before{}; Check(Status(&before,sizeof(before))!=FALSE,"pre-placement status");
            Check(Arm(Executable().c_str(),child.Window(),monitors[1])!=FALSE,"native repaint placement arm");
            Check(PostMessageW(child.Window(),PlacementMessage,0,0)!=FALSE,"fixture placement command");
            WaitForFixture(child.observed,child.process,"fixture placement observation handshake");
            NativeStatus after{}; Check(Status(&after,sizeof(after))!=FALSE,"post-placement status");
            const FixtureState& state=*child.state;
            if (interruption) {
                Check(state.interruptions==1 && state.interruptSucceeded!=0,"application synchronously canceled or rearmed the real controller");
                Check(EqualRect(&state.before,&state.after) && MonitorFromWindow(child.Window(),MONITOR_DEFAULTTONEAREST)==monitors[0],
                    "canceled callback did not apply stale target geometry");
                Check(after.activated==before.activated,"canceled callback did not report a completed activation");
                if (interruption==2) {
                    Check(after.armed==before.armed+2,"replacement intent was armed inside the application handler");
                    child.state->interruptMode=0; ResetEvent(child.observed);
                    Check(PostMessageW(child.Window(),PlacementMessage,0,0)!=FALSE,"replacement intent activation command");
                    WaitForFixture(child.observed,child.process,"replacement intent observation handshake");
                    Check(WaitForActivation(Status,after,before.activated)
                        && MonitorFromWindow(child.Window(),MONITOR_DEFAULTTONEAREST)==monitors[1]
                        && state.paints>0 && state.paintedColor==static_cast<LONG>(RestoredColor),
                        "old callback did not cancel the replacement intent, which still moved and painted");
                }
                printf("PASS native repaint interruption: synchronous %s preserved controller intent and prevented stale geometry\n",
                    interruption==2?"cancel/rearm":"cancel");
                continue;
            }
            if (activation)
                Check(WaitForActivation(Status,after,before.activated),"real cross-process visible activation hook exercised");
            printf("native paint trace activate=%d max=%d suppressions=%ld sizes=%ld paints=%ld client=%ldx%ld size=%ldx%ld painted=%ldx%ld color=%06lx flags=%lx restored=%llu->%llu activated=%llu->%llu\n",
                activation?1:0,maximized?1:0,state.suppressions,state.sizes,state.paints,state.clientWidth,state.clientHeight,
                state.sizeWidth,state.sizeHeight,state.paintWidth,state.paintHeight,state.paintedColor,state.finalFlags,
                before.restored,after.restored,before.activated,after.activated);
            if (activation) {
                Check(state.activeAfter!=0,"fixture became active through SetActiveWindow on the private desktop");
            } else Check(after.restored>before.restored,"real cross-process pre-restore placement hook exercised");
            Check(state.suppressions>0,"application supplied redraw-suppression flags");
            Check(!state.iconic && state.maximized==(maximized?1:0),"placed window state preserved");
            Check(MonitorFromWindow(child.Window(),MONITOR_DEFAULTTONEAREST)==monitors[1],"placed window reached target monitor");
            Check(!EqualRect(&state.before,&state.after),"placement changed actual window geometry");
            Check((activation || state.sizes>0) && state.sizeWidth==state.clientWidth && state.sizeHeight==state.clientHeight,
                "application received coherent final client-size notification");
            Check(state.paints>0,"cross-monitor placement changed geometry without a client repaint");
            Check(state.paintWidth==state.clientWidth && state.paintHeight==state.clientHeight
                && state.paintedColor==static_cast<LONG>(RestoredColor)
                && state.paintMonitor==reinterpret_cast<UINT_PTR>(monitors[1]),
                "placed client repainted colored content at its final size on the target monitor");
            printf("PASS native repaint: %s moved to target with coherent client size and fresh colored content\n",
                activation?"visible activation":(maximized?"maximized restore":"normal restore"));
        }
        Check(Stop(3000)!=FALSE,"native paint controller stop");
        FreeLibrary(dll); dll=nullptr; exitCode=0;
    } catch (const std::exception& error) {
        fprintf(stderr,"FAIL native repaint: %s; Win32=%lu\n",error.what(),GetLastError());
        if (dll && (!Stop || Stop(3000))) FreeLibrary(dll);
    }
    if (controller) DestroyWindow(controller);
    SetThreadDesktop(original); CloseDesktop(desktop); return exitCode;
}
