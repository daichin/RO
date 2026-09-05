-- web.lua  ── 極小的設定介面
--
-- 只負責讀寫參數、手動觸發、讀 log。它跑在 NodeMCU 的非同步 socket
-- callback 裡，不會阻塞 ro.lua 的 100ms tick，斷網時整台機器照常運作。
--
-- 記憶體考量（實機量出來的教訓）：
--   ESP8266 開機後只有約 41 KB 堆積，ro+cfg+log 就吃掉 27 KB。
--   最早的版本把頁面拆成 45 個字串常數用 table.concat 組，結果每個字串
--   物件都有約 24 bytes 標頭、每個都是獨立的小配置 —— 光標頭近 1 KB，
--   而且嚴重碎片化，載入時連 272 bytes 都配不到。
--   所以頁面改成「兩個大樣板 + string.format」，常數數量從 45 降到個位數。
--   同理，這個檔裡的字串一律合併，不要為了排版拆行。

local ro  = require("ro")
local cfg = require("cfg")
local log = require("log")

local M = {}

local TAIL_BYTES = 16 * 1024   -- /log 預設只回最後這麼多
local CHUNK      = 512         -- 每次送出的位元組數

-- 一整頁一個樣板。%% 是字面的百分號（CSS 的 width:100%）。
local TPL = [[<!DOCTYPE html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>RO 純水回洗</title><style>body{font:16px/1.7 system-ui,sans-serif;margin:0;padding:16px;max-width:520px;background:#eef2f3;color:#0d1b21}h1{font-size:19px;margin:0 0 14px}table{width:100%%;border-collapse:collapse;background:#fff;margin-bottom:14px}td{padding:7px 10px;border-bottom:1px solid #d2dde0}td:first-child{color:#6c7f85;width:44%%}form{background:#fff;padding:12px;margin-bottom:10px}input{font:inherit;width:76px;padding:3px}button{font:inherit;padding:5px 12px}a{color:#0b6e8c}.m{background:#dcedf3;border-left:3px solid #0b6e8c;padding:9px 12px}</style><h1>RO 純水回洗</h1>%s<table><tr><td>狀態</td><td><b>%s</b></td></tr><tr><td>說明</td><td>%s</td></tr><tr><td>控制板泵</td><td>%s</td></tr><tr><td>安全鏈</td><td>%s</td></tr><tr><td>上次沖洗</td><td>%s</td></tr><tr><td>下次沖洗</td><td>%s</td></tr><tr><td>累計沖洗</td><td>%d 次</td></tr><tr><td>中止次數</td><td>%d%s</td></tr><tr><td>開機 · 運行</td><td>#%d · %d 秒</td></tr></table><form action=/set>沖洗時間 <input name=flush value=%s> 秒（上限 %s）<br>沖洗週期 <input name=interval value=%d> 分鐘<br>隔離延遲 <input name=isolate value=%d> ms<br><br><button>儲存</button></form><form action=/flush><button>手動沖洗</button></form><form action=/cycle><button>補桶＋沖洗</button></form><form action=/stop><button>立即停止</button></form><p><a href=/log>查看 log</a> ・ <a href="/log?full=1">完整 log</a></p><script>fetch('/settime?t='+Math.floor(Date.now()/1000)+'&tz='+(-new Date().getTimezoneOffset()))</script>]]

local function esc(s)
  s = tostring(s or "")
  return (s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"))
end

local function page(msg)
  local s = ro.status()

  local since = s.since_flush
      and string.format("%d 分鐘前", math.floor(s.since_flush / 60000))
      or "尚未沖洗"

  -- 下一次沖洗：四種情況要分清楚，否則看不出「為什麼還沒沖」
  local nxt
  if s.locked_ms then
    nxt = string.format("<b>已鎖定</b>，連續中止 %d 次，%d 分鐘後解除",
                        s.aborts_run, math.ceil(s.locked_ms / 60000))
  elseif not s.used then
    nxt = "上次沖洗後還沒人用水，不需要沖"
  elseif s.pending then
    nxt = "週期已到，等這次用水結束"
  elseif s.due_ms then
    nxt = string.format("約 %d 分鐘後", math.ceil(s.due_ms / 60000))
  else
    nxt = "待命"
  end

  return string.format(TPL,
    (msg and msg ~= "") and ('<p class=m>' .. esc(msg) .. '</p>') or "",
    esc(s.state), esc(s.reason),
    s.pump and "運轉中" or "停止",
    s.safe and "正常" or "<b>異常</b>",
    since, nxt,
    s.flushes, s.aborts,
    s.last_abort and ("（" .. esc(s.last_abort) .. "）") or "",
    s.boot_id, s.uptime_s,
    s.t_flush_s, cfg.fmt_s(cfg.T_FLUSH_MAX_MS),
    s.interval_m, s.isolate_ms)
end

-- ── /log 串流 ─────────────────────────────────────────────────
-- log 檔可達 128 KB 而自由堆積只有十幾 KB，整包讀進來會當機。
-- 分塊讀、在 "sent" 回呼裡接力，串完才關 socket。
-- NodeMCU 一次只保證開一個檔，所以兩個檔依序開關，不同時持有。
local function serve_log(sck, full)
  local CUR, OLD = log.names()
  local queue = full and { OLD, CUR } or { CUR }
  local qi, f = 0, nil

  local function open_next()
    while true do
      qi = qi + 1
      local name = queue[qi]
      if not name then return false end
      f = file.open(name, "r")
      if f then
        if not full then
          local sz = f:seek("end", 0) or 0
          f:seek("set", (sz > TAIL_BYTES) and (sz - TAIL_BYTES) or 0)
        end
        return true
      end
    end
  end

  local function pump(s)
    while true do
      if not f and not open_next() then s:close() return end
      local chunk = f:read(CHUNK)
      if chunk and #chunk > 0 then s:send(chunk) return end
      f:close()
      f = nil
    end
  end

  sck:on("sent", pump)
  sck:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nConnection: close\r\n\r\n")
end

-- ── 路由 ──────────────────────────────────────────────────────
local function handle(path, q)
  if path == "/set" then
    local msgs = {}
    local function apply(fn, v, label)
      if not v then return end
      local ok, m = fn(v)
      msgs[#msgs + 1] = (ok and "✓ " or "✗ ") .. m
      if ok then log.event("CFG", ro.state, label .. " → " .. m) end
    end
    apply(cfg.set_flush,    q.flush,    "沖洗時間")
    apply(cfg.set_interval, q.interval, "沖洗週期")
    apply(cfg.set_isolate,  q.isolate,  "隔離延遲")
    return page(table.concat(msgs, "　"))

  elseif path == "/flush" then
    local ok, m = ro.manual_flush()
    return page((ok and "✓ " or "✗ ") .. m)

  elseif path == "/cycle" then
    local ok, m = ro.manual_cycle()
    return page((ok and "✓ " or "✗ ") .. m)

  elseif path == "/stop" then
    ro.stop()
    return page("✓ 已停止，四路繼電器全部復歸")

  elseif path == "/settime" then
    local t = tonumber(q.t)
    if t then log.set_time(t, tonumber(q.tz) or 0) end
    return (t and "ok " or "bad ") .. log.stamp(), "text/plain"

  elseif path == "/status" then
    local s = ro.status()
    return string.format(
      "state=%s pump=%s safe=%s used=%s pending=%s locked_ms=%s due_ms=%s boot=%d flushes=%d aborts=%d flush_s=%s interval_m=%d isolate_ms=%d heap=%s",
      s.state, tostring(s.pump), tostring(s.safe), tostring(s.used),
      tostring(s.pending), tostring(s.locked_ms), tostring(s.due_ms),
      s.boot_id, s.flushes, s.aborts, s.t_flush_s, s.interval_m, s.isolate_ms,
      tostring(node and node.heap and node.heap() or "?")), "text/plain"
  end

  return page()
end

local function parse_query(qs)
  local q = {}
  if not qs then return q end
  for k, v in qs:gmatch("([^&=]+)=([^&]*)") do q[k] = v end
  return q
end

function M.start()
  M.srv = net.createServer(net.TCP, 30)
  M.srv:listen(80, function(conn)
    conn:on("receive", function(sck, payload)
      local target = payload:match("^GET%s+(%S+)") or "/"
      local path, qs = target:match("^([^?]*)%??(.*)$")
      local q = parse_query(qs)

      -- log 走串流，不能組成一個字串
      if path == "/log" then
        if q.clear then
          log.clear()
          sck:on("sent", function(s) s:close() end)
          sck:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\ncleared\n")
        else
          serve_log(sck, q.full ~= nil)
        end
        return
      end

      local ok, body, ctype = pcall(handle, path, q)
      if not ok then body, ctype = "internal error", "text/plain" end

      sck:on("sent", function(s) s:close() end)
      sck:send("HTTP/1.1 200 OK\r\nContent-Type: " ..
               (ctype or "text/html; charset=utf-8") ..
               "\r\nConnection: close\r\n\r\n" .. body)
    end)
  end)
  print("[web] 設定介面已啟動 :80")
end

return M
