# 安裝 glb-viewer：複製檔案到使用者資料夾，並把它登錄為 .glb 的可選開啟程式。
# 只寫入目前使用者的範圍，不需要系統管理員權限。可重複執行。
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GlbViewer'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [string]$Repo = 'wkai2573/glb-viewer',
    [string]$Ref = 'main',
    [switch]$NoOpenSettings
)

$ErrorActionPreference = 'Stop'

$progId = 'GlbViewer.File'
$required = 'GlbViewer.ps1', 'GlbViewer.vbs', 'viewer.html', 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js', 'three.LICENSE.txt'

# 找出來源：在專案資料夾內執行就用本機檔案，否則從 GitHub 下載。
$srcDir = $null
if ($PSScriptRoot) {
    $local = Join-Path $PSScriptRoot 'src'
    if (Test-Path -LiteralPath (Join-Path $local 'GlbViewer.ps1')) { $srcDir = $local }
}

$temp = $null
try {
    if (-not $srcDir) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('glb-viewer-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $temp | Out-Null
        $zip = Join-Path $temp 'source.zip'
        Write-Host "從 GitHub 下載 $Repo 的 $Ref ..."
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Ref.zip" -OutFile $zip -UseBasicParsing
        Expand-Archive -LiteralPath $zip -DestinationPath $temp
        $srcDir = Join-Path (Get-ChildItem -LiteralPath $temp -Directory | Select-Object -First 1).FullName 'src'
    }

    $missing = $required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcDir $_)) }
    if ($missing) { throw "來源缺少檔案：$($missing -join ', ')" }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    foreach ($name in $required) {
        Copy-Item -LiteralPath (Join-Path $srcDir $name) -Destination (Join-Path $InstallDir $name) -Force
    }
    Copy-Item -LiteralPath (Join-Path (Split-Path $srcDir -Parent) 'uninstall.ps1') -Destination (Join-Path $InstallDir 'uninstall.ps1') -Force

    # 舊版用過、現在不再需要的檔案
    foreach ($name in 'model-viewer.min.js', 'model-viewer.LICENSE.txt') {
        Remove-Item -LiteralPath (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue
    }
} finally {
    if ($temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

$progKey = "$ClassesRoot\$progId"
New-Item -Path "$progKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $progKey -Name '(default)' -Value 'GLB 檢視器'
Set-ItemProperty -Path "$progKey\shell\open\command" -Name '(default)' `
    -Value ('wscript.exe "{0}" "%1"' -f (Join-Path $InstallDir 'GlbViewer.vbs'))

$withKey = "$ClassesRoot\.glb\OpenWithProgids"
New-Item -Path $withKey -Force | Out-Null
New-ItemProperty -Path $withKey -Name $progId -Value '' -PropertyType String -Force | Out-Null

$isRealRegistry = $ClassesRoot -eq 'HKCU:\Software\Classes'
if ($isRealRegistry) {
    Add-Type -Namespace GlbViewerSetup -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
    [GlbViewerSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

Write-Host "已安裝到 $InstallDir"

if ($isRealRegistry) {
    $userChoice = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.glb\UserChoice'
    $current = if (Test-Path $userChoice) { (Get-ItemProperty $userChoice).ProgId } else { $null }

    if ($current -eq $progId) {
        Write-Host '.glb 的預設開啟程式已經是 GLB 檢視器。'
    } else {
        Write-Host 'Windows 不允許程式自行變更預設，請手動選一次：'
        Write-Host '  在任一 .glb 上按右鍵，選「開啟檔案時使用」，再選「選擇其他應用程式」，'
        Write-Host '  選「GLB 檢視器」並勾選「一律使用」。'
        if (-not $NoOpenSettings) { Start-Process 'ms-settings:defaultapps' }
    }
}
