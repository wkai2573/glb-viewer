// GLB 縮圖元件：Explorer 的縮圖提供者，以及它背後的軟體光柵化渲染器。
// 安裝時由 install.ps1 以系統內建的 csc.exe 編譯（C# 5），所以這裡不能用較新的語法。
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
using System.Text;

namespace GlbViewer.Thumbnail
{
    // 模型用了本元件不支援的格式，例如 Draco、Meshopt、外部檔案
    public class UnsupportedGlbException : Exception
    {
        public UnsupportedGlbException(string message) : base(message) { }
    }

    public class RenderTimeoutException : Exception
    {
        public RenderTimeoutException() : base("渲染超過時間預算。") { }
    }

    // 公開的渲染介面：輸入 .glb，輸出縮圖
    public static class GlbRenderer
    {
        public const long MaxFileBytes = 100L * 1024 * 1024;
        public const int DefaultBudgetMs = 4000;

        // 回傳 size x size 的預乘透明度 BGRA 像素
        public static byte[] RenderBgra(byte[] glb, int size, int timeBudgetMs)
        {
            if (glb == null) throw new ArgumentNullException("glb");
            if (glb.LongLength > MaxFileBytes) throw new UnsupportedGlbException("檔案超過大小上限。");
            if (size < 16) size = 16;
            if (size > 1024) size = 1024;
            var clock = new Budget(timeBudgetMs);
            var model = new GlbModel(glb, clock);
            var parts = model.BuildParts();
            clock.Check();
            return new Rasterizer(parts, size, clock).Render();
        }

        public static void RenderToPng(string glbPath, string pngPath, int size, int timeBudgetMs)
        {
            var info = new FileInfo(glbPath);
            if (info.Length > MaxFileBytes) throw new UnsupportedGlbException("檔案超過大小上限。");
            byte[] bgra = RenderBgra(File.ReadAllBytes(glbPath), size, timeBudgetMs);
            int n = (int)Math.Sqrt(bgra.Length / 4);
            using (var bmp = new Bitmap(n, n, PixelFormat.Format32bppPArgb))
            {
                var data = bmp.LockBits(new Rectangle(0, 0, n, n), ImageLockMode.WriteOnly, PixelFormat.Format32bppPArgb);
                try { Marshal.Copy(bgra, 0, data.Scan0, bgra.Length); }
                finally { bmp.UnlockBits(data); }
                bmp.Save(pngPath, ImageFormat.Png);
            }
        }
    }

    internal sealed class Budget
    {
        readonly Stopwatch watch = Stopwatch.StartNew();
        readonly int limitMs;
        public Budget(int limitMs) { this.limitMs = limitMs; }
        public void Check()
        {
            if (watch.ElapsedMilliseconds >= limitMs) throw new RenderTimeoutException();
        }
    }

    // ---------------------------------------------------------------- JSON

    internal sealed class JsonReader
    {
        // 正常的 glTF 巢狀不超過十來層。遞迴沒有上限的話，惡意檔案會讓堆疊溢位，整個程序直接結束。
        const int MaxDepth = 64;

        readonly string s;
        int i;
        int depth;
        JsonReader(string text) { s = text; }

        public static object Parse(string text)
        {
            var r = new JsonReader(text);
            object v = r.ReadValue();
            r.SkipWs();
            if (r.i != r.s.Length) throw new InvalidDataException("JSON 結尾有多餘內容。");
            return v;
        }

        void SkipWs()
        {
            while (i < s.Length && (s[i] == ' ' || s[i] == '\t' || s[i] == '\r' || s[i] == '\n')) i++;
        }

        object ReadValue()
        {
            SkipWs();
            if (i >= s.Length) throw new InvalidDataException("JSON 提前結束。");
            char c = s[i];
            if (c == '{' || c == '[')
            {
                if (++depth > MaxDepth) throw new InvalidDataException("JSON 巢狀過深。");
                try { return c == '{' ? ReadObject() : ReadArray(); }
                finally { depth--; }
            }
            if (c == '"') return ReadString();
            if (c == 't') { Expect("true"); return true; }
            if (c == 'f') { Expect("false"); return false; }
            if (c == 'n') { Expect("null"); return null; }
            return ReadNumber();
        }

        void Expect(string word)
        {
            if (string.CompareOrdinal(s, i, word, 0, word.Length) != 0) throw new InvalidDataException("JSON 格式錯誤。");
            i += word.Length;
        }

        object ReadObject()
        {
            var d = new Dictionary<string, object>();
            i++;
            SkipWs();
            if (i < s.Length && s[i] == '}') { i++; return d; }
            while (true)
            {
                SkipWs();
                if (i >= s.Length || s[i] != '"') throw new InvalidDataException("JSON 物件的鍵格式錯誤。");
                string key = ReadString();
                SkipWs();
                if (i >= s.Length || s[i] != ':') throw new InvalidDataException("JSON 物件缺少冒號。");
                i++;
                d[key] = ReadValue();
                SkipWs();
                if (i >= s.Length) throw new InvalidDataException("JSON 提前結束。");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == '}') { i++; return d; }
                throw new InvalidDataException("JSON 物件格式錯誤。");
            }
        }

        object ReadArray()
        {
            var list = new List<object>();
            i++;
            SkipWs();
            if (i < s.Length && s[i] == ']') { i++; return list; }
            while (true)
            {
                list.Add(ReadValue());
                SkipWs();
                if (i >= s.Length) throw new InvalidDataException("JSON 提前結束。");
                if (s[i] == ',') { i++; continue; }
                if (s[i] == ']') { i++; return list; }
                throw new InvalidDataException("JSON 陣列格式錯誤。");
            }
        }

        string ReadString()
        {
            i++;
            var sb = new StringBuilder();
            while (true)
            {
                if (i >= s.Length) throw new InvalidDataException("JSON 字串提前結束。");
                char c = s[i++];
                if (c == '"') return sb.ToString();
                if (c != '\\') { sb.Append(c); continue; }
                if (i >= s.Length) throw new InvalidDataException("JSON 字串提前結束。");
                char e = s[i++];
                switch (e)
                {
                    case 'n': sb.Append('\n'); break;
                    case 't': sb.Append('\t'); break;
                    case 'r': sb.Append('\r'); break;
                    case 'b': sb.Append('\b'); break;
                    case 'f': sb.Append('\f'); break;
                    case 'u':
                        if (i + 4 > s.Length) throw new InvalidDataException("JSON 跳脫序列錯誤。");
                        sb.Append((char)int.Parse(s.Substring(i, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture));
                        i += 4;
                        break;
                    default: sb.Append(e); break;
                }
            }
        }

        object ReadNumber()
        {
            int start = i;
            while (i < s.Length && "+-0123456789.eE".IndexOf(s[i]) >= 0) i++;
            if (i == start) throw new InvalidDataException("JSON 格式錯誤。");
            return double.Parse(s.Substring(start, i - start), NumberStyles.Float, CultureInfo.InvariantCulture);
        }
    }

