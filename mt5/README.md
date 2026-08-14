# AlgoStopGuard — MT5 daily profit watchdog

An Expert Advisor that watches the P/L your bot (magic number `777`) makes during the day and
**switches the terminal's AutoTrading / Algo Trading button OFF** once the day's target is banked,
so the day closes with the profit you wanted. It stays off for the rest of the day.

Files:

| File | Purpose |
| --- | --- |
| `AlgoStopGuard.mq5` | The EA source |
| `AlgoStopGuard.set` | Preset with your settings (magic 777, 6000 USC, 100 USC drawdown, 06:00–17:00 IST) |

## Install

1. In MT5: **File → Open Data Folder → MQL5 → Experts**, copy `AlgoStopGuard.mq5` there.
2. Copy `AlgoStopGuard.set` into **MQL5 → Presets**.
3. In MetaEditor press **F7** to compile (0 errors expected).
4. **Tools → Options → Expert Advisors → tick "Allow DLL imports"**, then OK.
   This is required — MQL5 has no native call for the AutoTrading button, so the EA presses it by
   posting the terminal's own `WM_COMMAND` (id `33020`) through `user32.dll`. Without it the EA still
   tracks and alerts, but cannot press the button.
5. Refresh the Navigator, drag **AlgoStopGuard** onto **any chart in the same terminal** that runs
   your bot (a spare chart is fine — it does not need to be the bot's chart or symbol).
6. In the properties dialog → **Inputs → Load** → pick `AlgoStopGuard.set` → OK.

The AutoTrading button is terminal-wide, so it does not matter which chart hosts the guard.
Turning it off stops **every** EA in that terminal from placing new orders, which is the intent.

## What it does

Every second, inside the session window, it computes the day's P/L for magic `777`
(closed deals since local midnight + floating on open positions, including swap/commission) and
evaluates four rules. Any one of them fires the stop:

| Rule | Fires when | Default |
| --- | --- | --- |
| **A — Target** | profit ≥ `InpTargetProfit − InpTargetTolerance` **and** drawdown ≤ `InpMaxDrawdown` | 5800 USC with DD ≤ 100 |
| **B — Lock-in** | the day peaked ≥ `InpMinLockProfit` and has given back ≥ `InpPeakGiveback` while still ≥ `InpMinLockProfit` | peak ≥ 5000, gives back 400 |
| **C — Fail-safe** | profit ≥ `InpFailsafeProfit`, regardless of drawdown | 6500 USC |
| **D — Window end** | window closes with profit ≥ `InpMinLockProfit` (off by default) | disabled |

Rule A is your main condition. Rule B is what guarantees the 5000–6000 band: if profit spikes past
5000 but the drawdown never drops below 100, Rule A never fires and the profit could bleed away —
Rule B takes it on the way down instead. Rule C is the backstop for a stuck-wide drawdown.

When a rule fires the EA closes out (see below), presses the button, verifies
`TERMINAL_TRADE_ALLOWED` actually went false (retrying up to `InpMaxClickAttempts` times), logs and
alerts, and writes a lock file `MQL5/Files/AlgoStopGuard_<login>.txt`.

## Closing out on stop

Switching AutoTrading off only blocks *new* orders — open positions keep running and pending orders
still trigger on the server. So when the stop fires the EA also flattens the book, but only when the
day is genuinely in the money:

> **day profit ≥ `InpCloseMinProfit` (5000) and drawdown ≤ `InpCloseMaxDrawdown` (100)**

Both are measured at the instant of stopping, with the same drawdown definition as the stop rules.
If either fails the positions are left alone and the reason is written to the Experts log — that way
a Rule C fail-safe stop with a wide drawdown never dumps positions at a bad moment; it just stops the
bot from opening more.

The close-out runs **before** the button is pressed, because once AutoTrading is off this EA cannot
trade either. It retries up to `InpClosePasses` times, sets the fill policy per symbol, and allows
`InpCloseSlippage` points of deviation. Anything it could not close is reported in the log and the
alert so you can finish it by hand.

| Input | Default | Notes |
| --- | --- | --- |
| `InpCloseOnStop` | `true` | Master switch for the close-out. |
| `InpCloseScope` | all positions | `0` closes every position on the account, `1` closes only the magic-filtered ones. Switch to `1` if you ever hold manual trades in this account. |
| `InpCloseMinProfit` / `InpCloseMaxDrawdown` | `5000` / `100` | The gate above. |
| `InpDeletePendingOnClose` | `true` | Also deletes pending orders, which AutoTrading-off does not stop. |

**No switching back on the same day:** while the lock is set, if AutoTrading is turned on again the
EA presses the button off again within a second (`InpEnforceLockAllDay`). The lock file means this
survives an EA reload or a full terminal restart — it is keyed to the IST calendar date, and clears
by itself at IST midnight. To override deliberately, remove the EA from the chart (or delete the
lock file).

## Key inputs

| Input | Default | Notes |
| --- | --- | --- |
| `InpMagicNumber` | `777` | Your bot's magic. Set `InpFilterByMagic=false` to track everything. |
| `InpPnlBasis` | bot only | Switch to *whole account* to track equity minus the day's opening equity instead. |
| `InpTargetProfit` / `InpTargetTolerance` | `6000` / `200` | The "or close to it" band — fires at 5800. |
| `InpMaxDrawdown` | `100` | With `InpDrawdownMode=0` this is the open floating loss on the bot's positions. Mode 1 measures give-back from the day's peak; mode 2 uses the worse of the two. |
| `InpTzOffsetMinutes` | `330` | IST = GMT+5:30. The EA derives the window from GMT, so it is immune to your broker's server time and to DST. |
| `InpStartHour` … `InpEndMinute` | `06:00`–`17:00` | Weekdays only via `InpWeekdaysOnly`. |
| `InpCloseOnStop` | `true` | Closes the book on stop when profit ≥ 5000 and drawdown ≤ 100 — see above. |
| `InpDryRun` | `false` | Logs and alerts but never presses the button or closes anything. |

On a Vantage **cent** account the account currency is USC, so 6000 = 6000 cents = 60 USD. All inputs
are in account currency, so the numbers in the set file are already what you asked for.

## Suggested first run

Set `InpDryRun=true` for one session and watch the on-chart panel and the Experts log. It shows
closed P/L, floating, day total, peak, drawdown, and the level at which it will fire. When the
numbers line up with what you see in the terminal, flip `InpDryRun` back to `false`.

## Caveats

- **DLL imports must be allowed.** That is the only way to reach the AutoTrading button from MQL5.
- Windows only — `user32.dll` does not exist under Wine/Linux MT5 builds in the usual way.
- If your MT5 build ever changes the button's command id, change `InpAlgoButtonCmdId` (33020 is the
  MT5 value; 32851 is the MT4 one).
- Turning AutoTrading off stops **new** orders only; the close-out above is what actually flattens
  the day. If its profit/drawdown gate is not met, positions stay open on their SL/TP.
- The close-out needs trading permission at that moment (AutoTrading still on, "Allow algo trading"
  ticked for this EA, market open). If it cannot trade it says so in the log and alert, and still
  switches AutoTrading off.
- Commission on still-open positions is not exposed by MT5 and is therefore not included in the
  floating figure; closed deals include it in full.
