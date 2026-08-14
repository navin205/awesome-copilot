//+------------------------------------------------------------------+
//|                                                AlgoStopGuard.mq5 |
//|                                                                  |
//|  Daily profit watchdog for MetaTrader 5.                         |
//|                                                                  |
//|  Watches the P/L produced by a trading bot (filtered by magic     |
//|  number) during a configurable session window, and switches the   |
//|  terminal's AutoTrading ("Algo Trading") button OFF once the       |
//|  day's profit target is banked with an acceptable drawdown.       |
//|  Once it has fired, it keeps the button OFF for the rest of the   |
//|  day - including across EA reloads and terminal restarts.         |
//|                                                                  |
//|  Attach to ANY chart in the SAME terminal that runs the bot.      |
//|  Requires: Tools > Options > Expert Advisors > Allow DLL imports  |
//|  (the AutoTrading button is toggled through a Windows message).   |
//+------------------------------------------------------------------+
#property copyright "AlgoStopGuard"
#property version   "1.00"
#property description "Tracks daily P/L of a bot (magic number) and turns the MT5 AutoTrading button OFF once the profit target is reached with a low drawdown. Stays off for the rest of the day."

#include <Trade\Trade.mqh>

//--- Windows API: used only to press the AutoTrading button --------
#import "user32.dll"
int  PostMessageW(long hWnd, uint Msg, ulong wParam, long lParam);
long GetAncestor(long hWnd, uint gaFlags);
long GetParent(long hWnd);
#import

#define WM_COMMAND 0x0111
#define GA_ROOT    2

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_PNL_BASIS
  {
   PNL_BOT_ONLY = 0,     // Bot only (closed + floating, magic filtered)
   PNL_ACCOUNT  = 1      // Whole account (equity - day start equity)
  };

enum ENUM_DD_MODE
  {
   DD_OPEN_LOSS   = 0,   // Open floating loss on tracked positions
   DD_FROM_PEAK   = 1,   // Give-back from the day's peak profit
   DD_WORST_OF_2  = 2    // Worst of the two (strictest)
  };

enum ENUM_CLOSE_SCOPE
  {
   CLOSE_ALL_POSITIONS = 0,   // Every open position on the account
   CLOSE_TRACKED_ONLY  = 1    // Only the positions this EA tracks (magic filtered)
  };

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input group "=== 1. What to track ==="
input ENUM_PNL_BASIS InpPnlBasis        = PNL_BOT_ONLY; // P/L basis
input bool           InpFilterByMagic   = true;         // Only count trades of one magic number
input long           InpMagicNumber     = 777;          // Magic number of the bot
input bool           InpFilterBySymbol  = false;        // Only count trades on this chart's symbol

input group "=== 2. GATE - both must hold before the button is pressed ==="
input double InpMinStopProfit       = 5000.0;  // Never stop below this profit
input double InpMaxDrawdown         = 100.0;   // Drawdown ceiling before the day reaches target
input double InpRelaxDdAtProfit     = 6000.0;  // Once the day has TOUCHED this profit... (0 = never)
input double InpMaxDrawdownAtTarget = 1000.0;  // ...the drawdown ceiling becomes this
input ENUM_DD_MODE InpDrawdownMode  = DD_OPEN_LOSS; // How drawdown is measured

input group "=== 3. WHEN to stop, once the gate is open ==="
input bool   InpEnableTargetRule  = true;    // RULE A: stop at the target
input double InpTargetProfit      = 6000.0;  // Target profit for the day
input double InpTargetTolerance   = 200.0;   // "Close to it" tolerance (fires at target - this)
input bool   InpEnableGivebackRule= true;    // RULE B: stop if profit falls back from the peak
input double InpPeakGiveback      = 400.0;   // Give-back from peak that triggers RULE B

input group "=== 4. Session window (IST by default) ==="
input int  InpTzOffsetMinutes = 330;   // Minutes ahead of GMT (IST = 330)
input int  InpStartHour       = 6;     // Window start hour (local tz above)
input int  InpStartMinute     = 0;     // Window start minute
input int  InpEndHour         = 17;    // Window end hour
input int  InpEndMinute       = 0;     // Window end minute
input bool InpWeekdaysOnly    = true;  // Monday..Friday only
input bool InpOnlyInWindow    = true;  // Ignore targets outside the window
input bool InpStopAtWindowEnd = false; // RULE C: stop at window end (gate still applies)