    // 讀取 JSON 節點的小工具，缺少或型別不符一律回傳預設值
    internal static class J
    {
        public static object Get(object o, string key)
        {
            var d = o as Dictionary<string, object>;
            object v;
            if (d != null && d.TryGetValue(key, out v)) return v;
            return null;
        }
        public static object At(object list, int index)
        {
            var l = list as List<object>;
            if (l == null || index < 0 || index >= l.Count) return null;
            return l[index];
        }
        public static int Count(object list)
        {
            var l = list as List<object>;
            return l == null ? 0 : l.Count;
        }
        public static double Num(object o, string key, double def)
        {
            object v = Get(o, key);
            return v is double ? (double)v : def;
        }
        public static int Int(object o, string key, int def)
        {
            object v = Get(o, key);
            return v is double ? (int)(double)v : def;
        }
        public static bool Bool(object o, string key, bool def)
        {
            object v = Get(o, key);
            return v is bool ? (bool)v : def;
        }
        public static string Str(object o, string key)
        {
            return Get(o, key) as string;
        }
        public static double[] Nums(object o, string key, int length)
        {
            var l = Get(o, key) as List<object>;
            if (l == null || l.Count != length) return null;
            var r = new double[length];
            for (int k = 0; k < length; k++)
            {
                if (!(l[k] is double)) return null;
                r[k] = (double)l[k];
            }
            return r;
        }
    }

    // ---------------------------------------------------------------- 矩陣（欄優先，與 glTF 相同）

    internal static class Mat
    {
        public static double[] Identity()
        {
            var m = new double[16];
            m[0] = m[5] = m[10] = m[15] = 1;
            return m;
        }

        public static double[] Mul(double[] a, double[] b)
        {
            var r = new double[16];
            for (int c = 0; c < 4; c++)
                for (int row = 0; row < 4; row++)
                {
                    double sum = 0;
                    for (int k = 0; k < 4; k++) sum += a[k * 4 + row] * b[c * 4 + k];
                    r[c * 4 + row] = sum;
                }
            return r;
        }

        public static double[] FromTrs(double[] t, double[] q, double[] s)
        {
            double x = q[0], y = q[1], z = q[2], w = q[3];
            double n = Math.Sqrt(x * x + y * y + z * z + w * w);
            if (n > 0) { x /= n; y /= n; z /= n; w /= n; } else { x = y = z = 0; w = 1; }
            var m = Identity();
            m[0] = (1 - 2 * (y * y + z * z)) * s[0]; m[1] = (2 * (x * y + z * w)) * s[0]; m[2] = (2 * (x * z - y * w)) * s[0];
            m[4] = (2 * (x * y - z * w)) * s[1]; m[5] = (1 - 2 * (x * x + z * z)) * s[1]; m[6] = (2 * (y * z + x * w)) * s[1];
            m[8] = (2 * (x * z + y * w)) * s[2]; m[9] = (2 * (y * z - x * w)) * s[2]; m[10] = (1 - 2 * (x * x + y * y)) * s[2];
            m[12] = t[0]; m[13] = t[1]; m[14] = t[2];
            return m;
        }

        // 法線矩陣（反轉置矩陣乘上行列式），列優先的 3x3。方向正確，長度不保證，使用後要正規化。
        public static double[] CofactorOfLinear(double[] m)
        {
            double m00 = m[0], m10 = m[1], m20 = m[2];
            double m01 = m[4], m11 = m[5], m21 = m[6];
            double m02 = m[8], m12 = m[9], m22 = m[10];
            return new double[]
            {
                m11 * m22 - m12 * m21, m12 * m20 - m10 * m22, m10 * m21 - m11 * m20,
                m02 * m21 - m01 * m22, m00 * m22 - m02 * m20, m01 * m20 - m00 * m21,
                m01 * m12 - m02 * m11, m02 * m10 - m00 * m12, m00 * m11 - m01 * m10
            };
        }
    }

    // ---------------------------------------------------------------- 場景資料

    // 基本色貼圖，解碼後縮小到最長邊不超過 512，只保留取樣需要的像素
    internal sealed class Texture
    {
        public int W, H;
        public uint[] Px;                       // 0xAARRGGBB
        public int WrapS = 10497, WrapT = 10497;

        static double Wrap(double t, int mode)
        {
            if (mode == 33071) return Math.Min(Math.Max(t, 0), 1);
            if (mode == 33648)
            {
                double m = t - 2 * Math.Floor(t / 2);
                return m <= 1 ? m : 2 - m;
            }
            return t - Math.Floor(t);
        }

        public void Sample(double u, double v, out float r, out float g, out float b)
        {
            int x = (int)(Wrap(u, WrapS) * W);
            int y = (int)(Wrap(v, WrapT) * H);
            if (x >= W) x = W - 1;
            if (y >= H) y = H - 1;
            if (x < 0) x = 0;
            if (y < 0) y = 0;
            uint p = Px[y * W + x];
            r = ((p >> 16) & 0xFF) / 255f;
            g = ((p >> 8) & 0xFF) / 255f;
            b = (p & 0xFF) / 255f;
        }
    }

    internal sealed class Material
    {
        public float R = 1, G = 1, B = 1;
        public Texture Tex;
        public int UvSet;
    }

    // 展開到世界座標的一個圖元
    internal sealed class Part
    {
        public float[] P;     // xyz
        public float[] N;     // xyz，可為 null
        public float[] Uv;    // uv，可為 null
        public float[] C;     // 頂點色 rgb（sRGB），可為 null
        public int[] I;       // 三角形索引
        public Material Mat;
    }

    internal sealed class GlbModel
    {
        const int MaxDepth = 256;

        readonly object root;
        readonly byte[] glbBin;
        readonly Budget clock;
        readonly byte[][] buffers;
        readonly Dictionary<int, Material> materials = new Dictionary<int, Material>();
        readonly Dictionary<int, double[]> globals = new Dictionary<int, double[]>();
        readonly Dictionary<int, Texture> textures = new Dictionary<int, Texture>();
        readonly Dictionary<int, double[][]> skins = new Dictionary<int, double[][]>();
        int[] parentOf;

