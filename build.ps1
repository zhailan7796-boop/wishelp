param([switch]$SkipTests)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'native\build-native.ps1') -SkipTests
if ($LASTEXITCODE -ne 0) { throw 'Native component build failed.' }
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$launcher = Join-Path $root 'Start.exe'
$icon = Join-Path $root 'launcher\TaskbarFollow.ico'
& $compiler /nologo /target:winexe /platform:anycpu /optimize+ /reference:System.Windows.Forms.dll ('/win32icon:' + $icon) ('/out:' + $launcher) (Join-Path $root 'launcher\Launcher.cs')
if ($LASTEXITCODE -ne 0) { throw 'Launcher compilation failed' }
if (-not $SkipTests) {
    $localSettings = Join-Path $root 'settings.ini'
    if (-not (Test-Path -LiteralPath $localSettings)) {
        Copy-Item -LiteralPath (Join-Path $root 'settings.default.ini') -Destination $localSettings
    }
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tests\Run-Tests.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'Tests failed; no package was produced' }
}
$dist = Join-Path $root 'dist'
$staging = Join-Path $dist ('stage-' + [Guid]::NewGuid().ToString('N'))
$packageRoot = Join-Path $staging 'TaskbarFollow'
New-Item -ItemType Directory -Path $packageRoot -Force | Out-Null
foreach ($name in @('TaskbarFollow.ahk','DisplayWatch.ahk','Probe.ahk','Diagnose.ahk','Start.exe','Start.cmd','settings.default.ini','README.md','LICENSE','THIRD-PARTY-NOTICES.md','build.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root $name) -Destination $packageRoot
}
Copy-Item -LiteralPath (Join-Path $root 'settings.default.ini') -Destination (Join-Path $packageRoot 'settings.ini')
foreach ($dir in @('lib','docs','launcher','third-party')) {
    Copy-Item -LiteralPath (Join-Path $root $dir) -Destination $packageRoot -Recurse
}
$runtime = Join-Path $packageRoot 'runtime'
$tests = Join-Path $packageRoot 'tests'
$tools = Join-Path $packageRoot 'tools'
New-Item -ItemType Directory -Path $runtime,$tests,$tools -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $root 'tools\Invoke-InputDesktop.ps1') -Destination $tools
Copy-Item -LiteralPath (Join-Path $root 'tools\Configure-DisplayStartup.ahk') -Destination $tools
$nativePackage = Join-Path $packageRoot 'native'
$nativeBin = Join-Path $nativePackage 'bin'
New-Item -ItemType Directory -Path $nativeBin -Force | Out-Null
foreach ($name in @('NativeHooks.cpp','NativeHooks.h','PeekPreview.h','NativeTests.cpp','NativeLifecycleTests.cpp','NativePaintTests.cpp','NativeRoutingTests.cpp','Native.manifest','build-native.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('native\' + $name)) -Destination $nativePackage
}
$nativeRuntime = Join-Path $root 'native\bin\runtime.ini'
$nativeDll = (Get-Content -LiteralPath $nativeRuntime | Where-Object { $_ -like 'Dll=*' }).Substring(4)
Copy-Item -LiteralPath $nativeRuntime -Destination $nativeBin
Copy-Item -LiteralPath (Join-Path $root ('native\bin\' + $nativeDll)) -Destination $nativeBin
foreach ($name in @('AutoHotkey64.exe','AutoHotkey32.exe','license.txt')) {
    Copy-Item -LiteralPath (Join-Path $root ('runtime\' + $name)) -Destination $runtime
}
foreach ($name in @('Unit.ahk','IdentityCache.ahk','AppIdentity.ahk','CompatibilityFollow.ahk','SelfFollow.ahk','NativeShutdown.ahk','DisplayAutoStart.ahk','BackgroundInstance.ahk','BackgroundInstanceFixture.ahk','Smoke.ahk','UiaCache.ahk','WindowMove.ahk','Instance.ahk','InstanceFixture.ahk','Run-Tests.ps1','LiveTaskbar.ahk','LiveChrome.ahk','LiveRequestedApps.ahk','TaskbarInput.ahk','HoverInput.ahk','StatusRefresh.ahk','Run-LiveTaskbar.ps1')) {
    Copy-Item -LiteralPath (Join-Path $root ('tests\' + $name)) -Destination $tests
}
$verify = Start-Process -FilePath (Join-Path $packageRoot 'Start.exe') -ArgumentList '--check' -WorkingDirectory $packageRoot -WindowStyle Hidden -Wait -PassThru
if ($verify.ExitCode -ne 0) { throw ('Staged launcher check failed: ' + $verify.ExitCode) }
Write-Output 'PASS staged portable launcher/configuration check'
# Deliberately no live diagnostics, logs, downloaded HTML, or developer output in the package.
$hashLines = foreach ($item in Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Sort-Object FullName) {
    $relative = $item.FullName.Substring($packageRoot.Length + 1).Replace('\','/')
    (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant() + '  ' + $relative
}
$hashLines | Set-Content -LiteralPath (Join-Path $packageRoot 'SHA256SUMS.txt') -Encoding UTF8
$version = [Reflection.AssemblyName]::GetAssemblyName($launcher).Version.ToString(3)
$zipName = 'TaskbarFollow-' + $version + '-portable.zip'
$zip = Join-Path $dist $zipName
# Write portable ZIP entry names explicitly: Windows PowerShell 5 Compress-Archive writes backslashes.
Add-Type -AssemblyName System.IO.Compression
$zipStream = [IO.File]::Open($zip, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
$archive = New-Object IO.Compression.ZipArchive($zipStream, [IO.Compression.ZipArchiveMode]::Create, $false)
try {
    foreach ($item in Get-ChildItem -LiteralPath $packageRoot -File -Recurse | Sort-Object FullName) {
        $relative = 'TaskbarFollow/' + $item.FullName.Substring($packageRoot.Length + 1).Replace('\','/')
        $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
        $inputStream = [IO.File]::OpenRead($item.FullName)
        $outputStream = $entry.Open()
        try { $inputStream.CopyTo($outputStream) }
        finally { $outputStream.Dispose(); $inputStream.Dispose() }
    }
} finally { $archive.Dispose(); $zipStream.Dispose() }
$zipHash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLowerInvariant()
($zipHash + '  ' + $zipName) | Set-Content -LiteralPath ($zip + '.sha256') -Encoding ASCII
Write-Output ('Package: ' + $zip)
Write-Output ('Size: ' + (Get-Item -LiteralPath $zip).Length + ' bytes')
Write-Output ('SHA256: ' + $zipHash)


