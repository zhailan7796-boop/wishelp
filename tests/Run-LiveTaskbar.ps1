param([Parameter(Mandatory=$true)][ValidateSet('cursor','edge','code','fixture','hover','hover-group','status','explorer','video')][string]$Case)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$scriptName = if ($Case -in @('status','explorer','video')) { 'LiveRequestedApps.ahk' } elseif ($Case -like 'hover*') { 'HoverInput.ahk' } elseif ($Case -eq 'fixture') { 'TaskbarInput.ahk' } else { 'LiveTaskbar.ahk' }
$caseArgument = if ($Case -eq 'hover-group') { 'two' } else { $Case }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'tools\Invoke-InputDesktop.ps1') -Script ('tests\' + $scriptName) -ScriptArgs $caseArgument -OutputName ('live-' + $Case)
exit $LASTEXITCODE