input group "=== 5. Lock behaviour ==="
input bool InpEnforceLockAllDay = true;  // Re-press the button if AutoTrading is switched back on
input bool InpDryRun            = false; // Log/alert only, never press the button or close trades

input group "=== 6. Close out when the stop fires ==="
input bool InpCloseOnStop            = true;                 // Close open positions when stopping
input ENUM_CLOSE_SCOPE InpCloseScope = CLOSE_ALL_POSITIONS;  // Which positions to close
input bool InpDeletePendingOnClose   = true;                 // Also delete pending orders
input int  InpCloseSlippage          = 30;                   // Max deviation when closing, points
input int  InpClosePasses            = 5;                    // Retry passes over the open trades

input group "=== 7. Notifications & advanced ==="
input bool InpAlertOnStop        = true;   // Pop-up alert
input bool InpPushOnStop         = false;  // Push notification to the MT5 mobile app
input bool InpShowPanel          = true;   // Show status panel on the chart
input int  InpTimerSeconds       = 1;      // Check interval, seconds
input int  InpMaxClickAttempts   = 5;      // Retries when pressing the button
input int  InpAlgoButtonCmdId    = 33020;  // Terminal command id of the AutoTrading button

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade   g_trade;

string   g_lockedDay      = "";      // IST date (yyyy.mm.dd) on which we stopped
bool     g_lockedToday    = false;   // stop already fired for the current IST day
string   g_currentDay     = "";      // IST date currently being tracked
double   g_dayStartEquity = 0.0;     // equity captured at the start of the IST day
double   g_dayPeakProfit  = 0.0;     // best profit seen today
bool     g_ddRelaxed      = false;   // day touched InpRelaxDdAtProfit: wider ceiling in force
bool     g_dllOk          = false;   // DLL imports available
datetime g_lastArmedLog   = 0;       // throttle for "waiting for drawdown" messages
datetime g_lastEnforceLog = 0;       // throttle for enforcement messages
datetime g_lastStopAttempt= 0;       // throttle for retries after a failed press
datetime g_lastFailAlert  = 0;       // throttle for "could not press the button" alerts
string   g_lastStopReason = "";

//--- values refreshed on every timer tick
double   g_dayProfit      = 0.0;
double   g_floating       = 0.0;
double   g_closed         = 0.0;
double   g_drawdown       = 0.0;
bool     g_inWindow       = false;

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+
//--- broker server time offset from GMT, rounded to the nearest 15 min
int ServerGmtOffsetSeconds()
  {
   long diff = (long)TimeTradeServer() - (long)TimeGMT();
   return (int)(MathRound((double)diff / 900.0) * 900.0);
  }

//--- "now" in the configured local timezone (IST by default)
datetime LocalNow()
  {
   return (datetime)((long)TimeGMT() + (long)InpTzOffsetMinutes * 60);
  }

string LocalDayString()
  {
   MqlDateTime t;
   TimeToStruct(LocalNow(), t);
   return StringFormat("%04d.%02d.%02d", t.year, t.mon, t.day);
  }

//--- start of the current local day, expressed in broker server time
datetime LocalDayStartAsServerTime()
  {
   long loc          = (long)LocalNow();
   long locMidnight  = loc - (loc % 86400);
   long gmtMidnight  = locMidnight - (long)InpTzOffsetMinutes * 60;
   return (datetime)(gmtMidnight + ServerGmtOffsetSeconds());
  }

bool IsInsideWindow()
  {
   MqlDateTime t;
   TimeToStruct(LocalNow(), t);

   if(InpWeekdaysOnly && (t.day_of_week == 0 || t.day_of_week == 6))
      return false;

   int now   = t.hour * 60 + t.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = InpEndHour   * 60 + InpEndMinute;

   if(start <= end)
      return (now >= start && now < end);

   return (now >= start || now < end);   // window crossing midnight
  }

