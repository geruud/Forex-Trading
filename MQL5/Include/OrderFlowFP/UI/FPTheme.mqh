//+------------------------------------------------------------------+
//| FPTheme.mqh - OrderFlowFP UI: enums, palettes, colour maths       |
//| 02 §9: 2 panel themes x 16 bull/bear accent themes.               |
//| Every colour is kept as ARGB (0xFFRRGGBB) ready for CCanvas.       |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPTHEME_MQH
#define ORDERFLOWFP_UI_FPTHEME_MQH

//--- footprint styles (02 §8.4/8.5). Only MINIMALIST is implemented; the others are greyed tabs.
enum ENUM_FP_STYLE
{
   FP_STYLE_MINIMALIST        = 0,  // Minimalist
   FP_STYLE_BACKGROUND_CELLS  = 1,  // Background Cells (not implemented - draws Minimalist)
   FP_STYLE_CANDLE_FRAME      = 2,  // Candle Frame (not implemented - draws Minimalist)
   FP_STYLE_VP_CANDLE         = 3,  // Volume Profile Candle (not implemented - draws Minimalist)
   FP_STYLE_FRAMELESS         = 4,  // Frameless (not implemented - draws Minimalist)
   FP_STYLE_MIDDLE_CANDLE     = 5,  // Middle Candle (not implemented - draws Minimalist)
   FP_STYLE_DELTA_CELLS       = 6,  // Delta Cells (not implemented - draws Minimalist)
   FP_STYLE_BIDASK_PROFILE    = 7,  // Bid x Ask Profile (not implemented - draws Minimalist)
   FP_STYLE_BIDASK_CELLS      = 8   // Bid x Ask Cells (not implemented - draws Minimalist)
};

enum ENUM_FP_PANEL_THEME
{
   FP_PANEL_DARK  = 0,   // Dark
   FP_PANEL_LIGHT = 1    // Light
};

enum ENUM_FP_COLOR_THEME
{
   FP_CT_CLASSIC          = 0,   // 1 Classic (green / red)
   FP_CT_BLUE_ORANGE      = 1,   // 2 Blue / Orange
   FP_CT_CYAN_MAGENTA     = 2,   // 3 Cyan / Magenta
   FP_CT_LIME_PINK        = 3,   // 4 Lime / Pink
   FP_CT_GOLD_PURPLE      = 4,   // 5 Gold / Purple
   FP_CT_TEAL_CORAL       = 5,   // 6 Teal / Coral
   FP_CT_SKY_CRIMSON      = 6,   // 7 Sky / Crimson
   FP_CT_MINT_ROSE        = 7,   // 8 Mint / Rose
   FP_CT_ORANGE_DARK_GREY = 8,   // 9 Orange / Dark grey
   FP_CT_GREEN_DARK_GREY  = 9,   // 10 Green / Dark grey
   FP_CT_NAVY_SLATE       = 10,  // 11 Navy / Slate
   FP_CT_NAVY_GOLD        = 11,  // 12 Navy / Gold
   FP_CT_WHITE_DARK_GREY  = 12,  // 13 White / Dark grey
   FP_CT_EMERALD_WHITE    = 13,  // 14 Emerald / White
   FP_CT_CHERRY_TEAL      = 14,  // 15 Cherry / Teal
   FP_CT_OLIVE_SANDY      = 15   // 16 Olive / Sandy
};
#define FP_COLOR_THEMES 16

enum ENUM_FP_VP_MODE
{
   FP_VP_BARS    = 0,   // Last N bars
   FP_VP_SESSION = 1    // Current session
};

//+------------------------------------------------------------------+
//| colour helpers (ARGB)                                             |
//+------------------------------------------------------------------+
uint FPRGB(const int r, const int g, const int b)
{
   return (0xFF000000 | ((uint)(r & 255) << 16) | ((uint)(g & 255) << 8) | (uint)(b & 255));
}
int  FPRed(const uint c)   { return (int)((c >> 16) & 255); }
int  FPGreen(const uint c) { return (int)((c >> 8) & 255); }
int  FPBlue(const uint c)  { return (int)(c & 255); }

//--- MQL5 color (0x00BBGGRR) -> ARGB
uint FPFromColor(const color c)
{
   return ColorToARGB(c, 255);
}

//--- result = bg*(1-a) + fg*a, opaque
uint FPBlend(const uint bg, const uint fg, const double a)
{
   double t = a;
   if(t < 0.0)
      t = 0.0;
   if(t > 1.0)
      t = 1.0;
   int r = (int)MathRound(FPRed(bg)   + (FPRed(fg)   - FPRed(bg))   * t);
   int g = (int)MathRound(FPGreen(bg) + (FPGreen(fg) - FPGreen(bg)) * t);
   int b = (int)MathRound(FPBlue(bg)  + (FPBlue(fg)  - FPBlue(bg))  * t);
   return FPRGB(r, g, b);
}

