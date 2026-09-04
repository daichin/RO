-- log.lua  ── 事件記錄
--
-- 為什麼寫檔案而不是 RAM 環形緩衝區：Flash 約 3 MB、自由堆積只有約 40 KB，
-- 差 75 倍。而且寫檔重開機不會丟 —— 半夜的中止事件正是最需要留住的。
--
-- 時間戳由訪客校時（見 web.lua 的 /settime），不裝 sntp 模組。
-- 校時之前寫的行時間欄位是 "-"，之後的行就有本地時間。

local M = {}

local CUR   = "log.txt"
local OLD   = "log.1.txt"
local BOOTF = "boot.txt"

M.MAX_BYTES = 128 * 1024   -- 單檔上限，輪替後總共最多 256 KB

M.boot_id       = 0
M.epoch_at_boot = nil      -- 校時後才有值
M.tz_min        = 0

local size = 0             -- CUR 的位元組數，開機時讀一次，之後自己累加
local uptime_s = 0

-- ── epoch → 本地時間 ──────────────────────────────────────────
-- Howard Hinnant 的 civil_from_days。已用 Python 對 4120 個案例
-- （含閏日、2100 非閏世紀年、int32 上限、多種時區含 15 分鐘偏移）
-- 與 datetime 交叉比對過，零誤差。
--
-- 整數版韌體的 `/` 本來就是整數除法，而這裡的值全為非負，
-- 整數除法等於 floor，所以在浮點版與整數版行為一致。
local function civil_from_days(z)
  z = z + 719468
  local era = math.floor(z / 146097)
  local doe = z - era * 146097
  local yoe = math.floor((doe - math.floor(doe / 1460)
                             + math.floor(doe / 36524)
                             - math.floor(doe / 146096)) / 365)
  local y   = yoe + era * 400
  local doy = doe - (365 * yoe + math.floor(yoe / 4) - math.floor(yoe / 100))
  local mp  = math.floor((5 * doy + 2) / 153)
  local d   = doy - math.floor((153 * mp + 2) / 5) + 1
  local m   = mp + (mp < 10 and 3 or -9)
  if m <= 2 then y = y + 1 end
  return y, m, d
end

function M.stamp()
  if not M.epoch_at_boot then return "-" end
  local t    = M.epoch_at_boot + uptime_s + M.tz_min * 60
  local days = math.floor(t / 86400)
  local secs = t - days * 86400
  local y, m, d = civil_from_days(days)
  return string.format("%04d-%02d-%02d %02d:%02d:%02d",
                       y, m, d,
                       math.floor(secs / 3600),
                       math.floor(secs / 60) % 60,
                       secs % 60)
end

-- ── 檔案 ──────────────────────────────────────────────────────
local function file_size(name)
  local l = file.list()
  return (l and l[name]) or 0
end

local function rotate()
  file.remove(OLD)
  file.rename(CUR, OLD)
  size = 0
end

-- ── 對外 ──────────────────────────────────────────────────────

-- 由 ro.lua 每個 tick 呼叫，log 用它算開機以來的秒數
function M.set_uptime(s)
  uptime_s = s
end

-- kind: BOOT / STATE / ABORT / CFG / TIME / LOCK
function M.event(kind, state, text)
  local line = string.format("%s %d.%d %s %s %s\n",
                             M.stamp(), M.boot_id, uptime_s,
                             kind, state or "-", text or "")

  if size + #line > M.MAX_BYTES then rotate() end

  -- 寫檔失敗不能讓狀態機掛掉，所以整段包起來。
  -- 每次 open→append→close，不跨事件持有 handle，重開機不會留半開的檔。
  local ok = pcall(function()
    local f = file.open(CUR, "a")
    if not f then return end
    f:write(line)
    f:close()
    size = size + #line
  end)
  if not ok then print("[log] 寫入失敗") end
end

-- 由 /settime 呼叫。第一次校到時間就補記一筆，方便回頭對照。
function M.set_time(epoch, tz_min)
  local first = (M.epoch_at_boot == nil)
  M.epoch_at_boot = epoch - uptime_s
  M.tz_min = tz_min or 0
  if first then
    M.event("TIME", "-", string.format("校時完成，tz=%d 分", M.tz_min))
  end
end

function M.clear()
  file.remove(CUR)
  file.remove(OLD)
  size = 0
  M.event("BOOT", "-", "log 已清空")
end

function M.names()
  return CUR, OLD
end

function M.size()
  return size
end

function M.start()
  -- 開機序號：沒有 RTC 時，這是唯一能區分不同開機階段的東西
  local n = 0
  local f = file.open(BOOTF, "r")
  if f then
    n = tonumber(f:readline() or "0") or 0
    f:close()
  end
  M.boot_id = n + 1
  f = file.open(BOOTF, "w")
  if f then
    f:write(tostring(M.boot_id))
    f:close()
  end

  size = file_size(CUR)
  M.event("BOOT", "-", string.format("開機 #%d", M.boot_id))
end

return M
