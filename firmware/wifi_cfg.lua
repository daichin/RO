-- wifi_cfg.lua  ── WiFi 連線（選配）
--
-- WiFi 只是為了讓你能隨時改參數。整套沖洗邏輯完全離線可運作 ——
-- 連不上、斷線、重連都不會影響 ro.lua 的時序或 ABORT 路徑，
-- 因為這裡用的全是非阻塞的事件回呼，沒有任何等待迴圈。
--
-- 把下面兩行填好即可。留空字串就完全跳過 WiFi。

local SSID = ""
local PASS = ""

local M = {}

function M.start()
  if SSID == "" then
    print("[wifi] 未設定 SSID，離線運作")
    return
  end

  wifi.setmode(wifi.STATION)
  wifi.sta.config({ ssid = SSID, pwd = PASS, auto = true, save = false })

  -- 事件回呼，不是輪詢等待。連線失敗只是印一行，不會卡住任何東西。
  wifi.eventmon.register(wifi.eventmon.STA_GOT_IP, function(t)
    print("[wifi] 已連線 " .. t.IP)
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
