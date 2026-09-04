-- ro.lua  ── 純水回洗狀態機
--
-- 核心假設（見 docs/design-plan.md「核心設計」）：
--   K_tank 關閉時，桶與管路被隔離。沖洗期間廢水閥全開、膜幾乎沒有背壓，
--   透水量可忽略，而且純水管上的逆止閥另一側是充飽壓力的管路，推不開。
--   所以整個沖洗對控制板是隱形的 —— 高壓開關一路保持斷開，板子從頭到尾在睡。
--
-- 觸發是計時器，不是用水事件：
--   沖洗完成後開始計時，MIN_INTERVAL 內用水一律不沖；時間一到就補桶＋沖洗，
--   若那一刻正在用水，就等這次用完立刻做。
--   （若把觸發綁在用水事件上，某次用水剛好落在鎖定窗內就會被永久跳過，
--     之後很久沒人用水的話，膜殼就一直泡在自來水裡。）
--
-- 時間全部用 tick 累加，不用 tmr.now()，避免 32-bit 微秒回繞。

local cfg = require("cfg")
local log = require("log")

local M = {}

-- ── 腳位（NodeMCU 索引，不是 GPIO 編號）────────────────────────
local PIN_PERM  = 1   -- D1 / GPIO5   純水沖洗閥
local PIN_PUMP  = 2   -- D2 / GPIO4   強制啟動水泵
local PIN_WASTE = 5   -- D5 / GPIO14  廢水閥電源切換
local PIN_TANK  = 6   -- D6 / GPIO12  桶隔離閥
local PIN_IN1   = 7   -- D7 / GPIO13  控制板橘線：低 = 泵運轉
local PIN_IN2   = 0   -- D0 / GPIO16  藍綠安全鏈：低 = 缺水或漏水

local OUTPUTS = { PIN_PERM, PIN_PUMP, PIN_WASTE, PIN_TANK }

-- 繼電器模組跳線設在 L（低電平觸發），並用 open-drain 驅動。
--   開  = 拉低到 0V，在模組規格的 0–1.5V 觸發範圍內
--   關  = 放開成高阻抗，由模組自己上拉到 5V，光耦完全截止（零殘流）
-- 高電平觸發需要 3.8–5V，而 ESP8266 只有 3.3V，根本不在規格內。
local ON, OFF = gpio.LOW, gpio.HIGH

-- ── 時間常數 ───────────────────────────────────────────────────
local TICK_MS  = 100
local DEBOUNCE = 5                  -- 連續 5 個 tick（500ms）才承認電位改變
local POST_MS  = 2000               -- 關閥之間的間隔與洩壓時間
local REFILL_TIMEOUT_MS = 10 * 60 * 1000   -- 補桶逾時，避免卡死
local REFILL_NOPUMP_MS  = 60 * 1000        -- 開了 K_tank 但板子沒啟動 = 桶本來就滿的

-- 連續中止退避。若中止的原因是隔離假設不成立（沖洗本身吵醒了板子），
-- 會變成「補桶 → 沖洗 → 板子醒 → 中止 → 板子停 → 補桶」的緊迴圈，
-- 一直操泵也會把 log 寫爆。
local ABORT_LOCK_N  = 3
local ABORT_LOCK_MS = 6 * 60 * 60 * 1000

-- 沖洗中的狀態。這幾個狀態下 K_tank 是關的，控制板應該完全不動。
local FLUSHING = { ISOLATE = true, PRIME = true, RUN = true, POST1 = true, POST2 = true }

-- ── 狀態 ───────────────────────────────────────────────────────
M.state       = "IDLE"
M.last_reason = "開機"
M.flush_count = 0
M.abort_count = 0
M.last_abort  = nil

local now_ms      = 0
local deadline    = nil     -- 絕對時間（now_ms），nil = 這個狀態不靠計時推進
local last_flush  = nil     -- nil = 開機後還沒沖過，視為很久以前
local state_since = 0

-- used：上次沖洗之後控制板有沒有製過水。
--   沒人用水的話膜殼裡本來就是純水，再沖一次只是拿純水換純水，純粹空轉。
--   只在 IDLE 由 IN1 下降沿設定 —— REFILL 期間板子當然也在製水，
--   但那是我們自己叫的、而且緊接著就沖洗，不能拿來自我觸發。
local used = false

-- pending：計時器已到期但板子正在製水，等這次用完。純粹給狀態顯示用。
local pending = false

local refill_saw_pump = false
local consec_aborts   = 0
local lock_until      = nil

-- ── 去彈跳 ─────────────────────────────────────────────────────
local function new_input(pin, initial)
  return { pin = pin, raw = initial, n = DEBOUNCE, val = initial }
end
local in1, in2

local function sample(st)
  local v = gpio.read(st.pin)
  if v == st.raw then
    if st.n < DEBOUNCE then st.n = st.n + 1 end
  else
    st.raw, st.n = v, 0
  end
  if st.n >= DEBOUNCE and st.val ~= st.raw then
    local prev = st.val
    st.val = st.raw
    return prev, st.val          -- 回傳 (舊值, 新值) 表示發生變化
  end
  return nil
