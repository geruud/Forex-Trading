//+------------------------------------------------------------------+
//| FPCanvas.mqh - OrderFlowFP UI: CCanvas with a font cache and the   |
//| primitives the renderer needs (dashes, blends, rounded boxes).     |
//|                                                                    |
//| CCanvas::TextOut() calls TextSetFont() on EVERY call; this class   |
//| registers fonts once (ids) and switches only when the id changes.  |
//| All font sizes are POSITIVE pixel sizes (02 §6).                   |
//+------------------------------------------------------------------+
#ifndef ORDERFLOWFP_UI_FPCANVAS_MQH
#define ORDERFLOWFP_UI_FPCANVAS_MQH

#include <Canvas\Canvas.mqh>
#include "FPTheme.mqh"

#define FPC_MAX_FONTS 40

class CFPCanvas : public CCanvas
{
private:
   string            m_fName[FPC_MAX_FONTS];
   int               m_fSize[FPC_MAX_FONTS];
   uint              m_fFlags[FPC_MAX_FONTS];
   int               m_fCharW[FPC_MAX_FONTS];
   int               m_fCharH[FPC_MAX_FONTS];
   int               m_nFonts;
   int               m_curFont;

public:
                     CFPCanvas(void) : m_nFonts(0), m_curFont(-1) {}

   //--- fonts ----------------------------------------------------------
   void              ResetFonts(void) { m_nFonts = 0; m_curFont = -1; }
   int               AddFont(const string name, const int px, const uint flags)
     {
      if(m_nFonts >= FPC_MAX_FONTS)
         return 0;
      int id = m_nFonts;
      m_nFonts++;
      m_fName[id]  = name;
      m_fSize[id]  = (px < 4) ? 4 : px;
      m_fFlags[id] = flags;
      m_curFont = -1;
      UseFont(id);
      uint w = 0, h = 0;
      TextGetSize("0", w, h);
      m_fCharW[id] = (int)w;
      m_fCharH[id] = (int)h;
      return id;
     }
   void              UseFont(const int id)
     {
      if(id == m_curFont || id < 0 || id >= m_nFonts)
         return;
      TextSetFont(m_fName[id], m_fSize[id], m_fFlags[id], 0);
      m_curFont = id;
     }
   int               CharW(const int id) const { return (id >= 0 && id < m_nFonts) ? m_fCharW[id] : 7; }
   int               CharH(const int id) const { return (id >= 0 && id < m_nFonts) ? m_fCharH[id] : 12; }
   int               FontPx(const int id) const { return (id >= 0 && id < m_nFonts) ? m_fSize[id] : 12; }

   void              Txt(const int font, const int x, const int y, const string s, const uint clr, const uint align = 0)
     {
      UseFont(font);
      ::TextOut(s, x, y, align, m_pixels, m_width, m_height, clr, m_format);
     }
   int               TxtW(const int font, const string s)
     {
      UseFont(font);
      uint w = 0, h = 0;
      TextGetSize(s, w, h);
      return (int)w;
     }
   //--- letter-spaced text (tabs); returns the drawn width
   int               SpacedW(const int font, const string s, const int spacing)
     {
      int n = StringLen(s);
      int w = 0;
      for(int i = 0; i < n; i++)
         w += TxtW(font, StringSubstr(s, i, 1)) + ((i < n - 1) ? spacing : 0);
      return w;
     }
   void              SpacedTxt(const int font, const int x, const int y, const string s, const uint clr, const int spacing)
     {
      int n = StringLen(s);
      int cx = x;
      for(int i = 0; i < n; i++)
        {
         string ch = StringSubstr(s, i, 1);
         if(ch != " ")
            Txt(font, cx, y, ch, clr, TA_LEFT | TA_VCENTER);
         cx += TxtW(font, ch) + spacing;
        }
     }

   //--- rectangles (x, y, w, h) ----------------------------------------
   void              Box(const int x, const int y, const int w, const int h, const uint c)
     {
      if(w > 0 && h > 0)
         FillRectangle(x, y, x + w - 1, y + h - 1, c);
     }
   void              Frame(const int x, const int y, const int w, const int h, const uint c)
     {
      if(w > 0 && h > 0)
         Rectangle(x, y, x + w - 1, y + h - 1, c);
     }
   void              HL(const int x1, const int x2, const int y, const uint c) { LineHorizontal(x1, x2, y, c); }
   void              VL(const int x, const int y1, const int y2, const uint c) { LineVertical(x, y1, y2, c); }

