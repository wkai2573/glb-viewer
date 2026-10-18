param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$NoLaunch,
    # 更新來源。平常用預設值指向 GitHub，測試時改指向本機檔案。
    [string]$VersionUrl = 'https://raw.githubusercontent.com/wkai2573/glb-viewer/main/VERSION',
    [string]$ZipUrl = 'https://github.com/wkai2573/glb-viewer/archive/refs/heads/main.zip'
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { exit 1 }
$file = (Resolve-Path -LiteralPath $Path).Path
$name = [IO.Path]::GetFileName($file)

# 版本檔在安裝資料夾裡和腳本放在一起；從原始碼資料夾執行時在上一層。
# 只有安裝出來的副本才允許更新，免得把原始碼資料夾蓋掉。
$canUpdate = Test-Path -LiteralPath (Join-Path $PSScriptRoot 'VERSION')
$versionFile = if ($canUpdate) { Join-Path $PSScriptRoot 'VERSION' } else { Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION' }

function ConvertTo-Version([string]$Text) {
    $t = $Text.Trim().TrimStart([char]0xFEFF)
    if ($t -notmatch '^\d+\.\d+\.\d+$') { throw "版本號格式不對：$t" }
    [version]$t
}

# 讀不到或格式不對時回傳 $null，不要假裝成 0.0.0
function Get-LocalVersion {
    if (Test-Path -LiteralPath $versionFile) {
        try { return ConvertTo-Version ([IO.File]::ReadAllText($versionFile)) } catch { }
    }
    $null
}

$localVersionError = '無法讀取本機的版本檔，請重新執行安裝指令。'

function Save-Remote([string]$Url, [string]$OutFile, [int]$TimeoutSec) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing -TimeoutSec $TimeoutSec
}

# 每個更新函式都回傳 @{ Status; Body }，由路由轉成 JSON
function Invoke-UpdateCheck {
    $current = Get-LocalVersion
    if (-not $current) { return @{ Status = 500; Body = @{ ok = $false; error = $localVersionError } } }
    $tmp = [IO.Path]::GetTempFileName()
    try {
        Save-Remote $VersionUrl $tmp 10
        $latest = ConvertTo-Version ([IO.File]::ReadAllText($tmp))
    } catch {
        return @{ Status = 502; Body = @{ ok = $false; error = "無法取得最新版本：$($_.Exception.Message)" } }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    @{ Status = 200; Body = @{ ok = $true; current = $current.ToString(); latest = $latest.ToString(); newer = ($latest -gt $current) } }
}

# 是否有新版以下載回來的內容裡的版本檔為準，不另外再查一次遠端版本
function Invoke-UpdateApply {
    $current = Get-LocalVersion
    if (-not $current) { return @{ Status = 500; Body = @{ ok = $false; error = $localVersionError } } }
    $work = Join-Path ([IO.Path]::GetTempPath()) ('glbviewer-update-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $work | Out-Null
        $zip = Join-Path $work 'source.zip'
        Save-Remote $ZipUrl $zip 60
        Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $work 'x')
        $top = Get-ChildItem -LiteralPath (Join-Path $work 'x') -Directory | Select-Object -First 1
        if (-not $top) { throw '下載的壓縮檔是空的。' }

        $versionPath = Join-Path $top.FullName 'VERSION'
        if (-not (Test-Path -LiteralPath $versionPath)) { throw '下載的內容沒有版本檔。' }
        $downloaded = ConvertTo-Version ([IO.File]::ReadAllText($versionPath))
        if ($downloaded -le $current) {
            return @{ Status = 409; Body = @{ ok = $false; error = "目前的 $current 已是最新版本，下載到的是 $downloaded。" } }
        }

        # 用新版自己的安裝腳本覆蓋檔案，這樣新版新增或移除的檔案也會一併處理
        $installer = Join-Path $top.FullName 'install.ps1'
        if (-not (Test-Path -LiteralPath $installer)) { throw '下載的內容沒有安裝腳本。' }
        # 子程序寫到標準錯誤時，Windows PowerShell 5.1 在 Stop 模式下會直接丟例外，改成只看結束碼
        $ErrorActionPreference = 'Continue'
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $installer -InstallDir $PSScriptRoot -UpdateOnly 2>&1
        $exit = $LASTEXITCODE
        $ErrorActionPreference = 'Stop'
        if ($exit -ne 0) { throw "安裝失敗：$(($out | Out-String).Trim())" }

        @{ Status = 200; Body = @{ ok = $true; version = $downloaded.ToString() } }
    } catch {
        @{ Status = 500; Body = @{ ok = $false; error = "更新失敗：$($_.Exception.Message)" } }
    } finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Send-Json($Response, [int]$Status, $Body) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress))
    $Response.StatusCode = $Status
    $Response.ContentType = 'application/json; charset=utf-8'
    $Response.ContentLength64 = $bytes.Length
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'viewer.html'), [Text.Encoding]::UTF8)
# 檢視頁用到的腳本，只提供這份清單內的檔案
$scripts = @{}
foreach ($js in 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js') {
    $scripts[$js] = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $js))
}
$page = $template.Replace('{{NAME}}', [Net.WebUtility]::HtmlEncode($name)).
    Replace('{{VERSION}}', $(if ($v = Get-LocalVersion) { $v.ToString() } else { '?' })).
    Replace('{{CANUPDATE}}', $canUpdate.ToString().ToLower())
