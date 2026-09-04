-- init.lua  ── 開機入口
--
-- 唯一的職責：在做任何其他事情之前，把四路繼電器壓成安全狀態。
--
-- 繼電器模組跳線設在 L（低電平觸發），並用 open-drain 驅動：
-- HIGH = 放開成高阻抗 → 模組自己上拉到 5V → 光耦截止 → 繼電器斷開。
-- 四路斷開 = 機器退化成單純的直通式 RO，照常出水。
--
-- 之後才延遲啟動應用程式。延遲的用意是留一個窗口 ──
-- 如果 ro.lua 或 web.lua 寫壞造成開機迴圈，可以在這 5 秒內
-- 用序列埠下 `stop()` 把啟動取消，不必重刷韌體。

local PINS_OUT = { 1, 2, 5, 6 }   -- D1 K_perm / D2 K_pump / D5 K_waste / D6 K_tank

for _, p in ipairs(PINS_OUT) do
  gpio.mode(p, gpio.OPENDRAIN)
  gpio.write(p, gpio.HIGH)
end

print("[boot] relays forced off")

_G.cancel_boot = false
function stop()
  _G.cancel_boot = true
  print("[boot] cancelled -- 應用程式不會啟動")
end

local boot = tmr.create()
boot:alarm(5000, tmr.ALARM_SINGLE, function()
  if _G.cancel_boot then return end

  -- WiFi 是選配。連不上不影響沖洗邏輯，所以先起狀態機再連網。
  local ro = require("ro")
  ro.start()

  local ok, err = pcall(function()
    require("wifi_cfg").start()
    require("web").start()
  end)
  if not ok then
    print("[boot] 網路/網頁啟動失敗，離線運作: " .. tostring(err))
  end
end)
