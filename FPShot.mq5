//+------------------------------------------------------------------+
//| FPShot.mq5 - screenshot helper for the FootprintChart indicator.  |
//| For every template name in InpVariants: open a chart of the        |
//| script's symbol/period, apply MQL5\Profiles\Templates\<name>.tpl,  |
//| wait until the indicator reports ready=1 (OBJPROP_TEXT of its      |
//| canvas object), hide the native scales, ChartScreenShot() into     |
//| MQL5\Files\OrderFlowFP\<name>.png, close the chart.                |
//| Read-only: no trading calls. Used by tools\mt5_screenshot.ps1.     |
//+------------------------------------------------------------------+
#property copyright "OrderFlowFP"
#property version   "1.00"

input string InpVariants     = "fp_shot";   // comma-separated template names (without .tpl)
input int    InpMaxWaitSec   = 150;         // max wait for ready=1 per variant
input int    InpSettleSec    = 6;           // extra wait after ready (frames, studies)
input bool   InpHideScales   = true;        // hide the native price/time scales before the shot

string FindCanvas(const long ch)
{
   int n = ObjectsTotal(ch, 0, OBJ_BITMAP_LABEL);
   for(int i = 0; i < n; i++)
     {
      string nm = ObjectName(ch, i, 0, OBJ_BITMAP_LABEL);
      if(StringFind(nm, "OFPFC_") == 0)
         return nm;
     }
   return "";
}

void Snap(const long ch, const string obj, const string name)
{
   int w = (int)ChartGetInteger(ch, CHART_WIDTH_IN_PIXELS);
   int h = (int)ChartGetInteger(ch, CHART_HEIGHT_IN_PIXELS, 0);
   string fn = "OrderFlowFP\\" + name + ".png";
   bool ok = ChartScreenShot(ch, fn, w, h, ALIGN_RIGHT);
   Print("FPShot: ", name, ": ", ok ? "saved " : "FAILED ", fn, " ", w, "x", h, " | ", ObjectGetString(ch, obj, OBJPROP_TEXT));
}

//--- indicator test hooks: 7701 = press header button <id>, 7702 = press key <code>
//    button ids (FPLayout.mqh): RESET 4, ZOOM OUT 6, DELTA BARS 10, SIDE PANELS 11, LIVE 12
void Press(const long ch, const int btn)  { EventChartCustom(ch, 7701, btn, 0.0, ""); Sleep(400); }
void Key(const long ch, const int code)   { EventChartCustom(ch, 7702, code, 0.0, ""); Sleep(250); }

void NavSequence(const long ch, const string obj, const string name)
{
   Press(ch, 6);
   Press(ch, 6);
   Press(ch, 6);                       // zoom 16 -> 10: compact candles
   Sleep(1500);
   Snap(ch, obj, name + "_1_zoomout");
   Press(ch, 4);                       // RESET
   for(int i = 0; i < 12; i++)
      Key(ch, 37);                     // Left x12: 12 bars back in history (LIVE inactive)
   Sleep(1500);
   Snap(ch, obj, name + "_2_history");
   Press(ch, 12);                      // LIVE
   Press(ch, 11);                      // SIDE PANELS off
   Press(ch, 10);                      // DELTA BARS on
   Sleep(1500);
   Snap(ch, obj, name + "_3_sideoff_delta");
   Key(ch, 84);                        // T: next colour theme
   Key(ch, 76);                        // L: light panels
   Press(ch, 11);                      // SIDE PANELS back on
   Sleep(1500);
   Snap(ch, obj, name + "_4_theme_keys");
}

//--- spec = "name" (docked chart) or "name:WxH" (undocked floating chart window of W x H screen px)
void ShootOne(const string spec)
{
   string name = spec;
   int fw = 0, fh = 0;
   int p = StringFind(spec, ":");
   if(p > 0)
     {
      name = StringSubstr(spec, 0, p);
      string sz[];
      if(StringSplit(StringSubstr(spec, p + 1), 'x', sz) == 2)
        {
         fw = (int)StringToInteger(sz[0]);
         fh = (int)StringToInteger(sz[1]);
        }
     }
   long ch = ChartOpen(_Symbol, (ENUM_TIMEFRAMES)_Period);
   if(ch <= 0)
     {
      Print("FPShot: ChartOpen failed (", GetLastError(), ")");
      return;
     }
   if(fw > 0 && fh > 0)
     {
      if(!ChartSetInteger(ch, CHART_IS_DOCKED, false))
         Print("FPShot: undock failed (", GetLastError(), ")");
      ChartSetInteger(ch, CHART_FLOAT_LEFT, 20);
      ChartSetInteger(ch, CHART_FLOAT_TOP, 20);
      ChartSetInteger(ch, CHART_FLOAT_RIGHT, 20 + fw);
      ChartSetInteger(ch, CHART_FLOAT_BOTTOM, 20 + fh);
      ChartRedraw(ch);
      Sleep(500);
     }
   string tpl = "\\Profiles\\Templates\\" + name + ".tpl";
   if(!ChartApplyTemplate(ch, tpl))
      Print("FPShot: ChartApplyTemplate(", tpl, ") failed (", GetLastError(), ")");
   ChartRedraw(ch);
   string obj = "";
   for(int i = 0; i < 60 && obj == "" && !IsStopped(); i++)
     {
      Sleep(500);
      obj = FindCanvas(ch);
     }
   if(obj == "")
     {
      Print("FPShot: ", name, ": indicator canvas not found on the chart (template not applied?)");
      ChartClose(ch);
      return;
     }
   if(InpHideScales)
     {
      ChartSetInteger(ch, CHART_SHOW_PRICE_SCALE, false);
      ChartSetInteger(ch, CHART_SHOW_DATE_SCALE, false);
      ChartRedraw(ch);
     }
   string st = "";
   ulong t0 = GetTickCount64();
   while(!IsStopped() && GetTickCount64() - t0 < (ulong)InpMaxWaitSec * 1000)
     {
      st = ObjectGetString(ch, obj, OBJPROP_TEXT);
      if(StringFind(st, "ready=1") >= 0)
         break;
      Sleep(500);
     }
   Print("FPShot: ", name, ": ready after ", (GetTickCount64() - t0) / 1000, " s: ", st);
   Sleep(InpSettleSec * 1000);
   ChartRedraw(ch);
   Sleep(500);
   Snap(ch, obj, name);
   if(StringFind(name, "nav") >= 0)
      NavSequence(ch, obj, name);
   if(fw > 0 && fh > 0)
      ChartSetInteger(ch, CHART_IS_DOCKED, true);
   ChartClose(ch);
}

