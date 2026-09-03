# RO 純水回洗韌體（NodeMCU / Lua）

設計說明在計畫檔：`C:\Users\daichin\.claude\plans\1-rosy-squirrel.md`

## 檔案

| 檔案 | 職責 |
|---|---|
| `init.lua` | 開機入口。**第一件事就是把四路繼電器壓成 LOW**，然後延遲 5 秒才啟動應用 |
| `ro.lua` | 狀態機。100ms tick，安全檢查在最前面 |
| `cfg.lua` | 參數持久化（`cfg.txt`），含硬上限 |
| `web.lua` | 極小的 HTTP 設定介面與手動觸發 |
| `wifi_cfg.lua` | WiFi 連線（**選配**，要先填 SSID／密碼） |

## 燒錄前

1. NodeMCU 韌體需含模組：`gpio` `tmr` `file` `net` `wifi` `string`（3.x 的 file 物件 API）。
2. 編輯 `wifi_cfg.lua` 填入 SSID／密碼。**留空就完全跳過 WiFi**，沖洗邏輯照常離線運作。
3. 用 ESPlorer／nodemcu-tool 上傳全部 `.lua`。`init.lua` 最後上傳。

## 開機的安全窗口

`init.lua` 會在啟動應用前等 5 秒。若某支檔案改壞造成開機迴圈，在這 5 秒內從序列埠下：

```
stop()
```

就會取消啟動，不必重刷韌體。

## 設定介面

連上後開 `http://<裝置IP>/`

| 路徑 | 作用 |
|---|---|
| `/` | 狀態頁 ＋ 參數表單 |
| `/set?flush=8&interval=30` | 改參數（秒／分鐘），寫入 flash |
| `/flush` | 手動沖洗（跳過補桶，測試用） |
| `/cycle` | 手動補桶＋沖洗 |
| `/stop` | 立即停止，四路復歸 |
| `/status` | 純文字狀態，方便腳本抓 |

## 參數

| 參數 | 預設 | 硬上限 |
|---|---|---|
| 沖洗時間 `T_FLUSH` | 8s | **15s** |
| 沖洗週期 `MIN_INTERVAL` | 30 分鐘 | — |
| 充管延遲 `T_PRIME` | 2s | — |

**硬上限不是形式**：沖洗時 K_tank 關閉，桶是一個封閉、沒有補水的容器，把它抽乾就是泵乾轉。上限寫在 `cfg.lua` 的 `T_FLUSH_MAX_MS`，量完桶容積與泵流量後應該往下調到實測的安全值。

## 狀態機

```
IDLE ──(有人用水)──> used=true
     └─(used 且 週期到)─> REFILL ──(板子停機)──> FLUSH ──> IDLE
```

- **`used` 旗標**：沒人用水就不沖。膜殼裡本來就是純水，再沖只是空轉。
- **沖洗中偵測到板子啟動 → 立刻中止**：代表有人開了龍頭。此時廢水閥全開、膜建不起壓力，硬撐下去使用者會沒水喝。中止不更新 `last_flush`，用完水自動重試。
- 這個中止同時是**核心假設的哨兵**：若在沒人用水時觸發，就代表「沖洗對板子隱形」的隔離假設不成立。日誌會直接告訴你。

## 語法檢查

沒有 Lua 工具鏈時，可用 scratchpad 裡的結構檢查器（檢查 `end` 配對、括號、`if`/`then`）：

```bash
python luacheck.py init.lua cfg.lua ro.lua web.lua wifi_cfg.lua
```

它只驗結構，不驗執行期符號 —— NodeMCU 的 `gpio`／`tmr` 等全域在 PC 上不存在，本來也檢查不到。
