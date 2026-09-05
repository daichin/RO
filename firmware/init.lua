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

local function heap(tag)
  print(string.format("[mem] %-4s heap=%d", tag, node.heap()))
end

local boot = tmr.create()
boot:alarm(5000, tmr.ALARM_SINGLE, function()
  if _G.cancel_boot then return end
  heap("boot")

  -- WiFi 是選配。連不上不影響沖洗邏輯，所以先起狀態機。
  require("ro").start()
  collectgarbage()
  heap("ro")

  -- 這裡的順序很重要。
  --
  -- 編譯 Lua 原始碼是整個開機流程中最吃記憶體的動作，而 WiFi 一連上就會
  -- 佔走一大塊堆積。原本 wifi 排在 web 前面，結果 web.lua 編到一半配不到
  -- 記憶體（E:M 64），整個網頁介面起不來。
  --
  -- 所以拆成兩步：先 require（編譯，趁堆積還多），連上網之後才 listen。
  local ok, web = pcall(require, "web")
  if not ok then
    print("[boot] web 載入失敗，離線運作: " .. tostring(web))
    web = nil
  end
  collectgarbage()
  heap("web")

  local ok2, err = pcall(function()
    require("wifi_cfg").start(function()
      -- 拿到 IP 才掛伺服器。這時 web 早就編譯好了，只是綁一個 socket，
      -- 幾乎不吃記憶體。
      if web then
        local ok3, e = pcall(web.start)
        if not ok3 then print("[boot] web 啟動失敗: " .. tostring(e)) end
        heap("srv")
      end
    end)
  end)
  if not ok2 then
    print("[boot] wifi 啟動失敗，離線運作: " .. tostring(err))
  end
end)