bool WindowJustEnded()
  {
   MqlDateTime t;
   TimeToStruct(LocalNow(), t);

   if(InpWeekdaysOnly && (t.day_of_week == 0 || t.day_of_week == 6))
      return false;

   int now = t.hour * 60 + t.min;
   int end = InpEndHour * 60 + InpEndMinute;
   return (now >= end && now < end + 5);
  }

//+------------------------------------------------------------------+
//| P/L calculation                                                  |
//+------------------------------------------------------------------+
bool PositionMatches()
  {
   if(InpFilterByMagic && PositionGetInteger(POSITION_MAGIC) != InpMagicNumber)
      return false;
   if(InpFilterBySymbol && PositionGetString(POSITION_SYMBOL) != _Symbol)
      return false;
   return true;
  }

double FloatingProfit(const bool applyFilters)
  {
   double sum = 0.0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(applyFilters && !PositionMatches())
         continue;
      sum += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
     }
   return sum;
  }

double ClosedProfitToday(const bool applyFilters)
  {
   datetime from = LocalDayStartAsServerTime();
   if(!HistorySelect(from, TimeCurrent() + 86400))
      return 0.0;

   double sum   = 0.0;
   int    total = HistoryDealsTotal();

   for(int i = 0; i < total; i++)
     {
      ulong ticket = HistoryDealGetTicket(i);
      if(ticket == 0)
         continue;

      long type = HistoryDealGetInteger(ticket, DEAL_TYPE);
      if(type != DEAL_TYPE_BUY && type != DEAL_TYPE_SELL)
         continue;   // skip balance / credit / correction entries

      if((datetime)HistoryDealGetInteger(ticket, DEAL_TIME) < from)
         continue;

      if(applyFilters)
        {
         if(InpFilterByMagic && HistoryDealGetInteger(ticket, DEAL_MAGIC) != InpMagicNumber)
            continue;
         if(InpFilterBySymbol && HistoryDealGetString(ticket, DEAL_SYMBOL) != _Symbol)
            continue;
        }

      sum += HistoryDealGetDouble(ticket, DEAL_PROFIT)
             + HistoryDealGetDouble(ticket, DEAL_SWAP)
             + HistoryDealGetDouble(ticket, DEAL_COMMISSION)
             + HistoryDealGetDouble(ticket, DEAL_FEE);
     }
   return sum;
  }

void RefreshPnl()
  {
   if(InpPnlBasis == PNL_ACCOUNT)
     {
      g_floating  = FloatingProfit(false);
      g_dayProfit = AccountInfoDouble(ACCOUNT_EQUITY) - g_dayStartEquity;
      g_closed    = g_dayProfit - g_floating;
     }
   else
     {
      g_floating  = FloatingProfit(true);
      g_closed    = ClosedProfitToday(true);
      g_dayProfit = g_closed + g_floating;
     }

   if(g_dayProfit > g_dayPeakProfit)
      g_dayPeakProfit = g_dayProfit;

   if(!g_ddRelaxed && InpRelaxDdAtProfit > 0.0 && g_dayPeakProfit >= InpRelaxDdAtProfit)
     {
      g_ddRelaxed = true;
      Print(StringFormat("AlgoStopGuard: day touched %.2f - drawdown ceiling widened from %.2f to %.2f "
                         "for the rest of the day.",
                         g_dayPeakProfit, InpMaxDrawdown, InpMaxDrawdownAtTarget));
     }

   double openLoss  = (g_floating < 0.0 ? -g_floating : 0.0);
   double fromPeak  = g_dayPeakProfit - g_dayProfit;
   if(fromPeak < 0.0)
      fromPeak = 0.0;

   switch(InpDrawdownMode)
     {
      case DD_FROM_PEAK:
         g_drawdown = fromPeak;
         break;
      case DD_WORST_OF_2:
         g_drawdown = MathMax(openLoss, fromPeak);
         break;
      default:
         g_drawdown = openLoss;
         break;
     }
  }

//+------------------------------------------------------------------+
//| AutoTrading button control                                       |
//+------------------------------------------------------------------+
bool AlgoTradingEnabled()
  {
   return (bool)TerminalInfoInteger(TERMINAL_TRADE_ALLOWED);
  }

