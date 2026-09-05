-- wifi_cfg.lua  ── WiFi 連線（選配）
--
-- WiFi 只是為了讓你能隨時改參數。整套沖洗邏輯完全離線可運作 ——
-- 連不上、斷線、重連都不會影響 ro.lua 的時序或 ABORT 路徑，
-- 因為這裡用的全是非阻塞的事件回呼，沒有任何等待迴圈。
--
-- 帳密放在 wifi_secret.lua（未納版控），不放在這裡 ——
-- 這樣密碼不會被 commit 上去，pull 的時候也不會跟你的本機設定打架。
-- 照著 wifi_secret.lua.example 複製一份填好即可。
--
-- 沒有那個檔就走離線模式，沖洗邏輯完全不受影響，只是沒有網頁介面。

local SSID, PASS = "", ""
do
  local ok, sec = pcall(require, "wifi_secret")
  if ok and type(sec) == "table" then
    SSID, PASS = sec.ssid or "", sec.pass or ""
  end
end

local M = {}

-- on_ip: 拿到 IP 之後呼叫一次。init.lua 用它來延後啟動網頁伺服器，
--        避免在記憶體最緊的時候做事。
function M.start(on_ip)
  if SSID == "" then
    print("[wifi] 未設定 SSID，離線運作")
    return
  end

  wifi.setmode(wifi.STATION)
  wifi.sta.config({ ssid = SSID, pwd = PASS, auto = true, save = false })

  -- 事件回呼，不是輪詢等待。連線失敗只是印一行，不會卡住任何東西。
  local served = false
  wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, function(t)
    print("[wifi] 已連線 " .. t.IP)
    -- 斷線重連會再觸發一次，但伺服器只需要掛一次
    if on_ip and not served then
      served = true
      on_ip(t.IP)
    end
  end)

  wifi.eventmon.register(wifi.eventmon.STA_DISCONNECTED, function(t)
    print("[wifi] 斷線 reason=" .. tostring(t.reason) .. "，背景自動重連中")
  end)

  print("[wifi] 連線中 " .. SSID)
end

function M.ip()
  return wifi.sta.getip()
end

return M
