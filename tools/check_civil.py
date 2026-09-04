"""Cross-check the Lua epoch -> local datetime algorithm against Python's datetime.

The Lua version (log.lua) uses Howard Hinnant's civil_from_days. This is a
line-for-line port so a mismatch here means the Lua is wrong too.

NodeMCU integer builds do integer division for `/`, which equals floor() for
the non-negative values used here, so math.floor() is a no-op there. We model
that with // to make sure the algorithm doesn't secretly depend on floats.
"""
import random
from datetime import datetime, timedelta, timezone


def civil_from_days(z):
    z = z + 719468
    era = z // 146097
    doe = z - era * 146097
    yoe = (doe - doe // 1460 + doe // 36524 - doe // 146096) // 365
    y = yoe + era * 400
    doy = doe - (365 * yoe + yoe // 4 - yoe // 100)
    mp = (5 * doy + 2) // 153
    d = doy - (153 * mp + 2) // 5 + 1
    m = mp + (3 if mp < 10 else -9)
    if m <= 2:
        y += 1
    return y, m, d


def fmt(epoch, tz_min):
    t = epoch + tz_min * 60
    days = t // 86400
    secs = t - days * 86400
    y, m, d = civil_from_days(days)
    return "%04d-%02d-%02d %02d:%02d:%02d" % (
        y, m, d, secs // 3600, (secs // 60) % 60, secs % 60)


def expected(epoch, tz_min):
    dt = datetime.fromtimestamp(epoch, timezone.utc) + timedelta(minutes=tz_min)
    return dt.strftime("%Y-%m-%d %H:%M:%S")


TZS = [0, 480, 540, -300, -480, 330, 345, -210, 720, -720]

cases = []
# fixed edge cases: epoch 0, leap days, year boundaries, month ends, DST-free extremes
for e in [0, 1, 86399, 86400,
          951782400,   # 2000-02-29 leap day
          1078012800,  # 2004-02-29
          4107542400,  # 2100-03-01 (2100 is NOT a leap year)
          1709164800,  # 2024-02-29
          1735689599,  # 2024-12-31 23:59:59 UTC
          1735689600,  # 2025-01-01 00:00:00 UTC
          1756944000,  # 2025-09-04
          2147483647]: # int32 max
    for tz in TZS:
        cases.append((e, tz))

random.seed(20260905)
for _ in range(4000):
    cases.append((random.randint(0, 2147483647), random.choice(TZS)))

bad = 0
for epoch, tz in cases:
    got, want = fmt(epoch, tz), expected(epoch, tz)
    if got != want:
        bad += 1
        if bad <= 10:
            print("MISMATCH epoch=%d tz=%d  got=%s  want=%s" % (epoch, tz, got, want))

print("checked %d cases, %d mismatches" % (len(cases), bad))
raise SystemExit(1 if bad else 0)
