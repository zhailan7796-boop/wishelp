param(
    [string]$OutputDir = (Join-Path $PSScriptRoot 'dist'),
    [string]$Wix = 'wix'
)

$ErrorActionPreference = 'Stop'

$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
    throw 'The Windows .NET Framework C# compiler is required to build the app.'
}
Get-Command $Wix -ErrorAction Stop | Out-Null

$output = (New-Item -ItemType Directory -Path $OutputDir -Force).FullName
$obj = (New-Item -ItemType Directory -Path (Join-Path $output 'obj') -Force).FullName
$app = Join-Path $obj 'DesktopIconToggle.exe'
$source = Join-Path $PSScriptRoot 'src'

$compilerArgs = @(
    '/nologo', '/target:winexe', '/platform:anycpu', '/optimize+', '/debug-', '/codepage:65001'
    '/reference:System.Windows.Forms.dll', '/reference:Microsoft.CSharp.dll'
    ('/win32icon:' + (Join-Path $source 'CowCat.ico'))
    ('/win32manifest:' + (Join-Path $source 'app.manifest'))
    ('/out:' + $app)
    (Join-Path $source 'DesktopIconToggle.cs')
)
& $compiler @compilerArgs
if ($LASTEXITCODE -ne 0) { throw "C# compilation failed ($LASTEXITCODE)." }

$fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($app)
$version = '{0}.{1}.{2}' -f $fileVersion.FileMajorPart, $fileVersion.FileMinorPart, $fileVersion.FileBuildPart
$msi = Join-Path $output "DesktopIconToggle-Setup-$version.msi"
$package = Join-Path $PSScriptRoot 'installer\Package.wxs'

& $Wix build $package -arch x86 -d "ProductVersion=$version" -d "AppExePath=$app" -intermediateFolder $obj -pdbtype none -o $msi
if ($LASTEXITCODE -ne 0) { throw "MSI build failed ($LASTEXITCODE)." }

Get-Item -LiteralPath $msi
