#pragma once
#include <windows.h>
#include <cstdint>

constexpr unsigned TF_MAX_ENTRIES = 64;
constexpr unsigned TF_MAX_WINDOWS = 32;
constexpr unsigned TF_COLD_START = 1;
constexpr unsigned TF_REQUIRE_APP_ID = 2;
constexpr unsigned TF_COMPATIBILITY = 4; // explicit-click, after-show routing for x86 applications
constexpr unsigned TF_TEST_MODE = 1;
struct NativeCandidate { std::uint64_t hwnd; std::uint32_t pid, reserved; };
struct alignas(8) NativeEntry {
    std::uint64_t taskbar;
    RECT button;
    std::uint32_t flags, count;
    wchar_t appId[256], path[1024];
    NativeCandidate windows[TF_MAX_WINDOWS];
};
static_assert(sizeof(NativeEntry) == 3104, "AHK cache ABI");
struct alignas(8) NativeStatus {
    std::uint32_t size, running, enabled, cacheCount;
    std::uint64_t cacheAge, armed, created, restored, activated, firstShown, cancelled;
    std::uint32_t lastKind, lastPid;
    std::uint64_t lastWindow, latency, eventNumber;
    wchar_t target[32];
};
static_assert(sizeof(NativeStatus) == 168, "AHK status ABI");
struct alignas(8) NativeIntent {
    NativeEntry entry;
    std::uint64_t monitor, released, expires;
    std::uint32_t serial, reserved;
};
static_assert(sizeof(NativeIntent) == 3136, "AHK compatibility intent ABI");
enum NativeEvent : unsigned { TF_ARMED=1, TF_CREATE=2, TF_RESTORE=3, TF_ACTIVATE=4,
    TF_FIRST_SHOW=5, TF_CANCEL=6, TF_GROUP=7, TF_UNSUPPORTED=8, TF_SAME_SCREEN=9, TF_EXPIRED=10,
    TF_PEEK_SHOW=12, TF_PEEK_HIDE=13, TF_POSITION_REJECTED=16 };

#ifdef TF_BUILD_DLL
#define TF_API extern "C" __declspec(dllexport)
#else
#define TF_API extern "C" __declspec(dllimport)
#endif
TF_API BOOL TF_Start(HWND owner, unsigned flags);
TF_API void TF_Stop();
// FALSE retains resources for a retry (ERROR_BUSY may not yet request a stop).
// Only TRUE permits the caller to release its DLL reference.
TF_API BOOL TF_StopAndWait(unsigned timeoutMs);
TF_API void TF_SetEnabled(BOOL enabled);
TF_API void TF_Configure(unsigned timeoutMs, BOOL bringActive);
TF_API void TF_Cancel(unsigned cooldownMs);
TF_API BOOL TF_PublishCache(const NativeEntry* entries, unsigned count, unsigned stride);
TF_API BOOL TF_Status(NativeStatus* status, unsigned bytes);
TF_API BOOL TF_CompatibilityIntent(unsigned serial, NativeIntent* intent, unsigned bytes);
// A stale compatibility callback cannot cancel a newer click transaction.
TF_API BOOL TF_CancelCompatibility(unsigned serial);
// Test mode installs no input hooks and can arm only the test executable's path.
TF_API BOOL TF_TestArm(const wchar_t* path, HWND window, HMONITOR target);
TF_API BOOL TF_TestArmIdentity(const wchar_t* path, const wchar_t* appId, HMONITOR target);
TF_API void TF_SetPeekEnabled(BOOL enabled);
TF_API BOOL TF_ShowPeek(HWND source, DWORD pid, HWND popup, int x, int y);
TF_API void TF_HidePeek();
TF_API HWND TF_TestPeek(HWND source, HWND popup, HMONITOR target, BOOL show);
TF_API unsigned TF_HoverCandidates(NativeCandidate* candidates, unsigned capacity);
TF_API BOOL TF_AccessibleName(int x, int y, wchar_t* name, unsigned capacity);
// Idle-only lifecycle fault injection; events are duplicated and consulted only
// in TF_TEST_MODE. A successful stop releases the duplicates and resets it.
TF_API BOOL TF_TestLifecycle(HANDLE startupGate, HANDLE shutdownGate,
    HANDLE startupEntered, HANDLE shutdownEntered, DWORD startupError);
TF_API BOOL TF_TestSetUnhookFailure(BOOL enabled);
TF_API BOOL TF_TestReleaseEntry(const NativeEntry* entry, HMONITOR target, BOOL preview);
