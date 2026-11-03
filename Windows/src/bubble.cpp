#include "bubble.h"

#include <algorithm>
#include <cmath>
#include <vector>

using namespace Gdiplus;

namespace {
const wchar_t* kBubbleClass = L"DesktopPetBubble";
const float kWidth = 244.0f;
const float kPad = 12.0f;
const float kTitleH = 15.0f;
const float kLineH = 17.0f;
const float kHintH = 13.0f;
const float kTail = 9.0f;
const unsigned long long kLifeMs = 7000;
}  // namespace

bool PetBubble::create(HINSTANCE inst) {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &PetBubble::wndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_HAND);
    wc.lpszClassName = kBubbleClass;
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE,
                            kBubbleClass, L"DesktopPetBubble", WS_POPUP, 0, 0, 10, 10, nullptr,
                            nullptr, inst, this);
    if (!hwnd_) return false;
    SetWindowLongPtrW(hwnd_, GWLP_USERDATA, (LONG_PTR)this);
    measure_ = ui::createSurface(600, 400);
    return measure_ != nullptr;
}

std::wstring PetBubble::wrapText(const std::wstring& text, float maxWidth, float size, int maxLines) {
    if (!measure_) return text;
    ui::Canvas c(measure_->g, 1.0f);
    std::vector<std::wstring> lines;
    std::wstring cur;
    for (wchar_t ch : text) {
        if (ch == L'\n') {
            lines.push_back(cur);
            cur.clear();
            continue;
        }
        std::wstring next = cur + ch;
        if (c.textWidth(next, size) > maxWidth && !cur.empty()) {
            lines.push_back(cur);
            cur = std::wstring(1, ch);
        } else {
            cur = next;
        }
    }
    if (!cur.empty()) lines.push_back(cur);

    if ((int)lines.size() > maxLines) {
        lines.resize(maxLines);
    }
    std::wstring out;
    for (size_t i = 0; i < lines.size(); ++i) {
        if (i) out += L"\n";
        out += lines[i];
    }
    return out;
}

void PetBubble::show(const std::wstring& title, const std::wstring& message,
                     const std::wstring& hint, const RECT& anchor, unsigned int accentArgb,
                     bool lightTheme, std::function<void()> onClick) {
    title_ = title;
    hint_ = hint;
    message_ = wrapText(message, kWidth - kPad * 2, 12.5f, 3);
    accent_ = accentArgb;
    light_ = lightTheme;
    onClick_ = onClick;

    int lineCount = 1;
    for (wchar_t c : message_) if (c == L'\n') ++lineCount;

    h_ = (int)std::lround(kPad + kTitleH + 4 + lineCount * kLineH + 5 + kHintH + kPad + kTail);
    w_ = (int)kWidth;

    if (surface_ && (surface_->w != (int)std::lround(w_ * dpi_) ||
                     surface_->h != (int)std::lround(h_ * dpi_))) {
        ui::destroySurface(surface_);
    }
    if (!surface_) surface_ = ui::createSurface((int)std::lround(w_ * dpi_), (int)std::lround(h_ * dpi_));

    visible_ = true;
    anchor_ = anchor;
    positionNear(anchor);
    paint();
    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    hideAt_ = GetTickCount64() + kLifeMs;
}

void PetBubble::hide() {
    if (!visible_) return;
    visible_ = false;
    ShowWindow(hwnd_, SW_HIDE);
}

void PetBubble::tick() {
    if (!visible_) return;
    if (GetTickCount64() >= hideAt_) hide();
}

void PetBubble::positionNear(const RECT& anchor) {
    int bw = (int)std::lround(w_ * dpi_);
    int bh = (int)std::lround(h_ * dpi_);
    HMONITOR mon = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    GetMonitorInfoW(mon, &mi);

    int cx = (anchor.left + anchor.right) / 2;
    int x = cx - bw / 2;
    int y = anchor.top - bh - (int)std::lround(2 * dpi_);
    tailDown_ = true;
    if (y < mi.rcWork.top + 4) {
        y = anchor.bottom - (int)std::lround(30 * dpi_);
        tailDown_ = false;
    }
    if (x < mi.rcWork.left + 4) x = mi.rcWork.left + 4;
    if (x + bw > mi.rcWork.right - 4) x = mi.rcWork.right - 4 - bw;
    if (y + bh > mi.rcWork.bottom) y = mi.rcWork.bottom - bh;

    x_ = x;
    y_ = y;
    SetWindowPos(hwnd_, HWND_TOPMOST, x, y, bw, bh, SWP_NOACTIVATE);
}

void PetBubble::follow(const RECT& anchor) {
    if (!visible_) return;
    anchor_ = anchor;
    positionNear(anchor);
}

void PetBubble::paint() {
    if (!surface_) return;
    ui::clearSurface(surface_);
    ui::Canvas c(surface_->g, dpi_);
    ui::Theme th = ui::makeTheme(light_, accent_);

    float cardH = h_ - kTail;
    float cardY = tailDown_ ? 0.0f : kTail;
    Gdiplus::RectF card = c.R(0.5f, cardY + 0.5f, w_ - 1.0f, cardH - 1.0f);
    c.fillRound(card, 12.0f, th.card);
    c.strokeRound(card, 12.0f, th.stroke, 1.0f);

    // 尾巴
    float cx = w_ / 2.0f;
    {
        GraphicsPath path;
        if (tailDown_) {
            float base = cardY + cardH - 1.0f;
            PointF pts[3] = {PointF(c.s(cx - 7), c.s(base)), PointF(c.s(cx + 7), c.s(base)),
                            PointF(c.s(cx), c.s(base + kTail))};
            path.AddPolygon(pts, 3);
        } else {
            float base = cardY + 1.0f;
            PointF pts[3] = {PointF(c.s(cx - 7), c.s(base)), PointF(c.s(cx + 7), c.s(base)),
                            PointF(c.s(cx), c.s(base - kTail))};
            path.AddPolygon(pts, 3);
        }
        SolidBrush b(th.card);
        surface_->g->FillPath(&b, &path);
    }

    float y = cardY + kPad - 2;
    c.text(title_, c.R(kPad, y, kWidth - kPad * 2, kTitleH), th.accent, 10.5f, ui::Canvas::LEADING, true);
    y += kTitleH + 4;

    // 多行正文
    size_t start = 0;
    while (start <= message_.size()) {
        size_t nl = message_.find(L'\n', start);
        std::wstring line = message_.substr(start, nl == std::wstring::npos ? std::wstring::npos : nl - start);
        c.text(line, c.R(kPad, y, kWidth - kPad * 2, kLineH), th.text, 12.5f, ui::Canvas::LEADING);
        y += kLineH;
        if (nl == std::wstring::npos) break;
        start = nl + 1;
    }

    y += 5;
    c.text(hint_, c.R(kPad, y, kWidth - kPad * 2, kHintH), th.tertiary, 10.0f, ui::Canvas::LEADING,
           false, true);

    ui::presentLayered(hwnd_, surface_, x_, y_);
}

LRESULT CALLBACK PetBubble::wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    PetBubble* a = (PetBubble*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
        case WM_NCCREATE: {
            CREATESTRUCTW* cs = (CREATESTRUCTW*)lp;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
            return TRUE;
        }
        case WM_LBUTTONUP:
            if (a) {
                auto cb = a->onClick_;
                a->hide();
                if (cb) cb();
            }
            return 0;
        case WM_MOUSEACTIVATE:
            return MA_NOACTIVATE;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
