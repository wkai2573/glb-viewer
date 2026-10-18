# 縮圖測試：透過公開接縫驗證行為。
#   接縫一：GlbRenderer.RenderToPng，輸入 .glb 路徑，輸出 PNG，不經過 Explorer。
#   接縫二：install.ps1 與 uninstall.ps1 寫到測試專用登錄位置的縮圖與圖示項目。
# 單獨執行：powershell -ExecutionPolicy Bypass -File .\test-thumbnail.ps1
$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$sample = Join-Path $root 'samples\triangle.glb'

$script:failures = 0
function Assert-That([string]$Name, [bool]$Condition, [string]$Detail = '') {
    if ($Condition) {
        Write-Host "  通過  $Name"
    } else {
        Write-Host "  失敗  $Name  $Detail" -ForegroundColor Red
        $script:failures++
    }
}

Add-Type -AssemblyName System.Drawing
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;

public static class ImageStats
{
    // 回傳：寬、高、不透明像素數、外框左右上下、不透明像素的平均 R G B
    public static double[] Measure(string path)
    {
        using (var src = new Bitmap(path))
        using (var bmp = new Bitmap(src.Width, src.Height, PixelFormat.Format32bppArgb))
        {
            using (var g = Graphics.FromImage(bmp)) { g.DrawImage(src, 0, 0, src.Width, src.Height); }
            var data = bmp.LockBits(new Rectangle(0, 0, bmp.Width, bmp.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
            var bytes = new byte[data.Stride * data.Height];
            Marshal.Copy(data.Scan0, bytes, 0, bytes.Length);
            bmp.UnlockBits(data);
            int minX = int.MaxValue, maxX = -1, minY = int.MaxValue, maxY = -1;
            long count = 0, sr = 0, sg = 0, sb = 0;
            for (int y = 0; y < bmp.Height; y++)
                for (int x = 0; x < bmp.Width; x++)
                {
                    int o = y * data.Stride + x * 4;
                    int a = bytes[o + 3];
                    if (a > 8)
                    {
                        if (x < minX) minX = x; if (x > maxX) maxX = x;
                        if (y < minY) minY = y; if (y > maxY) maxY = y;
                    }
                    if (a >= 250) { count++; sb += bytes[o]; sg += bytes[o + 1]; sr += bytes[o + 2]; }
                }
            double n = count == 0 ? 1 : count;
            return new double[] { bmp.Width, bmp.Height, count, minX, maxX, minY, maxY, sr / n, sg / n, sb / n };
        }
    }
}
'@

$work = Join-Path ([IO.Path]::GetTempPath()) ('glbthumb-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$testRoot = 'HKCU:\Software\GlbViewerTest\ThumbClasses'
$installDir = Join-Path $work 'install'

# 在子程序裡載入元件並渲染，載入的檔案才不會被測試程序鎖住
$helper = Join-Path $work 'render-helper.ps1'
Set-Content -LiteralPath $helper -Encoding UTF8 -Value @'
param($Dll, $Glb, $Png, $Size, $Budget)
$ErrorActionPreference = 'Stop'
[Reflection.Assembly]::LoadFrom($Dll) | Out-Null
try {
    [GlbViewer.Thumbnail.GlbRenderer]::RenderToPng($Glb, $Png, [int]$Size, [int]$Budget)
} catch {
    Write-Output ('ERR:' + $_.Exception.GetBaseException().Message)
    exit 3
}
'@

# 直接驅動縮圖提供者的 COM 介面：餵它一個 IStream，取回 HBITMAP，就是 Explorer 會走的路徑
$providerHelper = Join-Path $work 'provider-helper.ps1'
Set-Content -LiteralPath $providerHelper -Encoding UTF8 -Value @'
param($Dll, $Glb, $Size)
$ErrorActionPreference = 'Stop'
[Reflection.Assembly]::LoadFrom($Dll) | Out-Null
Add-Type -ReferencedAssemblies System.Drawing, $Dll -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class TestStream
{
    [DllImport("ole32.dll")] static extern int CreateStreamOnHGlobal(IntPtr hGlobal, bool deleteOnRelease, out IStream stream);
    public static void Init(GlbViewer.Thumbnail.IInitializeWithStream provider, byte[] data)
    {
        IStream s;
        CreateStreamOnHGlobal(IntPtr.Zero, true, out s);
        s.Write(data, data.Length, IntPtr.Zero);
        s.Seek(0, 0, IntPtr.Zero);
        provider.Initialize(s, 0);
    }
}
"@
try {
    $provider = New-Object GlbViewer.Thumbnail.GlbThumbnailProvider
    [TestStream]::Init($provider, [IO.File]::ReadAllBytes($Glb))
    $handle = [IntPtr]::Zero
    $alpha = [GlbViewer.Thumbnail.WTS_ALPHATYPE]0
    $provider.GetThumbnail([uint32]$Size, [ref]$handle, [ref]$alpha)
    $bmp = [Drawing.Bitmap]::FromHbitmap($handle)
    $filled = 0
    for ($y = 0; $y -lt $bmp.Height; $y += 4) { for ($x = 0; $x -lt $bmp.Width; $x += 4) { if ($bmp.GetPixel($x, $y).ToArgb() -band 0xFFFFFF) { $filled++ } } }
    Write-Output ('OK {0} {1} {2} {3}' -f $bmp.Width, $bmp.Height, $filled, [int]$alpha)
} catch {
    Write-Output ('ERR:' + $_.Exception.GetBaseException().Message)
    exit 3
}
'@

function Invoke-Provider([string]$Glb, [int]$Size = 64) {
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $providerHelper $script:dll $Glb $Size
    [pscustomobject]@{ Ok = ($LASTEXITCODE -eq 0); Output = ($out | Out-String).Trim() }
}

function Invoke-Render([string]$Glb, [int]$Size = 128, [int]$BudgetMs = 4000) {
    $png = Join-Path $work ([guid]::NewGuid().ToString('N') + '.png')
    $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper $script:dll $Glb $png $Size $BudgetMs
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $png)
    $stats = if ($ok) { [ImageStats]::Measure($png) } else { $null }
    [pscustomobject]@{ Ok = $ok; Png = $png; Stats = $stats; Output = ($out | Out-String) }
}

# ---- 用 PowerShell 現場組出最小的 GLB，測試不需要提交二進位樣本 ----
function New-Bytes([string]$Kind, [double[]]$Values) {
    $ms = New-Object IO.MemoryStream
    foreach ($v in $Values) {
        if ($Kind -eq 'f32') { $b = [BitConverter]::GetBytes([single]$v) }
        elseif ($Kind -eq 'u32') { $b = [BitConverter]::GetBytes([uint32]$v) }
        elseif ($Kind -eq 'u16') { $b = [BitConverter]::GetBytes([uint16]$v) }
        elseif ($Kind -eq 'i16') { $b = [BitConverter]::GetBytes([int16]$v) }
        else { $b = [byte[]]@([byte]$v) }
        $ms.Write($b, 0, $b.Length)
    }
    , $ms.ToArray()
}

function New-Builder {
    [pscustomobject]@{ Bin = (New-Object IO.MemoryStream); Views = (New-Object Collections.ArrayList); Accessors = (New-Object Collections.ArrayList) }
}

function Add-View($Builder, [byte[]]$Bytes) {
    while ($Builder.Bin.Length % 4 -ne 0) { $Builder.Bin.WriteByte(0) }
    $offset = [int]$Builder.Bin.Length
    $Builder.Bin.Write($Bytes, 0, $Bytes.Length)
    [void]$Builder.Views.Add(@{ buffer = 0; byteOffset = $offset; byteLength = $Bytes.Length })
    $Builder.Views.Count - 1
}

function Add-Accessor($Builder, [byte[]]$Bytes, [int]$ComponentType, [string]$Type, [int]$Count, [switch]$Normalized) {
    $view = Add-View $Builder $Bytes
    $a = @{ bufferView = $view; componentType = $ComponentType; count = $Count; type = $Type }
    if ($Normalized) { $a.normalized = $true }
    [void]$Builder.Accessors.Add($a)
    $Builder.Accessors.Count - 1
}

function Save-Glb($Builder, [hashtable]$Doc, [string]$Path) {
    $Doc.asset = @{ version = '2.0' }
    if (-not $Doc.ContainsKey('buffers')) { $Doc.buffers = @(@{ byteLength = [int]$Builder.Bin.Length }) }
    $Doc.bufferViews = $Builder.Views.ToArray()
    if (($Builder.Accessors.Count -gt 0) -and -not $Doc.ContainsKey('accessors')) { $Doc.accessors = $Builder.Accessors.ToArray() }
    $json = [Text.Encoding]::UTF8.GetBytes(($Doc | ConvertTo-Json -Depth 20 -Compress))
    $jsonPad = (4 - $json.Length % 4) % 4
    $bin = $Builder.Bin.ToArray()
    $binPad = (4 - $bin.Length % 4) % 4
    $ms = New-Object IO.MemoryStream
    $w = New-Object IO.BinaryWriter $ms
    $w.Write([uint32]0x46546C67); $w.Write([uint32]2)
    $w.Write([uint32](12 + 8 + $json.Length + $jsonPad + 8 + $bin.Length + $binPad))
    $w.Write([uint32]($json.Length + $jsonPad)); $w.Write([uint32]0x4E4F534A)
    $w.Write($json); for ($k = 0; $k -lt $jsonPad; $k++) { $w.Write([byte]0x20) }
    $w.Write([uint32]($bin.Length + $binPad)); $w.Write([uint32]0x004E4942)
    $w.Write($bin); for ($k = 0; $k -lt $binPad; $k++) { $w.Write([byte]0) }
    $w.Flush()
    [IO.File]::WriteAllBytes($Path, $ms.ToArray())
}

# 一個三角形的場景。$Attributes 可以追加屬性，$Nodes 與 $Doc 可以覆蓋預設的節點與其他欄位。
function New-TriangleGlb([string]$Name, [hashtable]$Material = $null, [hashtable]$Attributes = @{}, $Builder = $null, $Nodes = $null, [hashtable]$Doc = @{}, [string]$PositionKind = 'f32', [double[]]$Positions = @(0, 0, 0, 1, 0, 0, 0, 1, 0)) {
    if (-not $Builder) { $Builder = New-Builder }
    $ctype = if ($PositionKind -eq 'i16') { 5122 } else { 5126 }
    $pos = Add-Accessor $Builder (New-Bytes $PositionKind $Positions) $ctype 'VEC3' 3
    $attrs = @{ POSITION = $pos }
    foreach ($k in $Attributes.Keys) { $attrs[$k] = $Attributes[$k] }
    $prim = @{ attributes = $attrs }
    $d = @{ scene = 0; meshes = @(@{ primitives = @($prim) }) }
    if ($Material) { $prim.material = 0; $d.materials = @($Material) }
    if (-not $Nodes) { $Nodes = @(@{ mesh = 0 }) }
    $d.nodes = $Nodes
    $d.scenes = @(@{ nodes = @(0) })
    foreach ($k in $Doc.Keys) { $d[$k] = $Doc[$k] }
    $path = Join-Path $work "$Name.glb"
    Save-Glb $Builder $d $path
    $path
}

function New-PngBytes([int]$R, [int]$G, [int]$B) {
    $bmp = New-Object Drawing.Bitmap 4, 4
    for ($x = 0; $x -lt 4; $x++) { for ($y = 0; $y -lt 4; $y++) { $bmp.SetPixel($x, $y, [Drawing.Color]::FromArgb($R, $G, $B)) } }
    $ms = New-Object IO.MemoryStream
    $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    , $ms.ToArray()
}

function Test-Dominant($Stats, [string]$Channel) {
    $r = $Stats[7]; $g = $Stats[8]; $b = $Stats[9]
    switch ($Channel) {
        'R' { ($r -gt 2 * $g) -and ($r -gt 2 * $b) }
        'G' { ($g -gt 2 * $r) -and ($g -gt 2 * $b) }
        'B' { ($b -gt 2 * $r) -and ($b -gt 2 * $g) }
    }
}

$common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')

function Invoke-Install([string]$Dir, [string]$Reg, [string[]]$Extra = @()) {
    & powershell.exe @common (Join-Path $root 'install.ps1') -InstallDir $Dir -ClassesRoot $Reg -NoOpenSettings @Extra | Out-Null
    $LASTEXITCODE
}

function Invoke-Uninstall([string]$Dir, [string]$Reg) {
    & powershell.exe @common (Join-Path $root 'uninstall.ps1') -InstallDir $Dir -ClassesRoot $Reg | Out-Null
    $LASTEXITCODE
}

try {
    Write-Host '縮圖元件的安裝'
    $common = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File')
    $opts = @('-InstallDir', $installDir, '-ClassesRoot', $testRoot)
    & powershell.exe @common (Join-Path $root 'install.ps1') @opts -NoOpenSettings | Out-Null
    Assert-That '安裝成功結束' ($LASTEXITCODE -eq 0)
    $script:dll = (Get-ChildItem -LiteralPath $installDir -Filter 'GlbThumb_*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    Assert-That '安裝後有縮圖元件' ([bool]$script:dll)

    if ($script:dll) {
        Write-Host '渲染'
        $r = Invoke-Render $sample 128
        Assert-That '範例三角形可以渲染' $r.Ok $r.Output
        if ($r.Ok) {
            $s = $r.Stats
            Assert-That '輸出是正方形且尺寸正確' (($s[0] -eq 128) -and ($s[1] -eq 128))
            Assert-That '有畫出內容' ($s[2] -gt 500) "$($s[2])"
            $cx = ($s[3] + $s[4]) / 2; $cy = ($s[5] + $s[6]) / 2
            Assert-That '內容置中' (([math]::Abs($cx - 63.5) -le 3) -and ([math]::Abs($cy - 63.5) -le 3)) "$cx,$cy"
            $extent = [math]::Max($s[4] - $s[3], $s[6] - $s[5]) + 1
            Assert-That '內容縮放到幾乎填滿並留有邊距' (($extent -ge 100) -and ($extent -le 118)) "$extent"
        }

        Write-Host '材質與場景'
        $red = New-TriangleGlb 'red' @{ pbrMetallicRoughness = @{ baseColorFactor = @(1, 0, 0, 1) } }
        $r = Invoke-Render $red
        Assert-That '基本色係數會反映在顏色上' ($r.Ok -and (Test-Dominant $r.Stats 'R')) "$($r.Output) $($r.Stats[7..9] -join ',')"

        # 兩個節點共用同一個網格，分別平移到左右兩邊，放在有縮放的父節點底下
        $b = New-Builder
        $wide = New-TriangleGlb 'wide' -Builder $b -Nodes @(
            @{ children = @(1, 2); scale = @(1, 1, 1) },
            @{ mesh = 0; translation = @(-5, 0, 0) },
            @{ mesh = 0; translation = @(5, 0, 0) })
        $r = Invoke-Render $wide
        if ($r.Ok) {
            $w = $r.Stats[4] - $r.Stats[3] + 1; $h = $r.Stats[6] - $r.Stats[5] + 1
            Assert-That '節點階層與平移會被套用' (($w / $h) -gt 2) "$w x $h"
        } else { Assert-That '節點階層與平移會被套用' $false $r.Output }

        # 量化：位置用非正規化的 16 位元整數，靠節點縮放還原，結果要和浮點版本一致
        $plain = Invoke-Render (New-TriangleGlb 'plain')
        $quant = Invoke-Render (New-TriangleGlb 'quant' -PositionKind 'i16' -Positions @(0, 0, 0, 100, 0, 0, 0, 100, 0) -Nodes @(@{ mesh = 0; scale = @(0.01, 0.01, 0.01) }))
        if ($plain.Ok -and $quant.Ok) {
            $diff = 0..6 | ForEach-Object { [math]::Abs($plain.Stats[$_] - $quant.Stats[$_]) } | Measure-Object -Maximum
            Assert-That '量化的位置與浮點版本畫出相同的外形' ($diff.Maximum -le 1) "$($diff.Maximum)"
        } else { Assert-That '量化的位置與浮點版本畫出相同的外形' $false ($plain.Output + $quant.Output) }

        $b = New-Builder
        $colors = Add-Accessor $b (New-Bytes 'f32' @(0, 0, 1, 1, 0, 0, 1, 1, 0, 0, 1, 1)) 5126 'VEC4' 3
        $vc = Invoke-Render (New-TriangleGlb 'vcolor' -Builder $b -Attributes @{ COLOR_0 = $colors })
        Assert-That '頂點色會反映在顏色上' ($vc.Ok -and (Test-Dominant $vc.Stats 'B')) "$($vc.Output) $($vc.Stats[7..9] -join ',')"

        $b = New-Builder
        $uv = Add-Accessor $b (New-Bytes 'f32' @(0, 0, 1, 0, 0, 1)) 5126 'VEC2' 3
        $image = Add-View $b (New-PngBytes 0 200 0)
        $tex = New-TriangleGlb 'texture' @{ pbrMetallicRoughness = @{ baseColorTexture = @{ index = 0 } } } -Builder $b -Attributes @{ TEXCOORD_0 = $uv } -Doc @{
            textures = @(@{ source = 0 }); images = @(@{ bufferView = $image; mimeType = 'image/png' }) }
        $r = Invoke-Render $tex
        Assert-That '基本色貼圖會反映在顏色上' ($r.Ok -and (Test-Dominant $r.Stats 'G')) "$($r.Output) $($r.Stats[7..9] -join ',')"

        # 骨架：關節在預設姿勢下沿 X 放大四倍，蒙皮後的三角形要變寬
        $b = New-Builder
        $joints = Add-Accessor $b (New-Bytes 'u8' @(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)) 5121 'VEC4' 3
        $weights = Add-Accessor $b (New-Bytes 'f32' @(1, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0)) 5126 'VEC4' 3
        $skinned = New-TriangleGlb 'skinned' -Builder $b -Attributes @{ JOINTS_0 = $joints; WEIGHTS_0 = $weights } -Nodes @(
            @{ mesh = 0; skin = 0 }, @{ scale = @(4, 1, 1) }) -Doc @{ skins = @(@{ joints = @(1) }); scenes = @(@{ nodes = @(0, 1) }) }
        $r = Invoke-Render $skinned
        if ($plain.Ok -and $r.Ok) {
            $plainRatio = ($plain.Stats[4] - $plain.Stats[3] + 1) / ($plain.Stats[6] - $plain.Stats[5] + 1)
            $skinRatio = ($r.Stats[4] - $r.Stats[3] + 1) / ($r.Stats[6] - $r.Stats[5] + 1)
            Assert-That '蒙皮會套用關節的預設姿勢' ($skinRatio -gt 1.5 * $plainRatio) "$skinRatio vs $plainRatio"
        } else { Assert-That '蒙皮會套用關節的預設姿勢' $false $r.Output }

        Write-Host '不支援與保護上限'
        $draco = New-TriangleGlb 'draco' -Doc @{ meshes = @(@{ primitives = @(@{ attributes = @{ POSITION = 0 }; extensions = @{ KHR_draco_mesh_compression = @{ bufferView = 0; attributes = @{ POSITION = 0 } } } }) }) }
        Assert-That 'Draco 壓縮的模型回報失敗' (-not (Invoke-Render $draco).Ok)
        foreach ($ext in 'EXT_meshopt_compression', 'KHR_texture_basisu') {
            $f = New-TriangleGlb "req-$ext" -Doc @{ extensionsRequired = @($ext); extensionsUsed = @($ext) }
            Assert-That "必須使用 $ext 的模型回報失敗" (-not (Invoke-Render $f).Ok)
        }
        $external = New-TriangleGlb 'external' -Doc @{ buffers = @(@{ byteLength = 36; uri = 'other.bin' }) }
        Assert-That '依賴外部緩衝檔的模型回報失敗' (-not (Invoke-Render $external).Ok)
        $none = New-TriangleGlb 'nomesh' -Doc @{ meshes = @(@{ primitives = @() }) }
        Assert-That '沒有可顯示網格的模型回報失敗' (-not (Invoke-Render $none).Ok)

        $garbage = Join-Path $work 'garbage.glb'
        [IO.File]::WriteAllBytes($garbage, [byte[]](1..200 | ForEach-Object { $_ % 251 }))
        Assert-That '不是 GLB 的檔案回報失敗' (-not (Invoke-Render $garbage).Ok)
        $cut = Join-Path $work 'cut.glb'
        $all = [IO.File]::ReadAllBytes($red)
        [IO.File]::WriteAllBytes($cut, $all[0..($all.Length / 2)])
        Assert-That '被截斷的 GLB 回報失敗' (-not (Invoke-Render $cut).Ok)

        $big = Join-Path $work 'big.glb'
        $fs = [IO.File]::Create($big); $fs.SetLength(101MB); $fs.Dispose()
        Assert-That '超過 100 MB 的檔案回報失敗' (-not (Invoke-Render $big).Ok)
        Remove-Item -LiteralPath $big -Force

        Assert-That '超過時間預算時回報失敗' (-not (Invoke-Render $red 128 0).Ok)

        # 惡意或損毀的檔案：必須由元件自己丟出例外並回報失敗，不能讓程序崩潰或配置巨量記憶體
        $deep = Join-Path $work 'deep.glb'
        $jsonBytes = [Text.Encoding]::UTF8.GetBytes(('[' * 200000) + (']' * 200000))
        $jsonPad = (4 - $jsonBytes.Length % 4) % 4
        $ms = New-Object IO.MemoryStream
        $bw = New-Object IO.BinaryWriter $ms
        $bw.Write([uint32]0x46546C67); $bw.Write([uint32]2); $bw.Write([uint32](12 + 8 + $jsonBytes.Length + $jsonPad))
        $bw.Write([uint32]($jsonBytes.Length + $jsonPad)); $bw.Write([uint32]0x4E4F534A)
        $bw.Write($jsonBytes); for ($k = 0; $k -lt $jsonPad; $k++) { $bw.Write([byte]0x20) }
        $bw.Flush()
        [IO.File]::WriteAllBytes($deep, $ms.ToArray())
        $r = Invoke-Render $deep
        Assert-That 'JSON 巢狀過深時由元件回報失敗而不是崩潰' ((-not $r.Ok) -and ($r.Output -like 'ERR:*')) $r.Output
        $hugeCount = New-TriangleGlb 'hugecount' -Doc @{ accessors = @(@{ bufferView = 0; componentType = 5126; count = 100000000; type = 'VEC3' }) }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-Render $hugeCount
        Assert-That '存取器數量大得離譜時很快就由元件回報失敗' ((-not $r.Ok) -and ($r.Output -like 'ERR:*') -and ($clock.Elapsed.TotalSeconds -lt 4)) "$($r.Output) $($clock.Elapsed.TotalSeconds)"

        Write-Host '縮圖提供者介面'
        $p = Invoke-Provider $sample 64
        $parts = $p.Output -split '\s+'
        Assert-That '提供者能從串流讀取並回傳點陣圖' ($p.Ok -and $parts[0] -eq 'OK' -and [int]$parts[1] -eq 64 -and [int]$parts[2] -eq 64) $p.Output
        Assert-That '點陣圖有畫出內容' ($p.Ok -and [int]$parts[3] -gt 20) $p.Output
        Assert-That '點陣圖宣告為含透明度' ($p.Ok -and [int]$parts[4] -eq 2) $p.Output
        Assert-That '提供者遇到不支援的檔案會失敗' (-not (Invoke-Provider $garbage 64).Ok)
    }

    Write-Host '登錄與安裝流程'
    $clsid = '{6F1C2D8B-3A47-4E5B-9C0D-2B7A5E4F1D93}'
    $handlerId = '{E357FCCD-A995-4576-B01F-234630154E96}'
    $foreignClsid = '{AAAAAAAA-0000-0000-0000-000000000000}'
    $inproc = "$testRoot\CLSID\$clsid\InprocServer32"
    $reg = if (Test-Path $inproc) { Get-ItemProperty $inproc } else { $null }
    Assert-That '縮圖元件已登錄為 COM 類別' ($reg -and $reg.'(default)' -eq 'mscoree.dll' -and $reg.Class -eq 'GlbViewer.Thumbnail.GlbThumbnailProvider')
    Assert-That '登錄的 CodeBase 指向安裝資料夾裡的元件' ($reg -and $script:dll -and $reg.CodeBase -eq ([Uri]$script:dll).AbsoluteUri)
    $handler = "$testRoot\.glb\ShellEx\$handlerId"
    Assert-That '.glb 的縮圖提供者指向本程式' ((Test-Path $handler) -and ((Get-ItemProperty $handler).'(default)' -eq $clsid))
    $iconKey = "$testRoot\GlbViewer.File\DefaultIcon"
    $expectedIcon = '"{0}",0' -f (Join-Path $installDir 'GlbViewer.ico')
    Assert-That '檔案類型圖示指向安裝資料夾的圖示檔' ((Test-Path $iconKey) -and ((Get-ItemProperty $iconKey).'(default)' -eq $expectedIcon))
    Assert-That '圖示檔已安裝' (Test-Path -LiteralPath (Join-Path $installDir 'GlbViewer.ico'))

    # 舊版本的元件：沒被鎖住的會被清掉，被鎖住的留著但不能讓安裝失敗
    Set-Content -LiteralPath (Join-Path $installDir 'GlbThumb_0_0_1.dll') -Value 'old'
    $lockedOld = Join-Path $installDir 'GlbThumb_0_0_2.dll'
    Set-Content -LiteralPath $lockedOld -Value 'old'
    $lock = [IO.File]::Open($lockedOld, 'Open', 'Read', 'Read')
    try { $code = Invoke-Install $installDir $testRoot } finally { $lock.Dispose() }
    Assert-That '重複安裝成功，舊版元件被鎖住也不會失敗' ($code -eq 0)
    Assert-That '重複安裝會清掉沒被鎖住的舊版元件' (-not (Test-Path -LiteralPath (Join-Path $installDir 'GlbThumb_0_0_1.dll')))
    Assert-That '被鎖住的舊版元件留著' (Test-Path -LiteralPath $lockedOld)
    Remove-Item -LiteralPath $lockedOld -Force
    Assert-That '重複安裝後登錄仍指向目前的元件' ((Get-ItemProperty $inproc).CodeBase -eq ([Uri]$script:dll).AbsoluteUri)

    # .glb 已有別人的縮圖元件：預設不蓋掉，加 -ForceThumbnail 才改用本程式的
    $foreignRoot = 'HKCU:\Software\GlbViewerTest\ForeignClasses'
    $foreignDir = Join-Path $work 'foreign'
    New-Item -Path "$foreignRoot\.glb\ShellEx\$handlerId" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$foreignRoot\.glb\ShellEx\$handlerId" -Name '(default)' -Value $foreignClsid
    $code = Invoke-Install $foreignDir $foreignRoot
    Assert-That '有別人的縮圖元件時安裝仍然成功' ($code -eq 0 -and (Test-Path -LiteralPath (Join-Path $foreignDir 'GlbViewer.vbs')))
    Assert-That '有別人的縮圖元件時不會蓋掉' ((Get-ItemProperty "$foreignRoot\.glb\ShellEx\$handlerId").'(default)' -eq $foreignClsid)
    Assert-That '有別人的縮圖元件時不註冊本程式的元件' (-not (Test-Path "$foreignRoot\CLSID\$clsid"))
    $code = Invoke-Install $foreignDir $foreignRoot @('-ForceThumbnail')
    Assert-That '加 -ForceThumbnail 會改用本程式的縮圖元件' ($code -eq 0 -and ((Get-ItemProperty "$foreignRoot\.glb\ShellEx\$handlerId").'(default)' -eq $clsid))
    $null = Invoke-Uninstall $foreignDir $foreignRoot
    Assert-That '強制改用本程式的縮圖後移除，會還原原本的縮圖元件' ((Test-Path "$foreignRoot\.glb\ShellEx\$handlerId") -and ((Get-ItemProperty "$foreignRoot\.glb\ShellEx\$handlerId").'(default)' -eq $foreignClsid) -and -not (Test-Path "$foreignRoot\CLSID\$clsid"))
    New-Item -Path "$foreignRoot\.glb\ShellEx\$handlerId" -Force | Out-Null
    Set-ItemProperty -LiteralPath "$foreignRoot\.glb\ShellEx\$handlerId" -Name '(default)' -Value $foreignClsid
    $null = Invoke-Uninstall $foreignDir $foreignRoot
    Assert-That '移除時不會動到別人的縮圖元件' ((Test-Path "$foreignRoot\.glb\ShellEx\$handlerId") -and ((Get-ItemProperty "$foreignRoot\.glb\ShellEx\$handlerId").'(default)' -eq $foreignClsid))

    # 更新按鈕走的 -UpdateOnly：沒有關聯設定的安裝也能補上縮圖，但不會憑空建立程式關聯
    $updateRoot = 'HKCU:\Software\GlbViewerTest\UpdateClasses'
    $updateDir = Join-Path $work 'update'
    $code = Invoke-Install $updateDir $updateRoot @('-UpdateOnly')
    Assert-That '-UpdateOnly 成功' ($code -eq 0)
    Assert-That '-UpdateOnly 會補上縮圖元件' ((Get-ChildItem -LiteralPath $updateDir -Filter 'GlbThumb_*.dll').Count -eq 1 -and (Test-Path "$updateRoot\.glb\ShellEx\$handlerId"))
    Assert-That '-UpdateOnly 不會建立程式關聯' (-not (Test-Path "$updateRoot\GlbViewer.File") -and -not (Test-Path "$updateRoot\.glb\OpenWithProgids"))
    $null = Invoke-Install $updateDir $updateRoot
    Remove-Item -LiteralPath "$updateRoot\GlbViewer.File\DefaultIcon" -Force
    $code = Invoke-Install $updateDir $updateRoot @('-UpdateOnly')
    Assert-That '-UpdateOnly 對舊安裝會補上檔案類型圖示' ($code -eq 0 -and (Test-Path "$updateRoot\GlbViewer.File\DefaultIcon"))
    Assert-That '-UpdateOnly 不會動到開啟指令' ((Get-ItemProperty "$updateRoot\GlbViewer.File\shell\open\command").'(default)' -like "*$updateDir\GlbViewer.vbs*")
    $null = Invoke-Uninstall $updateDir $updateRoot

    # 使用者可能在 PowerShell 7 貼上安裝指令，編譯器要照樣找得到
    $pwsh = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if ($pwsh) {
        $pwshRoot = 'HKCU:\Software\GlbViewerTest\PwshClasses'
        $pwshDir = Join-Path $work 'pwsh'
        & $pwsh.Source -NoProfile -File (Join-Path $root 'install.ps1') -InstallDir $pwshDir -ClassesRoot $pwshRoot -NoOpenSettings | Out-Null
        Assert-That '在 PowerShell 7 安裝也會編譯並登錄縮圖元件' (($LASTEXITCODE -eq 0) -and (@(Get-ChildItem -LiteralPath $pwshDir -Filter 'GlbThumb_*.dll' -ErrorAction SilentlyContinue).Count -eq 1) -and (Test-Path "$pwshRoot\.glb\ShellEx\$handlerId"))
        $null = Invoke-Uninstall $pwshDir $pwshRoot
    }

    Write-Host '移除'
    $code = Invoke-Uninstall $installDir $testRoot
    Assert-That '移除成功結束' ($code -eq 0)
    Assert-That '移除後安裝資料夾消失' (-not (Test-Path -LiteralPath $installDir))
    Assert-That '移除後縮圖元件的登錄消失' (-not (Test-Path "$testRoot\CLSID\$clsid"))
    Assert-That '移除後 .glb 的縮圖提供者消失' (-not (Test-Path $handler))
    Assert-That '移除後檔案類型圖示消失' (-not (Test-Path "$testRoot\GlbViewer.File"))

    # 縮圖元件正被 Explorer 使用（檔案被鎖住）時，移除仍要成功，只留下那個檔案
    $lockRoot = 'HKCU:\Software\GlbViewerTest\LockClasses'
    $lockDir = Join-Path $work 'lockdir'
    $null = Invoke-Install $lockDir $lockRoot
    $lockedDll = (Get-ChildItem -LiteralPath $lockDir -Filter 'GlbThumb_*.dll' | Select-Object -First 1).FullName
    $lock = [IO.File]::Open($lockedDll, 'Open', 'Read', 'Read')
    try { $code = Invoke-Uninstall $lockDir $lockRoot } finally { $lock.Dispose() }
    Assert-That '元件被鎖住時移除仍成功結束' ($code -eq 0)
    $remaining = @(Get-ChildItem -LiteralPath $lockDir -Recurse -File -ErrorAction SilentlyContinue)
    Assert-That '元件被鎖住時只留下元件檔' (($remaining.Count -eq 1) -and ($remaining[0].Name -like 'GlbThumb_*.dll')) "$($remaining.Name -join ',')"
    Assert-That '元件被鎖住時登錄項目仍會移除' (-not (Test-Path "$lockRoot\CLSID\$clsid") -and -not (Test-Path "$lockRoot\GlbViewer.File"))
    $code = Invoke-Uninstall $lockDir $lockRoot
    Assert-That '元件解除鎖定後再執行一次移除，可以清掉殘留的元件' (($code -eq 0) -and -not (Test-Path -LiteralPath $lockDir))
} finally {
    Remove-Item -LiteralPath 'HKCU:\Software\GlbViewerTest' -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:failures -gt 0) {
    Write-Host "`n縮圖測試共 $($script:failures) 項失敗" -ForegroundColor Red
    exit 1
}
Write-Host "`n縮圖測試全部通過"