        public GlbModel(byte[] data, Budget clock)
        {
            this.clock = clock;
            if (data.Length < 20) throw new InvalidDataException("不是有效的 GLB。");
            if (BitConverter.ToUInt32(data, 0) != 0x46546C67u) throw new InvalidDataException("不是 GLB 檔。");
            if (BitConverter.ToUInt32(data, 4) != 2u) throw new UnsupportedGlbException("只支援 glTF 2.0。");
            long total = Math.Min((long)BitConverter.ToUInt32(data, 8), (long)data.Length);
            long pos = 12;
            string json = null;
            while (pos + 8 <= total)
            {
                long len = BitConverter.ToUInt32(data, (int)pos);
                uint type = BitConverter.ToUInt32(data, (int)pos + 4);
                pos += 8;
                if (pos + len > total) throw new InvalidDataException("GLB 區塊超出檔案範圍。");
                if (type == 0x4E4F534Au && json == null)
                {
                    json = Encoding.UTF8.GetString(data, (int)pos, (int)len);
                }
                else if (type == 0x004E4942u && glbBin == null)
                {
                    glbBin = new byte[len];
                    Buffer.BlockCopy(data, (int)pos, glbBin, 0, (int)len);
                }
                pos += (len + 3) & ~3L;
            }
            if (json == null) throw new InvalidDataException("GLB 缺少 JSON 區塊。");
            root = JsonReader.Parse(json);

            var required = J.Get(root, "extensionsRequired") as List<object>;
            if (required != null)
            {
                foreach (object e in required)
                {
                    string name = e as string;
                    if (name == "KHR_draco_mesh_compression" || name == "EXT_meshopt_compression" || name == "KHR_texture_basisu")
                        throw new UnsupportedGlbException("不支援 " + name + "。");
                }
            }
            buffers = new byte[J.Count(J.Get(root, "buffers"))][];
        }

        // ------------------------------------------------ 緩衝區與存取器

        byte[] GetBuffer(int index)
        {
            if (index < 0 || index >= buffers.Length) throw new InvalidDataException("緩衝區索引錯誤。");
            if (buffers[index] != null) return buffers[index];
            object b = J.At(J.Get(root, "buffers"), index);
            string uri = J.Str(b, "uri");
            byte[] bytes;
            if (uri == null)
            {
                if (index != 0 || glbBin == null) throw new InvalidDataException("缺少二進位區塊。");
                bytes = glbBin;
            }
            else
            {
                bytes = DecodeDataUri(uri);
            }
            buffers[index] = bytes;
            return bytes;
        }

        static byte[] DecodeDataUri(string uri)
        {
            if (!uri.StartsWith("data:", StringComparison.OrdinalIgnoreCase)) throw new UnsupportedGlbException("不支援外部檔案。");
            int comma = uri.IndexOf(',');
            if (comma < 0 || uri.IndexOf(";base64", 0, comma, StringComparison.OrdinalIgnoreCase) < 0)
                throw new UnsupportedGlbException("不支援的 data URI。");
            return Convert.FromBase64String(uri.Substring(comma + 1));
        }

        static int ComponentSize(int componentType)
        {
            switch (componentType)
            {
                case 5120: case 5121: return 1;
                case 5122: case 5123: return 2;
                case 5125: case 5126: return 4;
                default: throw new InvalidDataException("不認得的元件型別。");
            }
        }

        static int ComponentCount(string type)
        {
            switch (type)
            {
                case "SCALAR": return 1;
                case "VEC2": return 2;
                case "VEC3": return 3;
                case "VEC4": return 4;
                case "MAT2": return 4;
                case "MAT3": return 9;
                case "MAT4": return 16;
                default: throw new InvalidDataException("不認得的存取器型別。");
            }
        }

        // 取得存取器的位置資訊；沒有 bufferView 時回傳 false（內容視為全 0）
        bool Locate(object accessor, int elementSize, out byte[] buf, out int offset, out int stride, out int count)
        {
            count = J.Int(accessor, "count", 0);
            buf = null; offset = 0; stride = elementSize;
            int viewIndex = J.Int(accessor, "bufferView", -1);
            if (viewIndex < 0) return false;
            object view = J.At(J.Get(root, "bufferViews"), viewIndex);
            if (view == null) throw new InvalidDataException("bufferView 索引錯誤。");
            if (J.Get(J.Get(view, "extensions"), "EXT_meshopt_compression") != null)
                throw new UnsupportedGlbException("不支援 Meshopt 壓縮。");
            buf = GetBuffer(J.Int(view, "buffer", 0));
            offset = J.Int(view, "byteOffset", 0) + J.Int(accessor, "byteOffset", 0);
            int s = J.Int(view, "byteStride", 0);
            if (s > 0) stride = s;
            if (count < 0 || offset < 0) throw new InvalidDataException("存取器範圍錯誤。");
            if (count > 0 && (long)offset + (long)(count - 1) * stride + elementSize > buf.Length)
                throw new InvalidDataException("存取器超出緩衝區。");
            return true;
        }

        // 單一存取器的元素上限。檔案本身有大小上限，但沒有 bufferView 的存取器不受檔案大小約束。
        const long MaxElements = 24L * 1024 * 1024;

        static void CheckCount(object accessor, int comps)
        {
            int count = J.Int(accessor, "count", 0);
            if (count < 0 || (long)count * comps > MaxElements) throw new InvalidDataException("存取器數量不合理。");
        }

        float[] ReadFloats(int accessorIndex, out int comps)
        {
            object a = J.At(J.Get(root, "accessors"), accessorIndex);
            if (a == null) throw new InvalidDataException("存取器索引錯誤。");
            int ctype = J.Int(a, "componentType", 0);
            comps = ComponentCount(J.Str(a, "type"));
            bool normalized = J.Bool(a, "normalized", false);
            int csize = ComponentSize(ctype);
            byte[] buf; int offset, stride, count;
            // 數量來自檔案內容，要先確認合理、確認沒有超出緩衝區，才能依它配置陣列
            CheckCount(a, comps);
            bool located = Locate(a, comps * csize, out buf, out offset, out stride, out count);
            var result = new float[count * comps];
            if (!located) return result;
            for (int e = 0; e < count; e++)
            {
                int p = offset + e * stride;
                for (int c = 0; c < comps; c++)
                {
                    result[e * comps + c] = ReadComponent(buf, p + c * csize, ctype, normalized);
                }
            }
            return result;
        }

        static float ReadComponent(byte[] b, int p, int ctype, bool normalized)
        {
            switch (ctype)
            {
                case 5120: { sbyte v = (sbyte)b[p]; return normalized ? Math.Max(v / 127f, -1f) : v; }
                case 5121: { byte v = b[p]; return normalized ? v / 255f : v; }
                case 5122: { short v = BitConverter.ToInt16(b, p); return normalized ? Math.Max(v / 32767f, -1f) : v; }
                case 5123: { ushort v = BitConverter.ToUInt16(b, p); return normalized ? v / 65535f : v; }
                case 5125: return BitConverter.ToUInt32(b, p);
                default: return BitConverter.ToSingle(b, p);
            }
        }

