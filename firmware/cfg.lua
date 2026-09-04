-- cfg.lua  ── 可在執行時變更、且斷電後保留的參數
--
-- 存成純文字 key=value，避免依賴 sjson。
-- 檔案讀不到或壞掉時一律退回預設值，機器不會因為設定檔而停擺。
--
-- 整數版韌體注意：全檔不使用 %f 格式。整數版的 LUA_NUMBER 是 int32，
-- `8000 / 1000` 直接得到整數 8，而 %f 不一定編進去。秒數一律用 fmt_s()
-- 以整數運算組出 "8.5" 這種字串。

local M = {}

local FILE = "cfg.txt"

-- ── 硬上限：韌體拒絕任何超過這個值的設定 ────────────────────────
-- 沖洗時 K_tank 是關的，桶是一個封閉、沒有補水的容器。
-- 1000G 系統的泵流量大，把桶抽乾就是乾轉傷泵。
-- 這個上限是最後一道防線，量測三做完後應該再往下調到實測的安全值。
M.T_FLUSH_MAX_MS   = 15000
M.T_ISOLATE_MAX_MS = 2000

-- ── 預設值 ────────────────────────────────────────────────────
M.t_flush_ms      = 8000              -- 沖洗時間
M.min_interval_ms = 30 * 60 * 1000    -- 沖洗週期
M.t_isolate_ms    = 200               -- K_tank 關閉後、開其他閥之前的間隔
M.t_prime_ms      = 2000              -- 充管延遲，避免泵空打

-- 毫秒 → "8.5" 這種字串。純整數運算，整數版韌體也正確。
function M.fmt_s(ms)
  return string.format("%d.%d", math.floor(ms / 1000),
                       math.floor((ms % 1000) / 100))
end

local function num(s)
  local v = tonumber(s)
  if v and v == v then return v end   -- v == v 排除 nan
  return nil
end

function M.load()
  local f = file.open(FILE, "r")
  if not f then
    print("[cfg] 無設定檔，使用預設值")
    return
  end
  while true do
    local line = f:readline()
    if not line then break end
    local k, v = line:match("^(%w+)=(%-?[%d%.]+)")
    if k == "flush"    then M.t_flush_ms      = num(v) or M.t_flush_ms end
    if k == "interval" then M.min_interval_ms = num(v) or M.min_interval_ms end
    if k == "isolate"  then M.t_isolate_ms    = num(v) or M.t_isolate_ms end
  end
  f:close()

  -- 即使檔案裡是個離譜的值也要夾回範圍，設定檔不該有繞過上限的能力
  M.t_flush_ms   = math.min(math.max(M.t_flush_ms, 1000), M.T_FLUSH_MAX_MS)
  M.t_isolate_ms = math.min(math.max(M.t_isolate_ms, 0), M.T_ISOLATE_MAX_MS)
  if M.min_interval_ms < 0 then M.min_interval_ms = 0 end

  print(string.format("[cfg] flush=%dms interval=%dms isolate=%dms",
        M.t_flush_ms, M.min_interval_ms, M.t_isolate_ms))
end

function M.save()
  local f = file.open(FILE, "w")
  if not f then
    print("[cfg] 寫入失敗")
    return false
  end
  f:write(string.format("flush=%d\ninterval=%d\nisolate=%d\n",
          M.t_flush_ms, M.min_interval_ms, M.t_isolate_ms))
  f:close()
  return true
end

-- 設定沖洗秒數。回傳 ok, 訊息。
function M.set_flush(seconds)
  local s = num(seconds)
  if not s then return false, "不是數字" end
  local ms = math.floor(s * 1000)
  if ms < 1000 then
    return false, "太短，至少 1 秒"
  end
  if ms > M.T_FLUSH_MAX_MS then
    return false, "超過硬上限 " .. M.fmt_s(M.T_FLUSH_MAX_MS) .. " 秒（防止泵乾轉）"
  end
  M.t_flush_ms = ms
  M.save()
  return true, "沖洗時間 = " .. M.fmt_s(ms) .. " 秒"
end

-- 設定沖洗週期（分鐘）。
function M.set_interval(minutes)
  local m = num(minutes)
  if not m then return false, "不是數字" end
  if m < 0 then return false, "不能是負數" end
  M.min_interval_ms = math.floor(m * 60 * 1000)
  M.save()
  return true, string.format("沖洗週期 = %d 分鐘", math.floor(m))
end

-- 設定隔離延遲（毫秒）。
function M.set_isolate(ms_in)
  local v = num(ms_in)
  if not v then return false, "不是數字" end
  local ms = math.floor(v)
  if ms < 0 or ms > M.T_ISOLATE_MAX_MS then
    return false, string.format("要在 0–%d ms 之間", M.T_ISOLATE_MAX_MS)
  end
  M.t_isolate_ms = ms
  M.save()
  return true, string.format("隔離延遲 = %d ms", ms)
end

return M
