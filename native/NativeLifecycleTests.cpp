#include "NativeHooks.h"
#include <cstdio>
#include <string>
#include <stdexcept>
#include <thread>

// This executable owns a separate desktop and installs no low-level input
// hooks. Event gates exercise real worker lifetime without timing races.
namespace {
unsigned Checks{};
void Check(bool condition,const char* label) {
    if (!condition) throw std::runtime_error(label);
    ++Checks;
}
using StartFn=BOOL(*)(HWND,unsigned);
using StopFn=BOOL(*)(unsigned);
using LegacyStopFn=void(*)();
using StatusFn=BOOL(*)(NativeStatus*,unsigned);
using LifecycleFn=BOOL(*)(HANDLE,HANDLE,HANDLE,HANDLE,DWORD);
using UnhookFailureFn=BOOL(*)(BOOL);

struct Api {
    std::wstring path;
    HMODULE module{};
    StartFn Start{};
    StopFn Stop{};
    LegacyStopFn LegacyStop{};
    StatusFn Status{};
    LifecycleFn Lifecycle{};
    UnhookFailureFn UnhookFailure{};
    explicit Api(const wchar_t* input) {
        wchar_t absolute[32768]{};
        const DWORD chars=GetFullPathNameW(input,32768,absolute,nullptr);
        Check(chars>0 && chars<32768,"native DLL absolute path");
        path=absolute;
        Load();
    }
    void Load() {
        module=LoadLibraryW(path.c_str());
        Check(module!=nullptr,"load native lifecycle DLL");
        Start=reinterpret_cast<StartFn>(GetProcAddress(module,"TF_Start"));
        Stop=reinterpret_cast<StopFn>(GetProcAddress(module,"TF_StopAndWait"));
        LegacyStop=reinterpret_cast<LegacyStopFn>(GetProcAddress(module,"TF_Stop"));
        Status=reinterpret_cast<StatusFn>(GetProcAddress(module,"TF_Status"));
        Lifecycle=reinterpret_cast<LifecycleFn>(GetProcAddress(module,"TF_TestLifecycle"));
        UnhookFailure=reinterpret_cast<UnhookFailureFn>(GetProcAddress(module,"TF_TestSetUnhookFailure"));
        Check(Start && Stop && LegacyStop && Status && Lifecycle && UnhookFailure,"native lifecycle exports");
    }
    bool Present() const { return GetModuleHandleW(path.c_str())!=nullptr; }
    void ReleaseCallerReference() {
        Check(module!=nullptr,"caller reference is owned");
        const HMODULE owned=module;
        module=nullptr;
        Check(FreeLibrary(owned)!=FALSE,"release caller DLL reference");
    }
    bool ReadStatus(NativeStatus& status) const {
        status={};
        return Status(&status,sizeof(status))!=FALSE;
    }
    void ExpectStopped(const char* label) const {
        NativeStatus status{};
        Check(!ReadStatus(status),label);
    }
    void ExpectRetained(const char* label) const {
        NativeStatus status{};
        Check(ReadStatus(status),label);
        Check(status.running==0 && status.enabled==0,"retained mapping is disabled and not running");
    }
    ~Api() {
        // Gates unwind before this object. A failed test must not unload DLL
        // code while its owned worker remains active.
        if (!module && Present()) module=LoadLibraryW(path.c_str());
        if (module && (!Stop || Stop(3000))) FreeLibrary(module);
    }
};

struct Gates {
    HANDLE startup{},shutdown{},startupEntered{},shutdownEntered{};
    Gates(bool blockStartup,bool blockShutdown) {
        startup=CreateEventW(nullptr,TRUE,blockStartup?FALSE:TRUE,nullptr);
        shutdown=CreateEventW(nullptr,TRUE,blockShutdown?FALSE:TRUE,nullptr);
        startupEntered=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        shutdownEntered=CreateEventW(nullptr,TRUE,FALSE,nullptr);
        Check(startup && shutdown && startupEntered && shutdownEntered,"create owned lifecycle gates");
    }
    void Configure(Api& api,DWORD error=0) const {
        Check(api.Lifecycle(startup,shutdown,startupEntered,shutdownEntered,error)!=FALSE,"configure idle lifecycle fault gates");
    }
    void ReleaseStartup() const { Check(SetEvent(startup)!=FALSE,"release startup gate"); }
    void ReleaseShutdown() const { Check(SetEvent(shutdown)!=FALSE,"release shutdown gate"); }
    void AwaitShutdown() const {
        Check(WaitForSingleObject(shutdownEntered,3000)==WAIT_OBJECT_0,"worker reaches shutdown gate");
    }
    ~Gates() {
        if (startup) SetEvent(startup);
        if (shutdown) SetEvent(shutdown);
        for (HANDLE event : {startup,shutdown,startupEntered,shutdownEntered})
            if (event) CloseHandle(event);
    }
};

void ExpectStartRejected(Api& api) {
    Check(!api.Start(nullptr,TF_TEST_MODE),"restart is refused until previous lifetime is reaped");
    Check(GetLastError()==ERROR_ALREADY_INITIALIZED,"restart reports ERROR_ALREADY_INITIALIZED");
}
void ExpectTimeout(Api& api,unsigned timeout) {
    Check(!api.Stop(timeout),"stop reports an uncompleted worker");
    Check(GetLastError()==ERROR_TIMEOUT,"stop timeout preserves ERROR_TIMEOUT");
}
void NormalAndRepeated(Api& api) {
    Check(api.Stop(0)!=FALSE,"initial idle stop succeeds");
    api.ExpectStopped("idle status has no controller mapping");
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"normal worker starts");
    NativeStatus status{};
    Check(api.ReadStatus(status) && status.running==1,"running worker status is readable");
    Check(!api.Lifecycle(nullptr,nullptr,nullptr,nullptr,0),"fault configuration cannot change during an active lifetime");
    ExpectStartRejected(api);
    Check(api.Stop(3000)!=FALSE,"normal stop joins worker");
    api.ExpectStopped("normal stop releases mapping");
    Check(api.Stop(0)!=FALSE,"repeated stop succeeds");
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"legacy stop wrapper worker starts");
    api.LegacyStop();
    api.ExpectStopped("legacy stop wrapper also joins before releasing mapping");

    DWORD before{},after{};
    Check(GetProcessHandleCount(GetCurrentProcess(),&before)!=FALSE,"read warmed process handle count");
    for (unsigned round=0;round<8;++round) {
        Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"repeat lifecycle startup");
        Check(api.Stop(3000)!=FALSE,"repeat lifecycle joined stop");
    }
    Check(GetProcessHandleCount(GetCurrentProcess(),&after)!=FALSE,"read repeated lifecycle handle count");
    Check(after<=before+1,"repeated lifecycle does not accumulate thread/event/mapping handles");
    printf("PASS lifecycle normal/repeated stop and eight restarts; handles-before=%lu; handles-after=%lu\n",before,after);
}
void ShutdownTimeout(Api& api) {
    Gates gates(false,true);
    gates.Configure(api);
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"gated worker starts");
    ExpectTimeout(api,25);
    gates.AwaitShutdown();
    api.ExpectRetained("timed-out stop retains valid shared mapping");
    ExpectStartRejected(api);
    ExpectTimeout(api,0);
    gates.ReleaseShutdown();
    Check(api.Stop(3000)!=FALSE,"stop retry joins released worker");
    api.ExpectStopped("successful retry releases retained mapping");
    Check(api.Stop(0)!=FALSE,"repeat stop after timeout recovery succeeds");
    puts("PASS lifecycle delayed shutdown: timeout retains resources, retry reclaims them");
}
void StartupFailure(Api& api) {
    {
        Gates immediate(false,false);
        immediate.Configure(api,ERROR_GEN_FAILURE);
        Check(!api.Start(nullptr,TF_TEST_MODE),"startup failure with unblocked cleanup is reported");
        Check(GetLastError()==ERROR_GEN_FAILURE,"unblocked startup failure preserves its error");
        api.ExpectStopped("unblocked failed startup rolls back its mapping");
    }
    // Failure is reported before shutdown can finish; TF_Start must retain
    // its original startup error rather than overwrite it with cleanup timeout.
    Gates gates(false,true);
    gates.Configure(api,ERROR_GEN_FAILURE);
    Check(!api.Start(nullptr,TF_TEST_MODE),"injected startup failure is reported");
    Check(GetLastError()==ERROR_GEN_FAILURE,"startup failure preserves original error through timed-out cleanup");
    gates.AwaitShutdown();
    api.ExpectRetained("failed startup with blocked exit retains mapping");
    ExpectStartRejected(api);
    gates.ReleaseShutdown();
    Check(api.Stop(3000)!=FALSE,"failed startup cleanup can be retried");
    api.ExpectStopped("failed startup retry releases mapping");
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"startup succeeds after failed lifetime was reaped");
    Check(api.Stop(3000)!=FALSE,"post-failure worker stops");
    puts("PASS lifecycle startup failure: original error, retained resources, cleanup retry and restart");
}
void StartupTimeout(Api& api) {
    Gates gates(true,true);
    gates.Configure(api);
    Check(!api.Start(nullptr,TF_TEST_MODE),"startup blocked before message queue times out");
    Check(GetLastError()==ERROR_TIMEOUT,"startup timeout reports ERROR_TIMEOUT");
    Check(WaitForSingleObject(gates.startupEntered,0)==WAIT_OBJECT_0,"worker entered startup gate before queue creation");
    api.ExpectRetained("startup timeout retains worker readiness event and mapping");
    ExpectStartRejected(api);
    gates.ReleaseStartup();
    gates.AwaitShutdown();
    api.ExpectRetained("late startup observes cancellation without publishing running state");
    ExpectTimeout(api,0);
    gates.ReleaseShutdown();
    Check(api.Stop(3000)!=FALSE,"pre-queue cancelled worker eventually joins");
    api.ExpectStopped("pre-queue cancellation releases mapping after join");
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"restart succeeds after pre-queue cancellation");
    Check(api.Stop(3000)!=FALSE,"restarted worker stops normally");
    puts("PASS lifecycle startup timeout: cancellation survives absent queue and cannot revive running state");
}
void WorkerModuleReference(Api& api) {
    Gates gates(false,true);
    gates.Configure(api);
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"module-lifetime worker starts");
    api.ReleaseCallerReference();
    Check(api.Present(),"active worker retains its own DLL reference");
    // The worker is the only module owner now. Its shutdown gate keeps it
    // resident while a stop timeout is observed through the existing export.
    ExpectTimeout(api,0);
    gates.AwaitShutdown();
    Check(api.Present(),"timed-out worker keeps DLL code resident without caller reference");
    api.ExpectRetained("worker-only DLL reference keeps timed-out mapping readable");
    api.Load();
    gates.ReleaseShutdown();
    Check(api.Stop(3000)!=FALSE,"module-lifetime worker is joined before caller unload");
    api.ReleaseCallerReference();
    Check(!api.Present(),"completed worker releases its private DLL reference");
    api.Load();
    Check(api.Stop(0)!=FALSE,"freshly reloaded module starts idle");
    puts("PASS lifecycle DLL references: active/blocked worker remains resident, joined worker can unload");
}
void UnhookFailure(Api& api) {
    Check(api.Start(nullptr,TF_TEST_MODE)!=FALSE,"unhook-failure worker starts");
    Check(api.UnhookFailure(TRUE)!=FALSE,"enable owned test-mode unhook failure");
    Check(!api.Stop(3000),"failed hook removal does not report successful stop");
    Check(GetLastError()==ERROR_ACCESS_DENIED,"failed hook removal preserves its Win32 error");
    api.ExpectRetained("failed hook removal retains disabled mapping after worker exit");
    ExpectStartRejected(api);
    api.ReleaseCallerReference();
    Check(api.Present(),"failed hook removal retains DLL even without caller reference");
    api.ExpectRetained("failed unhook keeps exported status code and mapping valid");
    api.Load();
    Check(api.UnhookFailure(FALSE)!=FALSE,"clear unhook failure while completed worker awaits cleanup");
    Check(api.Stop(3000)!=FALSE,"unhook retry completes cleanup after worker already exited");
    api.ExpectStopped("unhook retry releases retained mapping");
    api.ReleaseCallerReference();
    Check(!api.Present(),"successful unhook retry releases retained module reference");
    api.Load();
    Check(api.Stop(0)!=FALSE,"module reload after unhook recovery is idle");
    puts("PASS lifecycle unhook failure: completed thread retains hooks/resources/DLL until successful retry");
}
void ConcurrentLifecycleLock(Api& api) {
    Gates gates(true,false);
    gates.Configure(api);
    DWORD enteredResult=WAIT_FAILED,stopError=ERROR_SUCCESS;
    BOOL stopResult=TRUE,released=FALSE;
    const StopFn stop=api.Stop;
    std::thread contender([&] {
        enteredResult=WaitForSingleObject(gates.startupEntered,3000);
        if (enteredResult==WAIT_OBJECT_0) {
            stopResult=stop(0);
            stopError=GetLastError();
        }
        released=SetEvent(gates.startup);
    });
    // Do not assert or throw while the contender borrows this stack context.
    // Even a failed start releases its gate and joins the owned control thread.
    const BOOL started=api.Start(nullptr,TF_TEST_MODE);
    SetEvent(gates.startup);
    contender.join();
    Check(enteredResult==WAIT_OBJECT_0,"concurrent stop observes startup while lifecycle lock is held");
    Check(stopResult==FALSE && stopError==ERROR_BUSY,"concurrent stop reports ERROR_BUSY without cancelling startup");
    Check(released!=FALSE,"concurrent control thread releases its owned startup gate");
    Check(started!=FALSE,"busy concurrent stop leaves original startup successful");
    NativeStatus status{};
    Check(api.ReadStatus(status) && status.running==1 && status.enabled==1,"busy concurrent stop does not request cancellation");
    Check(api.Stop(3000)!=FALSE,"concurrent-lock worker stops normally after control thread joins");
    api.ExpectStopped("concurrent-lock scenario releases its mapping");
    puts("PASS lifecycle concurrent stop: busy result preserves in-progress startup and clean shutdown");
}
}

