#include "ui.h"

#include <algorithm>
#include <cmath>

using namespace Gdiplus;

namespace ui {

std::wstring widen(const std::string& utf8) {
    if (utf8.empty()) return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), nullptr, 0);
    std::wstring out((size_t)n, L'\0');
    MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), (int)utf8.size(), &out[0], n);
    return out;
}

std::string narrow(const std::wstring& w) {
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string out((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &out[0], n, nullptr, nullptr);
    return out;
}

bool systemUsesLightTheme() {
    DWORD value = 0, size = sizeof(value);
    LONG rc = RegGetValueW(HKEY_CURRENT_USER,
                           L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
                           L"AppsUseLightTheme", RRF_RT_REG_DWORD, nullptr, &value, &size);
    return rc == ERROR_SUCCESS && value != 0;
}

Theme makeTheme(bool lightMode, unsigned int accentArgb) {
    Theme t;
    t.light = lightMode;
    if (lightMode) {
        t.card = rgba(250, 250, 252, 250);
        t.stroke = rgba(0, 0, 0, 26);
        t.text = rgba(26, 26, 28);
        t.secondary = rgba(110, 110, 115);
        t.tertiary = rgba(160, 160, 165);
        t.separator = rgba(0, 0, 0, 26);
        t.chip = rgba(0, 0, 0, 12);
        t.onAccent = rgba(30, 22, 14);
    } else {
        t.card = rgba(30, 32, 36, 250);
        t.stroke = rgba(255, 255, 255, 22);
        t.text = rgba(245, 245, 247);
        t.secondary = rgba(170, 172, 178);
        t.tertiary = rgba(120, 122, 128);
        t.separator = rgba(255, 255, 255, 26);
        t.chip = rgba(255, 255, 255, 20);
        t.onAccent = rgba(28, 20, 12);
    }
    t.accent = fromArgb(accentArgb ? accentArgb : 0xFFFFB648);
    // 与 macOS 同一套五档暖色
    t.heat[0] = rgba(0, 0, 0, 0);
    t.heat[1] = rgba(247, 219, 158);
    t.heat[2] = rgba(245, 189, 87);
    t.heat[3] = rgba(230, 140, 41);
    t.heat[4] = rgba(199, 92, 31);
    t.heat[5] = rgba(153, 56, 26);
    return t;
}

Surface* createSurface(int w, int h) {
    if (w <= 0 || h <= 0) return nullptr;
    Surface* s = new Surface();
    s->w = w;
    s->h = h;
    HDC screen = GetDC(nullptr);
    s->dc = CreateCompatibleDC(screen);
    ReleaseDC(nullptr, screen);

    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;      // top-down
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    s->bmp = CreateDIBSection(s->dc, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (!s->bmp) {
        destroySurface(s);
        return nullptr;
    }
    s->bits = bits;
    SelectObject(s->dc, s->bmp);

    s->bitmap = new Bitmap(w, h, w * 4, PixelFormat32bppPARGB, (BYTE*)bits);
    s->g = new Graphics(s->bitmap);
    s->g->SetSmoothingMode(SmoothingModeAntiAlias);
    s->g->SetPixelOffsetMode(PixelOffsetModeHalf);
    s->g->SetTextRenderingHint(TextRenderingHintAntiAliasGridFit);
    clearSurface(s);
    return s;
}

void destroySurface(Surface*& s) {
    if (!s) return;
    delete s->g;
    delete s->bitmap;
    if (s->bmp) DeleteObject(s->bmp);
    if (s->dc) DeleteDC(s->dc);
    delete s;
    s = nullptr;
}

void clearSurface(Surface* s) {
    if (!s || !s->bits) return;
    memset(s->bits, 0, (size_t)s->w * s->h * 4);
}

void presentLayered(HWND hwnd, Surface* s, int x, int y) {
    if (!s) return;
    POINT src = {0, 0};
    SIZE size = {s->w, s->h};
    POINT dst = {x, y};
    BLENDFUNCTION bf = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd, nullptr, &dst, &size, s->dc, &src, 0, &bf, ULW_ALPHA);
}

void presentTo(HDC target, Surface* s) {
    if (!s) return;
    BitBlt(target, 0, 0, s->w, s->h, s->dc, 0, 0, SRCCOPY);
}

// ---------------------------------------------------------------- Canvas
namespace {
GraphicsPath* roundPath(const RectF& r, float radius) {
    GraphicsPath* p = new GraphicsPath();
    float d = radius * 2.0f;
    if (d > r.Width) d = r.Width;
    if (d > r.Height) d = r.Height;
    if (d <= 0.5f) {
        p->AddRectangle(r);
        return p;
    }
    p->AddArc(r.X, r.Y, d, d, 180.0f, 90.0f);
    p->AddArc(r.X + r.Width - d, r.Y, d, d, 270.0f, 90.0f);
    p->AddArc(r.X + r.Width - d, r.Y + r.Height - d, d, d, 0.0f, 90.0f);
    p->AddArc(r.X, r.Y + r.Height - d, d, d, 90.0f, 90.0f);
    p->CloseFigure();
    return p;
}
}  // namespace

Canvas::~Canvas() {
    for (auto& kv : fonts_) delete kv.second;
    fonts_.clear();
}

void Canvas::fillRound(const RectF& r, float radius, const Color& c) {
    if (c.GetA() == 0) return;
    GraphicsPath* p = roundPath(r, radius * s_);
    SolidBrush b(c);
    g_->FillPath(&b, p);
    delete p;
}

void Canvas::strokeRound(const RectF& r, float radius, const Color& c, float width) {
    if (c.GetA() == 0) return;
    GraphicsPath* p = roundPath(r, radius * s_);
    Pen pen(c, width * s_);
    g_->DrawPath(&pen, p);
    delete p;
}

void Canvas::fillRect(const RectF& r, const Color& c) {
    SolidBrush b(c);
    g_->FillRectangle(&b, r);
}

void Canvas::line(float x1, float y1, float x2, float y2, const Color& c, float width) {
    Pen pen(c, width * s_);
    pen.SetStartCap(LineCapRound);
    pen.SetEndCap(LineCapRound);
    g_->DrawLine(&pen, s(x1), s(y1), s(x2), s(y2));
}

Font* Canvas::fontFor(float size, bool bold) {
    int key = (int)(size * 10) * 2 + (bold ? 1 : 0);
    auto it = fonts_.find(key);
    if (it != fonts_.end()) return it->second;
    const wchar_t* families[] = {L"Microsoft YaHei UI", L"Microsoft YaHei", L"Segoe UI"};
    Font* f = nullptr;
    for (const wchar_t* fam : families) {
        FontFamily ff(fam);
        if (ff.IsAvailable()) {
            f = new Font(&ff, size * s_, FontStyleRegular, UnitPixel);
            break;
        }
    }
    if (!f) {
        FontFamily ff(L"Segoe UI");
        f = new Font(&ff, size * s_, FontStyleRegular, UnitPixel);
    }
    fonts_[key] = f;
    return f;
}

void Canvas::text(const std::wstring& str, const RectF& r, const Color& c, float size,
                  Align align, bool bold, bool ellipsis) {
    if (str.empty()) return;
    Font* f = fontFor(size, bold);
    StringFormat fmt;
    fmt.SetAlignment(align == CENTER ? StringAlignmentCenter
                                     : (align == TRAILING ? StringAlignmentFar : StringAlignmentNear));
    fmt.SetLineAlignment(StringAlignmentCenter);
    fmt.SetFormatFlags(StringFormatFlagsNoWrap);
    if (ellipsis) fmt.SetTrimming(StringTrimmingEllipsisCharacter);
    SolidBrush brush(c);
    g_->DrawString(str.c_str(), (INT)str.size(), f, r, &fmt, &brush);
}

void Canvas::textAt(const std::wstring& str, float x, float y, const Color& c, float size, bool bold) {
    if (str.empty()) return;
    Font* f = fontFor(size, bold);
    SolidBrush brush(c);
    g_->DrawString(str.c_str(), (INT)str.size(), f, PointF(s(x), s(y)), &brush);
}

float Canvas::textWidth(const std::wstring& str, float size, bool bold) {
    if (str.empty()) return 0.0f;
    Font* f = fontFor(size, bold);
    RectF bounds;
    g_->MeasureString(str.c_str(), (INT)str.size(), f, PointF(0, 0), &bounds);
    return bounds.Width + 1.0f;
}

float Canvas::textHeight(float size) {
    Font* f = fontFor(size, false);
    return f->GetHeight(g_) + 2.0f;
}

void Canvas::chip(const RectF& r, const std::wstring& title, bool selected, bool enabled,
                  const Theme& th) {
    Color fill = selected ? th.accent : th.chip;
    Color fg = selected ? th.onAccent : th.text;
    if (!enabled) {
        fill = withAlpha(th.chip, 60);
        fg = th.tertiary;
    }
    fillRound(r, 8.0f, fill);
    text(title, r, fg, 11.0f, CENTER, selected);
}

void Canvas::toggle(const RectF& r, bool on, bool enabled, const Theme& th) {
    Color track = on ? th.accent : withAlpha(th.secondary, th.light ? 70 : 60);
    if (!enabled) track = withAlpha(th.chip, 80);
    fillRound(r, r.Height / 2.0f, track);
    float knob = r.Height - 4.0f;
    float kx = on ? r.X + r.Width - knob - 2.0f : r.X + 2.0f;
    SolidBrush knobBrush(rgba(255, 255, 255, enabled ? 255 : 160));
    g_->FillEllipse(&knobBrush, RectF(kx, r.Y + 2.0f, knob, knob));
}

void Canvas::pencil(const RectF& r, const Color& c) {
    Pen pen(c, 2.2f * s_);
    pen.SetStartCap(LineCapRound);
    pen.SetEndCap(LineCapRound);
    g_->DrawLine(&pen, s(r.X + 4.5f), s(r.Y + r.Height - 3.5f),
                 s(r.X + r.Width - 3.5f), s(r.Y + 4.5f));
    SolidBrush b(c);
    PointF tip[3] = {PointF(s(r.X + 3.0f), s(r.Y + r.Height - 3.0f)),
                     PointF(s(r.X + 7.4f), s(r.Y + r.Height - 3.0f)),
                     PointF(s(r.X + 3.0f), s(r.Y + r.Height - 7.4f))};
    g_->FillPolygon(&b, tip, 3);
}

void Canvas::cross(const RectF& r, const Color& c) {
    Pen pen(c, 1.3f * s_);
    pen.SetStartCap(LineCapRound);
    pen.SetEndCap(LineCapRound);
    float inset = 4.0f;
    g_->DrawLine(&pen, s(r.X + inset), s(r.Y + inset), s(r.X + r.Width - inset), s(r.Y + r.Height - inset));
    g_->DrawLine(&pen, s(r.X + r.Width - inset), s(r.Y + inset), s(r.X + inset), s(r.Y + r.Height - inset));
}

void Canvas::paw(const RectF& r, const Color& c) {
    static const wchar_t* art[8] = {L"##.##.##", L"##.##.##", L"........", L".######.",
                                    L".######.", L".######.", L"........", L"........"};
    float step = r.Width / 8.0f;
    SolidBrush b(c);
    for (int row = 0; row < 8; ++row) {
        for (int col = 0; col < 8; ++col) {
            if (art[row][col] != L'#') continue;
            g_->FillRectangle(&b, RectF(s(r.X + col * step), s(r.Y + row * step),
                                        s(step) + 0.5f, s(step) + 0.5f));
        }
    }
}

}  // namespace ui
