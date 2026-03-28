//+------------------------------------------------------------------+
//|                                         GoldExnessProPerfect.mq5 |
//|                                  Copyright 2024, TradingBotExpert|
//|                                             https://www.mql5.com |
//+------------------------------------------------------------------+
#property copyright "Copyright 2024, TradingBotExpert"
#property link      "https://www.mql5.com"
#property version   "1.64"
#property strict

#include <Trade\Trade.mqh>

//--- INPUT PARAMETERS
input group "=== Identity (MUST BE UNIQUE PER CHART) ==="
input int      InpMagicNum       = 998877;   

input group "=== Entry Conditions ==="
input double   InpMinBodyPct     = 40.0;     
input double   InpMaxBodyPct     = 100.0;    

input group "=== Risk Management ==="
input double   InpDailyProfit    = 50.0;     
input double   InpDailyLossPct   = 50.0;     
input int      InpMaxDailyTrades = 200;      
input double   InpLotSize        = 0.01;     
input int      InpTP             = 3000;     
input int      InpSL             = 1000;     
input int      InpSlippage       = 300;      // High slippage for maximum speed

input group "=== Trade Management ==="
input int      InpBEPoints       = 300;      
input int      InpBEBuffer       = 50;       
input int      InpTrailingSL     = 200;      

input group "=== Session Settings (Server Time) ==="
input bool     InpAsiaOn         = true;
input int      InpAsiaStart      = 0, InpAsiaEnd = 8;
input bool     InpLondonOn       = true;
input int      InpLondonStart    = 8, InpLondonEnd = 16;
input bool     InpNYOn           = true;
input int      InpNYStart        = 13, InpNYEnd = 21;

input group "=== News Filter Settings ==="
input bool     InpUseNewsFilter  = false;    
input int      InpMinsBefore     = 30;       
input int      InpMinsAfter      = 30;       
input bool     InpHighImpactOnly = true;     
input bool     InpFilterUSD      = true;     
input bool     InpFilterGold     = true;     

//--- GLOBAL VARIABLES
CTrade         trade;
datetime       last_processed_bar = 0;
int            trades_today      = 0;
double         daily_start_bal   = 0;
datetime       current_day       = 0;

struct NewsEvent { datetime time; string impact; string currency; };
NewsEvent      g_news_list[];
datetime       last_news_update = 0;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber(InpMagicNum);
   trade.SetDeviationInPoints(InpSlippage);
   
   // --- MAXIMUM SPEED SETTINGS ---
   trade.SetAsyncMode(true); // Don't wait for broker (Asynchronous)
   
   uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0) trade.SetTypeFilling(ORDER_FILLING_FOK);
   else if((filling & SYMBOL_FILLING_IOC) != 0) trade.SetTypeFilling(ORDER_FILLING_IOC);
   else trade.SetTypeFilling(ORDER_FILLING_RETURN);
   
   daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE);
   current_day = iTime(_Symbol, PERIOD_D1, 0);
   
   if(InpUseNewsFilter) UpdateNewsData();
   return(INIT_SUCCEEDED);
}

//+------------------------------------------------------------------+
//| Main Loop                                                        |
//+------------------------------------------------------------------+
void OnTick()
{
   CheckDailyReset();
   if(!IsRiskAllowed()) return;
   if(InpUseNewsFilter && IsNewsTime()) return;

   ManageExits();

   datetime current_bar_time = iTime(_Symbol, _Period, 0);
   if(last_processed_bar != current_bar_time)
   {
      CheckForEntries();
      last_processed_bar = current_bar_time;
   }
}

//+------------------------------------------------------------------+
//| News Logic                                                       |
//+------------------------------------------------------------------+
bool IsNewsTime()
{
   if(TimeCurrent() - last_news_update > 14400) UpdateNewsData();
   int total = ArraySize(g_news_list);
   if(total == 0) return false;
   datetime now = TimeTradeServer();
   for(int i=0; i<total; i++)
   {
      if(InpHighImpactOnly && g_news_list[i].impact != "High") continue;
      bool relevant = false;
      if(InpFilterUSD && g_news_list[i].currency == "USD") relevant = true;
      if(InpFilterGold && (g_news_list[i].currency == "XAU" || g_news_list[i].currency == "GOLD")) relevant = true;
      if(!relevant) continue;
      if(now >= g_news_list[i].time - (InpMinsBefore * 60) && now <= g_news_list[i].time + (InpMinsAfter * 60)) return true;
   }
   return false;
}

void UpdateNewsData()
{
   string url = "https://nfs.faireconomy.media/ff_calendar_thisweek.json";
   char post[], result[]; string headers;
   if(WebRequest("GET", url, NULL, 0, post, result, headers) == 200)
   {
      last_news_update = TimeCurrent();
      ParseNewsJSON(CharArrayToString(result));
   }
}

void ParseNewsJSON(string json)
{
   ArrayFree(g_news_list);
   string items[];
   int count = StringSplit(json, '}', items);
   for(int i=0; i<count; i++)
   {
      if(InpHighImpactOnly && StringFind(items[i], "\"impact\":\"High\"") < 0) continue;
      NewsEvent ev;
      int cur_pos = StringFind(items[i], "\"country\":\"");
      if(cur_pos >= 0) ev.currency = StringSubstr(items[i], cur_pos+11, 3);
      if(StringFind(items[i], "\"impact\":\"High\"") >= 0) ev.impact = "High";
      else if(StringFind(items[i], "\"impact\":\"Medium\"") >= 0) ev.impact = "Medium";
      else ev.impact = "Low";
      int date_pos = StringFind(items[i], "\"date\":\"");
      if(date_pos >= 0)
      {
         string dt_str = StringSubstr(items[i], date_pos+8, 19);
         StringReplace(dt_str, "T", " ");
         datetime news_time_utc = StringToTime(dt_str);
         ev.time = news_time_utc + (int)(TimeTradeServer() - TimeGMT()); 
         int size = ArraySize(g_news_list);
         ArrayResize(g_news_list, size+1);
         g_news_list[size] = ev;
      }
   }
}