long TerminalMainWindow()
  {
   long chartWnd = ChartGetInteger(0, CHART_WINDOW_HANDLE);
   if(chartWnd == 0)
      return 0;

   long root = GetAncestor(chartWnd, GA_ROOT);
   if(root != 0)
      return root;

   long current = chartWnd, parent = 0;
   while((parent = GetParent(current)) != 0)
      current = parent;
   return current;
  }

bool PressAlgoButton()
  {
   if(!g_dllOk)
      return false;

   long hwnd = TerminalMainWindow();
   if(hwnd == 0)
     {
      Print("AlgoStopGuard: could not resolve the terminal window handle.");
      return false;
     }
   return (PostMessageW(hwnd, WM_COMMAND, (ulong)InpAlgoButtonCmdId, 0) != 0);
  }

//--- press the button until TERMINAL_TRADE_ALLOWED reports OFF
bool TurnAlgoTradingOff()
  {
   if(!AlgoTradingEnabled())
      return true;

   if(InpDryRun)
     {
      Print("AlgoStopGuard: DRY RUN - would switch AutoTrading OFF now.");
      return false;
     }

   for(int attempt = 1; attempt <= InpMaxClickAttempts; attempt++)
     {
      if(!AlgoTradingEnabled())
         return true;

      if(!PressAlgoButton())
        {
         Print("AlgoStopGuard: failed to send the AutoTrading command (attempt ", attempt, ").");
         Sleep(500);
         continue;
        }

      uint started = GetTickCount();
      while(GetTickCount() - started < 2000)
        {
         Sleep(100);
         if(!AlgoTradingEnabled())
           {
            Print("AlgoStopGuard: AutoTrading switched OFF (attempt ", attempt, ").");
            return true;
           }
        }
      Print("AlgoStopGuard: AutoTrading still ON after attempt ", attempt, ", retrying.");
     }
   return !AlgoTradingEnabled();
  }

//+------------------------------------------------------------------+
//| Closing out when the stop fires                                  |
//+------------------------------------------------------------------+
//--- is the currently selected position in scope for closing?
bool CloseScopeMatches()
  {
   if(InpCloseScope == CLOSE_ALL_POSITIONS)
      return true;
   return PositionMatches();
  }

//--- The stop gate already guarantees profit >= InpMinStopProfit and
//--- drawdown <= InpMaxDrawdown, so a stop that fires at all is by
//--- definition a day worth flattening.
bool ShouldCloseOut()
  {
   return InpCloseOnStop;
  }

//--- returns the number of positions still open after all passes
int CloseOpenPositions()
  {
   int remaining = 0;

   for(int pass = 1; pass <= InpClosePasses; pass++)
     {
      remaining = 0;

      for(int i = PositionsTotal() - 1; i >= 0; i--)
        {
         ulong ticket = PositionGetTicket(i);
         if(ticket == 0)
            continue;
         if(!CloseScopeMatches())
            continue;

         g_trade.SetTypeFillingBySymbol(PositionGetString(POSITION_SYMBOL));

         if(!g_trade.PositionClose(ticket, InpCloseSlippage))
           {
            remaining++;
            Print("AlgoStopGuard: close failed for position #", ticket,
                  " (pass ", pass, ") retcode=", g_trade.ResultRetcode(),
                  " ", g_trade.ResultRetcodeDescription());
           }
        }

      if(remaining == 0)
         break;
      Sleep(700);
     }
   return remaining;
  }

//--- pending orders survive AutoTrading being off, so clear them too
int DeletePendingOrders()
  {
   int remaining = 0;

   for(int pass = 1; pass <= InpClosePasses; pass++)
     {
      remaining = 0;

      for(int i = OrdersTotal() - 1; i >= 0; i--)
        {
         ulong ticket = OrderGetTicket(i);
         if(ticket == 0)
            continue;

         if(InpCloseScope == CLOSE_TRACKED_ONLY)
           {
            if(InpFilterByMagic && OrderGetInteger(ORDER_MAGIC) != InpMagicNumber)
               continue;
            if(InpFilterBySymbol && OrderGetString(ORDER_SYMBOL) != _Symbol)
               continue;
           }

         if(!g_trade.OrderDelete(ticket))
           {
            remaining++;
            Print("AlgoStopGuard: delete failed for order #", ticket,
                  " (pass ", pass, ") retcode=", g_trade.ResultRetcode(),
                  " ", g_trade.ResultRetcodeDescription());
           }
        }

      if(remaining == 0)
         break;
      Sleep(700);
     }
   return remaining;
  }