   void              HDash(const int x1, const int x2, const int y, const uint c, const int on, const int off)
     {
      int a = MathMin(x1, x2), b = MathMax(x1, x2);
      int step = MathMax(1, on + off);
      for(int x = a; x <= b; x += step)
         LineHorizontal(x, MathMin(x + on - 1, b), y, c);
     }
   void              VDash(const int x, const int y1, const int y2, const uint c, const int on, const int off)
     {
      int a = MathMin(y1, y2), b = MathMax(y1, y2);
      int step = MathMax(1, on + off);
      for(int y = a; y <= b; y += step)
         LineVertical(x, y, MathMin(y + on - 1, b), c);
     }
   //--- any-angle dashed segment (Bresenham with an on/off pattern)
   void              DashSeg(int x1, int y1, const int x2, const int y2, const uint c, const int on, const int off)
     {
      int dx = MathAbs(x2 - x1), sx = (x1 < x2) ? 1 : -1;
      int dy = -MathAbs(y2 - y1), sy = (y1 < y2) ? 1 : -1;
      int err = dx + dy;
      int k = 0;
      int period = MathMax(1, on + off);
      for(int guard = 0; guard < 20000; guard++)
        {
         if((k % period) < on)
            PixelSet(x1, y1, c);
         k++;
         if(x1 == x2 && y1 == y2)
            break;
         int e2 = 2 * err;
         if(e2 >= dy)
           {
            err += dy;
            x1 += sx;
           }
         if(e2 <= dx)
           {
            err += dx;
            y1 += sy;
           }
        }
     }

   //--- true per-pixel blending into the pixel buffer (bitmap stays opaque)
   void              BlendPixel(const int x, const int y, const uint c, const double a)
     {
      if(x < 0 || y < 0 || x >= m_width || y >= m_height)
         return;
      int i = y * m_width + x;
      m_pixels[i] = FPBlend(m_pixels[i], c, a);
     }
   void              BlendBox(int x, int y, int w, int h, const uint c, const double a)
     {
      if(w <= 0 || h <= 0)
         return;
      int x2 = x + w - 1, y2 = y + h - 1;
      if(x < 0)
         x = 0;
      if(y < 0)
         y = 0;
      if(x2 >= m_width)
         x2 = m_width - 1;
      if(y2 >= m_height)
         y2 = m_height - 1;
      if(x > x2 || y > y2)
         return;
      int ia = (int)MathRound(a * 256.0);
      if(ia <= 0)
         return;
      if(ia > 256)
         ia = 256;
      int fr = FPRed(c), fg = FPGreen(c), fb = FPBlue(c);
      for(int yy = y; yy <= y2; yy++)
        {
         int row = yy * m_width;
         for(int xx = x; xx <= x2; xx++)
           {
            uint p = m_pixels[row + xx];
            int r = (int)((p >> 16) & 255), g = (int)((p >> 8) & 255), b = (int)(p & 255);
            r += ((fr - r) * ia) >> 8;
            g += ((fg - g) * ia) >> 8;
            b += ((fb - b) * ia) >> 8;
            m_pixels[row + xx] = 0xFF000000 | ((uint)r << 16) | ((uint)g << 8) | (uint)b;
           }
        }
     }

