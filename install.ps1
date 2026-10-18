# 安裝 glb-viewer：複製檔案到使用者資料夾，並把它登錄為 .glb 的可選開啟程式。
# 只寫入目前使用者的範圍，不需要系統管理員權限。可重複執行。
param(
    [string]$InstallDir = (Join-Path $env:LOCALAPPDATA 'GlbViewer'),
    [string]$ClassesRoot = 'HKCU:\Software\Classes',
    [string]$Repo = 'wkai2573/glb-viewer',
    [string]$Ref = 'main',
    [switch]$NoOpenSettings,
    # 只覆蓋檔案，不動預設程式的關聯設定也不開設定頁。檢視器內的更新按鈕會用它呼叫新版下載回來的安裝腳本，
    # 所以這個參數與 -InstallDir 必須維持相容。縮圖與圖示屬於安裝內容，更新時也會一併補上。
    [switch]$UpdateOnly,
    # .glb 已有其他縮圖元件時，預設不去蓋掉它。加上這個參數才改用本程式的。
    [switch]$ForceThumbnail
)

$ErrorActionPreference = 'Stop'

$progId = 'GlbViewer.File'
$required = 'GlbViewer.ps1', 'GlbViewer.vbs', 'viewer.html', 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js', 'three.LICENSE.txt', 'GlbViewer.ico'
# 只在安裝時用來編譯、不會複製到安裝資料夾的來源檔
$compileOnly = 'GlbThumbnail.cs'

$thumbClsid = '{6F1C2D8B-3A47-4E5B-9C0D-2B7A5E4F1D93}'
$thumbHandlerId = '{E357FCCD-A995-4576-B01F-234630154E96}'
$thumbClass = 'GlbViewer.Thumbnail.GlbThumbnailProvider'

# 縮圖元件的檔名帶版本號：舊版元件可能正被 Explorer 載入而無法覆蓋，所以每個版本用不同的檔名。
function Get-ThumbnailAssemblyName([string]$Version) {
    'GlbThumb_' + ($Version -replace '[^0-9A-Za-z]', '_')
}