end

-- ── 輸出 ───────────────────────────────────────────────────────
local function all_off()
  for _, p in ipairs(OUTPUTS) do gpio.write(p, OFF) end
end

local function enter(state, hold_ms, reason)
  M.state       = state
  M.last_reason = reason or M.last_reason
  state_since   = now_ms
  deadline      = hold_ms and (now_ms + hold_ms) or nil
  print(string.format("[ro] -> %s  (%s)", state, M.last_reason))
  log.event("STATE", state, M.last_reason)
end

-- 中止不更新 last_flush、也不清掉 used。回到 IDLE 後條件重新成立，
-- 會在適當時機自動重試，不需要額外的重試邏輯。
function M.abort(why)
  all_off()                        -- 安全動作先做完，之後才記 log
  M.abort_count = M.abort_count + 1
  M.last_abort  = why
  pending       = false
  consec_aborts = consec_aborts + 1

  M.state       = "IDLE"
  M.last_reason = "ABORT: " .. why
  state_since   = now_ms
  deadline      = nil
  print("[ro] ABORT: " .. why)
  log.event("ABORT", "IDLE", why)

  if consec_aborts >= ABORT_LOCK_N then
    lock_until = now_ms + ABORT_LOCK_MS
    log.event("LOCK", "IDLE", string.format(
      "連續中止 %d 次，鎖定 %d 小時。若這幾次都不是你開龍頭造成的，代表隔離假設不成立",
      consec_aborts, ABORT_LOCK_MS / 3600000))
  end
end

-- ── 條件 ───────────────────────────────────────────────────────
local function interval_elapsed()
  if last_flush == nil then return true end
  return (now_ms - last_flush) >= cfg.min_interval_ms
end

local function locked()
  return lock_until and now_ms < lock_until
end

function M.time_since_flush_ms()
  if last_flush == nil then return nil end
  return now_ms - last_flush
end

-- ── 動作 ───────────────────────────────────────────────────────

-- 補桶：把桶接回管路，讓控制板自己去把它填滿。
-- 必須排在沖洗之前 —— 反過來的話補桶會把自來水推回膜殼，前功盡棄。
local function begin_refill(reason)
  refill_saw_pump = false
  pending         = false
  gpio.write(PIN_TANK, ON)
  enter("REFILL", nil, reason)
end

-- 沖洗第一步：先把桶隔離，等 T_ISOLATE 之後才動其他閥。
-- 繼電器與電磁閥不是同時動作的，若 K_tank 還沒關到底、K_perm 就已經開了，
-- 那一瞬間桶和管路同時通到泵前三通，管路壓力會被拉掉、把板子吵醒。
local function begin_flush(reason)
  gpio.write(PIN_TANK, OFF)
  enter("ISOLATE", cfg.t_isolate_ms, reason)
end

-- ── 事件 ───────────────────────────────────────────────────────

-- 控制板停機（IN1 上升沿）
local function on_board_stop()
  if M.state == "REFILL" then
    begin_flush("桶已補滿")
  end
  -- IDLE 的觸發不在這裡處理：每個 tick 都會重新評估條件，
  -- 板子一停機 in1.val 就變成 1，下一個 tick 自然進 REFILL。
end

-- 控制板啟動（IN1 下降沿）
local function on_board_start()
  if M.state == "IDLE" then
    if not used then
      used = true
      M.last_reason = "偵測到用水，本週期結束後會沖洗"
    end

  elseif M.state == "REFILL" then
    refill_saw_pump = true

  elseif FLUSHING[M.state] then
    -- 沖洗期間 K_tank 是關的，板子應該完全不動。它動了就代表有人開了龍頭
    -- 把管路壓力放掉。此刻廢水閥全開、膜建不起壓力，硬撐下去使用者會沒水喝。
    --
    -- 這同時是核心假設的哨兵：若在沒有人用水的情況下觸發，
    -- 就代表「沖洗對板子隱形」的隔離假設不成立。
    M.abort("使用者開了龍頭，把機器讓回去")
  end
end