   //--- rounded boxes (radius in px, small radii)
   void              RoundBox(const int x, const int y, const int w, const int h, const int r, const uint c)
     {
      if(w <= 0 || h <= 0)
         return;
      int rr = MathMin(r, MathMin(w, h) / 2);
      if(rr <= 0)
        {
         Box(x, y, w, h, c);
         return;
        }
      Box(x, y + rr, w, h - 2 * rr, c);
      for(int i = 0; i < rr; i++)
        {
         double dyy = rr - i - 0.5;
         int inset = rr - (int)MathFloor(MathSqrt((double)(rr * rr) - dyy * dyy) + 0.5);
         LineHorizontal(x + inset, x + w - 1 - inset, y + i, c);
         LineHorizontal(x + inset, x + w - 1 - inset, y + h - 1 - i, c);
        }
     }
   void              RoundFrame(const int x, const int y, const int w, const int h, const int r, const uint c)
     {
      if(w <= 0 || h <= 0)
         return;
      int rr = MathMin(r, MathMin(w, h) / 2);
      if(rr <= 1)
        {
         Frame(x, y, w, h, c);
         return;
        }
      LineHorizontal(x + rr, x + w - 1 - rr, y, c);
      LineHorizontal(x + rr, x + w - 1 - rr, y + h - 1, c);
      LineVertical(x, y + rr, y + h - 1 - rr, c);
      LineVertical(x + w - 1, y + rr, y + h - 1 - rr, c);
      //--- corners: quarter circles
      for(int i = 0; i <= rr; i++)
        {
         double a = (M_PI / 2.0) * i / rr;
         int ox = (int)MathRound(rr - rr * MathCos(a));
         int oy = (int)MathRound(rr - rr * MathSin(a));
         PixelSet(x + ox, y + oy, c);
         PixelSet(x + w - 1 - ox, y + oy, c);
         PixelSet(x + ox, y + h - 1 - oy, c);
         PixelSet(x + w - 1 - ox, y + h - 1 - oy, c);
        }
     }
   //--- filled triangle pointing up (dir>0) or down (dir<0), centred on (cx, cy)
   void              Arrow(const int cx, const int cy, const int size, const int dir, const uint c)
     {
      int hs = MathMax(2, size);
      if(dir > 0)
         FillTriangle(cx - hs, cy + hs / 2, cx + hs, cy + hs / 2, cx, cy - hs / 2 - 1, c);
      else
         FillTriangle(cx - hs, cy - hs / 2, cx + hs, cy - hs / 2, cx, cy + hs / 2 + 1, c);
     }
   //--- anti-aliased disc / ring by distance (background-independent)
   void              DiscAA(const int cx, const int cy, const double r, const uint c)
     {
      int ri = (int)MathCeil(r) + 1;
      for(int yy = -ri; yy <= ri; yy++)
         for(int xx = -ri; xx <= ri; xx++)
           {
            double d = MathSqrt((double)(xx * xx + yy * yy));
            double a = r + 0.5 - d;
            if(a <= 0.0)
               continue;
            BlendPixel(cx + xx, cy + yy, c, (a >= 1.0) ? 1.0 : a);
           }
     }
   void              RingAA(const int cx, const int cy, const double r, const double width, const uint c)
     {
      int ri = (int)MathCeil(r + width) + 1;
      double r0 = r - width / 2.0, r1 = r + width / 2.0;
      for(int yy = -ri; yy <= ri; yy++)
         for(int xx = -ri; xx <= ri; xx++)
           {
            double d = MathSqrt((double)(xx * xx + yy * yy));
            double a = MathMin(d - r0 + 0.5, r1 + 0.5 - d);
            if(a <= 0.0)
               continue;
            BlendPixel(cx + xx, cy + yy, c, (a >= 1.0) ? 1.0 : a);
           }
     }
   //--- anti-aliased thick line (distance to segment)
   void              ThickLineAA(const double x1, const double y1, const double x2, const double y2, const double width, const uint c)
     {
      int minx = (int)MathFloor(MathMin(x1, x2) - width - 1), maxx = (int)MathCeil(MathMax(x1, x2) + width + 1);
      int miny = (int)MathFloor(MathMin(y1, y2) - width - 1), maxy = (int)MathCeil(MathMax(y1, y2) + width + 1);
      double vx = x2 - x1, vy = y2 - y1;
      double len2 = vx * vx + vy * vy;
      double hw = width / 2.0;
      for(int yy = miny; yy <= maxy; yy++)
         for(int xx = minx; xx <= maxx; xx++)
           {
            double t = 0.0;
            if(len2 > 0.0)
               t = ((xx - x1) * vx + (yy - y1) * vy) / len2;
            if(t < 0.0)
               t = 0.0;
            if(t > 1.0)
               t = 1.0;
            double px = x1 + t * vx - xx, py = y1 + t * vy - yy;
            double d = MathSqrt(px * px + py * py);
            double a = hw + 0.5 - d;
            if(a <= 0.0)
               continue;
            BlendPixel(xx, yy, c, (a >= 1.0) ? 1.0 : a);
           }
     }
};

#endif // ORDERFLOWFP_UI_FPCANVAS_MQH
//+------------------------------------------------------------------+