//+------------------------------------------------------------------+
//| Entry Condition Check                                            |
//+------------------------------------------------------------------+
void CheckForEntries()
{
   if(CountActivePositions() > 0) return; 
   if(!IsSessionAllowed() || trades_today >= InpMaxDailyTrades) return;

   MqlRates rates[];
   ArraySetAsSeries(rates, true);
   if(CopyRates(_Symbol, _Period, 1, 2, rates) < 2) return;

   if(IsValidBody(rates[0]) && IsValidBody(rates[1]))
   {
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if(rates[0].close > rates[0].open && rates[1].close > rates[1].open)
      {
         double sl = NormalizeDouble(ask - InpSL * _Point, _Digits);
         double tp = NormalizeDouble(ask + InpTP * _Point, _Digits);
         if(trade.Buy(InpLotSize, _Symbol, ask, sl, tp)) trades_today++;
      }
      else if(rates[0].close < rates[0].open && rates[1].close < rates[1].open)
      {
         double sl = NormalizeDouble(bid + InpSL * _Point, _Digits);
         double tp = NormalizeDouble(bid - InpTP * _Point, _Digits);
         if(trade.Sell(InpLotSize, _Symbol, bid, sl, tp)) trades_today++;
      }
   }
}

//+------------------------------------------------------------------+
//| Manage Exits (Fast Async Modification)                           |
//+------------------------------------------------------------------+
void ManageExits()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
   {
      ulong ticket = PositionGetTicket(i);
      if(PositionSelectByTicket(ticket))
      {
         if(PositionGetString(POSITION_SYMBOL) != _Symbol || PositionGetInteger(POSITION_MAGIC) != InpMagicNum) continue;
         
         double entry = PositionGetDouble(POSITION_PRICE_OPEN);
         double curSL = NormalizeDouble(PositionGetDouble(POSITION_SL), _Digits);
         double curTP = PositionGetDouble(POSITION_TP);
         long type    = PositionGetInteger(POSITION_TYPE);
         double bid   = SymbolInfoDouble(_Symbol, SYMBOL_BID);
         double ask   = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
         
         if(type == POSITION_TYPE_BUY)
         {
            double pProfit = (bid - entry) / _Point;
            double beLevel = NormalizeDouble(entry + (InpBEBuffer * _Point), _Digits);
            if(curSL < beLevel && pProfit >= InpBEPoints) trade.PositionModify(ticket, beLevel, curTP);
            else if(curSL >= beLevel)
            {
               double targetSL = NormalizeDouble(bid - (InpTrailingSL * _Point), _Digits);
               if(targetSL > curSL + (2 * _Point)) trade.PositionModify(ticket, targetSL, curTP);
            }
         }
         else 
         {
            double pProfit = (entry - ask) / _Point;
            double beLevel = NormalizeDouble(entry - (InpBEBuffer * _Point), _Digits);
            if((curSL > beLevel || curSL == 0) && pProfit >= InpBEPoints) trade.PositionModify(ticket, beLevel, curTP);
            else if(curSL <= beLevel && curSL != 0)
            {
               double targetSL = NormalizeDouble(ask + (InpTrailingSL * _Point), _Digits);
               if(targetSL < curSL - (2 * _Point)) trade.PositionModify(ticket, targetSL, curTP);
            }
         }
      }
   }
}

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
int CountActivePositions()
{
   int count = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum && PositionGetString(POSITION_SYMBOL) == _Symbol) count++;
   return count;
}

bool IsValidBody(MqlRates &rate)
{
   double range = rate.high - rate.low;
   if(range <= 0) return false;
   return ((MathAbs(rate.close - rate.open) / range) * 100.0 >= InpMinBodyPct);
}

bool IsRiskAllowed()
{
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   if(equity - daily_start_bal >= InpDailyProfit) return false;
   if(daily_start_bal - equity >= (daily_start_bal * InpDailyLossPct/100.0)) { CloseAllPositions(); return false; }
   return true;
}

bool IsSessionAllowed()
{
   MqlDateTime dt; TimeCurrent(dt);
   if(InpAsiaOn && dt.hour >= InpAsiaStart && dt.hour < InpAsiaEnd) return true;
   if(InpLondonOn && dt.hour >= InpLondonStart && dt.hour < InpLondonEnd) return true;
   if(InpNYOn && dt.hour >= InpNYStart && dt.hour < InpNYEnd) return true;
   return false;
}

void CheckDailyReset()
{
   datetime today = iTime(_Symbol, PERIOD_D1, 0);
   if(today != current_day) { current_day = today; daily_start_bal = AccountInfoDouble(ACCOUNT_BALANCE); trades_today = 0; }
}

void CloseAllPositions()
{
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionSelectByTicket(PositionGetTicket(i)))
         if(PositionGetInteger(POSITION_MAGIC) == InpMagicNum) trade.PositionClose(PositionGetTicket(i));
}