        int[] ReadIndices(int accessorIndex)
        {
            object a = J.At(J.Get(root, "accessors"), accessorIndex);
            if (a == null) throw new InvalidDataException("存取器索引錯誤。");
            int ctype = J.Int(a, "componentType", 0);
            if (ctype != 5121 && ctype != 5123 && ctype != 5125) throw new InvalidDataException("索引的元件型別錯誤。");
            int csize = ComponentSize(ctype);
            byte[] buf; int offset, stride, count;
            CheckCount(a, 1);
            bool located = Locate(a, csize, out buf, out offset, out stride, out count);
            var result = new int[count];
            if (!located) return result;
            for (int e = 0; e < count; e++)
            {
                int p = offset + e * stride;
                result[e] = ctype == 5121 ? buf[p] : ctype == 5123 ? BitConverter.ToUInt16(buf, p) : (int)BitConverter.ToUInt32(buf, p);
            }
            return result;
        }

        // ------------------------------------------------ 材質

        Material GetMaterial(int index)
        {
            Material m;
            if (materials.TryGetValue(index, out m)) return m;
            m = new Material();
            object def = J.At(J.Get(root, "materials"), index);
            if (def != null)
            {
                object pbr = J.Get(def, "pbrMetallicRoughness");
                object colorTexture = J.Get(pbr, "baseColorTexture");
                double[] f = J.Nums(pbr, "baseColorFactor", 4);
                // 舊版的鏡面光澤度擴充，用 diffuse 當作基本色
                object legacy = J.Get(J.Get(def, "extensions"), "KHR_materials_pbrSpecularGlossiness");
                if (pbr == null && legacy != null)
                {
                    f = J.Nums(legacy, "diffuseFactor", 4);
                    colorTexture = J.Get(legacy, "diffuseTexture");
                }
                if (f != null) { m.R = ToSrgb(f[0]); m.G = ToSrgb(f[1]); m.B = ToSrgb(f[2]); }
                if (colorTexture != null)
                {
                    m.UvSet = J.Int(colorTexture, "texCoord", 0);
                    m.Tex = GetTexture(J.Int(colorTexture, "index", -1));
                }
            }
            materials[index] = m;
            return m;
        }

        Texture GetTexture(int index)
        {
            Texture t;
            if (textures.TryGetValue(index, out t)) return t;
            t = null;
            object def = J.At(J.Get(root, "textures"), index);
            int source = J.Int(def, "source", -1);
            if (source >= 0)
            {
                t = DecodeImage(J.At(J.Get(root, "images"), source));
                if (t != null)
                {
                    object sampler = J.At(J.Get(root, "samplers"), J.Int(def, "sampler", -1));
                    t.WrapS = J.Int(sampler, "wrapS", 10497);
                    t.WrapT = J.Int(sampler, "wrapT", 10497);
                }
            }
            textures[index] = t;
            return t;
        }

        // 圖片解不開時當作沒有貼圖，不讓整個縮圖失敗
        const long MaxImagePixels = 4096L * 4096;

