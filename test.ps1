# 冒煙測試：以真實的 Windows PowerShell 啟動檢視器伺服器，只透過它的 HTTP 介面驗證行為。
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$serverScript = Join-Path $root 'src\GlbViewer.ps1'
$sample = Join-Path $root 'samples\triangle.glb'
$sampleBytes = [IO.File]::ReadAllBytes($sample)

$script:failures = 0
$script:servers = @()

function Assert-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  通過  $Name"
    } else {
        Write-Host "  失敗  $Name  $Detail" -ForegroundColor Red
        $script:failures++
    }
}

function Start-Viewer([string]$Script = $serverScript, [string[]]$Extra = @()) {
    $out = [IO.Path]::GetTempFileName()
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" -Path `"$sample`" -NoLaunch"
    foreach ($e in $Extra) { $argLine += " `"$e`"" }
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argLine `
        -RedirectStandardOutput $out -PassThru -WindowStyle Hidden
    $server = [pscustomobject]@{ Proc = $proc; Url = $null; Out = $out }
    $script:servers += $server

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not $server.Url) {
        Start-Sleep -Milliseconds 200
        $line = Get-Content -LiteralPath $out -ErrorAction SilentlyContinue |
            Where-Object { $_ -match '^http://127\.0\.0\.1:\d+/[0-9a-f]{32}/$' } | Select-Object -First 1
        if ($line) { $server.Url = $line }
        if ($proc.HasExited) { break }
    }
    $server
}

function Get-Status([string]$Url) {
    try {
        (Invoke-WebRequest -Uri $Url -UseBasicParsing).StatusCode
    } catch {
        if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { -1 }
    }
}

function Wait-Exit($Proc, [int]$Seconds) {
    $Proc.WaitForExit($Seconds * 1000)
}

# 呼叫更新相關的介面，回傳狀態碼與解析後的 JSON 內容
function Invoke-Api([string]$Url, [string]$Method = 'GET') {
    $status = 0; $body = ''
    try {
        $r = Invoke-WebRequest -Uri $Url -Method $Method -UseBasicParsing
        $status = [int]$r.StatusCode; $body = $r.Content
    } catch {
        if ($_.Exception.Response) {
            $status = [int]$_.Exception.Response.StatusCode
            # Invoke-WebRequest 已經讀走回應串流，錯誤時的內容放在 ErrorDetails
            if ($_.ErrorDetails) { $body = $_.ErrorDetails.Message }
        } else { $status = -1 }
    }
    $json = $null
    try { if ($body) { $json = $body | ConvertFrom-Json } } catch { }
    [pscustomobject]@{ Status = $status; Json = $json }
}

# 在暫存資料夾裡做出一份假的遠端：一個 VERSION 檔，和一個結構與 GitHub 下載的 zip 相同的原始碼壓縮檔
function Set-Remote([string]$Dir, [string]$Version, [string]$ZipVersion = $Version, [string]$Omit = '') {
    Set-Content -LiteralPath (Join-Path $Dir 'VERSION') -Value $Version
    $stage = Join-Path $Dir 'stage'
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    $top = Join-Path $stage 'glb-viewer-main'
    New-Item -ItemType Directory -Path (Join-Path $top 'src') -Force | Out-Null
    Copy-Item -Path (Join-Path $root 'src\*') -Destination (Join-Path $top 'src') -Recurse -Force
    Copy-Item -LiteralPath (Join-Path $root 'install.ps1'), (Join-Path $root 'uninstall.ps1') -Destination $top
    Set-Content -LiteralPath (Join-Path $top 'VERSION') -Value $ZipVersion
    if ($Omit) { Remove-Item -LiteralPath (Join-Path $top $Omit) -Force }
    $zip = Join-Path $Dir 'source.zip'
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zip)
}

function Get-FileUri([string]$Path) { ([Uri]$Path).AbsoluteUri }

$repoVersion = ''
$versionPath = Join-Path $root 'VERSION'
if (Test-Path -LiteralPath $versionPath) { $repoVersion = (Get-Content -LiteralPath $versionPath -Raw).Trim() }
$realCmdKey = 'HKCU:\Software\Classes\GlbViewer.File\shell\open\command'
$realCmdBefore = if (Test-Path $realCmdKey) { (Get-ItemProperty $realCmdKey).'(default)' } else { $null }
$realClsidKey = 'HKCU:\Software\Classes\CLSID\{6F1C2D8B-3A47-4E5B-9C0D-2B7A5E4F1D93}'
$realClsidBefore = Test-Path $realClsidKey

try {
    Write-Host '伺服器介面'
    $s = Start-Viewer
    Assert-That '啟動後會輸出網址' ([bool]$s.Url)

    if ($s.Url) {
        $page = Invoke-WebRequest -Uri $s.Url -UseBasicParsing
        Assert-That '首頁回應 200' ($page.StatusCode -eq 200)
        Assert-That '首頁標題帶有檔名' ($page.Content -match [regex]::Escape('triangle.glb'))
        Assert-That '首頁不含未取代的樣板標記' ($page.Content -notmatch '\{\{NAME\}\}')

        $model = Invoke-WebRequest -Uri ($s.Url + 'model.glb') -UseBasicParsing
        $got = $model.RawContentStream.ToArray()
        Assert-That '模型檔位元組與原檔完全相同' ([Linq.Enumerable]::SequenceEqual([byte[]]$got, [byte[]]$sampleBytes))
        Assert-That '模型的內容類型正確' ($model.Headers['Content-Type'] -eq 'model/gltf-binary')

        $wrong = $s.Url -replace '/[0-9a-f]{32}/$', '/wrong/'
        Assert-That '路徑前綴錯誤時回 404' ((Get-Status ($wrong + 'model.glb')) -eq 404)
        Assert-That '不存在的路由回 404' ((Get-Status ($s.Url + 'nope')) -eq 404)

        Write-Host '版本（開發模式）'
        Assert-That '版本檔存在且格式是三段數字' ($repoVersion -match '^\d+\.\d+\.\d+$') "[$repoVersion]"
        Assert-That '首頁顯示目前版本號' ($page.Content -match [regex]::Escape("v$repoVersion"))
        Assert-That '首頁不含任何未取代的樣板標記' ($page.Content -notmatch '\{\{[A-Z]+\}\}')
        Assert-That '開發模式不能檢查更新' ((Invoke-Api ($s.Url + 'update/check')).Status -eq 403)
        Assert-That '開發模式不能執行更新' ((Invoke-Api ($s.Url + 'update/apply') 'POST').Status -eq 403)

        Write-Host '離線元件'
        $srcs = @([regex]::Matches($page.Content, '<script[^>]*\ssrc="([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        Assert-That '首頁有引用腳本' ($srcs.Count -gt 0)
        $unreachable = $srcs | Where-Object {
            $r = $null
            try { $r = Invoke-WebRequest -Uri ($s.Url + $_) -UseBasicParsing } catch { }
            -not ($r -and $r.StatusCode -eq 200 -and $r.Headers['Content-Type'] -like 'text/javascript*' -and $r.Content.Length -gt 1000)
        }
        Assert-That '首頁引用的每個腳本都由本機伺服器提供' (-not $unreachable) ($unreachable -join ', ')
        Assert-That '首頁引用的腳本都是相對路徑' (-not ($srcs | Where-Object { $_ -match '^(https?:)?//' }))
        Assert-That '核心與解碼載入器都有引用' (($srcs -contains 'three.min.js') -and ($srcs -contains 'GLTFLoader.js') -and ($srcs -contains 'DRACOLoader.js') -and ($srcs -contains 'OrbitControls.js'))
        Assert-That '舊的顯示元件不再被提供' ((Get-Status ($s.Url + 'model-viewer.min.js')) -eq 404)
        Assert-That '腳本以外的檔案不會被提供' ((Get-Status ($s.Url + 'GlbViewer.ps1')) -eq 404)

        Write-Host '網站圖示'
        $ico = Invoke-WebRequest -Uri ($s.Url + 'GlbViewer.ico') -UseBasicParsing
        $icoSource = [IO.File]::ReadAllBytes((Join-Path $root 'src\GlbViewer.ico'))
        Assert-That '首頁有指定網站圖示' ($page.Content -match '<link rel="icon" href="GlbViewer.ico">')
        Assert-That '網站圖示由本機伺服器提供' (($ico.StatusCode -eq 200) -and ($ico.Headers['Content-Type'] -eq 'image/x-icon') -and [Linq.Enumerable]::SequenceEqual([byte[]]$ico.RawContentStream.ToArray(), [byte[]]$icoSource))
        Assert-That '網站圖示的路徑前綴錯誤時回 404' ((Get-Status ($wrong + 'GlbViewer.ico')) -eq 404)
        # 唯一允許的外部網址是 Draco 解碼器，只有開啟 Draco 壓縮的模型時才會用到
        $external = @([regex]::Matches($page.Content, 'https?://(?!127\.0\.0\.1)[^"''\s`)]+') | ForEach-Object { $_.Value })
        $unexpected = $external | Where-Object { $_ -ne 'https://www.gstatic.com/draco/versioned/decoders/1.4.1/' }
        Assert-That '首頁除了 Draco 解碼器外不依賴外部網站' (-not $unexpected) ($unexpected -join ', ')

        Write-Host '載入中字樣的 bug'
        Assert-That '隱藏屬性不會被樣式蓋掉' ($page.Content -match '\[hidden\]\s*\{[^}]*display:\s*none')

        Write-Host '結束行為'
        Invoke-WebRequest -Uri ($s.Url + 'bye') -UseBasicParsing | Out-Null
        Start-Sleep -Seconds 1
        Invoke-WebRequest -Uri $s.Url -UseBasicParsing | Out-Null  # 模擬重新整理
        Start-Sleep -Seconds 5
        Assert-That '關閉通知後馬上重新整理，不會結束' (-not $s.Proc.HasExited)

        Invoke-WebRequest -Uri ($s.Url + 'bye') -UseBasicParsing | Out-Null
        Assert-That '收到關閉通知後自行結束' (Wait-Exit $s.Proc 8)
    }

    Write-Host '安裝與移除'
    $installDir = Join-Path ([IO.Path]::GetTempPath()) ('glbviewer-test-' + [guid]::NewGuid().ToString('N'))
    $testRoot = 'HKCU:\Software\GlbViewerTest\Classes'
    $installer = Join-Path $root 'install.ps1'
    $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
    $opts = @('-InstallDir', $installDir, '-ClassesRoot', $testRoot)

    & powershell.exe @common $installer @opts -NoOpenSettings | Out-Null
    Assert-That '安裝成功結束' ($LASTEXITCODE -eq 0)

    $expected = 'GlbViewer.ps1', 'GlbViewer.vbs', 'viewer.html', 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js', 'three.LICENSE.txt', 'GlbViewer.ico', 'uninstall.ps1', 'VERSION'
    $missing = $expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installDir $_)) }
    Assert-That '安裝資料夾含有所有必要檔案' (-not $missing) ($missing -join ', ')

    $cmdKey = "$testRoot\GlbViewer.File\shell\open\command"
    $cmd = if (Test-Path $cmdKey) { (Get-ItemProperty $cmdKey).'(default)' } else { '' }
    Assert-That '開啟指令指向安裝資料夾的啟動檔' ($cmd -like "*$installDir\GlbViewer.vbs*" -and $cmd -like '*"%1"')

    $withKey = "$testRoot\.glb\OpenWithProgids"
    $registered = (Test-Path $withKey) -and ((Get-Item $withKey).Property -contains 'GlbViewer.File')
    Assert-That '.glb 已登錄為可選的開啟程式' $registered

    $verFile = Join-Path $installDir 'VERSION'
    $installedVersion = if (Test-Path -LiteralPath $verFile) { (Get-Content -LiteralPath $verFile -Raw).Trim() } else { '' }
    Assert-That '安裝資料夾的版本檔與原始碼一致' ($repoVersion -and $installedVersion -eq $repoVersion) "[$installedVersion]"

    # 模擬安裝的是舊版，遠端另有新版
    Set-Content -LiteralPath $verFile -Value '0.0.1'
    $remoteDir = Join-Path ([IO.Path]::GetTempPath()) ('glbviewer-remote-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $remoteDir | Out-Null
    Set-Remote $remoteDir '9.9.9'
    $remoteArgs = @('-VersionUrl', (Get-FileUri (Join-Path $remoteDir 'VERSION')), '-ZipUrl', (Get-FileUri (Join-Path $remoteDir 'source.zip')), '-ClassesRoot', $testRoot)

    $installed = Start-Viewer (Join-Path $installDir 'GlbViewer.ps1') $remoteArgs
    if ($installed.Url) {
        $js2 = $null
        try { $js2 = Invoke-WebRequest -Uri ($installed.Url + 'three.min.js') -UseBasicParsing } catch { }
        Assert-That '安裝後的副本可獨立運作' ($js2 -and $js2.StatusCode -eq 200)

        Write-Host '更新'
        $home2 = Invoke-WebRequest -Uri $installed.Url -UseBasicParsing
        Assert-That '安裝後的首頁顯示安裝的版本號' ($home2.Content -match 'v0\.0\.1')

        $chk = Invoke-Api ($installed.Url + 'update/check')
        Assert-That '有新版時檢查會回報最新版本' ($chk.Status -eq 200 -and $chk.Json.current -eq '0.0.1' -and $chk.Json.latest -eq '9.9.9' -and $chk.Json.newer -eq $true) "$($chk.Status)"
        Assert-That '更新只接受 POST' ((Invoke-Api ($installed.Url + 'update/apply')).Status -eq 405)

        Set-Content -LiteralPath (Join-Path $installDir 'viewer.html') -Value 'old'
        $psHash = (Get-FileHash -LiteralPath (Join-Path $installDir 'GlbViewer.ps1')).Hash

        Set-Remote $remoteDir '9.9.9' '0.0.1'
        $bad = Invoke-Api ($installed.Url + 'update/apply') 'POST'
        Assert-That '下載的內容版本不是新版時拒絕更新' ($bad.Status -eq 409 -and $bad.Json.ok -eq $false) "$($bad.Status)"

        Set-Remote $remoteDir '9.9.9' '9.9.9' 'src\GLTFLoader.js'
        $bad = Invoke-Api ($installed.Url + 'update/apply') 'POST'
        Assert-That '下載的內容缺少必要檔案時更新失敗' ($bad.Status -eq 500 -and $bad.Json.ok -eq $false) "$($bad.Status)"
        Assert-That '更新失敗時安裝的檔案原封不動' (((Get-Content -LiteralPath $verFile -Raw).Trim() -eq '0.0.1') -and ((Get-FileHash -LiteralPath (Join-Path $installDir 'GlbViewer.ps1')).Hash -eq $psHash) -and ((Get-Content -LiteralPath (Join-Path $installDir 'viewer.html') -Raw).Trim() -eq 'old'))

        # 複製到一半失敗（目標檔案被鎖住，只能讀不能寫）時，要還原成更新前的樣子
        $snapshot = { Get-ChildItem -LiteralPath $installDir -File | Sort-Object Name | ForEach-Object { $_.Name + ':' + (Get-FileHash -LiteralPath $_.FullName).Hash } }
        $before = & $snapshot
        Set-Remote $remoteDir '9.9.9'
        $lock = [IO.File]::Open((Join-Path $installDir 'DRACOLoader.js'), 'Open', 'Read', 'Read')
        try { $locked = Invoke-Api ($installed.Url + 'update/apply') 'POST' } finally { $lock.Dispose() }
        Assert-That '複製途中失敗時更新回報失敗' ($locked.Status -eq 500 -and $locked.Json.ok -eq $false) "$($locked.Status)"
        Assert-That '複製途中失敗時已複製的檔案會還原' ((@(& $snapshot) -join '|') -eq (@($before) -join '|'))
        Assert-That '更新失敗後不會留下暫存資料夾' (-not (Get-ChildItem -LiteralPath $installDir -Directory))

        Set-Content -LiteralPath $verFile -Value 'broken'
        Assert-That '本機版本檔損毀時檢查回 500' ((Invoke-Api ($installed.Url + 'update/check')).Status -eq 500)
        Set-Content -LiteralPath $verFile -Value '0.0.1'

        Rename-Item -LiteralPath (Join-Path $remoteDir 'VERSION') -NewName 'VERSION.gone'
        Assert-That '連不上遠端時檢查回 502' ((Invoke-Api ($installed.Url + 'update/check')).Status -eq 502)
        Set-Content -LiteralPath (Join-Path $remoteDir 'VERSION') -Value 'not a version'
        Assert-That '遠端版本號格式不對時檢查回 502' ((Invoke-Api ($installed.Url + 'update/check')).Status -eq 502)
        Remove-Item -LiteralPath (Join-Path $remoteDir 'VERSION.gone') -Force

        Set-Remote $remoteDir '0.0.1'
        $same = Invoke-Api ($installed.Url + 'update/check')
        Assert-That '遠端版本相同時回報已是最新' ($same.Status -eq 200 -and $same.Json.newer -eq $false)
        Assert-That '已是最新時拒絕更新' ((Invoke-Api ($installed.Url + 'update/apply') 'POST').Status -eq 409)

        Set-Remote $remoteDir '9.9.9'
        $ok = Invoke-Api ($installed.Url + 'update/apply') 'POST'
        Assert-That '有新版時更新成功' ($ok.Status -eq 200 -and $ok.Json.ok -eq $true -and $ok.Json.version -eq '9.9.9') "$($ok.Status)"
        Assert-That '更新後版本檔是新版本' ((Get-Content -LiteralPath $verFile -Raw).Trim() -eq '9.9.9')
        Assert-That '更新後檔案已換成新的內容' ((Get-FileHash -LiteralPath (Join-Path $installDir 'viewer.html')).Hash -eq (Get-FileHash -LiteralPath (Join-Path $root 'src\viewer.html')).Hash)
        $gone = $expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installDir $_)) }
        Assert-That '更新後所有必要檔案仍在' (-not $gone) ($gone -join ', ')
        $after = Invoke-Api ($installed.Url + 'update/check')
        Assert-That '更新後再檢查會回報已是最新' ($after.Status -eq 200 -and $after.Json.current -eq '9.9.9' -and $after.Json.newer -eq $false)
        Assert-That '更新不會動到系統登錄項目' (($realCmdBefore -eq $(if (Test-Path $realCmdKey) { (Get-ItemProperty $realCmdKey).'(default)' } else { $null })) -and ($realClsidBefore -eq (Test-Path $realClsidKey)))
        Assert-That '更新會把縮圖元件登錄在指定的位置' (Test-Path "$testRoot\.glb\ShellEx\{E357FCCD-A995-4576-B01F-234630154E96}")

        Invoke-WebRequest -Uri ($installed.Url + 'bye') -UseBasicParsing | Out-Null
        Wait-Exit $installed.Proc 8 | Out-Null
    } else {
        Assert-That '安裝後的副本可獨立運作' $false
    }

    # 模擬從舊版升級：舊版留下的檔案要在重新安裝時清掉
    $stale = 'model-viewer.min.js', 'model-viewer.LICENSE.txt'
    $stale | ForEach-Object { Set-Content -LiteralPath (Join-Path $installDir $_) -Value 'old' }
    & powershell.exe @common $installer @opts -NoOpenSettings | Out-Null
    Assert-That '重複安裝不會出錯' ($LASTEXITCODE -eq 0)
    $left = $stale | Where-Object { Test-Path -LiteralPath (Join-Path $installDir $_) }
    Assert-That '重新安裝會清掉舊版殘留的檔案' (-not $left) ($left -join ', ')

    & powershell.exe @common (Join-Path $installDir 'uninstall.ps1') @opts | Out-Null
    Assert-That '移除成功結束' ($LASTEXITCODE -eq 0)
    Assert-That '移除後安裝資料夾消失' (-not (Test-Path -LiteralPath $installDir))
    Assert-That '移除後登錄項目消失' (-not (Test-Path "$testRoot\GlbViewer.File"))
    $stillWith = (Test-Path $withKey) -and ((Get-Item $withKey).Property -contains 'GlbViewer.File')
    Assert-That '移除後 .glb 不再列出本程式' (-not $stillWith)
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\GlbViewerTest' -Recurse -Force -ErrorAction SilentlyContinue
    if ($installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($remoteDir) { Remove-Item -LiteralPath $remoteDir -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($srv in $script:servers) {
        if ($srv.Proc -and -not $srv.Proc.HasExited) { Stop-Process -Id $srv.Proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $srv.Out -Force -ErrorAction SilentlyContinue
    }
}

Write-Host '縮圖與圖示'
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'test-thumbnail.ps1')
if ($LASTEXITCODE -ne 0) { $script:failures++ }

if ($script:failures -gt 0) {
    Write-Host "`n共 $($script:failures) 項失敗" -ForegroundColor Red
    exit 1
}
Write-Host "`n全部通過"
