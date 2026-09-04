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

## 編譯 NodeMCU 韌體要選哪些模組

ESP8266 建議選 **Lua 5.1 release** 分支：5.3 吃更多 RAM，而這裡有跑 HTTP server，
ESP8266 的堆積空間本來就緊。程式碼兩邊都相容。

**必要的五個**（`string` `table` `math` 是 Lua 核心，不用選）：

| 模組 | 用在哪 |
|---|---|
| `GPIO` | 四路繼電器輸出、IN1／IN2 兩路輸入 |
| `timer` | 100ms 主 tick、開機延遲 |
| `file` | `cfg.txt` 參數持久化（SPIFFS） |
| `net` | HTTP 設定介面 |
| `wifi` | 連線 |

**刻意不需要的**（勾了只是浪費 flash）：

- `TLS / mbedTLS` —— 只跑純 HTTP。這個省最多空間
- `sjson` —— 設定刻意用純文字 `key=value`，就是為了不依賴它
- `SNTP` / `rtctime` —— 狀態機用開機以來的毫秒累加，**完全不需要對時**
- `MQTT`、`HTTP client`、`crypto`、`encoder`、`ow`、`i2c`、`spi`、`pwm`、`u8g2`
- `ADC` —— A0 目前保留沒用，之後接 TDS 探頭時再開

**更保守的選擇**：拿掉 `net` 和 `wifi` 也能跑。沖洗邏輯完全離線，只是改 `T_FLUSH`
要重新上傳 `cfg.lua`。少兩個模組、少一整類當機來源 —— 對一台泡在水槽下面五年的
機器來說值得考慮。`init.lua` 的 `pcall` 已經把網路啟動包起來，模組不存在只會印一
行錯誤，不影響狀態機。

### 兩個 API 相容性陷阱

- **`file` 物件 API**：`cfg.lua` 用 `local f = file.open(...)` 再 `f:readline()`。
  NodeMCU 2.x 以後才有，3.x 是標準。很舊的 5.1 build 只有全域式的
  `file.readline()`，那樣 `cfg.lua` 要改。
- **`wifi.eventmon` 是 ESP8266 專用**：ESP32 版 NodeMCU 沒有，要改用
  `wifi.sta.on(...)`。

## 燒錄前

1. 依上面選好模組編譯（或用 nodemcu-build.com）。
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