//--- attach exactly like the EA (iCustom with default inputs + ChartIndicatorAdd on the program's own chart),
//    shoot, and read the 8 data-window buffers back through the handle
void ShootICustom(const string name)
{
   long ch = ChartID();
   ResetLastError();
   int h = iCustom(_Symbol, (ENUM_TIMEFRAMES)_Period, "OrderFlowFP\\FootprintChart");
   if(h == INVALID_HANDLE)
     {
      Print("FPShot: ", name, ": iCustom failed (", GetLastError(), ")");
      return;
     }
   if(!ChartIndicatorAdd(ch, 0, h))
      Print("FPShot: ", name, ": ChartIndicatorAdd failed (", GetLastError(), ")");
   string obj = "";
   for(int i = 0; i < 60 && obj == "" && !IsStopped(); i++)
     {
      Sleep(500);
      obj = FindCanvas(ch);
     }
   if(obj == "")
     {
      Print("FPShot: ", name, ": canvas not found on the program's chart");
      IndicatorRelease(h);
      return;
     }
   string st = "";
   ulong t0 = GetTickCount64();
   while(!IsStopped() && GetTickCount64() - t0 < (ulong)InpMaxWaitSec * 1000)
     {
      st = ObjectGetString(ch, obj, OBJPROP_TEXT);
      if(StringFind(st, "ready=1") >= 0)
         break;
      Sleep(500);
     }
   Print("FPShot: ", name, ": ready after ", (GetTickCount64() - t0) / 1000, " s: ", st);
   Sleep(InpSettleSec * 1000);
   string lbl[8] = {"Volume", "Delta", "CumDelta", "POC", "BuyImb", "SellImb", "BuyStk", "SellStk"};
   for(int sh = 1; sh <= 3; sh++)
     {
      string line = "FPShot: " + name + ": buffers shift " + IntegerToString(sh) + " (" + TimeToString(iTime(_Symbol, (ENUM_TIMEFRAMES)_Period, sh), TIME_MINUTES) + "):";
      for(int b = 0; b < 8; b++)
        {
         double v[];
         if(CopyBuffer(h, b, sh, 1, v) == 1)
            line += " " + lbl[b] + "=" + ((v[0] == EMPTY_VALUE) ? "EMPTY" : DoubleToString(v[0], _Digits));
         else
            line += " " + lbl[b] + "=ERR" + IntegerToString(GetLastError());
        }
      Print(line);
     }
   if(InpHideScales)
     {
      ChartSetInteger(ch, CHART_SHOW_PRICE_SCALE, false);
      ChartSetInteger(ch, CHART_SHOW_DATE_SCALE, false);
      ChartRedraw(ch);
      Sleep(1500);
     }
   int w = (int)ChartGetInteger(ch, CHART_WIDTH_IN_PIXELS);
   int hh = (int)ChartGetInteger(ch, CHART_HEIGHT_IN_PIXELS, 0);
   string fn = "OrderFlowFP\\" + name + ".png";
   bool ok = ChartScreenShot(ch, fn, w, hh, ALIGN_RIGHT);
   Print("FPShot: ", name, ": ", ok ? "saved " : "FAILED ", fn, " ", w, "x", hh, " | ", ObjectGetString(ch, obj, OBJPROP_TEXT));
   if(InpHideScales)
     {
      ChartSetInteger(ch, CHART_SHOW_PRICE_SCALE, true);
      ChartSetInteger(ch, CHART_SHOW_DATE_SCALE, true);
     }
   IndicatorRelease(h);
}

void OnStart()
{
   string v[];
   int n = StringSplit(InpVariants, ',', v);
   for(int i = 0; i < n && !IsStopped(); i++)
     {
      StringTrimLeft(v[i]);
      StringTrimRight(v[i]);
      if(v[i] == "")
         continue;
      if(StringFind(v[i], "icustom") >= 0)
         ShootICustom(v[i]);
      else
         ShootOne(v[i]);
     }
   Print("FPShot: done (", n, " variants)");
}
//+------------------------------------------------------------------+
