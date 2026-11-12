#include "NativeHooks.h"
#include <cstdio>
#include <string>
#include <vector>
#include <stdexcept>

namespace {
unsigned Checks{};
struct Received { unsigned own{},compat{},serial{}; HMONITOR monitor{}; HWND window{}; } Messages;
void Check(bool value,const char* label) { if (!value) throw std::runtime_error(label); ++Checks; }
LRESULT CALLBACK Receive(HWND hwnd,UINT message,WPARAM wparam,LPARAM lparam) {
    if (message==0x8054) {
        ++Messages.own; Messages.monitor=reinterpret_cast<HMONITOR>(wparam);
        Messages.window=reinterpret_cast<HWND>(lparam); return 0;
    }
    if (message==0x8055) {
        ++Messages.compat; Messages.serial=static_cast<unsigned>(wparam);
        Messages.monitor=reinterpret_cast<HMONITOR>(lparam); return 0;
    }
    return DefWindowProcW(hwnd,message,wparam,lparam);
}
template<class Predicate> void Wait(Predicate predicate) {
    const ULONGLONG end=GetTickCount64()+2000;
    while (!predicate()) {
        MSG message{};
        while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
        if (GetTickCount64()>end) throw std::runtime_error("owned routing message timeout");
        Sleep(1);
    }
}
void Drain() {
    MSG message{};
    while (PeekMessageW(&message,nullptr,0,0,PM_REMOVE)) { TranslateMessage(&message); DispatchMessageW(&message); }
}
BOOL CALLBACK Collect(HMONITOR monitor,HDC,LPRECT,LPARAM data) {
    reinterpret_cast<std::vector<HMONITOR>*>(data)->push_back(monitor); return TRUE;
}
using StartFn=BOOL(*)(HWND,unsigned);
using StopFn=BOOL(*)(unsigned);
using ReleaseFn=BOOL(*)(const NativeEntry*,HMONITOR,BOOL);
using IntentFn=BOOL(*)(unsigned,NativeIntent*,unsigned);
using CancelFn=void(*)(unsigned);
using CancelCompatibilityFn=BOOL(*)(unsigned);
using EnableFn=void(*)(BOOL);
using StatusFn=BOOL(*)(NativeStatus*,unsigned);
}
int wmain(int argc,wchar_t** argv) {
    const HDESK original=GetThreadDesktop(GetCurrentThreadId());
    const std::wstring name=L"TaskbarFollow.RoutingTests."+std::to_wstring(GetCurrentProcessId());
    HDESK desktop=CreateDesktopW(name.c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) { fputs("FAIL routing desktop\n",stderr); return 1; }
    HMODULE module{}; HWND receiver{},statusWindow{}; StopFn stop{}; int result=0;
    try {
        Check(argc==2,"pass the native routing DLL path");
        WNDCLASSW cls{}; cls.hInstance=GetModuleHandleW(nullptr); cls.lpfnWndProc=Receive;
        cls.lpszClassName=L"TaskbarFollow.RoutingFixture";
        Check(RegisterClassW(&cls)!=0,"register owned routing window class");
        receiver=CreateWindowExW(0,cls.lpszClassName,L"",0,0,0,0,0,HWND_MESSAGE,nullptr,cls.hInstance,nullptr);
        statusWindow=CreateWindowExW(WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE,cls.lpszClassName,L"",WS_OVERLAPPEDWINDOW,
            0,0,640,400,nullptr,nullptr,cls.hInstance,nullptr);
        Check(receiver && statusWindow,"create hidden owned routing windows");
        module=LoadLibraryW(argv[1]); Check(module!=nullptr,"load routing DLL");
        auto start=reinterpret_cast<StartFn>(GetProcAddress(module,"TF_Start"));
        stop=reinterpret_cast<StopFn>(GetProcAddress(module,"TF_StopAndWait"));
        auto release=reinterpret_cast<ReleaseFn>(GetProcAddress(module,"TF_TestReleaseEntry"));
        auto intent=reinterpret_cast<IntentFn>(GetProcAddress(module,"TF_CompatibilityIntent"));
        auto cancel=reinterpret_cast<CancelFn>(GetProcAddress(module,"TF_Cancel"));
        auto cancelCompatibility=reinterpret_cast<CancelCompatibilityFn>(GetProcAddress(module,"TF_CancelCompatibility"));
        auto enable=reinterpret_cast<EnableFn>(GetProcAddress(module,"TF_SetEnabled"));
        auto status=reinterpret_cast<StatusFn>(GetProcAddress(module,"TF_Status"));
        Check(start && stop && release && intent && cancel && cancelCompatibility && enable && status,"routing ABI is present");
        std::vector<HMONITOR> monitors; EnumDisplayMonitors(nullptr,nullptr,Collect,reinterpret_cast<LPARAM>(&monitors));
        Check(!monitors.empty(),"at least one monitor is available");
        const HMONITOR target=monitors.back();
        Check(start(receiver,TF_TEST_MODE)!=FALSE,"start input-free routing controller");
        NativeEntry entry{}; GetModuleFileNameW(nullptr,entry.path,1024);
        wcscpy_s(entry.appId,L"TaskbarFollow.Status");
        entry.count=1; entry.windows[0]={reinterpret_cast<UINT_PTR>(statusWindow),GetCurrentProcessId(),0};
        Check(release(&entry,target,FALSE)!=FALSE,"verified own status entry is routed");
        Wait([] {return Messages.own==1;});
        Check(Messages.window==statusWindow && Messages.monitor==target,"own status message retains exact HWND and target");
        NativeStatus state{};
        Check(status(&state,sizeof(state)) && state.armed==0,"own status click does not arm a generic positioning transaction");

        entry.windows[0].pid+=1;
        Check(!release(&entry,target,FALSE),"stale candidate PID is rejected");
        entry.windows[0].pid=GetCurrentProcessId();
        wcscpy_s(entry.appId,L"Other.ExactIdentity");
        Check(release(&entry,target,FALSE)!=FALSE,"other owned test identity uses normal routing");
        Drain(); Check(Messages.own==1,"another identity cannot trigger status self-follow"); cancel(0);

        wcscpy_s(entry.appId,L"TaskbarFollow.CompatibilityFixture");
        entry.count=0; entry.flags=TF_COLD_START|TF_COMPATIBILITY;
        const unsigned previous=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"verified compatibility click is routed");
        Wait([&] {return Messages.compat==previous+1;});
        NativeIntent snapshot{};
        Check(Messages.monitor==target && intent(Messages.serial,&snapshot,sizeof(snapshot)),"compatibility message has a readable matching intent");
        Check(snapshot.serial==Messages.serial && snapshot.monitor==reinterpret_cast<UINT_PTR>(target),"snapshot preserves serial and target");
        Check(snapshot.entry.flags==(TF_COLD_START|TF_COMPATIBILITY) && snapshot.entry.count==0,"cold compatibility identity is preserved");
        Check(wcscmp(snapshot.entry.path,entry.path)==0 && snapshot.expires>snapshot.released,"snapshot contains verified executable and bounded lifetime");
        Check(!intent(Messages.serial+1,&snapshot,sizeof(snapshot)),"wrong serial cannot read another click");
        Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)-1),"incorrect ABI size is rejected");
        cancel(0); Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"new-input epoch cancellation invalidates a pending compatibility click");

        const unsigned replacedSerial=Messages.serial, beforeReplacement=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"replacement compatibility click is armed");
        Wait([&] {return Messages.compat==beforeReplacement+1;});
        const unsigned replacementSerial=Messages.serial;
        Check(replacementSerial!=replacedSerial && !cancelCompatibility(replacedSerial),"stale compatibility serial cannot cancel its replacement");
        Check(intent(replacementSerial,&snapshot,sizeof(snapshot)),"replacement compatibility intent survives stale cancellation");
        Check(cancelCompatibility(replacementSerial)!=FALSE,"matching compatibility serial cancels its own intent");
        Check(!intent(replacementSerial,&snapshot,sizeof(snapshot)) && !cancelCompatibility(replacementSerial),"compatibility cancellation cannot be replayed");

        const unsigned beforePause=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"second compatibility click is armed");
        Wait([&] {return Messages.compat==beforePause+1;});
        enable(FALSE); Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"pause invalidates the compatibility route");
        enable(TRUE);
        entry.count=2;
        entry.windows[0]={reinterpret_cast<UINT_PTR>(statusWindow),GetCurrentProcessId(),0};
        entry.windows[1]=entry.windows[0];
        const unsigned beforeGroup=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"group button is recognized without choosing a window");
        Drain(); Check(Messages.compat==beforeGroup,"unselected group cannot trigger compatibility positioning");
        Check(status(&state,sizeof(state)) && state.lastKind==TF_GROUP,"unselected group retains selection feedback");
        Check(release(&entry,target,TRUE)!=FALSE,"explicit thumbnail selection arms compatibility routing");
        Wait([&] {return Messages.compat==beforeGroup+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.count==2,"selected group retains verified candidate identities");
        cancel(0);

        entry.count=0; entry.flags=TF_COLD_START|TF_REQUIRE_APP_ID|TF_PACKAGED_FOLLOW;
        wcscpy_s(entry.appId,L"TaskbarFollow.PackageFixture_0000000000000!App");
        const unsigned beforePackage=Messages.compat;
        Check(release(&entry,target,FALSE)!=FALSE,"packaged launch arms native and after-show routing");
        Wait([&] {return Messages.compat==beforePackage+1;});
        Check(intent(Messages.serial,&snapshot,sizeof(snapshot)) && snapshot.entry.flags==entry.flags && !snapshot.nativeClaimed,
            "packaged launch exposes its exact flags and initially unclaimed state");
        Check(cancelCompatibility(Messages.serial)!=FALSE,"a packaged follow can end its own intent after confirmation");
        entry.count=0; entry.flags=0;
        Check(!release(&entry,target,FALSE),"unverified no-window button remains unsupported");
        wcscpy_s(entry.path,L"C:\\not-the-test-executable.exe"); entry.flags=TF_COLD_START|TF_COMPATIBILITY;
        Check(!release(&entry,target,FALSE),"test route cannot target an unrelated executable");
        Check(stop(3000)!=FALSE,"routing controller joins before resource release");
        Check(!intent(Messages.serial,&snapshot,sizeof(snapshot)),"a stopped controller exposes no stale intent");
        printf("PASS %u native explicit-click/self-window/compatibility routing assertions; no input hooks\n",Checks);
    } catch (const std::exception& error) {
        fprintf(stderr,"FAIL native routing: %s; Win32=%lu\n",error.what(),GetLastError()); result=1;
    }
    if (module && (!stop || stop(3000))) FreeLibrary(module);
    if (statusWindow) DestroyWindow(statusWindow);
    if (receiver) DestroyWindow(receiver);
    if (SetThreadDesktop(original)) CloseDesktop(desktop);
    return result;
}