//--- flatten the book; must run BEFORE AutoTrading is switched off
string CloseOutNow()
  {
   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
     {
      Print("AlgoStopGuard: cannot close out - trading is not allowed for this EA right now.");
      return " | could not close positions (trading not allowed)";
     }

   int stuckPositions = CloseOpenPositions();
   int stuckOrders    = (InpDeletePendingOnClose ? DeletePendingOrders() : 0);

   if(stuckPositions == 0 && stuckOrders == 0)
     {
      Print("AlgoStopGuard: all in-scope positions closed",
            (InpDeletePendingOnClose ? " and pending orders deleted." : "."));
      return " | positions closed";
     }

   Print("AlgoStopGuard: close-out incomplete - ", stuckPositions,
         " position(s) and ", stuckOrders, " pending order(s) remain. Close them manually.");
   return StringFormat(" | CLOSE-OUT INCOMPLETE: %d position(s), %d order(s) left open",
                       stuckPositions, stuckOrders);
  }

//+------------------------------------------------------------------+
//| Lock state persistence                                           |
//+------------------------------------------------------------------+
string StateFileName()
  {
   return "AlgoStopGuard_" + IntegerToString(AccountInfoInteger(ACCOUNT_LOGIN)) + ".txt";
  }

void SaveLockState(const string reason)
  {
   int handle = FileOpen(StateFileName(), FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
     {
      Print("AlgoStopGuard: could not write the state file, error ", GetLastError());
      return;
     }
   FileWriteString(handle, g_lockedDay + "\n");
   FileWriteString(handle, TimeToString(LocalNow(), TIME_DATE | TIME_SECONDS) + "\n");
   FileWriteString(handle, DoubleToString(g_dayProfit, 2) + "\n");
   FileWriteString(handle, reason + "\n");
   FileClose(handle);
  }

void LoadLockState()
  {
   if(!FileIsExist(StateFileName()))
      return;

   int handle = FileOpen(StateFileName(), FILE_READ | FILE_TXT | FILE_ANSI);
   if(handle == INVALID_HANDLE)
      return;

   string day = FileReadString(handle);
   FileClose(handle);

   StringTrimLeft(day);
   StringTrimRight(day);

   if(day == LocalDayString())
     {
      g_lockedDay   = day;
      g_lockedToday = true;
      Print("AlgoStopGuard: restored today's lock (", day, ") - AutoTrading stays OFF for the rest of the day.");
     }
  }

//+------------------------------------------------------------------+
//| Day roll-over                                                    |
//+------------------------------------------------------------------+
void StartNewDay(const string day)
  {
   g_currentDay = day;

   //--- balance as it was at local midnight, so attaching the EA mid-session
   //--- still sees the whole day's result (deposits/withdrawals aside)
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_BALANCE) - ClosedProfitToday(false);
   g_dayPeakProfit  = 0.0;
   g_ddRelaxed      = false;
   g_lastStopReason = "";
   g_lockedToday    = (g_lockedDay == day);
   Print("AlgoStopGuard: tracking ", day, " - day start balance ",
         DoubleToString(g_dayStartEquity, 2), " ", AccountInfoString(ACCOUNT_CURRENCY));
  }

