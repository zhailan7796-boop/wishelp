param([switch]$SkipTests,[switch]$NoRun)
$ErrorActionPreference = 'Stop'
$nativeRoot = $PSScriptRoot
$out = Join-Path $nativeRoot 'bin'
$obj = Join-Path $nativeRoot 'obj'
$null = New-Item -ItemType Directory -Path $out,$obj -Force
$vswhere = 'C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual C++ x64 tools are required to build the native prototype.' }
$version = (Get-Content -LiteralPath (Join-Path $vs 'VC\Auxiliary\Build\Microsoft.VCToolsVersion.default.txt')).Trim()
$vc = Join-Path $vs ('VC\Tools\MSVC\' + $version)
$sdk = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows Kits\Installed Roots').KitsRoot10
$sdkVersion = Get-ChildItem -LiteralPath (Join-Path $sdk 'Include') -Directory | Sort-Object Name -Descending | Select-Object -First 1 -ExpandProperty Name
$compiler = Join-Path $vc 'bin\Hostx64\x64\cl.exe'
$env:PATH = (Join-Path $sdk ('bin\' + $sdkVersion + '\x64')) + ';' + (Join-Path $vc 'bin\Hostx64\x64') + ';' + $env:PATH
$hashInput = (Get-FileHash -LiteralPath (Join-Path $nativeRoot 'NativeHooks.cpp') -Algorithm SHA256).Hash + (Get-FileHash -LiteralPath (Join-Path $nativeRoot 'NativeHooks.h') -Algorithm SHA256).Hash + (Get-FileHash -LiteralPath (Join-Path $nativeRoot 'PeekPreview.h') -Algorithm SHA256).Hash
$hasher = [Security.Cryptography.SHA256]::Create()
try { $digest = [BitConverter]::ToString($hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($hashInput))).Replace('-','').Substring(0,12).ToLowerInvariant() } finally { $hasher.Dispose() }
$dllName = 'NativeHooks-' + $digest + '-x64.dll'
$dll = Join-Path $out $dllName
$common = @('/nologo','/std:c++17','/EHsc','/W4','/WX','/utf-8','/O2','/MT','/DUNICODE','/D_UNICODE','/DNOMINMAX',('/I' + (Join-Path $vc 'include')))
foreach ($dir in @('ucrt','um','shared')) { $common += '/I' + (Join-Path $sdk ('Include\' + $sdkVersion + '\' + $dir)) }
$libraries = @('/link',('/LIBPATH:' + (Join-Path $vc 'lib\x64')),('/LIBPATH:' + (Join-Path $sdk ('Lib\' + $sdkVersion + '\um\x64'))),('/LIBPATH:' + (Join-Path $sdk ('Lib\' + $sdkVersion + '\ucrt\x64'))),'user32.lib','comctl32.lib','advapi32.lib','shell32.lib','ole32.lib','oleaut32.lib','oleacc.lib','dwmapi.lib','gdi32.lib')
if (-not (Test-Path -LiteralPath $dll)) {
    & $compiler @common /LD (Join-Path $nativeRoot 'NativeHooks.cpp') ('/Fo' + (Join-Path $obj 'NativeHooks.obj')) @libraries ('/OUT:' + $dll) ('/IMPLIB:' + (Join-Path $obj 'NativeHooks.lib'))
    if ($LASTEXITCODE -ne 0) { throw 'Native hook compilation failed.' }
}
@('[Native]',('Dll=' + $dllName),'Version=0.3.0','Architecture=x64') | Set-Content -LiteralPath (Join-Path $out 'runtime.ini') -Encoding ASCII
Write-Output ('PASS native hook build: ' + $dllName)
if (-not $SkipTests) {
    foreach ($suite in @('NativeLifecycleTests','NativeRoutingTests','NativePaintTests','NativeTests')) {
        $tests = Join-Path $out ($suite + '.exe')
        & $compiler @common (Join-Path $nativeRoot ($suite + '.cpp')) ('/Fo' + (Join-Path $obj ($suite + '.obj'))) @libraries ('/OUT:' + $tests) '/MANIFEST:EMBED' ('/MANIFESTINPUT:' + (Join-Path $nativeRoot 'Native.manifest'))
        if ($LASTEXITCODE -ne 0) { throw ($suite + ' compilation failed.') }
        if (-not $NoRun) {
            & $tests $dll
            if ($LASTEXITCODE -ne 0) { throw ($suite + ' failed.') }
        }
    }
}
