# 安裝 glb-viewer：複製檔案到使用者資料夾，並把它登錄為 .glb 的可選開啟程式。
# 只寫入目前使用者的範圍，不需要系統管理員權限。可重複執行。
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GlbViewer'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [string]$Repo = 'wkai2573/glb-viewer',
    [string]$Ref = 'main',
    [switch]$NoOpenSettings,
    # 只覆蓋檔案，不動登錄項目也不開設定頁。檢視器內的更新按鈕會用它呼叫新版下載回來的安裝腳本，
    # 所以這個參數與 -InstallDir 必須維持相容。
    [switch]$UpdateOnly
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

    # 專案根目錄的檔案，一起裝進安裝資料夾
    $rootDir = Split-Path $srcDir -Parent
    $rootFiles = 'uninstall.ps1', 'VERSION'

    # 全部確認齊全才開始複製，缺檔時不會留下半套
    $missing = @($required | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcDir $_)) }) +
        @($rootFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $rootDir $_)) })
    if ($missing) { throw "來源缺少檔案：$($missing -join ', ')" }

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null

    # 先全部複製到暫存資料夾並備份現有的檔案，覆蓋到一半失敗就還原，不會留下新舊混雜的安裝。
    # 版本檔排在最後，它代表整套檔案都已換好。
    $plan = @($required | ForEach-Object { @{ Name = $_; From = (Join-Path $srcDir $_) } }) +
        @($rootFiles | ForEach-Object { @{ Name = $_; From = (Join-Path $rootDir $_) } })
    $stage = Join-Path $InstallDir ('.update-' + [guid]::NewGuid().ToString('N'))
    $stageNew = Join-Path $stage 'new'
    $stageOld = Join-Path $stage 'old'
    New-Item -ItemType Directory -Path $stageNew, $stageOld -Force | Out-Null
    try {
        foreach ($f in $plan) { Copy-Item -LiteralPath $f.From -Destination (Join-Path $stageNew $f.Name) }
        $touched = @()
        try {
            foreach ($f in $plan) {
                $target = Join-Path $InstallDir $f.Name
                $existed = Test-Path -LiteralPath $target
                if ($existed) { Copy-Item -LiteralPath $target -Destination (Join-Path $stageOld $f.Name) }
                $touched += @{ Name = $f.Name; Existed = $existed }
                Copy-Item -LiteralPath (Join-Path $stageNew $f.Name) -Destination $target -Force
            }
        } catch {
            $failure = $_
            foreach ($t in $touched) {
                $target = Join-Path $InstallDir $t.Name
                try {
                    if ($t.Existed) { Copy-Item -LiteralPath (Join-Path $stageOld $t.Name) -Destination $target -Force }
                    else { Remove-Item -LiteralPath $target -Force }
                } catch { }
            }
            throw $failure
        }
    } finally {
        Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 舊版用過、現在不再需要的檔案
    foreach ($name in 'model-viewer.min.js', 'model-viewer.LICENSE.txt') {
        Remove-Item -LiteralPath (Join-Path $InstallDir $name) -Force -ErrorAction SilentlyContinue
    }
} finally {
    if ($temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

if ($UpdateOnly) {
    Write-Host "已更新 $InstallDir"
    exit 0
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
