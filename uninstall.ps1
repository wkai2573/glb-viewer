# 移除 glb-viewer：刪除登錄項目與安裝資料夾。
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GlbViewer'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes'
)

$ErrorActionPreference = 'Stop'

$progId = 'GlbViewer.File'

if (Test-Path -LiteralPath $InstallDir) {
    # 只刪確認是本程式安裝的資料夾，避免參數誤用時刪到別的地方。
    if (Test-Path -LiteralPath (Join-Path $InstallDir 'GlbViewer.vbs')) {
        # 先刪資料夾：失敗時登錄項目還在，修正原因後重跑即可。
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        } catch {
            Write-Error "無法刪除 $InstallDir。請關閉所有檢視器視窗，並確認目前的目錄不在該資料夾內，再重新執行。$($_.Exception.Message)"
            exit 1
        }
        Write-Host "已移除 $InstallDir"
    } else {
        Write-Warning "$InstallDir 看起來不是 glb-viewer 的安裝資料夾，已略過。"
    }
}

Remove-Item -LiteralPath "$ClassesRoot\$progId" -Recurse -Force -ErrorAction SilentlyContinue

$withKey = "$ClassesRoot\.glb\OpenWithProgids"
if (Test-Path $withKey) {
    Remove-ItemProperty -Path $withKey -Name $progId -ErrorAction SilentlyContinue
}

if ($ClassesRoot -eq 'HKCU:\Software\Classes') {
    Add-Type -Namespace GlbViewerSetup -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
    [GlbViewerSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

    $userChoice = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.glb\UserChoice'
    if ((Test-Path $userChoice) -and (Get-ItemProperty $userChoice).ProgId -eq $progId) {
        Write-Host '提醒：Windows 仍記得 .glb 預設用 GLB 檢視器，下次雙擊時會請你重新選擇程式。'
    }
}
Write-Host '已移除。'