        Texture DecodeImage(object image)
        {
            const int MaxSide = 512;
            try
            {
                byte[] bytes = null;
                string uri = J.Str(image, "uri");
                if (uri != null)
                {
                    bytes = DecodeDataUri(uri);
                }
                else
                {
                    object view = J.At(J.Get(root, "bufferViews"), J.Int(image, "bufferView", -1));
                    if (view == null) return null;
                    byte[] buf = GetBuffer(J.Int(view, "buffer", 0));
                    int offset = J.Int(view, "byteOffset", 0), length = J.Int(view, "byteLength", 0);
                    if (offset < 0 || length <= 0 || (long)offset + length > buf.Length) return null;
                    bytes = new byte[length];
                    Buffer.BlockCopy(buf, offset, bytes, 0, length);
                }
                using (var ms = new MemoryStream(bytes))
                using (var img = Image.FromStream(ms, false, false))
                {
                    int w = img.Width, h = img.Height;
                    // 解碼前先看檔頭宣告的尺寸：幾百 KB 的圖可以宣告成幾億像素，解碼會吃光記憶體與時間
                    if (w <= 0 || h <= 0 || (long)w * h > MaxImagePixels) return null;
                    clock.Check();
                    double shrink = Math.Min(1.0, (double)MaxSide / Math.Max(w, h));
                    int tw = Math.Max(1, (int)Math.Round(w * shrink)), th = Math.Max(1, (int)Math.Round(h * shrink));
                    using (var bmp = new Bitmap(tw, th, PixelFormat.Format32bppArgb))
                    {
                        using (var g = Graphics.FromImage(bmp))
                        {
                            g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                            g.PixelOffsetMode = PixelOffsetMode.Half;
                            g.DrawImage(img, new Rectangle(0, 0, tw, th), 0, 0, w, h, GraphicsUnit.Pixel);
                        }
                        var data = bmp.LockBits(new Rectangle(0, 0, tw, th), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
                        try
                        {
                            var raw = new int[tw * th];
                            for (int y = 0; y < th; y++) Marshal.Copy(IntPtr.Add(data.Scan0, y * data.Stride), raw, y * tw, tw);
                            var px = new uint[raw.Length];
                            for (int k = 0; k < raw.Length; k++) px[k] = unchecked((uint)raw[k]);
                            return new Texture { W = tw, H = th, Px = px };
                        }
                        finally { bmp.UnlockBits(data); }
                    }
                }
            }
            catch (RenderTimeoutException) { throw; }
            catch (Exception) { return null; }
        }

        static float ToSrgb(double linear)
        {
            if (linear <= 0) return 0;
            if (linear >= 1) return 1;
            return (float)Math.Pow(linear, 1.0 / 2.2);
        }

        // ------------------------------------------------ 節點與場景

        double[] LocalMatrix(object node)
        {
            double[] matrix = J.Nums(node, "matrix", 16);
            if (matrix != null) return matrix;
            double[] t = J.Nums(node, "translation", 3) ?? new double[] { 0, 0, 0 };
            double[] q = J.Nums(node, "rotation", 4) ?? new double[] { 0, 0, 0, 1 };
            double[] s = J.Nums(node, "scale", 3) ?? new double[] { 1, 1, 1 };
            return Mat.FromTrs(t, q, s);
        }

        void BuildParents()
        {
            int n = J.Count(J.Get(root, "nodes"));
            parentOf = new int[n];
            for (int k = 0; k < n; k++) parentOf[k] = -1;
            for (int k = 0; k < n; k++)
            {
                var kids = J.Get(J.At(J.Get(root, "nodes"), k), "children") as List<object>;
                if (kids == null) continue;
                foreach (object kid in kids)
                {
                    if (kid is double)
                    {
                        int c = (int)(double)kid;
                        if (c >= 0 && c < n) parentOf[c] = k;
                    }
                }
            }
        }

        double[] GlobalOf(int node)
        {
            double[] g;
            if (globals.TryGetValue(node, out g)) return g;
            var chain = new List<int>();
            int cur = node;
            while (cur >= 0 && !globals.ContainsKey(cur))
            {
                chain.Add(cur);
                if (chain.Count > MaxDepth) throw new InvalidDataException("節點階層過深或有迴圈。");
                cur = parentOf[cur];
            }
            double[] acc = cur >= 0 ? globals[cur] : Mat.Identity();
            for (int k = chain.Count - 1; k >= 0; k--)
            {
                acc = Mat.Mul(acc, LocalMatrix(J.At(J.Get(root, "nodes"), chain[k])));
                globals[chain[k]] = acc;
            }
            return globals[node];
        }

        List<int> SceneRoots()
        {
            var roots = new List<int>();
            var scenes = J.Get(root, "scenes");
            if (J.Count(scenes) > 0)
            {
                int which = J.Int(root, "scene", 0);
                var list = J.Get(J.At(scenes, which) ?? J.At(scenes, 0), "nodes") as List<object>;
                if (list != null)
                    foreach (object o in list) if (o is double) roots.Add((int)(double)o);
                return roots;
            }
            for (int k = 0; k < parentOf.Length; k++) if (parentOf[k] < 0) roots.Add(k);
            return roots;
        }

        public List<Part> BuildParts()
        {
            BuildParents();
            var parts = new List<Part>();
            var seen = new HashSet<int>();
            var stack = new Stack<KeyValuePair<int, int>>();
            foreach (int r in SceneRoots()) stack.Push(new KeyValuePair<int, int>(r, 0));
            while (stack.Count > 0)
            {
                var item = stack.Pop();
                int idx = item.Key;
                if (idx < 0 || idx >= parentOf.Length || !seen.Add(idx)) continue;
                if (item.Value > MaxDepth) throw new InvalidDataException("節點階層過深。");
                object node = J.At(J.Get(root, "nodes"), idx);
                int meshIndex = J.Int(node, "mesh", -1);
                if (meshIndex >= 0) AddMesh(meshIndex, GlobalOf(idx), GetSkin(J.Int(node, "skin", -1)), parts);
                var kids = J.Get(node, "children") as List<object>;
                if (kids != null)
                    foreach (object kid in kids) if (kid is double) stack.Push(new KeyValuePair<int, int>((int)(double)kid, item.Value + 1));
                clock.Check();
            }
            if (parts.Count == 0) throw new UnsupportedGlbException("沒有可以顯示的網格。");
            return parts;
        }

        // 每個關節的蒙皮矩陣：關節的世界矩陣乘上反向綁定矩陣。節點目前的姿勢就是預設姿勢。
        double[][] GetSkin(int skinIndex)
        {
            if (skinIndex < 0) return null;
            double[][] cached;
            if (skins.TryGetValue(skinIndex, out cached)) return cached;
            double[][] result = null;
            object skin = J.At(J.Get(root, "skins"), skinIndex);
            var joints = J.Get(skin, "joints") as List<object>;
            if (joints != null)
            {
                float[] ibm = null;
                int ibmAcc = J.Int(skin, "inverseBindMatrices", -1);
                if (ibmAcc >= 0)
                {
                    int comps;
                    ibm = ReadFloats(ibmAcc, out comps);
                    if (comps != 16) ibm = null;
                }
                result = new double[joints.Count][];
                for (int j = 0; j < joints.Count; j++)
                {
                    int node = joints[j] is double ? (int)(double)joints[j] : -1;
                    double[] m = node >= 0 && node < parentOf.Length ? GlobalOf(node) : Mat.Identity();
                    if (ibm != null && ibm.Length >= (j + 1) * 16)
                    {
                        var inv = new double[16];
                        for (int e = 0; e < 16; e++) inv[e] = ibm[j * 16 + e];
                        m = Mat.Mul(m, inv);
                    }
                    result[j] = m;
                }
            }
            skins[skinIndex] = result;
            return result;
        }

        void AddMesh(int meshIndex, double[] world, double[][] skin, List<Part> parts)
        {
            object mesh = J.At(J.Get(root, "meshes"), meshIndex);
            var prims = J.Get(mesh, "primitives") as List<object>;
            if (prims == null) return;
            foreach (object prim in prims)
            {
                Part part = BuildPart(prim, world, skin);
                if (part != null) parts.Add(part);
                clock.Check();
            }
        }

        Part BuildPart(object prim, double[] world, double[][] skin)
        {
            if (J.Get(J.Get(prim, "extensions"), "KHR_draco_mesh_compression") != null)
                throw new UnsupportedGlbException("不支援 Draco 壓縮。");
            int mode = J.Int(prim, "mode", 4);
            if (mode < 4 || mode > 6) return null;
            object attrs = J.Get(prim, "attributes");
            int posAcc = J.Int(attrs, "POSITION", -1);
            if (posAcc < 0) return null;

            int comps;
            float[] pos = ReadFloats(posAcc, out comps);
            if (comps != 3) throw new InvalidDataException("位置必須是三維。");
            int vertexCount = pos.Length / 3;

            float[] nrm = null;
            int nrmAcc = J.Int(attrs, "NORMAL", -1);
            if (nrmAcc >= 0)
            {
                nrm = ReadFloats(nrmAcc, out comps);
                if (comps != 3 || nrm.Length != pos.Length) nrm = null;
            }

            int[] raw;
            int idxAcc = J.Int(prim, "indices", -1);
            if (idxAcc >= 0)
            {
                raw = ReadIndices(idxAcc);
            }
            else
            {
                raw = new int[vertexCount];
                for (int k = 0; k < vertexCount; k++) raw[k] = k;
            }
            foreach (int v in raw) if (v < 0 || v >= vertexCount) throw new InvalidDataException("索引超出頂點範圍。");
            int[] tris = Triangulate(raw, mode);
            if (tris.Length == 0) return null;

            var part = new Part();
            part.I = tris;
            part.Mat = GetMaterial(J.Int(prim, "material", -1));

            // 頂點色轉成 sRGB 的三個分量
            int colorAcc = J.Int(attrs, "COLOR_0", -1);
            if (colorAcc >= 0)
            {
                float[] col = ReadFloats(colorAcc, out comps);
                if ((comps == 3 || comps == 4) && col.Length / comps == vertexCount)
                {
                    part.C = new float[vertexCount * 3];
                    for (int v = 0; v < vertexCount; v++)
                        for (int c = 0; c < 3; c++) part.C[v * 3 + c] = ToSrgb(col[v * comps + c]);
                }
            }

            if (part.Mat.Tex != null)
            {
                int uvAcc = J.Int(attrs, "TEXCOORD_" + part.Mat.UvSet, -1);
                if (uvAcc >= 0)
                {
                    float[] uv = ReadFloats(uvAcc, out comps);
                    if (comps == 2 && uv.Length / 2 == vertexCount) part.Uv = uv;
                }
            }

            // 蒙皮：有關節與權重時，頂點位置由關節矩陣決定，節點本身的變換會被忽略（glTF 規定）
            float[] jointIds = null, weights = null;
            if (skin != null)
            {
                int jAcc = J.Int(attrs, "JOINTS_0", -1), wAcc = J.Int(attrs, "WEIGHTS_0", -1);
                if (jAcc >= 0 && wAcc >= 0)
                {
                    int jc, wc;
                    jointIds = ReadFloats(jAcc, out jc);
                    weights = ReadFloats(wAcc, out wc);
                    if (jc != 4 || wc != 4 || jointIds.Length != vertexCount * 4 || weights.Length != vertexCount * 4)
                        jointIds = weights = null;
                }
            }

            part.P = new float[pos.Length];
            if (nrm != null) part.N = new float[nrm.Length];
            double[] normalMat = Mat.CofactorOfLinear(world);
            var blend = new double[16];
            for (int v = 0; v < vertexCount; v++)
            {
                double x = pos[v * 3], y = pos[v * 3 + 1], z = pos[v * 3 + 2];
                double nx = 0, ny = 0, nz = 0;
                if (nrm != null) { nx = nrm[v * 3]; ny = nrm[v * 3 + 1]; nz = nrm[v * 3 + 2]; }

                if (jointIds != null)
                {
                    Array.Clear(blend, 0, 16);
                    double sum = 0;
                    for (int k = 0; k < 4; k++)
                    {
                        double w = weights[v * 4 + k];
                        int j = (int)jointIds[v * 4 + k];
                        if (w <= 0 || j < 0 || j >= skin.Length) continue;
                        sum += w;
                        for (int e = 0; e < 16; e++) blend[e] += w * skin[j][e];
                    }
                    if (sum > 1e-9) { for (int e = 0; e < 16; e++) blend[e] /= sum; }
                    else { blend = Mat.Identity(); }
                    part.P[v * 3] = (float)(blend[0] * x + blend[4] * y + blend[8] * z + blend[12]);
                    part.P[v * 3 + 1] = (float)(blend[1] * x + blend[5] * y + blend[9] * z + blend[13]);
                    part.P[v * 3 + 2] = (float)(blend[2] * x + blend[6] * y + blend[10] * z + blend[14]);
                    if (nrm != null)
                    {
                        part.N[v * 3] = (float)(blend[0] * nx + blend[4] * ny + blend[8] * nz);
                        part.N[v * 3 + 1] = (float)(blend[1] * nx + blend[5] * ny + blend[9] * nz);
                        part.N[v * 3 + 2] = (float)(blend[2] * nx + blend[6] * ny + blend[10] * nz);
                    }
                    continue;
                }

                part.P[v * 3] = (float)(world[0] * x + world[4] * y + world[8] * z + world[12]);
                part.P[v * 3 + 1] = (float)(world[1] * x + world[5] * y + world[9] * z + world[13]);
                part.P[v * 3 + 2] = (float)(world[2] * x + world[6] * y + world[10] * z + world[14]);
                if (nrm != null)
                {
                    part.N[v * 3] = (float)(normalMat[0] * nx + normalMat[3] * ny + normalMat[6] * nz);
                    part.N[v * 3 + 1] = (float)(normalMat[1] * nx + normalMat[4] * ny + normalMat[7] * nz);
                    part.N[v * 3 + 2] = (float)(normalMat[2] * nx + normalMat[5] * ny + normalMat[8] * nz);
                }
            }
            return part;
        }

        static int[] Triangulate(int[] raw, int mode)
        {
            if (mode == 4)
            {
                int n = raw.Length / 3 * 3;
                var r = new int[n];
                Array.Copy(raw, r, n);
                return r;
            }
            if (raw.Length < 3) return new int[0];
            var list = new List<int>();
            for (int k = 2; k < raw.Length; k++)
            {
                if (mode == 5)
                {
                    if ((k & 1) == 0) { list.Add(raw[k - 2]); list.Add(raw[k - 1]); list.Add(raw[k]); }
                    else { list.Add(raw[k - 1]); list.Add(raw[k - 2]); list.Add(raw[k]); }
                }
                else
                {
                    list.Add(raw[0]); list.Add(raw[k - 1]); list.Add(raw[k]);
                }
            }
            return list.ToArray();
        }
    }