//--- relative luminance 0..1
double FPLuma(const uint c)
{
   return (0.2126 * FPRed(c) + 0.7152 * FPGreen(c) + 0.0722 * FPBlue(c)) / 255.0;
}

//+------------------------------------------------------------------+
//| Palette: every colour a frame needs                               |
//+------------------------------------------------------------------+
struct FPPalette
{
   bool  dark;
   uint  bg, panelBg, border, grid, gridFaint, text, text2, textOff;
   uint  bull, bear;
   uint  neutral;      // (140,145,155) analyst neutral / meter neutral
   uint  blue;         // (59,130,246) active button / ticker price
   uint  levelBlue;    // (96,165,250) analyst level sentences
   uint  gold;         // (250,204,21)
   uint  purple;       // (168,85,247) session POC, RSI
   uint  fuchsia;      // (255,0,255) per-bar POC outline
   uint  slate;        // (148,163,184) VAH/VAL
   uint  sdGrey;       // (120,126,138) touched S&D zone
   uint  buyImb[4];    // [1..3] tier colours of buyer imbalances
   uint  sellImb[4];   // [1..3] tier colours of seller imbalances
   uint  vpSell, vpBuy;  // bar VP raw colours (239,68,68) / (34,197,94)
   uint  darkText, lightText;
   uint  cdGreen, cdYellow, cdOrange, cdRed;   // countdown colours
   uint  headerBg, btnBg;
   uint  trBuy, trSell, trSL, trTP;            // trade overlay
};

//+------------------------------------------------------------------+
//| Theme builder                                                     |
//+------------------------------------------------------------------+
class CFPTheme
{
public:
   static void       Accent(const int theme, uint &bull, uint &bear)
     {
      switch(theme)
        {
         case FP_CT_CLASSIC:          bull = FPRGB(34, 197, 94);   bear = FPRGB(239, 68, 68);   break;
         case FP_CT_BLUE_ORANGE:      bull = FPRGB(59, 130, 246);  bear = FPRGB(249, 115, 22);  break;
         case FP_CT_CYAN_MAGENTA:     bull = FPRGB(6, 182, 212);   bear = FPRGB(217, 70, 239);  break;
         case FP_CT_LIME_PINK:        bull = FPRGB(132, 204, 22);  bear = FPRGB(236, 72, 153);  break;
         case FP_CT_GOLD_PURPLE:      bull = FPRGB(250, 204, 21);  bear = FPRGB(168, 85, 247);  break;
         case FP_CT_TEAL_CORAL:       bull = FPRGB(20, 184, 166);  bear = FPRGB(251, 113, 133); break;
         case FP_CT_SKY_CRIMSON:      bull = FPRGB(56, 189, 248);  bear = FPRGB(220, 20, 60);   break;
         case FP_CT_MINT_ROSE:        bull = FPRGB(110, 231, 183); bear = FPRGB(244, 63, 94);   break;
         case FP_CT_ORANGE_DARK_GREY: bull = FPRGB(217, 107, 0);   bear = FPRGB(85, 90, 100);   break;
         case FP_CT_GREEN_DARK_GREY:  bull = FPRGB(34, 197, 94);   bear = FPRGB(85, 90, 100);   break;
         case FP_CT_NAVY_SLATE:       bull = FPRGB(37, 99, 235);   bear = FPRGB(100, 116, 139); break;
         case FP_CT_NAVY_GOLD:        bull = FPRGB(37, 99, 235);   bear = FPRGB(234, 179, 8);   break;
         case FP_CT_WHITE_DARK_GREY:  bull = FPRGB(229, 231, 235); bear = FPRGB(85, 90, 100);   break;
         case FP_CT_EMERALD_WHITE:    bull = FPRGB(16, 185, 129);  bear = FPRGB(229, 231, 235); break;
         case FP_CT_CHERRY_TEAL:      bull = FPRGB(190, 18, 60);   bear = FPRGB(13, 148, 136);  break;
         case FP_CT_OLIVE_SANDY:      bull = FPRGB(132, 140, 40);  bear = FPRGB(244, 164, 96);  break;
         default:                     bull = FPRGB(34, 197, 94);   bear = FPRGB(239, 68, 68);   break;
        }
     }

   static string     AccentName(const int theme)
     {
      switch(theme)
        {
         case FP_CT_CLASSIC:          return "Classic";
         case FP_CT_BLUE_ORANGE:      return "Blue/Orange";
         case FP_CT_CYAN_MAGENTA:     return "Cyan/Magenta";
         case FP_CT_LIME_PINK:        return "Lime/Pink";
         case FP_CT_GOLD_PURPLE:      return "Gold/Purple";
         case FP_CT_TEAL_CORAL:       return "Teal/Coral";
         case FP_CT_SKY_CRIMSON:      return "Sky/Crimson";
         case FP_CT_MINT_ROSE:        return "Mint/Rose";
         case FP_CT_ORANGE_DARK_GREY: return "Orange/Dark grey";
         case FP_CT_GREEN_DARK_GREY:  return "Green/Dark grey";
         case FP_CT_NAVY_SLATE:       return "Navy/Slate";
         case FP_CT_NAVY_GOLD:        return "Navy/Gold";
         case FP_CT_WHITE_DARK_GREY:  return "White/Dark grey";
         case FP_CT_EMERALD_WHITE:    return "Emerald/White";
         case FP_CT_CHERRY_TEAL:      return "Cherry/Teal";
         case FP_CT_OLIVE_SANDY:      return "Olive/Sandy";
        }
      return "?";
     }

