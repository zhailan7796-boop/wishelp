param(
    [Parameter(Mandatory=$true)][string]$Script,
    [string[]]$ScriptArgs = @(),
    [string]$OutputName = 'input-desktop',
    [ValidateRange(1000,30000)][int]$TimeoutMs = 20000
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptPath = (Resolve-Path -LiteralPath (Join-Path $root $Script)).Path
if (-not $scriptPath.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'The script must be inside this workspace.' }
if ($OutputName -notmatch '^[a-zA-Z0-9-]+$') { throw 'Invalid output name.' }
$out = Join-Path $root 'tests\results'
$null = New-Item -ItemType Directory -Path $out -Force
$stdout = Join-Path $out ($OutputName + '.stdout.txt')
$stderr = Join-Path $out ($OutputName + '.stderr.txt')
Add-Type @'
using System;
using System.ComponentModel;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class FollowInputDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, width, height, charsX, charsY, fill, flags;
        public short show, reservedSize;
        public IntPtr reservedData, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public uint pid, tid; }
    [DllImport("user32.dll", SetLastError=true)] static extern IntPtr OpenInputDesktop(uint flags, bool inherit, uint access);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder text, uint length, out uint needed);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] static extern bool CreateProcess(string app, StringBuilder command, IntPtr psec, IntPtr tsec, bool inherit, uint flags, IntPtr env, string dir, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint timeout);
    [DllImport("kernel32.dll")] static extern bool GetExitCodeProcess(IntPtr handle, out uint code);
    [DllImport("kernel32.dll")] static extern bool TerminateProcess(IntPtr handle, uint code);
    static string Quote(string arg) {
        var result = new StringBuilder("\""); int slashes = 0;
        foreach (char c in arg) {
            if (c == '\\') { slashes++; continue; }
            result.Append('\\', c == '"' ? slashes * 2 + 1 : slashes); slashes = 0;
            result.Append(c);
        }
        result.Append('\\', slashes * 2); result.Append('"'); return result.ToString();
    }
    public static int Run(string root, string script, string[] args, string stdout, string stderr, int timeout) {
        IntPtr desktop = OpenInputDesktop(0, false, 0x41);
        if (desktop == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        var name = new StringBuilder(256); uint needed;
        try { if (!GetUserObjectInformation(desktop, 2, name, 512, out needed)) throw new Win32Exception(Marshal.GetLastWin32Error()); }
        finally { CloseDesktop(desktop); }
        string exe = Path.Combine(root, "runtime", "AutoHotkey64.exe");
        var command = new StringBuilder(Quote(exe) + " /ErrorStdOut=UTF-8 " + Quote(script));
        foreach (string arg in args) command.Append(" " + Quote(arg));
        using (var output = new FileStream(stdout, FileMode.Create, FileAccess.Write, FileShare.ReadWrite))
        using (var errors = new FileStream(stderr, FileMode.Create, FileAccess.Write, FileShare.ReadWrite)) {
            IntPtr oh = output.SafeFileHandle.DangerousGetHandle(), eh = errors.SafeFileHandle.DangerousGetHandle();
            if (!SetHandleInformation(oh, 1, 1) || !SetHandleInformation(eh, 1, 1)) throw new Win32Exception(Marshal.GetLastWin32Error());
            var startup = new StartupInfo(); startup.cb = Marshal.SizeOf(startup);
            startup.desktop = "winsta0\\" + name.ToString(); startup.flags = 0x101;
            startup.stdout = oh; startup.stderr = eh;
            ProcessInfo process;
            if (!CreateProcess(exe, command, IntPtr.Zero, IntPtr.Zero, true, 0x08000400, IntPtr.Zero, root, ref startup, out process)) throw new Win32Exception(Marshal.GetLastWin32Error());
            CloseHandle(process.thread);
            try {
                if (WaitForSingleObject(process.process, (uint)timeout) != 0) {
                    TerminateProcess(process.process, 124); WaitForSingleObject(process.process, 2000);
                    throw new TimeoutException("Input-desktop test timed out; only its owned test process was terminated.");
                }
                uint code;
                if (!GetExitCodeProcess(process.process, out code)) throw new Win32Exception(Marshal.GetLastWin32Error());
                return (int)code;
            } finally { CloseHandle(process.process); }
        }
    }
}
'@
$code = [FollowInputDesktop]::Run($root, $scriptPath, $ScriptArgs, $stdout, $stderr, $TimeoutMs)
$text = [IO.File]::ReadAllText($stdout, [Text.Encoding]::UTF8)
$errors = [IO.File]::ReadAllText($stderr, [Text.Encoding]::UTF8)
if ($text) { Write-Output $text.TrimEnd() }
if ($errors) { Write-Output $errors.TrimEnd() }
if ($code -ne 0 -or $errors -ne '' -or $text -match '==>|\bWarning:') { exit 1 }
exit 0