//+------------------------------------------------------------------+
//| Fire the stop                                                    |
//+------------------------------------------------------------------+
void FireStop(const string reason)
  {
   g_lastStopAttempt = TimeCurrent();

   string ccy = AccountInfoString(ACCOUNT_CURRENCY);
   string msg = StringFormat("AlgoStopGuard: %s | profit %.2f %s | drawdown %.2f | peak %.2f",
                             reason, g_dayProfit, ccy, g_drawdown, g_dayPeakProfit);
   Print(msg);

   bool closeOut = ShouldCloseOut();

   //--- dry run: report once, arm the in-memory lock so the log is not flooded
   if(InpDryRun)
     {
      g_lockedToday    = true;      // not persisted: a reload re-arms the guard
      g_lastStopReason = "DRY RUN - " + reason;
      msg += " | DRY RUN - the AutoTrading button was NOT pressed";
      msg += (closeOut ? " and positions were NOT closed (they would have been)."
                       : " and positions were not eligible for closing.");
      Print(msg);
      if(InpAlertOnStop)
         Alert(msg);
      return;
     }

   //--- close out first: once AutoTrading is off this EA cannot trade either
   if(closeOut)
      msg += CloseOutNow();

   if(TurnAlgoTradingOff())
     {
      g_lockedDay      = LocalDayString();
      g_lockedToday    = true;
      g_lastStopReason = reason;
      SaveLockState(reason);
      msg += " | AutoTrading is now OFF for the rest of the day.";

      Print(msg);
      if(InpAlertOnStop)
         Alert(msg);
      if(InpPushOnStop)
         SendNotification(msg);
      return;
     }

   //--- could not press the button: retry on the next cycle, but do not spam
   msg += (g_dllOk
           ? " | COULD NOT switch AutoTrading OFF - press the Algo Trading button manually!"
           : " | COULD NOT switch AutoTrading OFF - DLL imports are disabled. Press the Algo Trading button manually!");
   Print(msg);

   if(TimeCurrent() - g_lastFailAlert >= 300)
     {
      g_lastFailAlert = TimeCurrent();
      if(InpAlertOnStop)
         Alert(msg);
      if(InpPushOnStop)
         SendNotification(msg);
     }
  }

//+------------------------------------------------------------------+
//| Rule evaluation                                                  |
//+------------------------------------------------------------------+
//--- Drawdown ceiling in force right now. It widens for the rest of the day
//--- once the day has touched InpRelaxDdAtProfit: at that point the target is
//--- banked and a wider swing is worth tolerating to get out.
double EffectiveMaxDrawdown()
  {
   if(InpRelaxDdAtProfit > 0.0 && g_dayPeakProfit >= InpRelaxDdAtProfit)
      return InpMaxDrawdownAtTarget;
   return InpMaxDrawdown;
  }

//--- the two conditions that must BOTH hold before the button may be pressed
bool GateOpen()
  {
   return (g_dayProfit >= InpMinStopProfit && g_drawdown <= EffectiveMaxDrawdown());
  }

//--- explain, at most once a minute, why an otherwise ready day is still running
void LogGateBlock()
  {
   if(TimeCurrent() - g_lastArmedLog <= 60)
      return;

   //--- only worth saying when the profit side is already there
   if(g_dayProfit < InpMinStopProfit)
      return;

   g_lastArmedLog = TimeCurrent();
   Print(StringFormat("AlgoStopGuard: HOLDING - profit %.2f is above %.2f but drawdown %.2f is above the "
                      "ceiling of %.2f in force. The button stays ON until the drawdown comes in.",
                      g_dayProfit, InpMinStopProfit, g_drawdown, EffectiveMaxDrawdown()));
  }

bool EvaluateRules(string &reason)
  {
   //--- GATE: profit floor and drawdown ceiling. No rule below can override this.
   if(!GateOpen())
     {
      LogGateBlock();
      return false;
     }

   string gate = StringFormat("profit %.2f >= %.2f and drawdown %.2f <= %.2f",
                              g_dayProfit, InpMinStopProfit, g_drawdown, EffectiveMaxDrawdown());

   double trigger = InpTargetProfit - InpTargetTolerance;

   // RULE A - target reached, or close enough to it
   if(InpEnableTargetRule && g_dayProfit >= trigger)
     {
      reason = StringFormat("RULE A target (%s, trigger %.2f)", gate, trigger);
      return true;
     }

   // RULE B - the day peaked and is now giving profit back
   if(InpEnableGivebackRule
      && g_dayPeakProfit >= InpMinStopProfit
      && (g_dayPeakProfit - g_dayProfit) >= InpPeakGiveback)
     {
      reason = StringFormat("RULE B lock-in: peak %.2f, gave back %.2f >= %.2f (%s)",
                            g_dayPeakProfit, g_dayPeakProfit - g_dayProfit, InpPeakGiveback, gate);
      return true;
     }

   // RULE C - the session window is closing
   if(InpStopAtWindowEnd && WindowJustEnded())
     {
      reason = StringFormat("RULE C window end (%s)", gate);
      return true;
     }

   return false;
  }

