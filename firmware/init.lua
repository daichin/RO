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

  -- 網頁介面是選配，而且它很貴：web 約 12.5 KB、wifi_cfg 約 2 KB，
  -- 加上執行期要留給 HTTP 緩衝與 log 寫檔的餘裕，總共需要約 20 KB。
  --
  -- 未開 LFS 的韌體上，ro+cfg+log 已經吃掉 27 KB 的 41 KB 堆積，剩下的
  -- 塞不下。硬載的話會在中途 OOM —— 而且是載到一半才炸，狀態難以預期。
  --
  -- 所以先看夠不夠再決定載不載。不夠就乾脆完全跳過，機器維持純離線運作：
  -- 沖洗邏輯完全不受影響，只是不能用網頁改參數。
  --
  -- 開啟 LFS 重編韌體之後，模組的位元組碼會住在 flash 而不是 RAM，
  -- 堆積會遠高於這個門檻，這段就會自動開始載入網頁介面，不用改程式。
  local WEB_MIN_HEAP = 20000

  if node.heap() < WEB_MIN_HEAP then
    print(string.format(
      "[boot] 堆積 %d < %d，跳過網頁介面，純離線運作（沖洗邏輯不受影響）",
      node.heap(), WEB_MIN_HEAP))
    print("[boot] 想要網頁介面請重編韌體並開啟 LFS，詳見 firmware/README.md")
    return
  end

  -- 順序：先 require（編譯，最吃記憶體，趁堆積還多時做），
  --       連上網拿到 IP 之後才 listen（只是綁 socket，幾乎不吃記憶體）。
  local ok, web = pcall(require, "web")
  if not ok then
    print("[boot] web 載入失敗，離線運作: " .. tostring(web))
    web = nil
  end
  collectgarbage()
  heap("web")

  local ok2, err = pcall(function()
    require("wifi_cfg").start(function()
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
