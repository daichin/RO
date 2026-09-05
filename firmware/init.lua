-- init.lua  ── 開機入口
--
-- 這是唯一必須留在 SPIFFS、不能編譯、也不能放進 LFS 的檔案（NodeMCU 開機
-- 時按檔名找 init.lua），所以每次改動都要走一次序列埠上傳。刻意保持精簡 ——
-- 曾經因為註解太多、上傳被截斷而開不了機。各段的理由寫在 README。

local PINS_OUT = { 1, 2, 5, 6 }   -- D1 K_perm / D2 K_pump / D5 K_waste / D6 K_tank

-- 第一件事：放開成高阻抗 = 繼電器斷開（低電平觸發 + open-drain）
for _, p in ipairs(PINS_OUT) do
  gpio.mode(p, gpio.OPENDRAIN)
  gpio.write(p, gpio.HIGH)
end
print("[boot] relays forced off")

-- 5 秒窗口：改壞了在這期間下 stop() 就能打斷，不必重刷韌體
_G.cancel_boot = false
function stop()
  _G.cancel_boot = true
  print("[boot] cancelled")
end

local function heap(tag)
  print(string.format("[mem] %-4s heap=%d", tag, node.heap()))
end

local boot = tmr.create()
boot:alarm(5000, tmr.ALARM_SINGLE, function()
  if _G.cancel_boot then return end
  heap("boot")

  -- NodeMCU 3.0 的 require 不搜尋 LFS，要自己掛 loader
  if node.LFS and node.LFS.time then
    package.loaders[3] = function(n) return node.LFS.get(n) end
    print("[boot] LFS loader ok")
  end

  -- pcall：載入失敗不能變成開機迴圈。停在這裡繼電器仍是斷開的
  local ok, err = pcall(function() require("ro").start() end)
  if not ok then
    print("[boot] 狀態機啟動失敗，繼電器保持斷開: " .. tostring(err))
    return
  end
  collectgarbage()
  heap("ro")

  -- 網頁介面約需 20 KB（web 12.5 + wifi 2 + 執行期餘裕）。不夠就整個跳過
  if node.heap() < 20000 then
    print("[boot] 堆積不足，跳過網頁介面（沖洗邏輯不受影響）")
    return
  end

  -- 先 require（編譯，最吃記憶體），拿到 IP 才 listen
  local web
  ok, web = pcall(require, "web")
  if not ok then
    print("[boot] web 載入失敗: " .. tostring(web))
    web = nil
  end
  collectgarbage()
  heap("web")

  ok, err = pcall(function()
    require("wifi_cfg").start(function()
      if web then
        if not pcall(web.start) then print("[boot] web 啟動失敗") end
        heap("srv")
      end
    end)
  end)
  if not ok then print("[boot] wifi 啟動失敗: " .. tostring(err)) end
end)