int wmain(int argc,wchar_t** argv) {
    if (argc!=2) { fputs("FAIL lifecycle: pass native hook DLL path\n",stderr); return 2; }
    const std::wstring name=L"TaskbarFollow.LifecycleTests."+std::to_wstring(GetCurrentProcessId());
    const HDESK original=GetThreadDesktop(GetCurrentThreadId());
    HDESK desktop=CreateDesktopW(name.c_str(),nullptr,nullptr,0,GENERIC_ALL,nullptr);
    if (!desktop || !SetThreadDesktop(desktop)) {
        fprintf(stderr,"FAIL lifecycle desktop: %lu\n",GetLastError());
        if (desktop) CloseDesktop(desktop);
        return 1;
    }
    int result=0;
    try {
        Api api(argv[1]);
        NormalAndRepeated(api);
        ShutdownTimeout(api);
        StartupFailure(api);
        StartupTimeout(api);
        WorkerModuleReference(api);
        UnhookFailure(api);
        ConcurrentLifecycleLock(api);
        printf("PASS %u native lifecycle assertions; separate owned desktop; no input hooks\n",Checks);
    } catch (const std::exception& error) {
        fprintf(stderr,"FAIL native lifecycle: %s; Win32=%lu\n",error.what(),GetLastError());
        result=1;
    }
    if (SetThreadDesktop(original)) CloseDesktop(desktop);
    return result;
}
