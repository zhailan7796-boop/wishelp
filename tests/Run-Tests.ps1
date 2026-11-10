param()
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'runtime\AutoHotkey64.exe'
$out = Join-Path $PSScriptRoot 'results'
New-Item -ItemType Directory -Path $out -Force | Out-Null
$cases = @(
    @{Name='parse-config'; Script='TaskbarFollow.ahk'; Args='--check'},
    @{Name='unit'; Script='tests\Unit.ahk'; Args=''},
    @{Name='identity-cache'; Script='tests\IdentityCache.ahk'; Args=''},
    @{Name='app-identity'; Script='tests\AppIdentity.ahk'; Args=''},
    @{Name='compatibility-follow'; Script='tests\CompatibilityFollow.ahk'; Args=''},
    @{Name='native-shutdown'; Script='tests\NativeShutdown.ahk'; Args=''},
    @{Name='display-autostart'; Script='tests\DisplayAutoStart.ahk'; Args=''},
    @{Name='background-instance'; Script='tests\BackgroundInstance.ahk'; Args=''},
    @{Name='uia-smoke'; Script='tests\Smoke.ahk'; Args=''},
    @{Name='uia-cache'; Script='tests\UiaCache.ahk'; Args=''},
    @{Name='window-move'; Script='tests\WindowMove.ahk'; Args=''},
    @{Name='helper-ipc'; Script='TaskbarFollow.ahk'; Args='--lifecycle-test'},
    @{Name='startup-hooks'; Script='TaskbarFollow.ahk'; Args='--startup-test'},
    @{Name='status-window'; Script='TaskbarFollow.ahk'; Args='--status-test'},
    @{Name='status-refresh'; Script='tests\StatusRefresh.ahk'; Args=''},
    @{Name='self-follow'; Script='tests\SelfFollow.ahk'; Args=''},
    @{Name='single-instance'; Script='tests\Instance.ahk'; Args=''}
)
$failed = 0
foreach ($case in $cases) {
    $stdout = Join-Path $out ($case.Name + '.stdout.txt')
    $stderr = Join-Path $out ($case.Name + '.stderr.txt')
    $script = Join-Path $root $case.Script
    $arguments = '/ErrorStdOut=UTF-8 "' + $script + '" ' + $case.Args
    $process = Start-Process -FilePath $exe -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    $null = $process.Handle
    if (-not $process.WaitForExit(15000)) {
        $process.Kill()
        $process.WaitForExit()
        Write-Output ('FAIL ' + $case.Name + ': timed out; only its test process was terminated')
        $failed++
        continue
    }
    $process.WaitForExit()
    $text = [IO.File]::ReadAllText($stdout, [Text.Encoding]::UTF8)
    $errors = [IO.File]::ReadAllText($stderr, [Text.Encoding]::UTF8)
    if ($process.ExitCode -ne 0 -or $errors -ne '' -or $text -match '==>|\bWarning:') {
        Write-Output ('FAIL ' + $case.Name + ' exit=' + $process.ExitCode)
        $failed++
    } else { Write-Output ('PASS ' + $case.Name) }
    if ($text) { Write-Output $text.TrimEnd() }
    if ($errors) { Write-Output $errors.TrimEnd() }
}
Write-Output ('Suites=' + $cases.Count + '; failures=' + $failed)
if ($failed) { exit 1 }
exit 0


