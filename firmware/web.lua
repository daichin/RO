-- web.lua  ── 極小的設定介面
--
-- 只負責讀寫參數與手動觸發。它跑在 NodeMCU 的非同步 socket callback 裡，
-- 不會阻塞 ro.lua 的 100ms tick，斷網時整台機器照常運作。

local ro  = require("ro")
local cfg = require("cfg")

local M = {}

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

  -- 下一次沖洗：三種情況要分清楚，否則看不出「為什麼還沒沖」
  local next_flush
  if not s.used then
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
    "<tr><td>運行時間</td><td>", esc(s.uptime_s), " 秒</td></tr>",
    "</table>",
    "<form action=/set>",
    "沖洗時間 <input name=flush value=", esc(s.t_flush_s), "> 秒",
    "（上限 ", esc(cfg.T_FLUSH_MAX_MS / 1000), " 秒）<br>",
    "沖洗週期 <input name=interval value=", esc(s.interval_m), "> 分鐘<br><br>",
    "<button>儲存</button></form>",
    "<form action=/flush><button>手動沖洗</button></form>",
    "<form action=/cycle><button>補桶＋沖洗</button></form>",
    "<form action=/stop><button>立即停止</button></form>",
  })
end

local function handle(path, q)
  if path == "/set" then
    local msgs = {}
    if q.flush then
      local ok, m = cfg.set_flush(q.flush)
      msgs[#msgs + 1] = (ok and "✓ " or "✗ ") .. m
    end
    if q.interval then
      local ok, m = cfg.set_interval(q.interval)
      msgs[#msgs + 1] = (ok and "✓ " or "✗ ") .. m
    end
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

  elseif path == "/status" then
    local s = ro.status()
    return string.format(
      "state=%s pump=%s safe=%s used=%s pending=%s due_ms=%s " ..
      "flushes=%d aborts=%d flush_s=%.1f interval_m=%.0f",
      s.state, tostring(s.pump), tostring(s.safe),
      tostring(s.used), tostring(s.pending), tostring(s.due_ms),
      s.flushes, s.aborts, s.t_flush_s, s.interval_m), "text/plain"
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
      local ok, body, ctype = pcall(function()
        local target = payload:match("^GET%s+(%S+)") or "/"
        local path, qs = target:match("^([^?]*)%??(.*)$")
        return handle(path, parse_query(qs))
      end)

      if not ok then
        body  = "internal error"
        ctype = "text/plain"
      end
      ctype = ctype or "text/html; charset=utf-8"

      sck:send("HTTP/1.1 200 OK\r\nContent-Type: " .. ctype ..
               "\r\nConnection: close\r\n\r\n" .. body)
    end)
    conn:on("sent", function(sck) sck:close() end)
  end)
  print("[web] 設定介面已啟動 :80")
end

return M