//+------------------------------------------------------------------+
//| Status panel                                                     |
//+------------------------------------------------------------------+
void DrawPanel()
  {
   if(!InpShowPanel)
      return;

   string ccy   = AccountInfoString(ACCOUNT_CURRENCY);
   MqlDateTime t;
   TimeToStruct(LocalNow(), t);

   string gateInfo = StringFormat("%s  (needs P/L >= %.0f and DD <= %.0f%s)",
                                  (GateOpen() ? "OPEN" : "CLOSED"),
                                  InpMinStopProfit, EffectiveMaxDrawdown(),
                                  (g_ddRelaxed ? " - widened, target was reached" : ""));

   string closeInfo = (InpCloseOnStop
                       ? StringFormat("yes - %s%s",
                                      (InpCloseScope == CLOSE_ALL_POSITIONS ? "all positions" : "tracked only"),
                                      (InpDeletePendingOnClose ? " + pendings" : ""))
                       : "no");

   string state;
   if(g_lockedToday)
      state = "STOPPED for today (" + g_lastStopReason + ")";
   else
      if(!g_inWindow && InpOnlyInWindow)
         state = "outside session window";
      else
         state = (AlgoTradingEnabled() ? "monitoring, AutoTrading ON" : "monitoring, AutoTrading OFF");

   string text = StringFormat(
                    "AlgoStopGuard  v1.00\n"
                    "-----------------------------------------\n"
                    "Local time      : %02d:%02d:%02d  (%s)\n"
                    "Window          : %02d:%02d - %02d:%02d  [%s]\n"
                    "Basis           : %s%s\n"
                    "-----------------------------------------\n"
                    "Closed today    : %10.2f %s\n"
                    "Floating        : %10.2f %s\n"
                    "DAY P/L         : %10.2f %s\n"
                    "Peak today      : %10.2f %s\n"
                    "Drawdown        : %10.2f %s  (ceiling %.2f)\n"
                    "-----------------------------------------\n"
                    "GATE            : %s\n"
                    "Target fires at : %10.2f %s\n"
                    "Close on stop   : %s\n"
                    "AutoTrading     : %s\n"
                    "State           : %s%s",
                    t.hour, t.min, t.sec, LocalDayString(),
                    InpStartHour, InpStartMinute, InpEndHour, InpEndMinute,
                    (g_inWindow ? "OPEN" : "CLOSED"),
                    (InpPnlBasis == PNL_BOT_ONLY ? "bot only" : "whole account"),
                    (InpFilterByMagic ? " magic " + IntegerToString(InpMagicNumber) : ""),
                    g_closed, ccy,
                    g_floating, ccy,
                    g_dayProfit, ccy,
                    g_dayPeakProfit, ccy,
                    g_drawdown, ccy, EffectiveMaxDrawdown(),
                    gateInfo,
                    InpTargetProfit - InpTargetTolerance, ccy,
                    closeInfo,
                    (AlgoTradingEnabled() ? "ON" : "OFF"),
                    state,
                    (InpDryRun ? "\nMODE            : DRY RUN" : ""));

   Comment(text);
  }

