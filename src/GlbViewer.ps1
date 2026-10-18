param(
    [Parameter(Mandatory = $true)][string]$Path,
    [switch]$NoLaunch
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { exit 1 }
$file = (Resolve-Path -LiteralPath $Path).Path
$name = [IO.Path]::GetFileName($file)

$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'viewer.html'), [Text.Encoding]::UTF8)
# 檢視頁用到的腳本，只提供這份清單內的檔案
$scripts = @{}
foreach ($js in 'three.min.js', 'OrbitControls.js', 'GLTFLoader.js', 'DRACOLoader.js') {
    $scripts[$js] = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot $js))
}
$pageBytes = [Text.Encoding]::UTF8.GetBytes($template.Replace('{{NAME}}', [Net.WebUtility]::HtmlEncode($name)))

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