    // ---------------------------------------------------------------- 光柵化

    internal sealed class Rasterizer
    {
        // 視角：從前右上方看，正交投影
        const double AzimuthDeg = 35, ElevationDeg = 25;
        const double Margin = 0.08;

        readonly List<Part> parts;
        readonly int size;
        readonly Budget clock;
        readonly int ss;

        // 相機基底（世界座標）：右、上、朝向觀察者
        double rx, ry, rz, ux, uy, uz, ex, ey, ez;

        public Rasterizer(List<Part> parts, int size, Budget clock)
        {
            this.parts = parts;
            this.size = size;
            this.clock = clock;
            this.ss = size <= 384 ? 3 : 2;
            double az = AzimuthDeg * Math.PI / 180, el = ElevationDeg * Math.PI / 180;
            ex = Math.Sin(az) * Math.Cos(el); ey = Math.Sin(el); ez = Math.Cos(az) * Math.Cos(el);
            rx = ez; ry = 0; rz = -ex;
            double rl = Math.Sqrt(rx * rx + rz * rz);
            rx /= rl; rz /= rl;
            ux = ey * rz - ez * ry; uy = ez * rx - ex * rz; uz = ex * ry - ey * rx;
        }

        public byte[] Render()
        {
            // 先投影所有被引用的頂點，求出範圍
            double minX = double.MaxValue, maxX = double.MinValue, minY = double.MaxValue, maxY = double.MinValue;
            var cams = new float[parts.Count][];
            for (int pi = 0; pi < parts.Count; pi++)
            {
                Part part = parts[pi];
                int n = part.P.Length / 3;
                var cam = new float[n * 3];
                for (int v = 0; v < n; v++)
                {
                    double x = part.P[v * 3], y = part.P[v * 3 + 1], z = part.P[v * 3 + 2];
                    cam[v * 3] = (float)(x * rx + y * ry + z * rz);
                    cam[v * 3 + 1] = (float)(x * ux + y * uy + z * uz);
                    cam[v * 3 + 2] = (float)(x * ex + y * ey + z * ez);
                }
                cams[pi] = cam;
                foreach (int v in part.I)
                {
                    double cx = cam[v * 3], cy = cam[v * 3 + 1];
                    if (double.IsNaN(cx) || double.IsInfinity(cx) || double.IsNaN(cy) || double.IsInfinity(cy)) continue;
                    if (cx < minX) minX = cx; if (cx > maxX) maxX = cx;
                    if (cy < minY) minY = cy; if (cy > maxY) maxY = cy;
                }
                clock.Check();
            }
            double spanX = maxX - minX, spanY = maxY - minY;
            double span = Math.Max(spanX, spanY);
            if (!(span > 0) || double.IsInfinity(span)) throw new InvalidDataException("模型沒有大小。");

            int dim = size * ss;
            double scale = dim * (1 - 2 * Margin) / span;
            double midX = (minX + maxX) / 2, midY = (minY + maxY) / 2;
            double half = dim / 2.0;

            var color = new uint[dim * dim];
            var depth = new float[dim * dim];
            for (int k = 0; k < depth.Length; k++) depth[k] = float.NegativeInfinity;

            long triCount = 0;
            for (int pi = 0; pi < parts.Count; pi++)
            {
                Part part = parts[pi];
                float[] cam = cams[pi];
                int[] idx = part.I;
                for (int t = 0; t + 2 < idx.Length; t += 3)
                {
                    if ((++triCount & 0xFFF) == 0) clock.Check();
                    DrawTriangle(part, cam, idx[t], idx[t + 1], idx[t + 2], midX, midY, scale, half, dim, color, depth);
                }
            }
            return Downsample(color, dim);
        }