//+------------------------------------------------------------------+
//| Expert initialization                                            |
//+------------------------------------------------------------------+
int OnInit()
  {
   g_dllOk = (bool)MQLInfoInteger(MQL_DLLS_ALLOWED);

   if(!g_dllOk)
      Print("AlgoStopGuard: WARNING - DLL imports are not allowed. The EA can monitor and alert, "
            "but it CANNOT press the AutoTrading button. Enable Tools > Options > Expert Advisors "
            "> Allow DLL imports, then reload this EA.");

   if(InpTargetProfit <= 0.0)
     {
      Print("AlgoStopGuard: InpTargetProfit must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpTargetTolerance < 0.0 || InpTargetTolerance >= InpTargetProfit)
     {
      Print("AlgoStopGuard: InpTargetTolerance must be between 0 and InpTargetProfit.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpMinStopProfit <= 0.0)
     {
      Print("AlgoStopGuard: InpMinStopProfit must be greater than 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpRelaxDdAtProfit > 0.0 && InpMaxDrawdownAtTarget < InpMaxDrawdown)
      Print("AlgoStopGuard: note - InpMaxDrawdownAtTarget is below InpMaxDrawdown, so reaching the "
            "target TIGHTENS the drawdown ceiling. Check that this is intended.");
   if(InpMinStopProfit > InpTargetProfit - InpTargetTolerance)
      Print("AlgoStopGuard: note - the profit gate (", DoubleToString(InpMinStopProfit, 2),
            ") is above the RULE A trigger (", DoubleToString(InpTargetProfit - InpTargetTolerance, 2),
            "), so the gate is what decides RULE A.");
   if(InpStartHour < 0 || InpStartHour > 23 || InpEndHour < 0 || InpEndHour > 23)
     {
      Print("AlgoStopGuard: session hours must be between 0 and 23.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpCloseOnStop && InpClosePasses < 1)
     {
      Print("AlgoStopGuard: InpClosePasses must be at least 1.");
      return INIT_PARAMETERS_INCORRECT;
     }

   g_trade.SetAsyncMode(false);
   if(InpFilterByMagic)
      g_trade.SetExpertMagicNumber((ulong)InpMagicNumber);

   LoadLockState();
   StartNewDay(LocalDayString());
   RefreshPnl();

   int period = InpTimerSeconds;
   if(period < 1)
      period = 1;
   EventSetTimer(period);

   Print("AlgoStopGuard: started on ", _Symbol,
         " | GATE: stop only when P/L >= ", DoubleToString(InpMinStopProfit, 2),
         " AND drawdown <= ", DoubleToString(InpMaxDrawdown, 2),
         (InpRelaxDdAtProfit > 0.0
          ? " (ceiling widens to " + DoubleToString(InpMaxDrawdownAtTarget, 2)
            + " once the day touches " + DoubleToString(InpRelaxDdAtProfit, 2) + ")"
          : ""),
         " | target ", DoubleToString(InpTargetProfit, 2),
         " (fires at ", DoubleToString(InpTargetProfit - InpTargetTolerance, 2), ")",
         " | window ", InpStartHour, ":", InpStartMinute, "-", InpEndHour, ":", InpEndMinute,
         " GMT+", DoubleToString(InpTzOffsetMinutes / 60.0, 1));

   if(InpCloseOnStop)
      Print("AlgoStopGuard: when the stop fires it will also close ",
            (InpCloseScope == CLOSE_ALL_POSITIONS ? "ALL open positions" : "only tracked positions"),
            (InpDeletePendingOnClose ? " plus pending orders." : "."));

   DrawPanel();
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| Expert deinitialization                                          |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   Comment("");
  }

//+------------------------------------------------------------------+
//| Main loop                                                        |
//+------------------------------------------------------------------+
void OnTimer()
  {
   string today = LocalDayString();
   if(today != g_currentDay)
      StartNewDay(today);

   g_inWindow = IsInsideWindow();
   RefreshPnl();

   // Already stopped today: keep the button OFF, nothing else to do.
   if(g_lockedToday)
     {
      if(InpEnforceLockAllDay && AlgoTradingEnabled() && !InpDryRun)
        {
         if(TimeCurrent() - g_lastEnforceLog > 30)
           {
            g_lastEnforceLog = TimeCurrent();
            Print("AlgoStopGuard: AutoTrading was switched back ON after today's stop - switching it OFF again.");
           }
         TurnAlgoTradingOff();
        }
      DrawPanel();
      return;
     }

   if(InpOnlyInWindow && !g_inWindow && !(InpStopAtWindowEnd && WindowJustEnded()))
     {
      DrawPanel();
      return;
     }

   string reason = "";
   if(EvaluateRules(reason) && TimeCurrent() - g_lastStopAttempt >= 30)
      FireStop(reason);

   DrawPanel();
  }

//+------------------------------------------------------------------+
//| Tick handler - panel refresh only, all logic lives in OnTimer     |
//+------------------------------------------------------------------+
void OnTick()
  {
  }
//+------------------------------------------------------------------+
