// GDI+ 绘制小工具：分层窗口表面、圆角卡片、文字、chip、开关
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objidl.h>
#include <gdiplus.h>

#include <map>
#include <string>
#include <vector>

namespace ui {

inline Gdiplus::Color rgba(int r, int g, int b, int a = 255) {
    return Gdiplus::Color((BYTE)a, (BYTE)r, (BYTE)g, (BYTE)b);
}
inline Gdiplus::Color fromArgb(unsigned int argb) {
    return Gdiplus::Color((BYTE)((argb >> 24) & 0xFF), (BYTE)((argb >> 16) & 0xFF),
                          (BYTE)((argb >> 8) & 0xFF), (BYTE)(argb & 0xFF));
}
inline Gdiplus::Color withAlpha(Gdiplus::Color c, int a) {
    return Gdiplus::Color((BYTE)a, c.GetR(), c.GetG(), c.GetB());
}
inline Gdiplus::Color mix(Gdiplus::Color a, Gdiplus::Color b, double t) {
    return rgba((int)(a.GetR() + (b.GetR() - a.GetR()) * t),
                (int)(a.GetG() + (b.GetG() - a.GetG()) * t),
                (int)(a.GetB() + (b.GetB() - a.GetB()) * t),
                (int)(a.GetA() + (b.GetA() - a.GetA()) * t));
}

// 深 / 浅色外观（跟随 Windows「应用模式」）
struct Theme {
    bool light = false;
    Gdiplus::Color card;
    Gdiplus::Color stroke;
    Gdiplus::Color text;
    Gdiplus::Color secondary;
    Gdiplus::Color tertiary;
    Gdiplus::Color separator;
    Gdiplus::Color chip;
    Gdiplus::Color onAccent;
    Gdiplus::Color accent;
    Gdiplus::Color heat[6];
};

Theme makeTheme(bool lightMode, unsigned int accentArgb);
bool systemUsesLightTheme();

// 32 位 DIB + GDI+ Graphics，方便 UpdateLayeredWindow
struct Surface {
    int w = 0, h = 0;
    HDC dc = nullptr;
    HBITMAP bmp = nullptr;
    void* bits = nullptr;
    Gdiplus::Bitmap* bitmap = nullptr;
    Gdiplus::Graphics* g = nullptr;
};

Surface* createSurface(int w, int h);
void destroySurface(Surface*& s);
void clearSurface(Surface* s);
void presentLayered(HWND hwnd, Surface* s, int x, int y);
void presentTo(HDC target, Surface* s);

// 绘制上下文：坐标一律传逻辑值，内部乘 scale
class Canvas {
public:
    Canvas(Gdiplus::Graphics* g, float scale) : g_(g), s_(scale) {}
    ~Canvas();

    float s(float v) const { return v * s_; }
    Gdiplus::RectF R(float x, float y, float w, float h) const {
        return Gdiplus::RectF(x * s_, y * s_, w * s_, h * s_);
    }
    float scale() const { return s_; }

    void fillRound(const Gdiplus::RectF& r, float radius, const Gdiplus::Color& c);
    void strokeRound(const Gdiplus::RectF& r, float radius, const Gdiplus::Color& c, float width = 1.0f);
    void fillRect(const Gdiplus::RectF& r, const Gdiplus::Color& c);
    void line(float x1, float y1, float x2, float y2, const Gdiplus::Color& c, float width = 1.0f);

    enum Align { LEADING = 0, CENTER = 1, TRAILING = 2 };
    // 文本：size 是逻辑像素字号
    void text(const std::wstring& str, const Gdiplus::RectF& r, const Gdiplus::Color& c,
              float size, Align align = LEADING, bool bold = false, bool ellipsis = false);
    void textAt(const std::wstring& str, float x, float y, const Gdiplus::Color& c,
                float size, bool bold = false);      // 左上角定位
    float textWidth(const std::wstring& str, float size, bool bold = false);
    float textHeight(float size);

    // 常用控件
    void chip(const Gdiplus::RectF& r, const std::wstring& title, bool selected, bool enabled,
              const Theme& th);
    void toggle(const Gdiplus::RectF& r, bool on, bool enabled, const Theme& th);
    void pencil(const Gdiplus::RectF& r, const Gdiplus::Color& c);
    void cross(const Gdiplus::RectF& r, const Gdiplus::Color& c);
    void paw(const Gdiplus::RectF& r, const Gdiplus::Color& c);

private:
    Gdiplus::Font* fontFor(float size, bool bold);
    Gdiplus::Graphics* g_;
    float s_;
    std::map<int, Gdiplus::Font*> fonts_;
};

std::wstring widen(const std::string& utf8);
std::string narrow(const std::wstring& w);

// 逻辑尺寸按 DPI 放大
inline int scaled(int v, float s) { return (int)(v * s + 0.5f); }

}  // namespace ui
