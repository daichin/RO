-- cfg.lua  ── 可在執行時變更、且斷電後保留的參數
--
-- 存成純文字 key=value，避免依賴 sjson。
-- 檔案讀不到或壞掉時一律退回預設值，機器不會因為設定檔而停擺。

local M = {}

local FILE = "cfg.txt"

-- ── 硬上限：韌體拒絕任何超過這個值的設定 ────────────────────────
-- 沖洗時 K_tank 是關的，桶是一個封閉、沒有補水的容器。
-- 1000G 系統的泵流量大，把桶抽乾就是乾轉傷泵。
-- 這個上限是最後一道防線，量測三做完後應該再往下調到實測的安全值。
M.T_FLUSH_MAX_MS = 15000

-- ── 預設值 ────────────────────────────────────────────────────
M.t_flush_ms      = 8000              -- 沖洗時間
M.min_interval_ms = 30 * 60 * 1000    -- 兩次純水沖洗的最短間隔
M.t_prime_ms      = 2000              -- 充管延遲，避免泵空打

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
  end
  f:close()

  -- 即使檔案裡是個離譜的值也要夾回範圍，設定檔不該有繞過上限的能力
  M.t_flush_ms = math.min(math.max(M.t_flush_ms, 1000), M.T_FLUSH_MAX_MS)
  if M.min_interval_ms < 0 then M.min_interval_ms = 0 end

  print(string.format("[cfg] flush=%dms interval=%dms",
        M.t_flush_ms, M.min_interval_ms))
end

function M.save()
  local f = file.open(FILE, "w")
  if not f then
    print("[cfg] 寫入失敗")
    return false
  end
  f:write(string.format("flush=%d\ninterval=%d\n",
          M.t_flush_ms, M.min_interval_ms))
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
    return false, string.format("超過硬上限 %.1f 秒（防止泵乾轉）",
                                M.T_FLUSH_MAX_MS / 1000)
  end
  M.t_flush_ms = ms
  M.save()
  return true, string.format("沖洗時間 = %.1f 秒", ms / 1000)
end

-- 設定最短間隔（分鐘）。
function M.set_interval(minutes)
  local m = num(minutes)
  if not m then return false, "不是數字" end
  if m < 0 then return false, "不能是負數" end
  M.min_interval_ms = math.floor(m * 60 * 1000)
  M.save()
  return true, string.format("最短間隔 = %.0f 分鐘", m)
end

return M