        // 把座標夾進畫面範圍再轉成整數，座標再大也不會溢位
        static int ClampPixel(double v, int dim)
        {
            if (v < 0) return 0;
            if (v > dim - 1) return dim - 1;
            return (int)v;
        }

        void DrawTriangle(Part part, float[] cam, int a, int b, int c, double midX, double midY, double scale, double half, int dim, uint[] color, float[] depth)
        {
            double x0 = half + (cam[a * 3] - midX) * scale, y0 = half - (cam[a * 3 + 1] - midY) * scale;
            double x1 = half + (cam[b * 3] - midX) * scale, y1 = half - (cam[b * 3 + 1] - midY) * scale;
            double x2 = half + (cam[c * 3] - midX) * scale, y2 = half - (cam[c * 3 + 1] - midY) * scale;
            double area = (x1 - x0) * (y2 - y0) - (x2 - x0) * (y1 - y0);
            // 含非數值或無限大的三角形直接略過；用「不小於」的寫法，NaN 也會被擋下
            if (!(Math.Abs(area) >= 1e-9) || double.IsInfinity(area)) return;
            int minPx = ClampPixel(Math.Floor(Math.Min(x0, Math.Min(x1, x2))), dim);
            int maxPx = ClampPixel(Math.Ceiling(Math.Max(x0, Math.Max(x1, x2))), dim);
            int minPy = ClampPixel(Math.Floor(Math.Min(y0, Math.Min(y1, y2))), dim);
            int maxPy = ClampPixel(Math.Ceiling(Math.Max(y0, Math.Max(y1, y2))), dim);
            if (minPx > maxPx || minPy > maxPy) return;
            double inv = 1.0 / area;
            float z0 = cam[a * 3 + 2], z1 = cam[b * 3 + 2], z2 = cam[c * 3 + 2];

            // 幾何法線（世界座標），沒有頂點法線時使用
            double ax = part.P[b * 3] - part.P[a * 3], ay = part.P[b * 3 + 1] - part.P[a * 3 + 1], az = part.P[b * 3 + 2] - part.P[a * 3 + 2];
            double bx = part.P[c * 3] - part.P[a * 3], by = part.P[c * 3 + 1] - part.P[a * 3 + 1], bz = part.P[c * 3 + 2] - part.P[a * 3 + 2];
            double gx = ay * bz - az * by, gy = az * bx - ax * bz, gz = ax * by - ay * bx;
            double gl = Math.Sqrt(gx * gx + gy * gy + gz * gz);
            if (gl > 0) { gx /= gl; gy /= gl; gz /= gl; }

            Material mat = part.Mat;
            bool textured = mat.Tex != null && part.Uv != null;
            for (int py = minPy; py <= maxPy; py++)
            {
                double sy = py + 0.5;
                for (int px = minPx; px <= maxPx; px++)
                {
                    double sx = px + 0.5;
                    double b1 = ((sx - x0) * (y2 - y0) - (x2 - x0) * (sy - y0)) * inv;
                    double b2 = ((x1 - x0) * (sy - y0) - (sx - x0) * (y1 - y0)) * inv;
                    double b0 = 1 - b1 - b2;
                    if (b0 < 0 || b1 < 0 || b2 < 0) continue;
                    float z = (float)(b0 * z0 + b1 * z1 + b2 * z2);
                    int o = py * dim + px;
                    if (z <= depth[o]) continue;

                    double nx, ny, nz;
                    if (part.N != null)
                    {
                        nx = b0 * part.N[a * 3] + b1 * part.N[b * 3] + b2 * part.N[c * 3];
                        ny = b0 * part.N[a * 3 + 1] + b1 * part.N[b * 3 + 1] + b2 * part.N[c * 3 + 1];
                        nz = b0 * part.N[a * 3 + 2] + b1 * part.N[b * 3 + 2] + b2 * part.N[c * 3 + 2];
                        double nl = Math.Sqrt(nx * nx + ny * ny + nz * nz);
                        if (nl > 1e-12) { nx /= nl; ny /= nl; nz /= nl; } else { nx = gx; ny = gy; nz = gz; }
                    }
                    else
                    {
                        nx = gx; ny = gy; nz = gz;
                    }
                    // 雙面光照：法線背對觀察者就翻過來
                    if (nx * ex + ny * ey + nz * ez < 0) { nx = -nx; ny = -ny; nz = -nz; }

                    float cr = mat.R, cg = mat.G, cb = mat.B;
                    if (part.C != null)
                    {
                        cr *= (float)(b0 * part.C[a * 3] + b1 * part.C[b * 3] + b2 * part.C[c * 3]);
                        cg *= (float)(b0 * part.C[a * 3 + 1] + b1 * part.C[b * 3 + 1] + b2 * part.C[c * 3 + 1]);
                        cb *= (float)(b0 * part.C[a * 3 + 2] + b1 * part.C[b * 3 + 2] + b2 * part.C[c * 3 + 2]);
                    }
                    if (textured)
                    {
                        double u = b0 * part.Uv[a * 2] + b1 * part.Uv[b * 2] + b2 * part.Uv[c * 2];
                        double v = b0 * part.Uv[a * 2 + 1] + b1 * part.Uv[b * 2 + 1] + b2 * part.Uv[c * 2 + 1];
                        float tr, tg, tb;
                        mat.Tex.Sample(u, v, out tr, out tg, out tb);
                        cr *= tr; cg *= tg; cb *= tb;
                    }

                    depth[o] = z;
                    color[o] = Shade(cr, cg, cb, nx, ny, nz);
                }
            }
        }

