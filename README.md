# glb-viewer

在 Windows 上雙擊 `.glb` 就能直接預覽 3D 模型，像開相片一樣。

- 獨立的小視窗，關掉就結束，不會留下背景程式。
- 完全離線可用，模型只在本機處理，不會上傳。只有你按下標題列的「更新」時，才會連到 GitHub 檢查版本。
- 只安裝在目前使用者的範圍，不需要系統管理員權限。

## 安裝

在 PowerShell 貼上這一行，會從 GitHub 下載並安裝：

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wkai2573/glb-viewer/main/install.ps1).TrimStart([char]0xFEFF)))
```

也可以先下載專案，再在專案資料夾內執行：

```powershell
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

安裝位置是 `%LOCALAPPDATA%\GlbViewer`。重複執行會直接覆蓋更新。

### 設成預設程式

Windows 不允許程式自行變更預設，所以要手動做一次：

1. 在任一 `.glb` 上按右鍵，選「開啟檔案時使用」，再選「選擇其他應用程式」。
2. 選「GLB 檢視器」，勾選「一律使用此應用程式開啟 .glb 檔案」。

安裝時會順便開啟 Windows 的預設應用程式設定頁，方便你操作。

## 使用

雙擊 `.glb`。左鍵旋轉，滾輪縮放，右鍵平移。模型含動畫時，標題列會出現「播放動畫」。

### 光線效果

按標題列的「光線」會展開右側面板。

- **光線預設**：柔和攝影棚、正午強光、側逆光輪廓、風格 B，一鍵套用。
- **顯示方式**：
  - 上色：保留模型原本的材質，搭配內建的攝影棚環境光。
  - 純顏色：不打光，只看貼圖原色。
  - 風格 B：兩階明暗加描邊的卡通風格。
- **打光**：可以調水平角度、仰角、亮度、環境光，風格 B 另有明暗交界與描邊粗細。「光線跟著鏡頭」開啟時，光源方向以畫面為準。
- 按住 Shift 並在畫面上拖曳，可以直接轉動光源。

設定不會被記住，每次開啟都從「柔和攝影棚」開始。

專案附了一個範例檔 `samples/triangle.glb`，可以拿來試試看。

## 更新

標題列右上角的「更新」旁邊顯示目前的版本號。按下去會連到 GitHub 檢查最新版本：

1. 有新版時，會顯示目前與最新的版本號，按「更新」才會開始下載並安裝。
2. 完成後請關閉視窗，再重新開啟，才會使用新版。
3. 平常不會自動檢查，也不會自動連網。

更新只會覆蓋安裝資料夾裡的檔案，不會動到 `.glb` 的關聯設定。下載失敗或內容不完整時，會顯示錯誤，安裝資料夾維持原狀。

從原始碼資料夾直接執行時是開發模式，按鈕會提示不支援更新。

沒有「更新」按鈕的舊版，請再執行一次上面的安裝指令，之後就能用按鈕更新。

## 移除

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/wkai2573/glb-viewer/main/uninstall.ps1).TrimStart([char]0xFEFF)))
```

或者執行安裝資料夾裡的 `uninstall.ps1`：

```powershell
& "$env:LOCALAPPDATA\GlbViewer\uninstall.ps1"
```

會刪除安裝資料夾與登錄項目。

## 運作方式

雙擊後，`GlbViewer.vbs` 以無視窗方式啟動 `GlbViewer.ps1`。它只在 `127.0.0.1` 的隨機埠上開一個暫時的本機伺服器，提供檢視頁、模型與 three.js 的腳本，然後用 Microsoft Edge 的應用程式視窗開啟。找不到 Edge 時改用預設瀏覽器。網址帶有隨機路徑，並且會檢查請求的主機名稱。視窗關閉時頁面會通知伺服器，伺服器在幾秒內自行結束。

## 限制

- 只支援 `.glb`。`.gltf` 常依賴外部檔案，沒有處理。
- 使用 Draco 壓縮的模型，會從 Google 的網站載入解碼器，這類模型需要網路。
- 使用 KTX2 貼圖壓縮或 Meshopt 壓縮的模型不支援，會顯示錯誤訊息。
- 僅支援 Windows，需要 Windows PowerShell 5.1，系統內建即有。

## 開發與測試

```powershell
powershell -ExecutionPolicy Bypass -File .\test.ps1
```

測試會以真實的 Windows PowerShell 啟動伺服器，只透過 HTTP 驗證行為，並在暫存資料夾與測試專用的登錄位置跑完整的安裝、重裝、移除，不會動到真正的設定。

### 發佈新版本

版本號寫在專案根目錄的 `VERSION`，格式是三段數字。更新按鈕讀的是 GitHub 上 main 分支的這個檔案，數字比使用者安裝的大就視為有新版。所以發佈新版只要改 `VERSION`，再 push 到 main。

更新時，程式會下載 main 的壓縮檔，並用裡面新版的 `install.ps1 -InstallDir <安裝資料夾> -UpdateOnly` 覆蓋檔案。因此這兩個參數要維持相容，否則舊版安裝的使用者會更新失敗。

## 授權

本專案以 [MIT 授權](LICENSE) 釋出。

附帶的 [three.js](https://github.com/mrdoob/three.js) r128 以 MIT 授權釋出，授權文字見 [src/three.LICENSE.txt](src/three.LICENSE.txt)。
