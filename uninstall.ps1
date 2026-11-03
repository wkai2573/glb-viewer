# 移除 glb-viewer：刪除登錄項目與安裝資料夾。
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GlbViewer'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [ValidateSet('Auto', 'en', 'zh')][string]$Language = 'Auto'
)

$ErrorActionPreference = 'Stop'

$isZh = if ($Language -eq 'zh') { $true }
        elseif ($Language -eq 'en') { $false }
        else { ((Get-UICulture).Name -like 'zh*') }

$progId = 'GlbViewer.File'
$thumbClsid = '{6F1C2D8B-3A47-4E5B-9C0D-2B7A5E4F1D93}'
$thumbHandlerId = '{E357FCCD-A995-4576-B01F-234630154E96}'

if (Test-Path -LiteralPath $InstallDir) {
    # 只刪確認是本程式安裝的資料夾，避免參數誤用時刪到別的地方。
    # 上次移除時如果縮圖元件被鎖住，資料夾裡只剩元件檔，仍然要認得出來，才能再清一次。
    if ((Test-Path -LiteralPath (Join-Path $InstallDir 'GlbViewer.vbs')) -or
        (@(Get-ChildItem -LiteralPath $InstallDir -Filter 'GlbThumb_*.dll' -ErrorAction SilentlyContinue).Count -gt 0)) {
        # 先刪資料夾：失敗時登錄項目還在，修正原因後重跑即可。
        try {
            Remove-Item -LiteralPath $InstallDir -Recurse -Force
        } catch {
            $reason = $_.Exception.Message
            # 縮圖元件可能正被 Explorer 使用而刪不掉。其他檔案照刪，元件留到之後手動清除，不讓移除因此失敗。
            Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            $left = @(Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -File -ErrorAction SilentlyContinue)
            $blocking = @($left | Where-Object { $_.Name -notlike 'GlbThumb_*.dll' })
            if ($blocking.Count -gt 0) {
                $err = if ($isZh) {
                    "無法刪除 $InstallDir。請關閉所有檢視器視窗，並確認目前的目錄不在該資料夾內，再重新執行。$reason"
                } else {
                    "Cannot delete $InstallDir. Please close all viewer windows, ensure current directory is outside the folder, and retry. $reason"
                }
                Write-Error $err
                exit 1
            }
            Get-ChildItem -LiteralPath $InstallDir -Recurse -Force -Directory -ErrorAction SilentlyContinue |
                Sort-Object { $_.FullName.Length } -Descending |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
            foreach ($f in $left) {
                $warn = if ($isZh) {
                    "縮圖元件正被檔案總管使用，無法刪除：$($f.FullName)。登出或重新啟動檔案總管後，可以手動刪除這個檔案。"
                } else {
                    "Thumbnail component is locked by File Explorer and cannot be deleted: $($f.FullName). It can be deleted manually after logging out or restarting File Explorer."
                }
                Write-Warning $warn
            }
        }
        if (-not (Test-Path -LiteralPath $InstallDir)) {
            Write-Host $(if ($isZh) { "已移除 $InstallDir" } else { "Removed $InstallDir" })
        }
    } else {
        $warn = if ($isZh) {
            "$InstallDir 看起來不是 glb-viewer 的安裝資料夾，已略過。"
        } else {
            "$InstallDir does not appear to be a glb-viewer installation folder, skipped."
        }
        Write-Warning $warn
    }
}

Remove-Item -LiteralPath "$ClassesRoot\$progId" -Recurse -Force -ErrorAction SilentlyContinue

# 縮圖：只移除指向本程式的登錄項目，別人的縮圖元件不動
# 安裝時若用 -ForceThumbnail 蓋掉了別人的縮圖元件，會把原本的值記在本程式的 CLSID 底下，這裡還原。
$shellExKey = "$ClassesRoot\.glb\ShellEx"
$handlerKey = "$shellExKey\$thumbHandlerId"
$clsKey = "$ClassesRoot\CLSID\$thumbClsid"
$previousHandler = if (Test-Path -LiteralPath $clsKey) { (Get-ItemProperty -LiteralPath $clsKey).PreviousHandler } else { $null }
if ((Test-Path -LiteralPath $handlerKey) -and ((Get-ItemProperty -LiteralPath $handlerKey).'(default)' -eq $thumbClsid)) {
    if ($previousHandler) {
        Set-ItemProperty -LiteralPath $handlerKey -Name '(default)' -Value $previousHandler
    } else {
        Remove-Item -LiteralPath $handlerKey -Recurse -Force -ErrorAction SilentlyContinue
        if ((Test-Path -LiteralPath $shellExKey) -and -not (Get-ChildItem -LiteralPath $shellExKey -ErrorAction SilentlyContinue)) {
            Remove-Item -LiteralPath $shellExKey -Force -ErrorAction SilentlyContinue
        }
    }
}
Remove-Item -LiteralPath $clsKey -Recurse -Force -ErrorAction SilentlyContinue

$withKey = "$ClassesRoot\.glb\OpenWithProgids"
if (Test-Path $withKey) {
    Remove-ItemProperty -Path $withKey -Name $progId -ErrorAction SilentlyContinue
}

if ($ClassesRoot -eq 'HKCU:\Software\Classes') {
    Add-Type -Namespace GlbViewerSetup -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
    [GlbViewerSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)

    $userChoice = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.glb\UserChoice'
    if ((Test-Path $userChoice) -and (Get-ItemProperty $userChoice).ProgId -eq $progId) {
        $notice = if ($isZh) {
            '提醒：Windows 仍記得 .glb 預設用 GLB Viewer，下次雙擊時會請你重新選擇程式。'
        } else {
            'Notice: Windows still remembers GLB Viewer as default for .glb. You will be prompted to select an app upon next launch.'
        }
        Write-Host $notice
    }
}
Write-Host $(if ($isZh) { '已移除。' } else { 'Removed.' })
