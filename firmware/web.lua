-- web.lua  ── 極小的設定介面
--
-- 只負責讀寫參數、手動觸發、讀 log。它跑在 NodeMCU 的非同步 socket
-- callback 裡，不會阻塞 ro.lua 的 100ms tick，斷網時整台機器照常運作。

local ro  = require("ro")
local cfg = require("cfg")
local log = require("log")

local M = {}

local TAIL_BYTES = 16 * 1024   -- /log 預設只回最後這麼多，避免手機拉一大包
local CHUNK      = 512         -- 每次送出的位元組數

local function esc(s)
  s = tostring(s or "")
  s = s:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
  return s
end

local function page(msg)
  local s = ro.status()
  local since = "尚未沖洗"
  if s.since_flush then
    since = string.format("%d 分鐘前", math.floor(s.since_flush / 60000))
  end

  -- 下一次沖洗：四種情況要分清楚，否則看不出「為什麼還沒沖」
  local next_flush
  if s.locked_ms then
    next_flush = string.format("<b>已鎖定</b>，連續中止 %d 次，%d 分鐘後解除",
                               s.aborts_run, math.ceil(s.locked_ms / 60000))
  elseif not s.used then
    next_flush = "上次沖洗後還沒人用水，不需要沖"
  elseif s.pending then
    next_flush = "週期已到，等這次用水結束"
  elseif s.due_ms then
    next_flush = string.format("約 %d 分鐘後", math.ceil(s.due_ms / 60000))
  else
    next_flush = "待命"
  end

  local banner = ""
  if msg and msg ~= "" then
    banner = "<p class=m>" .. esc(msg) .. "</p>"
  end

  return table.concat({
    "<!DOCTYPE html><meta charset=utf-8>",
    "<meta name=viewport content='width=device-width,initial-scale=1'>",
    "<title>RO 純水回洗</title>",
    "<style>body{font:16px/1.7 system-ui,sans-serif;margin:0;padding:20px;",
    "max-width:520px;background:#eef2f3;color:#0d1b21}",
    "h1{font-size:20px;margin:0 0 16px}",
    "table{width:100%;border-collapse:collapse;background:#fff;margin-bottom:18px}",
    "td{padding:8px 12px;border-bottom:1px solid #d2dde0}",
    "td:first-child{color:#6c7f85;width:44%}",
    "form{background:#fff;padding:14px;margin-bottom:12px}",
    "input{font:inherit;width:80px;padding:4px}",
    "button{font:inherit;padding:6px 14px;margin-right:8px}",
    "a{color:#0b6e8c}",
    ".m{background:#dcedf3;border-left:3px solid #0b6e8c;padding:10px 14px}",
    "</style>",
    "<h1>RO 純水回洗</h1>", banner,
    "<table>",
    "<tr><td>狀態</td><td><b>", esc(s.state), "</b></td></tr>",
    "<tr><td>說明</td><td>", esc(s.reason), "</td></tr>",
    "<tr><td>控制板泵</td><td>", (s.pump and "運轉中" or "停止"), "</td></tr>",
    "<tr><td>安全鏈</td><td>", (s.safe and "正常" or "<b>異常</b>"), "</td></tr>",
    "<tr><td>上次沖洗</td><td>", since, "</td></tr>",
    "<tr><td>下次沖洗</td><td>", next_flush, "</td></tr>",
    "<tr><td>累計沖洗</td><td>", esc(s.flushes), " 次</td></tr>",
    "<tr><td>中止次數</td><td>", esc(s.aborts),
      (s.last_abort and ("（" .. esc(s.last_abort) .. "）") or ""), "</td></tr>",
    "<tr><td>開機序號 · 運行</td><td>#", esc(s.boot_id), " · ", esc(s.uptime_s), " 秒</td></tr>",
    "</table>",
    "<form action=/set>",
    "沖洗時間 <input name=flush value=", esc(s.t_flush_s), "> 秒",
    "（上限 ", esc(cfg.fmt_s(cfg.T_FLUSH_MAX_MS)), " 秒）<br>",
    "沖洗週期 <input name=interval value=", esc(s.interval_m), "> 分鐘<br>",
    "隔離延遲 <input name=isolate value=", esc(s.isolate_ms), "> ms<br><br>",
    "<button>儲存</button></form>",
    "<form action=/flush><button>手動沖洗</button></form>",
    "<form action=/cycle><button>補桶＋沖洗</button></form>",
    "<form action=/stop><button>立即停止</button></form>",
    "<p><a href=/log>查看 log</a> ・ <a href='/log?full=1'>完整 log</a></p>",
    -- 校時：裝置沒有 RTC 也沒裝 sntp，靠訪客的瀏覽器告訴它現在幾點。
    -- 只要有人開過一次這頁，之後的 log 就有本地時間。
    "<script>fetch('/settime?t='+Math.floor(Date.now()/1000)",
    "+'&tz='+(-new Date().getTimezoneOffset()))</script>",
  })
end

-- ── /log 串流 ─────────────────────────────────────────────────
-- log 檔可達 128 KB 而自由堆積只有約 40 KB，整包讀進來會當機。
-- 所以分塊讀、在 "sent" 回呼裡接力，串完才關 socket。
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
          -- 只回最後 TAIL_BYTES：先跳到檔尾取大小，再倒推
          local sz = f:seek("end", 0) or 0
          f:seek("set", (sz > TAIL_BYTES) and (sz - TAIL_BYTES) or 0)
        end
        return true
      end
    end
  end

  local function pump(s)
    while true do
      if not f and not open_next() then
        s:close()
        return
      end
      local chunk = f:read(CHUNK)
      if chunk and #chunk > 0 then
        s:send(chunk)
        return
      end
      f:close()
      f = nil
    end
  end

  sck:on("sent", pump)
  sck:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\n" ..
           "Connection: close\r\n\r\n")
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
    return table.concat({
      "state=", s.state,
      " pump=", tostring(s.pump),
      " safe=", tostring(s.safe),
      " used=", tostring(s.used),
      " pending=", tostring(s.pending),
      " locked_ms=", tostring(s.locked_ms),
      " due_ms=", tostring(s.due_ms),
      " boot=", tostring(s.boot_id),
      " flushes=", tostring(s.flushes),
      " aborts=", tostring(s.aborts),
      " flush_s=", s.t_flush_s,
      " interval_m=", tostring(s.interval_m),
      " isolate_ms=", tostring(s.isolate_ms),
      -- node 幾乎所有 build 都有，但不值得為了它讓整個 /status 失敗
      " heap=", tostring(node and node.heap and node.heap() or "?"),
    }), "text/plain"
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
          sck:send("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n" ..
                   "Connection: close\r\n\r\ncleared\n")
          sck:on("sent", function(s) s:close() end)
        else
          serve_log(sck, q.full ~= nil)
        end
        return
      end

      local ok, body, ctype = pcall(handle, path, q)
      if not ok then
        body, ctype = "internal error", "text/plain"
      end
      ctype = ctype or "text/html; charset=utf-8"

      sck:on("sent", function(s) s:close() end)
      sck:send("HTTP/1.1 200 OK\r\nContent-Type: " .. ctype ..
               "\r\nConnection: close\r\n\r\n" .. body)
    end)
  end)
  print("[web] 設定介面已啟動 :80")
end

return M