-- ── 主迴圈 ─────────────────────────────────────────────────────
local function tick()
  now_ms = now_ms + TICK_MS
  log.set_uptime(math.floor(now_ms / 1000))

  -- 1. 安全檢查放在最前面，而且不做任何可能阻塞的事。
  --    K_pump 並聯在泵的供電上，繞過了「漏水繼電器 → 低壓開關」的保護鏈，
  --    所以這條路徑是漏水時唯一會停下泵的東西。
  if gpio.read(PIN_IN2) == 0 and M.state ~= "IDLE" then
    M.abort("安全鏈斷開（缺水或漏水）")
    return
  end
  sample(in2)

  -- 2. 讀控制板的泵訊號
  local prev, cur = sample(in1)
  if prev then
    if prev == 0 and cur == 1 then on_board_stop()  end
    if prev == 1 and cur == 0 then on_board_start() end
  end

  -- 3. 狀態推進
  if M.state == "IDLE" then
    -- 計時器觸發。板子正在製水就先掛著，等它停。
    if used and interval_elapsed() and in2.val == 1 and not locked() then
      if in1.val == 1 then
        begin_refill("週期到，開始補桶")
      elseif not pending then
        pending = true
        M.last_reason = "週期到，等這次用水結束"
      end
    end

  elseif M.state == "REFILL" then
    if not refill_saw_pump and (now_ms - state_since) > REFILL_NOPUMP_MS then
      -- 開了 K_tank 但板子始終沒動 = 桶本來就是滿的，直接進沖洗
      begin_flush("桶原本就是滿的")
    elseif (now_ms - state_since) > REFILL_TIMEOUT_MS then
      M.abort("補桶逾時，板子一直沒有停機")
    end

  elseif deadline and now_ms >= deadline then
    if M.state == "ISOLATE" then
      gpio.write(PIN_WASTE, ON)
      gpio.write(PIN_PERM,  ON)
      enter("PRIME", cfg.t_prime_ms, "桶已隔離，開廢水閥與純水閥")

    elseif M.state == "PRIME" then
      gpio.write(PIN_PUMP, ON)
      enter("RUN", cfg.t_flush_ms, "純水正沖中")

    elseif M.state == "RUN" then
      gpio.write(PIN_PUMP, OFF)
      enter("POST1", POST_MS, "停泵")

    elseif M.state == "POST1" then
      gpio.write(PIN_PERM, OFF)
      enter("POST2", POST_MS, "洩壓")

    elseif M.state == "POST2" then
      gpio.write(PIN_WASTE, OFF)
      last_flush    = now_ms
      used          = false
      consec_aborts = 0
      lock_until    = nil
      M.flush_count = M.flush_count + 1
      enter("IDLE", nil, "沖洗完成，膜殼裡是純水")
    end
  end
end

-- ── 對外 ───────────────────────────────────────────────────────

-- 手動觸發會清掉退避鎖定 —— 你既然親自按了，就是要它跑。
local function clear_lock()
  consec_aborts = 0
  lock_until    = nil
end

-- 手動觸發：跳過週期與補桶，直接沖。測試用。
function M.manual_flush()
  if M.state ~= "IDLE" then
    return false, "目前不在 IDLE（" .. M.state .. "）"
  end
  if gpio.read(PIN_IN2) == 0 then
    return false, "安全鏈異常，拒絕沖洗"
  end
  clear_lock()
  begin_flush("手動觸發")
  return true, "已開始沖洗"
end

-- 手動觸發完整循環：補桶再沖洗。
function M.manual_cycle()
  if M.state ~= "IDLE" then
    return false, "目前不在 IDLE（" .. M.state .. "）"
  end
  if gpio.read(PIN_IN2) == 0 then
    return false, "安全鏈異常，拒絕沖洗"
  end
  clear_lock()
  begin_refill("手動觸發完整循環")
  return true, "已開始補桶"
end

function M.stop()
  all_off()
  pending       = false
  M.state       = "IDLE"
  M.last_reason = "手動停止"
  deadline      = nil
  log.event("STATE", "IDLE", "手動停止")
end

function M.status()
  local due = nil
  if used and last_flush then
    due = cfg.min_interval_ms - (now_ms - last_flush)
    if due < 0 then due = 0 end
  end
  return {
    state       = M.state,
    reason      = M.last_reason,
    uptime_s    = math.floor(now_ms / 1000),
    boot_id     = log.boot_id,
    since_flush = M.time_since_flush_ms(),
    due_ms      = due,                         -- 還有多久到週期；nil = 沒在等
    used        = used,
    pending     = pending,
    locked_ms   = locked() and (lock_until - now_ms) or nil,
    aborts_run  = consec_aborts,               -- 連續中止次數
    flushes     = M.flush_count,
    aborts      = M.abort_count,
    last_abort  = M.last_abort,
    pump        = (in1 and in1.val == 0),      -- 控制板是否在跑泵
    safe        = (in2 and in2.val == 1),      -- 安全鏈是否正常
    t_flush_s   = cfg.fmt_s(cfg.t_flush_ms),
    interval_m  = math.floor(cfg.min_interval_ms / 60000),
    isolate_ms  = cfg.t_isolate_ms,
  }
end

function M.start()
  -- open-drain：關 = 放開成高阻抗，由模組上拉到 5V。
  -- 開機時 ESP8266 的 GPIO 預設就是輸入（高阻抗），等同「關」，
  -- 所以上電、重開機、燒錄韌體全程四路都是斷開的。
  for _, p in ipairs(OUTPUTS) do
    gpio.mode(p, gpio.OPENDRAIN)
    gpio.write(p, OFF)
  end
  gpio.mode(PIN_IN1, gpio.INPUT)
  gpio.mode(PIN_IN2, gpio.INPUT)

  in1 = new_input(PIN_IN1, gpio.read(PIN_IN1))
  in2 = new_input(PIN_IN2, gpio.read(PIN_IN2))

  cfg.load()
  log.start()

  M.timer = tmr.create()
  M.timer:alarm(TICK_MS, tmr.ALARM_AUTO, tick)
  enter("IDLE", nil, "已啟動，等待第一次用水")
end

return M
