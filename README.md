# glb-viewer

在 Windows 上雙擊 `.glb` 就能直接預覽 3D 模型，像開相片一樣。

- 獨立的小視窗，關掉就結束，不會留下背景程式。
- 完全離線可用，模型只在本機處理，不會上傳。
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

專案附了一個範例檔 `samples/triangle.glb`，可以拿來試試看。

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

雙擊後，`GlbViewer.vbs` 以無視窗方式啟動 `GlbViewer.ps1`。它只在 `127.0.0.1` 的隨機埠上開一個暫時的本機伺服器，提供檢視頁、模型與 `model-viewer` 元件，然後用 Microsoft Edge 的應用程式視窗開啟。找不到 Edge 時改用預設瀏覽器。網址帶有隨機路徑，並且會檢查請求的主機名稱。視窗關閉時頁面會通知伺服器，伺服器在幾秒內自行結束。

## 限制

- 只支援 `.glb`。`.gltf` 常依賴外部檔案，沒有處理。
- 使用 Draco 或 KTX2 壓縮的模型，`model-viewer` 會從 Google 的網站載入解碼器，這類模型需要網路。
- 僅支援 Windows，需要 Windows PowerShell 5.1，系統內建即有。

## 開發與測試

```powershell
powershell -ExecutionPolicy Bypass -File .\test.ps1
```

測試會以真實的 Windows PowerShell 啟動伺服器，只透過 HTTP 驗證行為，並在暫存資料夾與測試專用的登錄位置跑完整的安裝、重裝、移除，不會動到真正的設定。

## 授權

本專案以 [MIT 授權](LICENSE) 釋出。

附帶的 [model-viewer](https://github.com/google/model-viewer) 3.5.0 以 Apache-2.0 授權釋出，授權文字見 [src/model-viewer.LICENSE.txt](src/model-viewer.LICENSE.txt)。