        // 光線定義在相機座標：一盞主光（左上前方）、一盞弱的補光（右下），再加環境光
        static readonly double[] Key = Normalize(-0.45, 0.65, 0.62);
        static readonly double[] Fill = Normalize(0.7, -0.2, 0.4);

        static double[] Normalize(double x, double y, double z)
        {
            double l = Math.Sqrt(x * x + y * y + z * z);
            return new double[] { x / l, y / l, z / l };
        }

        uint Shade(float r, float g, float b, double nx, double ny, double nz)
        {
            double cx = nx * rx + ny * ry + nz * rz;
            double cy = nx * ux + ny * uy + nz * uz;
            double cz = nx * ex + ny * ey + nz * ez;
            double key = Math.Max(0, cx * Key[0] + cy * Key[1] + cz * Key[2]);
            double fill = Math.Max(0, cx * Fill[0] + cy * Fill[1] + cz * Fill[2]);
            double light = 0.36 + 0.08 * cy + 0.56 * key + 0.12 * fill;
            if (light > 1) light = 1;
            uint ri = (uint)(Math.Min(1.0, r * light) * 255 + 0.5);
            uint gi = (uint)(Math.Min(1.0, g * light) * 255 + 0.5);
            uint bi = (uint)(Math.Min(1.0, b * light) * 255 + 0.5);
            return 0xFF000000u | (ri << 16) | (gi << 8) | bi;
        }

        // 把超取樣的畫面縮小成最終尺寸，輸出預乘透明度的 BGRA
        byte[] Downsample(uint[] color, int dim)
        {
            var output = new byte[size * size * 4];
            int samples = ss * ss;
            for (int y = 0; y < size; y++)
            {
                for (int x = 0; x < size; x++)
                {
                    int covered = 0;
                    int sr = 0, sg = 0, sb = 0;
                    for (int dy = 0; dy < ss; dy++)
                        for (int dx = 0; dx < ss; dx++)
                        {
                            uint px = color[(y * ss + dy) * dim + x * ss + dx];
                            if ((px >> 24) == 0) continue;
                            covered++;
                            sr += (int)((px >> 16) & 0xFF); sg += (int)((px >> 8) & 0xFF); sb += (int)(px & 0xFF);
                        }
                    int o = (y * size + x) * 4;
                    output[o] = (byte)(sb / samples);
                    output[o + 1] = (byte)(sg / samples);
                    output[o + 2] = (byte)(sr / samples);
                    output[o + 3] = (byte)(covered * 255 / samples);
                }
            }
            return output;
        }
    }

    // ---------------------------------------------------------------- Explorer 的縮圖提供者（COM）

    public enum WTS_ALPHATYPE { WTSAT_UNKNOWN = 0, WTSAT_RGB = 1, WTSAT_ARGB = 2 }

    [ComImport, Guid("e357fccd-a995-4576-b01f-234630154e96"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IThumbnailProvider
    {
        void GetThumbnail(uint cx, out IntPtr phbmp, out WTS_ALPHATYPE pdwAlpha);
    }

    [ComImport, Guid("b824b49d-22ac-4161-ac8a-9916e8fa3f7f"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    public interface IInitializeWithStream
    {
        void Initialize(IStream pstream, uint grfMode);
    }

    [ComVisible(true)]
    [Guid("6F1C2D8B-3A47-4E5B-9C0D-2B7A5E4F1D93")]
    [ClassInterface(ClassInterfaceType.None)]
    public sealed class GlbThumbnailProvider : IInitializeWithStream, IThumbnailProvider
    {
        byte[] data;

        public void Initialize(IStream pstream, uint grfMode)
        {
            System.Runtime.InteropServices.ComTypes.STATSTG stat;
            pstream.Stat(out stat, 1);
            pstream.Seek(0, 0, IntPtr.Zero);
            if (stat.cbSize > GlbRenderer.MaxFileBytes) throw new UnsupportedGlbException("檔案超過大小上限。");
            var buffer = new byte[(int)stat.cbSize];
            IntPtr readPtr = Marshal.AllocCoTaskMem(4);
            try
            {
                int total = 0;
                while (total < buffer.Length)
                {
                    var chunk = new byte[Math.Min(1 << 20, buffer.Length - total)];
                    pstream.Read(chunk, chunk.Length, readPtr);
                    int got = Marshal.ReadInt32(readPtr);
                    if (got <= 0) break;
                    Buffer.BlockCopy(chunk, 0, buffer, total, got);
                    total += got;
                }
                if (total != buffer.Length) Array.Resize(ref buffer, total);
            }
            finally { Marshal.FreeCoTaskMem(readPtr); }
            data = buffer;
        }

        public void GetThumbnail(uint cx, out IntPtr phbmp, out WTS_ALPHATYPE pdwAlpha)
        {
            phbmp = IntPtr.Zero;
            pdwAlpha = WTS_ALPHATYPE.WTSAT_ARGB;
            if (data == null) throw new InvalidOperationException("尚未初始化。");
            int size = (int)Math.Min(Math.Max(cx, 16u), 1024u);
            byte[] bgra = GlbRenderer.RenderBgra(data, size, GlbRenderer.DefaultBudgetMs);
            phbmp = CreateBitmap(bgra, size);
        }

        static IntPtr CreateBitmap(byte[] bgra, int size)
        {
            var header = new BITMAPINFOHEADER();
            header.biSize = (uint)Marshal.SizeOf(typeof(BITMAPINFOHEADER));
            header.biWidth = size;
            header.biHeight = -size;   // 由上往下
            header.biPlanes = 1;
            header.biBitCount = 32;
            IntPtr bits;
            IntPtr hbmp = CreateDIBSection(IntPtr.Zero, ref header, 0, out bits, IntPtr.Zero, 0);
            if (hbmp == IntPtr.Zero) throw new OutOfMemoryException();
            Marshal.Copy(bgra, 0, bits, bgra.Length);
            return hbmp;
        }

        [StructLayout(LayoutKind.Sequential)]
        struct BITMAPINFOHEADER
        {
            public uint biSize;
            public int biWidth;
            public int biHeight;
            public ushort biPlanes;
            public ushort biBitCount;
            public uint biCompression;
            public uint biSizeImage;
            public int biXPelsPerMeter;
            public int biYPelsPerMeter;
            public uint biClrUsed;
            public uint biClrImportant;
        }

        [DllImport("gdi32.dll", SetLastError = true)]
        static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER pbmi, uint usage, out IntPtr ppvBits, IntPtr hSection, uint offset);
    }
}