$pageBytes = [Text.Encoding]::UTF8.GetBytes($page)

# 隨機埠與隨機路徑前綴，避免被其他網頁猜到
$token = [guid]::NewGuid().ToString('N')
$listener = $null
foreach ($i in 1..30) {
    $port = Get-Random -Minimum 49152 -Maximum 65000
    $candidate = [Net.HttpListener]::new()
    $candidate.Prefixes.Add("http://127.0.0.1:$port/")
    try { $candidate.Start(); $listener = $candidate; break } catch { $candidate.Close() }
}
if (-not $listener) { exit 2 }

$url = "http://127.0.0.1:$port/$token/"
Write-Output $url

if (-not $NoLaunch) {
    $edge = @(
        "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
    ) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1

    if ($edge) {
        Start-Process -FilePath $edge -ArgumentList "--app=$url", '--window-size=1100,760'
    } else {
        Start-Process $url
    }
}

$startedAt = Get-Date
$lastSeen = Get-Date
$byeAt = $null
$task = $listener.GetContextAsync()

try {
    while ($true) {
        if ($task.Wait(500)) {
            $ctx = $task.Result
            $task = $listener.GetContextAsync()
            $req = $ctx.Request
            $res = $ctx.Response
            try {
                $rel = $req.Url.AbsolutePath
                $hostOk = $req.Headers['Host'] -eq "127.0.0.1:$port"
                $prefix = "/$token/"

                if (-not $hostOk -or -not $rel.StartsWith($prefix)) {
                    $res.StatusCode = 404
                } else {
                    $route = $rel.Substring($prefix.Length)
                    if ($route -ne 'bye') { $byeAt = $null }
                    $lastSeen = Get-Date

                    switch ($route) {
                        '' {
                            $res.ContentType = 'text/html; charset=utf-8'
                            $res.ContentLength64 = $pageBytes.Length
                            $res.OutputStream.Write($pageBytes, 0, $pageBytes.Length)
                        }
                        'model.glb' {
                            $res.ContentType = 'model/gltf-binary'
                            $fs = [IO.File]::Open($file, 'Open', 'Read', 'ReadWrite')
                            try {
                                $res.ContentLength64 = $fs.Length
                                $fs.CopyTo($res.OutputStream)
                            } finally { $fs.Dispose() }
                        }
                        { $_ -in 'update/check', 'update/apply' } {
                            if (-not $canUpdate) {
                                Send-Json $res 403 @{ ok = $false; error = '開發模式不支援更新。' }
                            } elseif ($route -eq 'update/apply' -and $req.HttpMethod -ne 'POST') {
                                Send-Json $res 405 @{ ok = $false; error = '更新只接受 POST。' }
                            } else {
                                $r = if ($route -eq 'update/check') { Invoke-UpdateCheck } else { Invoke-UpdateApply }
                                Send-Json $res $r.Status $r.Body
                                $lastSeen = Get-Date
                            }
                        }
                        'ping' { $res.StatusCode = 204 }
                        'bye'  { $byeAt = Get-Date; $res.StatusCode = 204 }
                        default {
                            if ($scripts.ContainsKey($route)) {
                                $bytes = $scripts[$route]
                                $res.ContentType = 'text/javascript; charset=utf-8'
                                $res.ContentLength64 = $bytes.Length
                                $res.OutputStream.Write($bytes, 0, $bytes.Length)
                            } else {
                                $res.StatusCode = 404
                            }
                        }
                    }
                }
            } catch {
                # 瀏覽器中途斷線等情況，忽略即可
            } finally {
                try { $res.Close() } catch { }
            }
        }

        $now = Get-Date
        if ($byeAt -and ($now - $byeAt).TotalSeconds -gt 3) { break }
        # 保險：太久沒有任何請求（例如視窗被強制結束）也會自行結束
        if (($now - $lastSeen).TotalSeconds -gt 120) { break }
    }
} finally {
    $listener.Stop()
    $listener.Close()
}
