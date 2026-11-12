#include "NativeHooks.h"
#include <cstdio>
#include <string>
#include <vector>
#include <stdexcept>
#include <tlhelp32.h>
#include <shobjidl.h>

namespace {
using StartFn=BOOL(*)(HWND,unsigned);
using StopFn=BOOL(*)(unsigned);
using ArmFn=BOOL(*)(const wchar_t*,HWND,HMONITOR);
using StatusFn=BOOL(*)(NativeStatus*,unsigned);
using EnableFn=void(*)(BOOL);
using CancelFn=void(*)(unsigned);
using ConfigureFn=void(*)(unsigned,BOOL);
CancelFn Cancel;
ConfigureFn Configure;
using IdentityArmFn=BOOL(*)(const wchar_t*,const wchar_t*,HMONITOR);
using TestPeekFn=HWND(*)(HWND,HWND,HMONITOR,BOOL);
IdentityArmFn ArmIdentity;
TestPeekFn TestPeek;
StartFn Start; StopFn Stop; ArmFn Arm; StatusFn Status; EnableFn Enable;
struct FixtureState {
    std::uint64_t hwnd, expected;
    int savedX, savedY;
    volatile LONG ready, checking, paints, wrong, maxState, actions;
    volatile LONG64 firstTick;
    wchar_t desktop[128];
};
FixtureState* Fixture{};
LRESULT CALLBACK FixtureProc(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
    if (message==WM_APP+1) {
        Fixture->paints=Fixture->wrong=0; Fixture->checking=1;
        ShowWindow(hwnd,wparam?SW_SHOWNORMAL:SW_RESTORE); return 0;
    }
    if (message==WM_APP+2) {
        if (wparam) ShowWindow(hwnd,SW_MINIMIZE);
        else { SetActiveWindow(nullptr); SetActiveWindow(hwnd); }
        InterlockedIncrement(&Fixture->actions); return 0;
    }
    if (message==WM_APP+3) {
        SetWindowPos(hwnd,nullptr,Fixture->savedX,Fixture->savedY,0,0,SWP_NOSIZE|SWP_NOACTIVATE|SWP_NOZORDER);
        InterlockedIncrement(&Fixture->actions); return 0;
    }
    if (message==WM_PAINT) {
        PAINTSTRUCT ps{}; HDC dc=BeginPaint(hwnd,&ps); RECT client{}; GetClientRect(hwnd,&client);
        FillRect(dc,&client,reinterpret_cast<HBRUSH>(COLOR_WINDOW+1));
        const wchar_t* label=L"TaskbarFollow native test fixture - no user documents";
        DrawTextW(dc,label,-1,&client,DT_CENTER|DT_VCENTER|DT_SINGLELINE); EndPaint(hwnd,&ps);
        if (Fixture && Fixture->checking && IsWindowVisible(hwnd) && !IsIconic(hwnd)) {
            if (reinterpret_cast<UINT_PTR>(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST))!=Fixture->expected) InterlockedIncrement(&Fixture->wrong);
            InterlockedExchange(&Fixture->maxState,IsZoomed(hwnd)?1:0);
            if (InterlockedIncrement(&Fixture->paints)==1) InterlockedExchange64(&Fixture->firstTick,GetTickCount64());
        }
        return 0;
    }
    if (message==WM_CLOSE) { DestroyWindow(hwnd); return 0; }
    if (message==WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcW(hwnd,message,wparam,lparam);
}
void Check(bool condition,const char* text) { if (!condition) throw std::runtime_error(text); }
template<class Predicate> void Wait(Predicate predicate,unsigned timeout=5000) {
    const ULONGLONG end=GetTickCount64()+timeout;
    do {
        MSG msg{};
        while (PeekMessageW(&msg,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        if (predicate()) return;
        Sleep(5);
    } while (GetTickCount64()<end);
    throw std::runtime_error("fixture timeout");
}
int RunFixture(int argc,wchar_t** argv) {
    if (argc<9 || argc>11) return 2;
    HANDLE mapping=OpenFileMappingW(FILE_MAP_ALL_ACCESS,FALSE,argv[2]);
    if (!mapping) return 3;
    Fixture=static_cast<FixtureState*>(MapViewOfFile(mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(FixtureState)));
    if (!Fixture) return 4;
    DWORD desktopBytes{};
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,Fixture->desktop,sizeof(Fixture->desktop),&desktopBytes);
    const int mode=_wtoi(argv[3]), x=_wtoi(argv[4]), y=_wtoi(argv[5]);
    Fixture->savedX=x; Fixture->savedY=y;
    Fixture->expected=_wcstoui64(argv[6],nullptr,10); Fixture->checking=mode==0?1:0;
    const bool maximized=_wtoi(argv[7])!=0, disabled=_wtoi(argv[8])!=0;
    if (argc>=11 && wcscmp(argv[10],L"-")!=0)
        if (FAILED(SetCurrentProcessExplicitAppUserModelID(argv[10]))) return 6;
    WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=FixtureProc;
    cls.lpszClassName=L"TaskbarFollow.NativeFixture"; cls.hCursor=LoadCursorW(nullptr,IDC_ARROW);
    RegisterClassW(&cls);
    HWND hwnd=CreateWindowExW(0,cls.lpszClassName,L"Native first-paint test",WS_OVERLAPPEDWINDOW,x,y,640,400,nullptr,nullptr,cls.hInstance,nullptr);
    if (!hwnd) return 5;
    if (argc>=10 && wcscmp(argv[9],L"-")!=0) {
        CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
        static const PROPERTYKEY key={{0x9f4c2855,0x9f79,0x4b39,{0xa8,0xd0,0xe1,0xd4,0x2d,0xe1,0xd5,0xf3}},5};
        IPropertyStore* store{};
        if (SUCCEEDED(SHGetPropertyStoreForWindow(hwnd,IID_PPV_ARGS(&store)))) {
            PROPVARIANT value{}; value.vt=VT_LPWSTR; value.pwszVal=argv[9];
            store->SetValue(key,value); store->Commit(); store->Release();
        }
    }
    if (mode==0) SetWindowPos(hwnd,nullptr,x,y,640,400,SWP_NOACTIVATE|SWP_NOZORDER); // app tries its saved old-screen position again
    Fixture->hwnd=reinterpret_cast<UINT_PTR>(hwnd);
    if (mode!=2) { ShowWindow(hwnd,maximized?SW_SHOWMAXIMIZED:SW_SHOWNORMAL); UpdateWindow(hwnd); }
    if (mode==1) { ShowWindow(hwnd,SW_MINIMIZE); Fixture->checking=0; }
    InterlockedExchange(&Fixture->ready,1);
    SetTimer(hwnd,99,15000,nullptr);
    MSG message{};
    while (GetMessageW(&message,nullptr,0,0)>0) {
        if (message.message==WM_TIMER && message.wParam==99) break;
        TranslateMessage(&message); DispatchMessageW(&message);
    }
    (void)disabled;
    UnmapViewOfFile(Fixture); CloseHandle(mapping); return 0;
}
struct Child {
    HANDLE process{}, mapping{};
    FixtureState* state{};
    ~Child() {
        if (state && state->hwnd) PostMessageW(reinterpret_cast<HWND>(static_cast<UINT_PTR>(state->hwnd)),WM_CLOSE,0,0);
        if (process) {
            if (WaitForSingleObject(process,1500)!=WAIT_OBJECT_0) { TerminateProcess(process,99); WaitForSingleObject(process,1500); }
            CloseHandle(process);
        }
        if (state) UnmapViewOfFile(state);
        if (mapping) CloseHandle(mapping);
    }
};
std::wstring Executable() { wchar_t path[1024]{}; GetModuleFileNameW(nullptr,path,1024); return path; }
void Spawn(Child& child,const std::wstring& name,int mode,const MONITORINFO& source,HMONITOR expected,bool maximized,bool disabled,const wchar_t* identity=nullptr,const wchar_t* processIdentity=nullptr) {
    child.mapping=CreateFileMappingW(INVALID_HANDLE_VALUE,nullptr,PAGE_READWRITE,0,sizeof(FixtureState),name.c_str());
    Check(child.mapping!=nullptr,"test mapping creation failed");
    child.state=static_cast<FixtureState*>(MapViewOfFile(child.mapping,FILE_MAP_ALL_ACCESS,0,0,sizeof(FixtureState)));
    Check(child.state!=nullptr,"test mapping view failed"); ZeroMemory(child.state,sizeof(*child.state));
    std::wstring command=L"\""+Executable()+L"\" --fixture "+name+L" "+std::to_wstring(mode)+L" "+std::to_wstring(source.rcWork.left+120)
        +L" "+std::to_wstring(source.rcWork.top+100)+L" "+std::to_wstring(reinterpret_cast<UINT_PTR>(expected))+L" "+(maximized?L"1":L"0")+L" "+(disabled?L"1":L"0");
    if (identity || processIdentity) command+=L" "+std::wstring(identity?identity:L"-");
    if (processIdentity) command+=L" "+std::wstring(processIdentity);
    wchar_t desktopName[256]{}; DWORD needed{};
    GetUserObjectInformationW(GetThreadDesktop(GetCurrentThreadId()),UOI_NAME,desktopName,sizeof(desktopName),&needed);
    std::wstring desktop=L"winsta0\\"+std::wstring(desktopName);
    STARTUPINFOW startup{sizeof(startup)}; startup.lpDesktop=desktop.data(); PROCESS_INFORMATION process{};
    Check(CreateProcessW(nullptr,command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,nullptr,&startup,&process)!=FALSE,"fixture process creation failed");
    child.process=process.hProcess; CloseHandle(process.hThread);
    Wait([&] { return child.state->ready!=0; });
}
BOOL CALLBACK Collect(HMONITOR monitor,HDC,LPRECT,LPARAM pointer) {
    reinterpret_cast<std::vector<HMONITOR>*>(pointer)->push_back(monitor); return TRUE;
}
}
int wmain(int argc,wchar_t** argv) {
    SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    if (argc>1 && wcscmp(argv[1],L"--fixture")==0) return RunFixture(argc,argv);
    const std::wstring testDesktop=L"TaskbarFollow.NativeTests."+std::to_wstring(GetCurrentProcessId());
    HDESK desktop=CreateDesktopW(testDesktop.c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) { fprintf(stderr,"FAIL test desktop creation: %lu\n",GetLastError()); return 1; }
    HMODULE dll{};
    try {
        Check(argc==2,"pass the native hook DLL path"); dll=LoadLibraryW(argv[1]); Check(dll!=nullptr,"DLL load failed");
        Start=reinterpret_cast<StartFn>(GetProcAddress(dll,"TF_Start")); Stop=reinterpret_cast<StopFn>(GetProcAddress(dll,"TF_StopAndWait"));
        Arm=reinterpret_cast<ArmFn>(GetProcAddress(dll,"TF_TestArm")); Status=reinterpret_cast<StatusFn>(GetProcAddress(dll,"TF_Status")); Enable=reinterpret_cast<EnableFn>(GetProcAddress(dll,"TF_SetEnabled"));
        Cancel=reinterpret_cast<CancelFn>(GetProcAddress(dll,"TF_Cancel"));
        Configure=reinterpret_cast<ConfigureFn>(GetProcAddress(dll,"TF_Configure"));
        ArmIdentity=reinterpret_cast<IdentityArmFn>(GetProcAddress(dll,"TF_TestArmIdentity"));
        TestPeek=reinterpret_cast<TestPeekFn>(GetProcAddress(dll,"TF_TestPeek"));
        Check(Start && Stop && Arm && Status && Enable && Cancel && Configure && ArmIdentity && TestPeek,"native ABI missing");
        std::vector<HMONITOR> monitors; EnumDisplayMonitors(nullptr,nullptr,Collect,reinterpret_cast<LPARAM>(&monitors));
        Check(monitors.size()>=2,"two monitors required");
        MONITORINFO source{sizeof(source)}; GetMonitorInfoW(monitors[0],&source);
        const HMONITOR target=monitors[1];
        Check(Start(nullptr,TF_TEST_MODE)!=FALSE,"native hook startup failed");
        for (int test=0;test<6;++test) {
            const bool cold=test==0, maximized=test==2, disabled=test==3, cancelled=test==4, expired=test==5;
            Child child;
            const std::wstring name=L"Local\\TaskbarFollow.NativeFixture."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(test);
            if (cold) Check(Arm(Executable().c_str(),nullptr,target)!=FALSE,"cold start arm failed");
            Spawn(child,name,cold?0:1,source,(disabled||cancelled||expired)?monitors[0]:target,maximized,disabled);
            HWND hwnd=reinterpret_cast<HWND>(static_cast<UINT_PTR>(child.state->hwnd));
            if (!cold) {
                Check(IsIconic(hwnd)!=FALSE,"fixture did not minimize");
                if (expired) Configure(1000,TRUE);
                Check(Arm(Executable().c_str(),hwnd,target)!=FALSE,"restore arm failed");
                if (disabled) Enable(FALSE);
                if (cancelled) Cancel(0);
                if (expired) {
                    const ULONGLONG until=GetTickCount64()+1300;
                    Wait([&] { return GetTickCount64()>=until; });
                }
                PostMessageW(hwnd,WM_APP+1,0,0);
            }
            Wait([&] { return child.state->paints>0; });
            NativeStatus status{}; Check(Status(&status,sizeof(status))!=FALSE,"status read failed");
            printf("native trace case=%d armed=%llu created=%llu restored=%llu firstShown=%llu last=%u paint-count=%ld wrong=%ld\n",test,status.armed,status.created,status.restored,status.firstShown,status.lastKind,child.state->paints,child.state->wrong);
            if (child.state->wrong) {
                PROCESS_MITIGATION_EXTENSION_POINT_DISABLE_POLICY extension{};
                GetProcessMitigationPolicy(child.process,ProcessExtensionPointDisablePolicy,&extension,sizeof(extension));
                printf("extension-points-disabled=%lu\n",extension.DisableExtensionPoints);
                DWORD childPid{}; GetWindowThreadProcessId(hwnd,&childPid);
                HANDLE modules=CreateToolhelp32Snapshot(TH32CS_SNAPMODULE,childPid); MODULEENTRY32W module{sizeof(module)};
                bool loaded=false;
                if (modules!=INVALID_HANDLE_VALUE) { if (Module32FirstW(modules,&module)) do { if (wcsstr(module.szModule,L"NativeHooks")) loaded=true; } while (Module32NextW(modules,&module)); CloseHandle(modules); }
                wprintf(L"payload-loaded=%d; child-desktop=%ls\n",loaded?1:0,child.state->desktop);
            }
            Check(child.state->wrong==0,"first visible paint occurred on the old monitor");
            Check(child.state->maxState==(maximized?1:0),"maximized state changed");
            if (cold) Check(status.created>0,"cross-process CBT create hook was not exercised");
            if (!cold && !disabled && !cancelled && !expired) Check(status.restored>0,"pre-restore hook was not exercised");
            if (expired) Check(status.lastKind==TF_EXPIRED,"expired transaction did not report its end");
            printf("PASS native %s: first visible paint on expected monitor; old-monitor paints=0; max=%d\n",
                cold?"cold-create-with-app-position-override":(expired?"expired-native-behavior":(cancelled?"cancelled-native-behavior":(disabled?"disabled-native-behavior":(maximized?"maximized-restore":"normal-restore")))),maximized?1:0);
            if (cold) {
                Check(Stop(3000)!=FALSE,"native controller did not stop before restart");
                Check(Start(nullptr,TF_TEST_MODE)!=FALSE,"restart with a live payload mapping failed");
                puts("PASS native controller restart while target application remains open");
            }
            Enable(TRUE);
        }
        Configure(8000,TRUE);
        for (bool cancelled : {false,true}) {
            Cancel(0); Child child;
            Spawn(child,L"Local\\TaskbarFollow.RollbackTest."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(cancelled),
                1,source,target,false,false);
            HWND hwnd=reinterpret_cast<HWND>(static_cast<UINT_PTR>(child.state->hwnd));
            NativeStatus before{}; Check(Status(&before,sizeof(before))!=FALSE,"before restore status");
            Check(Arm(Executable().c_str(),hwnd,target)!=FALSE,"rollback restore arm failed");
            PostMessageW(hwnd,WM_APP+1,0,0);
            Wait([&] {return child.state->paints>0;});
            Check(child.state->wrong==0,"restore did not paint first on target");
            if (cancelled) Cancel(0);
            PostMessageW(hwnd,WM_APP+3,0,0);
            Wait([&] {return child.state->actions!=0;});
            Check(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==(cancelled?monitors[0]:target),
                "post-show saved placement crossed monitors despite the current follow intent");
            if (!cancelled) {
                Wait([&] {NativeStatus status{}; return Status(&status,sizeof(status)) && status.firstShown>before.firstShown;});
                PostMessageW(hwnd,WM_APP+3,0,0);
                Wait([&] {return child.state->actions==2;});
                Check(MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==monitors[0],
                    "a completed intent still forced the old target");
            }
            puts(cancelled?"PASS native rollback: cancelled intent allows the later move"
                :"PASS native rollback: stays on target after saved placement, then allows later moves");
        }
        const wchar_t* exact=L"TaskbarFollow.Pwa.Exact";
        const wchar_t* other=L"TaskbarFollow.Pwa.Other";
        struct IdentityCase { const wchar_t* windowId; const wchar_t* processId; bool moves; const char* label; };
        const IdentityCase identityCases[]={
            {exact,nullptr,true,"exact window AppID assigned after creation"},
            {other,nullptr,false,"different window AppID stays untouched"},
            {nullptr,exact,true,"process-only desktop AppID (Tauri/CCSwitch route)"},
            {nullptr,other,false,"different process-only desktop AppID stays untouched"},
            {other,exact,false,"window AppID mismatch overrides matching process AppID"},
            {exact,other,true,"matching window AppID overrides mismatching process AppID"}
        };
        unsigned scenario=0;
        for (const auto& identity:identityCases) {
            Cancel(0); Child child;
            Check(ArmIdentity(Executable().c_str(),exact,target)!=FALSE,"identity arm failed");
            Spawn(child,L"Local\\TaskbarFollow.IdentityTest."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(scenario++),
                0,source,identity.moves?target:monitors[0],false,false,identity.windowId,identity.processId);
            Wait([&] { return child.state->paints>0; });
            Check(child.state->wrong==0,"identity routing moved the wrong window or missed the first paint");
            printf("PASS native identity: %s; first visible monitor correct\n",identity.label);
        }
        for (int mode : {1,2}) {
            Cancel(0); Child reused;
            Spawn(reused,L"Local\\TaskbarFollow.ReuseTest."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(mode),
                mode,source,target,false,false);
            HWND hwnd=reinterpret_cast<HWND>(static_cast<UINT_PTR>(reused.state->hwnd));
            Check(mode==1?IsIconic(hwnd)!=FALSE:IsWindowVisible(hwnd)==FALSE,"reuse fixture has no visible normal window");
            Check(Arm(Executable().c_str(),nullptr,target)!=FALSE,"cold existing-window arm failed");
            PostMessageW(hwnd,WM_APP+1,mode==2?1:0,0);
            Wait([&] {return reused.state->paints>0;});
            Check(reused.state->wrong==0 && MonitorFromWindow(hwnd,MONITOR_DEFAULTTONEAREST)==target,
                "cold existing hidden/minimized reuse missed the first target-screen paint");
            printf("PASS native cold reuse: %s existing window paints first on target\n",mode==1?"minimized":"hidden");
        }
        for (int minimize : {0,1}) {
            Cancel(0); Child stranger,reused;
            Spawn(stranger,L"Local\\TaskbarFollow.StrangerTest."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(minimize),
                3,source,monitors[0],false,false);
            Spawn(reused,L"Local\\TaskbarFollow.ClaimTest."+std::to_wstring(GetCurrentProcessId())+L"."+std::to_wstring(minimize),
                2,source,target,false,false);
            HWND strangerWindow=reinterpret_cast<HWND>(static_cast<UINT_PTR>(stranger.state->hwnd));
            HWND reusedWindow=reinterpret_cast<HWND>(static_cast<UINT_PTR>(reused.state->hwnd));
            Check(Arm(Executable().c_str(),nullptr,target)!=FALSE,"cold negative claim arm failed");
            PostMessageW(strangerWindow,WM_APP+2,minimize?1:0,0);
            Wait([&] {return stranger.state->actions!=0;});
            Check(MonitorFromWindow(strangerWindow,MONITOR_DEFAULTTONEAREST)==monitors[0],"unselected visible window was moved by a cold intent");
            PostMessageW(reusedWindow,WM_APP+1,1,0);
            Wait([&] {return reused.state->paints>0;});
            Check(reused.state->wrong==0,"unrelated activation/minimize stole the cold transaction claim");
            printf("PASS native cold claim: unrelated %s does not claim or move; hidden reuse remains eligible\n",minimize?"minimize":"visible activation");
        }
        Cancel(0);
        {
            Child child;
            Spawn(child,L"Local\\TaskbarFollow.PeekTest."+std::to_wstring(GetCurrentProcessId()),1,source,monitors[0],false,false);
            HWND sourceWindow=reinterpret_cast<HWND>(static_cast<UINT_PTR>(child.state->hwnd));
            WINDOWPLACEMENT before{sizeof(before)}; GetWindowPlacement(sourceWindow,&before);
            RECT rectBefore{}; GetWindowRect(sourceWindow,&rectBefore);
            HWND foreground=GetForegroundWindow();
            HWND overlay=TestPeek(sourceWindow,sourceWindow,target,TRUE);
            Check(overlay && IsWindowVisible(overlay),"DWM hover overlay unavailable");
            Check(MonitorFromWindow(overlay,MONITOR_DEFAULTTONEAREST)==target,"hover overlay on wrong monitor");
            WINDOWPLACEMENT after{sizeof(after)}; GetWindowPlacement(sourceWindow,&after);
            RECT rectAfter{}; GetWindowRect(sourceWindow,&rectAfter);
            Check(IsIconic(sourceWindow) && before.showCmd==after.showCmd && EqualRect(&before.rcNormalPosition,&after.rcNormalPosition) && EqualRect(&rectBefore,&rectAfter),"hover changed the source position or minimized state");
            Check(GetForegroundWindow()==foreground,"hover stole activation");
            TestPeek(nullptr,nullptr,nullptr,FALSE);
            Check(!IsWindow(overlay),"hover overlay did not clean up");
            puts("PASS DWM hover preview: target monitor, minimized source unchanged, no activation, cleanup");
        }
        Check(!Arm(L"C:\\not-the-test-process.exe",nullptr,target),"test arm accepted another application");
        Check(Stop(3000)!=FALSE,"native controller did not stop before DLL release");
        FreeLibrary(dll); puts("PASS native cross-process creation/normal restore/maximized restore/disable/test isolation"); return 0;
    } catch (const std::exception& e) {
        fprintf(stderr,"FAIL native: %s; Win32=%lu\n",e.what(),GetLastError());
        if (dll && (!Stop || Stop(3000))) FreeLibrary(dll);
        return 1;
    }
}
