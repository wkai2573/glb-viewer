# 由 assets\icon.svg 產生 src\GlbViewer.ico。只有改圖示時才需要執行，安裝流程不會用到。
# 用 Microsoft Edge 的無頭模式把 SVG 畫成大圖，縮成各尺寸，再封裝成 ico。
param(
    [string]$Svg = (Join-Path $PSScriptRoot '..\assets\icon.svg'),
    [string]$Out = (Join-Path $PSScriptRoot '..\src\GlbViewer.ico'),
    [int[]]$Sizes = @(16, 32, 48, 256)
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$edge = @(
    "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe"
) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $edge) { throw '找不到 Microsoft Edge。' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('glb-icon-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    $master = 1024
    $svgText = [IO.File]::ReadAllText((Resolve-Path -LiteralPath $Svg).Path)
    $page = Join-Path $work 'page.html'
    [IO.File]::WriteAllText($page, "<!doctype html><meta charset=utf-8><style>html,body{margin:0;background:transparent}svg{display:block;width:${master}px;height:${master}px}</style>$svgText", [Text.UTF8Encoding]::new($false))
    $shot = Join-Path $work 'master.png'
    $profile = Join-Path $work 'profile'
    & $edge --headless --disable-gpu --hide-scrollbars --no-first-run "--user-data-dir=$profile" `
        --default-background-color=00000000 "--window-size=$master,$master" "--screenshot=$shot" ([Uri]$page).AbsoluteUri | Out-Null
    if (-not (Test-Path -LiteralPath $shot)) { throw 'Edge 沒有輸出截圖。' }

    $masterBmp = [Drawing.Bitmap]::FromFile($shot)
    try {
        $images = foreach ($size in $Sizes) {
            $bmp = New-Object Drawing.Bitmap $size, $size, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $g = [Drawing.Graphics]::FromImage($bmp)
            $g.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
            $g.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
            $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
            $g.Clear([Drawing.Color]::Transparent)
            $g.DrawImage($masterBmp, (New-Object Drawing.Rectangle 0, 0, $size, $size), 0, 0, $masterBmp.Width, $masterBmp.Height, [Drawing.GraphicsUnit]::Pixel)
            $g.Dispose()
            $ms = New-Object IO.MemoryStream
            $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            [pscustomobject]@{ Size = $size; Png = $ms.ToArray() }
        }
    } finally {
        $masterBmp.Dispose()
    }

    # ico 容器：檔頭、每張圖一筆目錄，後面接 PNG 資料。256 在目錄裡記成 0。
    $stream = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $stream
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]@($images).Count)
    $offset = 6 + 16 * @($images).Count
    foreach ($img in $images) {
        $dim = if ($img.Size -ge 256) { 0 } else { $img.Size }
        $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$img.Png.Length); $w.Write([uint32]$offset)
        $offset += $img.Png.Length
    }
    foreach ($img in $images) { $w.Write($img.Png) }
    $w.Flush()
    $outPath = [IO.Path]::GetFullPath($Out)
    [IO.File]::WriteAllBytes($outPath, $stream.ToArray())
    Write-Host "已產生 $outPath（$($Sizes -join '、') 像素）"
} finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
