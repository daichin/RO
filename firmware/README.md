# RO 純水回洗韌體（NodeMCU / Lua）

設計說明：[`docs/design-plan.md`](../docs/design-plan.md)（完整計畫）、[`docs/ro-permeate-flush.html`](../docs/ro-permeate-flush.html)（同一份設計的網頁版）

## 檔案

| 檔案 | 職責 |
|---|---|
| `init.lua` | 開機入口。**第一件事就是把四路繼電器放開成斷開狀態**，然後延遲 5 秒才啟動應用 |
| `ro.lua` | 狀態機。100ms tick，安全檢查在最前面 |
| `cfg.lua` | 參數持久化（`cfg.txt`），含硬上限 |
| `web.lua` | 極小的 HTTP 設定介面與手動觸發 |
| `log.lua` | 事件記錄：寫 SPIFFS、輪替、epoch → 本地時間 |
| `wifi_cfg.lua` | WiFi 連線（**選配**） |
| `wifi_secret.lua` | WiFi 帳密。**未納版控**，照 `.example` 自行建立 |

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
2. 複製 `wifi_secret.lua.example` 成 `wifi_secret.lua` 並填入 SSID／密碼。
   **不建也可以** —— 找不到就走離線模式，沖洗邏輯照常運作，只是沒有網頁介面。
   這個檔在 `.gitignore` 裡，密碼不會進版控，pull 也不會跟本機設定打架。
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
| `/log` | 最後 16 KB 的事件記錄，串流輸出 |
| `/log?full=1` | 完整記錄（含輪替檔） |
| `/log?clear=1` | 清空記錄 |
| `/settime?t=<epoch>&tz=<分鐘>` | 校時。首頁載入時 JS 會自動呼叫一次 |

## 參數

| 參數 | 預設 | 硬上限 |
|---|---|---|
| 沖洗時間 `T_FLUSH` | 8s | **15s** |
| 沖洗週期 `MIN_INTERVAL` | 30 分鐘 | — |
| 隔離延遲 `T_ISOLATE` | 200ms | 2000ms |
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

這台機器上沒有 Lua 工具鏈，所以 `tools/` 底下放了兩支 Python 驗證腳本。

**結構檢查**（`end` 配對、括號、`if`/`then`）：

```bash
cd firmware && python ../tools/luacheck.py *.lua
```

它只驗結構，不驗執行期符號 —— NodeMCU 的 `gpio`／`tmr` 等全域在 PC 上不存在，本來也檢查不到。執行期的錯要靠設計計畫裡的階段一乾式測試。

**日曆換算交叉比對**：

```bash
python tools/check_civil.py
```

把 `log.lua` 的 `civil_from_days` 照抄成 Python，對 4120 個案例跟 `datetime` 比對。改到那段演算法時要重跑。

## 繼電器接線

模組跳線設在 **`L`（低電平觸發）**，韌體用 **open-drain** 驅動：

| 狀態 | GPIO | 模組輸入端 |
|---|---|---|
| 繼電器**開** | 拉低 | 0V，在規格的 0–1.5V 觸發範圍內 |
| 繼電器**關** | **放開成高阻抗** | 模組自己上拉到 5V，光耦完全截止 |

高電平觸發需要 3.8–5V，而 ESP8266 只有 3.3V，落在 1.5V 與 3.8V 中間、兩邊都不到 —— 那條路走不通。

開機時 GPIO 預設就是輸入（高阻抗），等同「關」，所以上電、重開機、燒錄韌體全程四路都是斷開的，不需要外部下拉電阻。

## 事件記錄

寫在 SPIFFS 的 `log.txt`，超過 128 KB 就輪替成 `log.1.txt`。以每天約 100 行估算，兩個檔約可留 40 天。重開機不會丟。

```
2026-09-05 03:12:45 7.1234 STATE REFILL 週期到，開始補桶
2026-09-05 03:12:59 7.1248 STATE IDLE 沖洗完成，膜殼裡是純水
- 7.90 BOOT - 開機 #7
```

欄位是「本地時間　開機序號.開機秒數　類別　狀態　說明」。類別有 `BOOT`／`STATE`／`ABORT`／`CFG`／`TIME`／`LOCK`。

**時間戳靠訪客校時**：裝置沒有 RTC，也沒裝 `sntp` 模組。首頁載入時會用三行 JS 把瀏覽器的時間送給裝置，之後寫的行就有本地時間；校時前的行時間欄位是 `-`。輪詢 `/status` 的腳本也可以順便帶 `/settime`。

日曆換算（epoch → 年月日）用 Howard Hinnant 的 `civil_from_days`，已在 PC 上對 4120 個案例與 Python 的 `datetime` 交叉比對過 —— 含閏日、2100 非閏世紀年、int32 上限、以及 15 分鐘偏移的時區。

### 連續中止退避

沖洗中偵測到控制板啟動就中止。如果中止的原因是隔離假設不成立（沖洗本身吵醒了板子），會變成「補桶 → 沖洗 → 板子醒 → 中止」的緊迴圈。

所以**連續 3 次中止而中間沒有一次成功沖洗，就鎖定 6 小時**並記一筆 `LOCK`。成功沖洗或手動觸發時清零。

看到 `LOCK` 就去比對 log 裡那三筆 `ABORT` 的時間 —— 如果都不是你開龍頭造成的，那就是核心假設有問題。

## 整數版韌體

目前燒的是 `integer` 版（`bin/` 裡那份），`LUA_NUMBER` 是 int32：

- **全部程式碼避開 `%f` 格式**。秒數用 `cfg.fmt_s()` 以整數運算組出 `8.5` 這種字串。
- 日曆換算的 `/` 在整數版本來就是整數除法，而算式裡的值全為非負，整數除法等於 `floor`，兩種版本行為一致。
