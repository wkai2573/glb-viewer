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

function Start-Viewer([string]$Script = $serverScript) {
    $out = [IO.Path]::GetTempFileName()
    $argLine = "-NoProfile -ExecutionPolicy Bypass -File `"$Script`" -Path `"$sample`" -NoLaunch"
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

    $expected = 'GlbViewer.ps1', 'GlbViewer.vbs', 'viewer.html', 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js', 'three.LICENSE.txt', 'uninstall.ps1'
    $missing = $expected | Where-Object { -not (Test-Path -LiteralPath (Join-Path $installDir $_)) }
    Assert-That '安裝資料夾含有所有必要檔案' (-not $missing) ($missing -join ', ')

    $cmdKey = "$testRoot\GlbViewer.File\shell\open\command"
    $cmd = if (Test-Path $cmdKey) { (Get-ItemProperty $cmdKey).'(default)' } else { '' }
    Assert-That '開啟指令指向安裝資料夾的啟動檔' ($cmd -like "*$installDir\GlbViewer.vbs*" -and $cmd -like '*"%1"')

    $withKey = "$testRoot\.glb\OpenWithProgids"
    $registered = (Test-Path $withKey) -and ((Get-Item $withKey).Property -contains 'GlbViewer.File')
    Assert-That '.glb 已登錄為可選的開啟程式' $registered

    $installed = Start-Viewer (Join-Path $installDir 'GlbViewer.ps1')
    if ($installed.Url) {
        $js2 = $null
        try { $js2 = Invoke-WebRequest -Uri ($installed.Url + 'three.min.js') -UseBasicParsing } catch { }
        Assert-That '安裝後的副本可獨立運作' ($js2 -and $js2.StatusCode -eq 200)
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
    foreach ($srv in $script:servers) {
        if ($srv.Proc -and -not $srv.Proc.HasExited) { Stop-Process -Id $srv.Proc.Id -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $srv.Out -Force -ErrorAction SilentlyContinue
    }
}

if ($script:failures -gt 0) {
    Write-Host "`n共 $($script:failures) 項失敗" -ForegroundColor Red
    exit 1
}
Write-Host "`n全部通過"