function Build-ThumbnailDll([string]$Source, [string]$InstallDir, [string]$AssemblyName) {
    # 不能用目前執行階段的目錄找：在 PowerShell 7 下它指向 PowerShell 7 自己，沒有 csc.exe
    $csc = @("$env:windir\Microsoft.NET\Framework64\v4.0.30319\csc.exe", "$env:windir\Microsoft.NET\Framework\v4.0.30319\csc.exe") |
        Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $csc) { throw '找不到 .NET Framework 4 的編譯器 csc.exe。' }
    # 組件名稱取自輸出的檔名，所以要先在暫存資料夾用正確的檔名編譯，再複製過去
    $work = Join-Path ([IO.Path]::GetTempPath()) ('glb-thumb-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $built = Join-Path $work "$AssemblyName.dll"
        $previous = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $log = & $csc /nologo /target:library /optimize+ "/out:$built" /reference:System.Drawing.dll $Source 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = $previous
        if ($exit -ne 0 -or -not (Test-Path -LiteralPath $built)) { throw "編譯失敗：$(($log | Out-String).Trim())" }
        $target = Join-Path $InstallDir "$AssemblyName.dll"
        try {
            Copy-Item -LiteralPath $built -Destination $target -Force
        } catch {
            # 同版本的元件正被使用而無法覆蓋時，沿用現有的
            if (-not (Test-Path -LiteralPath $target)) { throw }
        }
        $target
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# .glb 上已有別人提供的縮圖元件時，回傳它的 CLSID，否則回傳 $null
function Get-ForeignThumbnailHandler([string]$ClassesRoot, [string]$Clsid, [string]$HandlerId, [bool]$IncludeMachine) {
    $roots = @($ClassesRoot)
    if ($IncludeMachine) { $roots += 'HKLM:\Software\Classes' }
    foreach ($r in $roots) {
        foreach ($sub in ".glb\ShellEx\$HandlerId", "SystemFileAssociations\.glb\ShellEx\$HandlerId") {
            $key = "$r\$sub"
            if (-not (Test-Path -LiteralPath $key)) { continue }
            $value = (Get-ItemProperty -LiteralPath $key).'(default)'
            if ($value -and $value -ne $Clsid) { return $value }
        }
    }
    $null
}

function Register-ThumbnailProvider([string]$ClassesRoot, [string]$DllPath, [string]$AssemblyName, [string]$Clsid, [string]$HandlerId, [string]$Class) {
    $clsKey = "$ClassesRoot\CLSID\$Clsid"
    New-Item -Path "$clsKey\InprocServer32" -Force | Out-Null
    Set-ItemProperty -LiteralPath $clsKey -Name '(default)' -Value 'GLB 檢視器縮圖'
    $assembly = "$AssemblyName, Version=0.0.0.0, Culture=neutral, PublicKeyToken=null"
    $codeBase = ([Uri]$DllPath).AbsoluteUri
    # 和 regasm /codebase 寫出的登錄結構相同，但直接寫在使用者範圍，不需要系統管理員權限
    foreach ($key in "$clsKey\InprocServer32", "$clsKey\InprocServer32\0.0.0.0") {
        New-Item -Path $key -Force | Out-Null
        Set-ItemProperty -LiteralPath $key -Name '(default)' -Value 'mscoree.dll'
        Set-ItemProperty -LiteralPath $key -Name 'ThreadingModel' -Value 'Both'
        Set-ItemProperty -LiteralPath $key -Name 'Class' -Value $Class
        Set-ItemProperty -LiteralPath $key -Name 'Assembly' -Value $assembly
        Set-ItemProperty -LiteralPath $key -Name 'RuntimeVersion' -Value 'v4.0.30319'
        Set-ItemProperty -LiteralPath $key -Name 'CodeBase' -Value $codeBase
    }
    $handlerKey = "$ClassesRoot\.glb\ShellEx\$HandlerId"
    $previous = if (Test-Path -LiteralPath $handlerKey) { (Get-ItemProperty -LiteralPath $handlerKey).'(default)' } else { $null }
    New-Item -Path $handlerKey -Force | Out-Null
    Set-ItemProperty -LiteralPath $handlerKey -Name '(default)' -Value $Clsid
    # -ForceThumbnail 蓋掉了別人的設定時記下來，移除時才還原得回去。重複安裝時值已經是自己的，不會覆蓋這筆紀錄。
    if ($previous -and $previous -ne $Clsid) {
        Set-ItemProperty -LiteralPath $clsKey -Name 'PreviousHandler' -Value $previous
    }
}

$isRealRegistry = $ClassesRoot -eq 'HKCU:\Software\Classes'
$progKey = "$ClassesRoot\$progId"

# 找出來源：在專案資料夾內執行就用本機檔案，否則從 GitHub 下載。
$srcDir = $null
if ($PSScriptRoot) {
    $local = Join-Path $PSScriptRoot 'src'
    if (Test-Path -LiteralPath (Join-Path $local 'GlbViewer.ps1')) { $srcDir = $local }
}

$temp = $null
$thumbnailChanged = $false
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
    $missing = @($required + $compileOnly | Where-Object { -not (Test-Path -LiteralPath (Join-Path $srcDir $_)) }) +
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

    # 縮圖元件：編譯與登錄失敗都只警告，檢視器本身照常可用。
    try {
        $version = (Get-Content -LiteralPath (Join-Path $rootDir 'VERSION') -Raw).Trim().TrimStart([char]0xFEFF)
        $assemblyName = Get-ThumbnailAssemblyName $version
        $foreign = Get-ForeignThumbnailHandler $ClassesRoot $thumbClsid $thumbHandlerId $isRealRegistry
        if ($foreign -and -not $ForceThumbnail) {
            Write-Host ".glb 已有其他縮圖元件 $foreign，略過縮圖註冊。要改用本程式的，請加上 -ForceThumbnail 重新安裝。"
        } else {
            $dll = Build-ThumbnailDll (Join-Path $srcDir $compileOnly) $InstallDir $assemblyName
            Register-ThumbnailProvider $ClassesRoot $dll $assemblyName $thumbClsid $thumbHandlerId $thumbClass
            $thumbnailChanged = $true
            # 舊版本的元件檔，沒被鎖住就清掉；被鎖住的下次安裝或移除時再處理
            Get-ChildItem -LiteralPath $InstallDir -Filter 'GlbThumb_*.dll' |
                Where-Object { $_.FullName -ne $dll } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    } catch {
        Write-Warning "縮圖元件安裝失敗，已略過：$($_.Exception.Message)"
    }
} finally {
    if ($temp) { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
}

# 檔案類型圖示掛在本程式自己的 ProgId 上。更新時只在 ProgId 已存在時補上，不會憑空建立關聯。
if (-not $UpdateOnly -or (Test-Path -LiteralPath $progKey)) {
    New-Item -Path "$progKey\DefaultIcon" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$progKey\DefaultIcon" -Name '(default)' -Value ('"{0}",0' -f (Join-Path $InstallDir 'GlbViewer.ico'))
}

function Send-ShellAssocChanged {
    if (-not $isRealRegistry) { return }
    Add-Type -Namespace GlbViewerSetup -Name Shell -MemberDefinition '[System.Runtime.InteropServices.DllImport("shell32.dll")] public static extern void SHChangeNotify(int eventId, uint flags, System.IntPtr item1, System.IntPtr item2);'
    [GlbViewerSetup.Shell]::SHChangeNotify(0x08000000, 0, [IntPtr]::Zero, [IntPtr]::Zero)
}

if ($UpdateOnly) {
    if ($thumbnailChanged -or (Test-Path -LiteralPath $progKey)) { Send-ShellAssocChanged }
    Write-Host "已更新 $InstallDir"
    exit 0
}

New-Item -Path "$progKey\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $progKey -Name '(default)' -Value 'GLB 檢視器'
Set-ItemProperty -Path "$progKey\shell\open\command" -Name '(default)' `
    -Value ('wscript.exe "{0}" "%1"' -f (Join-Path $InstallDir 'GlbViewer.vbs'))

$withKey = "$ClassesRoot\.glb\OpenWithProgids"
New-Item -Path $withKey -Force | Out-Null
New-ItemProperty -Path $withKey -Name $progId -Value '' -PropertyType String -Force | Out-Null

Send-ShellAssocChanged

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