   //--- buyImb/sellImb: [0] = base input colour, [1..3] = per-tier inputs (clrNONE = base)
   static void       Build(const int panelTheme, const int colorTheme,
                           const color buyBase, const color sellBase,
                           const color &buyTier[], const color &sellTier[],
                           const bool themeOverridesImb, FPPalette &p)
     {
      p.dark = (panelTheme != FP_PANEL_LIGHT);
      if(p.dark)
        {
         p.bg      = FPRGB(15, 17, 23);
         p.panelBg = FPRGB(19, 22, 29);
         p.border  = FPRGB(40, 45, 55);
         p.grid    = FPRGB(28, 32, 40);
         p.text    = FPRGB(220, 225, 235);
         p.text2   = FPRGB(140, 145, 155);
        }
      else
        {
         p.bg      = FPRGB(248, 248, 248);
         p.panelBg = FPRGB(255, 255, 255);
         p.border  = FPRGB(214, 218, 225);
         p.grid    = FPRGB(232, 234, 238);
         p.text    = FPRGB(30, 35, 45);
         p.text2   = FPRGB(110, 115, 125);
        }
      p.gridFaint = FPBlend(p.bg, p.grid, 0.55);
      p.textOff   = FPBlend(p.bg, p.text2, p.dark ? 0.45 : 0.40);
      p.headerBg  = p.bg;
      p.btnBg     = p.panelBg;
      Accent(colorTheme, p.bull, p.bear);
      p.neutral   = FPRGB(140, 145, 155);
      p.blue      = FPRGB(59, 130, 246);
      p.levelBlue = FPRGB(96, 165, 250);
      p.gold      = FPRGB(250, 204, 21);
      p.purple    = FPRGB(168, 85, 247);
      p.fuchsia   = FPRGB(255, 0, 255);
      p.slate     = FPRGB(148, 163, 184);
      p.sdGrey    = FPRGB(120, 126, 138);
      p.vpSell    = FPRGB(239, 68, 68);
      p.vpBuy     = FPRGB(34, 197, 94);
      p.darkText  = FPRGB(30, 35, 45);
      p.lightText = FPRGB(220, 225, 235);
      p.cdGreen   = FPRGB(0, 255, 127);
      p.cdYellow  = FPRGB(250, 204, 21);
      p.cdOrange  = FPRGB(249, 115, 22);
      p.cdRed     = FPRGB(239, 68, 68);
      if(!p.dark)
        {
         //--- spring green / yellow are unreadable on white: darker variants
         p.cdGreen  = FPRGB(0, 160, 80);
         p.cdYellow = FPRGB(202, 138, 4);
        }
      p.trBuy  = FPRGB(59, 130, 246);
      p.trSell = FPRGB(236, 72, 153);
      p.trSL   = FPRGB(239, 68, 68);
      p.trTP   = FPRGB(34, 197, 94);
      //--- imbalance colours: fixed unless the theme overrides them
      uint bBase = themeOverridesImb ? p.bull : FPFromColor(buyBase);
      uint sBase = themeOverridesImb ? p.bear : FPFromColor(sellBase);
      p.buyImb[0]  = bBase;
      p.sellImb[0] = sBase;
      for(int t = 1; t <= 3; t++)
        {
         p.buyImb[t]  = bBase;
         p.sellImb[t] = sBase;
         if(!themeOverridesImb)
           {
            if(ArraySize(buyTier) > t && buyTier[t] != clrNONE)
               p.buyImb[t] = FPFromColor(buyTier[t]);
            if(ArraySize(sellTier) > t && sellTier[t] != clrNONE)
               p.sellImb[t] = FPFromColor(sellTier[t]);
           }
        }
     }

   //--- readable text on a filled cell: primary text, dark on very light cells (Dark theme),
   //    light on dark cells (Light theme, e.g. a dark-grey bear colour at full heat)
   static uint       TextOn(const FPPalette &p, const uint cellBg)
     {
      double l = FPLuma(cellBg);
      if(!p.dark)
         return (l < 0.40) ? FPRGB(245, 247, 250) : p.text;
      return (l > 0.6) ? p.darkText : p.text;
     }
};

#endif // ORDERFLOWFP_UI_FPTHEME_MQH
//+------------------------------------------------------------------+
