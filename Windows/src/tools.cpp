#include "tools.h"

#include <commctrl.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <string>

using namespace Gdiplus;

namespace {

const wchar_t* kPaneClass = L"DesktopPetToolsPane";

std::wstring w(const std::string& s) { return ui::widen(s); }

std::wstring trimWs(const std::wstring& s) {
    size_t a = s.find_first_not_of(L" \t\r\n");
    if (a == std::wstring::npos) return L"";
    size_t b = s.find_last_not_of(L" \t\r\n");
    return s.substr(a, b - a + 1);
}

std::wstring windowText(HWND h) {
    int n = GetWindowTextLengthW(h);
    std::wstring out((size_t)n, L'\0');
    GetWindowTextW(h, &out[0], n + 1);
    return out;
}

void setDefaultFont(HWND h) {
    SendMessageW(h, WM_SETFONT, (WPARAM)GetStockObject(DEFAULT_GUI_FONT), TRUE);
}

// 极简模态循环：直到 ctx.done
template <typename Pred>
void runModalLoop(HWND hwnd, Pred done) {
    while (!done()) {
        DWORD r = MsgWaitForMultipleObjects(0, nullptr, FALSE, INFINITE, QS_ALLINPUT);
        if (r != WAIT_OBJECT_0) break;
        MSG msg;
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            if (msg.message == WM_QUIT) {
                PostQuitMessage((int)msg.wParam);
                return;
            }
            if (!IsDialogMessageW(hwnd, &msg)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
    }
}

void centerOver(HWND dlg, HWND owner) {
    RECT o, d;
    GetWindowRect(owner, &o);
    GetWindowRect(dlg, &d);
    int dw = d.right - d.left, dh = d.bottom - d.top;
    int x = o.left + ((o.right - o.left) - dw) / 2;
    int y = o.top + ((o.bottom - o.top) - dh) / 2;
    SetWindowPos(dlg, HWND_TOPMOST, x, y, 0, 0, SWP_NOSIZE | SWP_SHOWWINDOW);
}

// ---------------------------------------------------------------- 添加 / 编辑事件
struct EventDlgCtx {
    CountdownStore* store = nullptr;
    std::string editingId;
    HWND hwnd = nullptr, edit = nullptr, picker = nullptr, check = nullptr;
    bool done = false, ok = false;
};

LRESULT CALLBACK eventDlgProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    EventDlgCtx* ctx = (EventDlgCtx*)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (msg) {
        case WM_NCCREATE: {
            CREATESTRUCTW* cs = (CREATESTRUCTW*)lp;
            ctx = (EventDlgCtx*)cs->lpCreateParams;
            ctx->hwnd = h;
            SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)ctx);
            return TRUE;
        }
        case WM_CREATE: {
            ctx = (EventDlgCtx*)GetWindowLongPtrW(h, GWLP_USERDATA);
            if (!ctx) return 0;
            const wchar_t* editCls = ctx->editingId.empty() ? L"添加未来倒计时" : L"编辑未来倒计时";
            SetWindowTextW(h, editCls);

            CreateWindowW(L"STATIC", L"标题", WS_CHILD | WS_VISIBLE, 16, 14, 60, 18, h, nullptr,
                          nullptr, nullptr);
            ctx->edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                        WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_AUTOHSCROLL,
                                        16, 36, 268, 24, h, (HMENU)1001, nullptr, nullptr);
            SendMessageW(ctx->edit, EM_SETLIMITTEXT, 60, 0);

            CreateWindowW(L"STATIC", L"日期", WS_CHILD | WS_VISIBLE, 16, 70, 60, 18, h, nullptr,
                          nullptr, nullptr);
            ctx->picker = CreateWindowExW(0, DATETIMEPICK_CLASSW, L"",
                                          WS_CHILD | WS_VISIBLE | WS_TABSTOP | DTS_SHORTDATEFORMAT,
                                          16, 92, 180, 26, h, (HMENU)1002, nullptr, nullptr);
            DateTime_SetFormat(ctx->picker, L"yyyy-MM-dd");

            ctx->check = CreateWindowW(L"BUTTON", L"每年重复",
                                       WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_AUTOCHECKBOX,
                                       16, 128, 120, 22, h, (HMENU)1003, nullptr, nullptr);

            CreateWindowW(L"BUTTON", L"保存", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                          100, 162, 84, 26, h, (HMENU)IDOK, nullptr, nullptr);
            CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_TABSTOP,
                          200, 162, 84, 26, h, (HMENU)IDCANCEL, nullptr, nullptr);

            for (HWND child = GetWindow(h, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT))
                setDefaultFont(child);

            // 预填
            const CountdownEvent* e =
                ctx->editingId.empty() ? nullptr : ctx->store->find(ctx->editingId);
            SYSTEMTIME st = {};
            GetLocalTime(&st);
            if (e) {
                SetWindowTextW(ctx->edit, ui::widen(e->title).c_str());
                int y, m, d;
                if (daykey::parse(e->dateKey, y, m, d)) {
                    st.wYear = (WORD)y;
                    st.wMonth = (WORD)m;
                    st.wDay = (WORD)d;
                }
                SendMessageW(ctx->check, BM_SETCHECK, e->yearly ? BST_CHECKED : BST_UNCHECKED, 0);
            } else {
                // 新建：默认今天，且不允许选过去的日期
                SYSTEMTIME minSt = st;
                DateTime_SetRange(ctx->picker, GDTR_MIN, &minSt);
            }
            DateTime_SetSystemtime(ctx->picker, GDT_VALID, &st);
            SetFocus(ctx->edit);
            return 0;
        }
        case WM_COMMAND: {
            int id = LOWORD(wp);
            if (id == IDCANCEL) {
                ctx->done = true;
                DestroyWindow(h);
                return 0;
            }
            if (id == IDOK) {
                std::wstring title = trimWs(windowText(ctx->edit));
                if (title.empty()) {
                    MessageBoxW(h, L"标题不能为空。", L"未来倒计时", MB_ICONINFORMATION | MB_OK);
                    SetFocus(ctx->edit);
                    return 0;
                }
                if (title.size() > 30) {
                    MessageBoxW(h, L"标题最多 30 个字。", L"未来倒计时", MB_ICONINFORMATION | MB_OK);
                    SetFocus(ctx->edit);
                    return 0;
                }
                SYSTEMTIME st = {};
                if (DateTime_GetSystemtime(ctx->picker, &st) != GDT_VALID) {
                    MessageBoxW(h, L"请选择一个有效日期。", L"未来倒计时", MB_ICONINFORMATION | MB_OK);
                    return 0;
                }
                std::string key = daykey::make(st.wYear, st.wMonth, st.wDay);
                std::string utf8Title = ui::narrow(title);
                if (ctx->store->contains(utf8Title, key, ctx->editingId)) {
                    MessageBoxW(h, L"这个事件已经有了（同标题同日期）。", L"未来倒计时",
                                MB_ICONINFORMATION | MB_OK);
                    return 0;
                }
                bool yearly = SendMessageW(ctx->check, BM_GETCHECK, 0, 0) == BST_CHECKED;
                bool ok = ctx->editingId.empty()
                              ? ctx->store->add(utf8Title, key, yearly)
                              : ctx->store->update(ctx->editingId, utf8Title, key, yearly);
                if (!ok) {
                    MessageBoxW(h, L"保存失败（可能已达 20 个上限）。", L"未来倒计时",
                                MB_ICONWARNING | MB_OK);
                    return 0;
                }
                ctx->ok = true;
                ctx->done = true;
                DestroyWindow(h);
                return 0;
            }
            break;
        }
        case WM_CLOSE:
            ctx->done = true;
            DestroyWindow(h);
            return 0;
        case WM_DESTROY:
            if (ctx) ctx->done = true;
            return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

// ---------------------------------------------------------------- 自定义分钟数
struct NumberDlgCtx {
    HWND hwnd = nullptr, edit = nullptr;
    int min = 1, max = 240;
    bool done = false, ok = false;
    int value = 0;
    const wchar_t* note = L"";
};

LRESULT CALLBACK numberDlgProc(HWND h, UINT msg, WPARAM wp, LPARAM lp) {
    NumberDlgCtx* ctx = (NumberDlgCtx*)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (msg) {
        case WM_NCCREATE: {
            CREATESTRUCTW* cs = (CREATESTRUCTW*)lp;
            ctx = (NumberDlgCtx*)cs->lpCreateParams;
            ctx->hwnd = h;
            SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)ctx);
            return TRUE;
        }
        case WM_CREATE: {
            ctx = (NumberDlgCtx*)GetWindowLongPtrW(h, GWLP_USERDATA);
            CreateWindowW(L"STATIC", ctx->note, WS_CHILD | WS_VISIBLE, 16, 12, 268, 40, h,
                          nullptr, nullptr, nullptr);
            CreateWindowW(L"STATIC", L"每隔", WS_CHILD | WS_VISIBLE, 16, 62, 44, 20, h, nullptr,
                          nullptr, nullptr);
            ctx->edit = CreateWindowExW(WS_EX_CLIENTEDGE, L"EDIT", L"",
                                        WS_CHILD | WS_VISIBLE | WS_TABSTOP | ES_NUMBER | ES_RIGHT,
                                        64, 58, 80, 24, h, (HMENU)2001, nullptr, nullptr);
            SendMessageW(ctx->edit, EM_SETLIMITTEXT, 6, 0);
            CreateWindowW(L"STATIC", L"分钟", WS_CHILD | WS_VISIBLE, 150, 62, 44, 20, h, nullptr,
                          nullptr, nullptr);
            CreateWindowW(L"BUTTON", L"确定", WS_CHILD | WS_VISIBLE | WS_TABSTOP | BS_DEFPUSHBUTTON,
                          100, 96, 84, 26, h, (HMENU)IDOK, nullptr, nullptr);
            CreateWindowW(L"BUTTON", L"取消", WS_CHILD | WS_VISIBLE | WS_TABSTOP, 200, 96, 84, 26,
                          h, (HMENU)IDCANCEL, nullptr, nullptr);
            for (HWND child = GetWindow(h, GW_CHILD); child; child = GetWindow(child, GW_HWNDNEXT))
                setDefaultFont(child);
            SetFocus(ctx->edit);
            return 0;
        }
        case WM_COMMAND: {
            int id = LOWORD(wp);
            if (id == IDCANCEL) { ctx->done = true; DestroyWindow(h); return 0; }
            if (id == IDOK) {
                int v = _wtoi(windowText(ctx->edit).c_str());
                if (v < ctx->min || v > ctx->max) {
                    wchar_t buf[128];
                    swprintf(buf, 128, L"请填 %d–%d 之间的分钟数。", ctx->min, ctx->max);
                    MessageBoxW(h, buf, L"播报间隔", MB_ICONINFORMATION | MB_OK);
                    SetFocus(ctx->edit);
                    return 0;
                }
                ctx->value = v;
                ctx->ok = true;
                ctx->done = true;
                DestroyWindow(h);
                return 0;
            }
            break;
        }
        case WM_CLOSE:
            ctx->done = true;
            DestroyWindow(h);
            return 0;
        case WM_DESTROY:
            if (ctx) ctx->done = true;
            return 0;
    }
    return DefWindowProcW(h, msg, wp, lp);
}

void ensureDialogClasses() {
    static bool registered = false;
    if (registered) return;
    registered = true;
    WNDCLASSW wc = {};
    wc.lpfnWndProc = eventDlgProc;
    wc.hInstance = GetModuleHandleW(nullptr);
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.hbrBackground = (HBRUSH)(COLOR_WINDOW + 1);
    wc.lpszClassName = L"DesktopPetEventDlg";
    RegisterClassW(&wc);

    WNDCLASSW wc2 = wc;
    wc2.lpfnWndProc = numberDlgProc;
    wc2.lpszClassName = L"DesktopPetNumberDlg";
    RegisterClassW(&wc2);
}

}  // namespace

// ---------------------------------------------------------------- 面板
ToolsPanel* ToolsPanel::self_ = nullptr;

bool ToolsPanel::create(HINSTANCE inst, HWND owner) {
    inst_ = inst;
    owner_ = owner;
    self_ = this;
    ensureDialogClasses();

    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &ToolsPanel::wndProc;
    wc.hInstance = inst;
    wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
    wc.lpszClassName = kPaneClass;
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    // 分层窗口必须带 WS_EX_LAYERED，否则 UpdateLayeredWindow 会直接失败（面板全透明）
    hwnd_ = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST, kPaneClass, L"桌面宠物工具",
                            WS_POPUP, 0, 0, kWidth, kHeight, owner, nullptr, inst, this);
    if (!hwnd_) return false;
    ensureSurface();
    return true;
}

void ToolsPanel::ensureSurface() {
    int pw = ui::scaled(kWidth, dpi);
    int ph = ui::scaled(kHeight, dpi);
    if (surface_ && surface_->w == pw && surface_->h == ph) return;
    if (surface_) ui::destroySurface(surface_);
    surface_ = ui::createSurface(pw, ph);
}

void ToolsPanel::applyTheme() { layout(); }

void ToolsPanel::show(int tab, const RECT& anchor) {
    tab_ = (tab < 0 || tab >= kTabCount) ? TAB_CHECKIN : tab;
    SYSTEMTIME st;
    GetLocalTime(&st);
    if (!visible_) {          // 每次打开重置到当前月
        year_ = st.wYear;
        month_ = st.wMonth;
        selectedDay_.clear();
        scroll_ = 0;
    }
    ensureSurface();
    layout();
    positionNear(anchor);   // 先定位置，首帧才不会闪在 (0,0)
    visible_ = true;
    paint();
    ShowWindow(hwnd_, SW_SHOW);
    SetForegroundWindow(hwnd_);
    SetFocus(hwnd_);
    SetTimer(hwnd_, 1, 1000, nullptr);
}

void ToolsPanel::hide() {
    if (!visible_) return;
    visible_ = false;
    lastClosedAt_ = GetTickCount64();
    KillTimer(hwnd_, 1);
    ShowWindow(hwnd_, SW_HIDE);
}

void ToolsPanel::toggle(const RECT& anchor) {
    if (visible_) {
        hide();
        return;
    }
    // 刚因为失焦自动收起（点猫也会触发），这时候再来一次右键是「想关掉」而不是「想打开」
    if (GetTickCount64() - lastClosedAt_ < 400) return;
    show(tab_, anchor);
}

void ToolsPanel::setTab(int tab) {
    if (tab < 0 || tab >= kTabCount) return;
    tab_ = tab;
    scroll_ = 0;
    refresh();
}

void ToolsPanel::refresh() {
    if (!visible_) return;
    ensureSurface();
    layout();
    paint();
}

void ToolsPanel::refreshDay() { refresh(); }

void ToolsPanel::positionNear(const RECT& anchor) {
    int pw = ui::scaled(kWidth, dpi);
    int ph = ui::scaled(kHeight, dpi);
    HMONITOR mon = MonitorFromRect(&anchor, MONITOR_DEFAULTTONEAREST);
    MONITORINFO mi = {sizeof(mi)};
    GetMonitorInfoW(mon, &mi);

    int x = anchor.right + ui::scaled(12, dpi);
    if (x + pw > mi.rcWork.right) {
        x = anchor.left - ui::scaled(12, dpi) - pw;
        if (x < mi.rcWork.left) x = (anchor.left + anchor.right) / 2 - pw / 2;
    }
    if (x < mi.rcWork.left) x = mi.rcWork.left;
    if (x + pw > mi.rcWork.right) x = mi.rcWork.right - pw;

    int y = anchor.top;
    if (y + ph > mi.rcWork.bottom) y = mi.rcWork.bottom - ph;
    if (y < mi.rcWork.top) y = mi.rcWork.top;

    x_ = (float)x;
    y_ = (float)y;
    SetWindowPos(hwnd_, HWND_TOPMOST, x, y, pw, ph, SWP_NOACTIVATE);
}

// ---------------------------------------------------------------- 布局
void ToolsPanel::layout() {
    hits_.clear();
    const float W = kWidth;
    const float segW = 236, segH = 28;
    float segX = (W - segW) / 2, segY = 8;
    for (int i = 0; i < kTabCount; ++i) {
        tabRects_[i] = {segX + i * (segW / kTabCount), segY, segW / kTabCount, segH};
        Hit h;
        h.kind = HIT_TAB;
        h.index = i;
        h.rect = tabRects_[i];
        hits_.push_back(h);
    }

    auto todayEvents = countdown ? countdown->todayEvents() : std::vector<CountdownEvent>();
    bandVisible_ = !todayEvents.empty();
    if (bandVisible_) {
        if (todayEvents.size() > 2) {
            bandText_ = "今天：" + todayEvents[0].title + " 等 " +
                        std::to_string(todayEvents.size()) + " 个事件";
        } else {
            bandText_ = "今天：";
            for (size_t i = 0; i < todayEvents.size(); ++i) {
                if (i) bandText_ += "、";
                bandText_ += todayEvents[i].title;
            }
        }
        bandRect_ = {16, 40, W - 32, 24};
        contentTop_ = 68;
    } else {
        bandRect_ = {0, 0, 0, 0};
        contentTop_ = 40;
    }

    const float pad = 20;

    if (tab_ == TAB_CHECKIN) {
        float top = contentTop_ + 6;
        studyBtn_ = {W - pad - 4 - 72, top + 4, 72, 26};
        hits_.push_back({HIT_STUDY_TOGGLE, 0, studyBtn_});

        float y = top + 34 + 10;
        monthPrev_ = {pad - 4, y, 24, 20};
        monthNext_ = {W - pad - 20, y, 24, 20};
        hits_.push_back({HIT_PREV_MONTH, 0, monthPrev_});
        hits_.push_back({HIT_NEXT_MONTH, 0, monthNext_});

        float gridTop = y + 22 + 14;
        float cellW = 34, gapX = 7, gapY = 4;
        float startX = (W - (7 * cellW + 6 * gapX)) / 2;
        auto grid = checkIn->monthGrid(year_, month_);
        for (int i = 0; i < 42; ++i) {
            int row = i / 7, col = i % 7;
            cells_[i] = {startX + col * (cellW + gapX), gridTop + row * (cellW + gapY), cellW, cellW};
            cellKeys_[i] = grid[i];
            if (!grid[i].empty()) hits_.push_back({HIT_DAY_CELL, i, cells_[i]});
        }

        float statsTop = gridTop + 6 * (cellW + gapY) + 10;
        checkInBtn_ = {W - pad - 104, statsTop, 104, 32};
        hits_.push_back({HIT_CHECKIN_BTN, 0, checkInBtn_});
    } else if (tab_ == TAB_COUNTDOWN) {
        addEventRect_ = {pad, kHeight - 8 - 32, W - pad * 2, 32};
        hits_.push_back({HIT_ADD_EVENT, 0, addEventRect_});
        listRect_ = {0, contentTop_, W, addEventRect_.y - 6 - contentTop_};

        auto rows = countdown->upcoming();
        float totalH = (float)rows.size() * 53.0f;
        rowScrollMax_ = (int)std::max(0.0f, totalH - listRect_.h);
        if (scroll_ > rowScrollMax_) scroll_ = (float)rowScrollMax_;

        for (size_t i = 0; i < rows.size(); ++i) {
            float y = listRect_.y + (float)i * 53.0f - scroll_;
            if (y + 52 < listRect_.y || y > listRect_.bottom()) continue;
            FRect editR = {W - pad - 44, y + 18, 16, 16};
            FRect delR = {W - pad - 22, y + 18, 16, 16};
            hits_.push_back({HIT_ROW_EDIT, (int)i, editR});
            hits_.push_back({HIT_ROW_DELETE, (int)i, delR});
        }
    } else {
        float y = contentTop_ + 4;
        y += 20;                                   // 小节标题
        cdSwitch_ = {W - pad - 42, y, 42, 24};
        hits_.push_back({HIT_SWITCH_CD, 0, cdSwitch_});
        y += 30;
        y += 16;                                   // 「开始提醒」小标题
        float gap = 6;
        float cw = (W - pad * 2 - 3 * gap) / 4;
        for (int i = 0; i < 4; ++i) {
            leadChips_[i] = {pad + i * (cw + gap), y, cw, 26};
            if (settings->cdEnabled) hits_.push_back({HIT_CHIP_CD_LEAD, i, leadChips_[i]});
        }
        y += 26 + 14;
        y += 16;                                   // 「提醒间隔」小标题
        float gap2 = 5;
        float cw2 = (W - pad * 2 - 4 * gap2) / 5;
        for (int i = 0; i < 5; ++i) {
            cdIntervalChips_[i] = {pad + i * (cw2 + gap2), y, cw2, 26};
            if (settings->cdEnabled) hits_.push_back({HIT_CHIP_CD_INTERVAL, i, cdIntervalChips_[i]});
        }
        y += 26 + 8;
        y += 18 + 12;                              // 预览行
        y += 14;                                   // 分隔线
        y += 20;                                   // 第二区块标题
        studySwitch_ = {W - pad - 42, y, 42, 24};
        hits_.push_back({HIT_SWITCH_STUDY, 0, studySwitch_});
        y += 30;
        y += 16;                                   // 「播报间隔」小标题
        for (int i = 0; i < 5; ++i) {
            studyChips_[i] = {pad + i * (cw2 + gap2), y, cw2, 26};
            if (settings->studyEnabled) hits_.push_back({HIT_CHIP_STUDY_INTERVAL, i, studyChips_[i]});
        }
    }
}

// ---------------------------------------------------------------- 绘制
void ToolsPanel::paint() {
    if (!visible_ || !surface_) return;
    theme_ = ui::makeTheme(lightTheme, accentArgb);
    ui::clearSurface(surface_);
    ui::Canvas c(surface_->g, dpi);

    const float W = kWidth, H = kHeight;
    c.fillRound(c.R(0.5f, 0.5f, W - 1, H - 1), 20, theme_.card);
    c.strokeRound(c.R(0.5f, 0.5f, W - 1, H - 1), 20, theme_.stroke, 1.0f);

    static const wchar_t* tabNames[kTabCount] = {L"打卡", L"未来倒计时", L"提醒"};
    for (int i = 0; i < kTabCount; ++i) {
        bool sel = (i == tab_);
        if (sel) c.fillRound(c.R(tabRects_[i].x, tabRects_[i].y, tabRects_[i].w, tabRects_[i].h), 7,
                             theme_.accent);
        c.text(tabNames[i], c.R(tabRects_[i].x, tabRects_[i].y, tabRects_[i].w, tabRects_[i].h),
               sel ? theme_.onAccent : theme_.text, 12.0f, ui::Canvas::CENTER, sel);
    }

    if (bandVisible_) {
        c.fillRound(c.R(bandRect_.x, bandRect_.y, bandRect_.w, bandRect_.h), 6,
                    ui::withAlpha(theme_.accent, 26));
        c.text(w(bandText_), c.R(bandRect_.x + 8, bandRect_.y, bandRect_.w - 16, bandRect_.h),
               theme_.accent, 11.0f, ui::Canvas::LEADING, false, true);
    }

    switch (tab_) {
        case TAB_CHECKIN: paintCheckIn(c); break;
        case TAB_COUNTDOWN: paintCountdown(c); break;
        default: paintSettings(c); break;
    }

    ui::presentLayered(hwnd_, surface_, (int)x_, (int)y_);
}

void ToolsPanel::paintCheckIn(ui::Canvas& c) {
    const float W = kWidth;
    float top = contentTop_ + 6;

    // 今日打卡条
    c.fillRound(c.R(16, top, W - 32, 34), 8, theme_.chip);
    std::string label = "今日打卡 " + StudyStore::format(study->todaySeconds());
    c.text(w(label), c.R(24, top, 120, 34), theme_.text, 11.5f, ui::Canvas::LEADING, false, true);

    // 色阶图例
    float dotX = studyBtn_.x - 10 - (5 * 10 + 4 * 3);
    for (int i = 0; i < 5; ++i) {
        c.fillRound(c.R(dotX + i * 13, top + 12, 10, 10), 3, theme_.heat[i + 1]);
    }

    // 开始 / 暂停
    bool running = study->running();
    c.fillRound(c.R(studyBtn_.x, studyBtn_.y, studyBtn_.w, studyBtn_.h), 13, theme_.accent);
    c.text(running ? L"暂停" : L"开始",
           c.R(studyBtn_.x, studyBtn_.y, studyBtn_.w, studyBtn_.h), theme_.onAccent, 11.5f,
           ui::Canvas::CENTER, true);

    // 月份切换
    float headerY = monthPrev_.y;
    c.line(monthPrev_.x + 14, headerY + 6, monthPrev_.x + 6, headerY + 12, theme_.secondary, 1.6f);
    c.line(monthPrev_.x + 6, headerY + 12, monthPrev_.x + 14, headerY + 18, theme_.secondary, 1.6f);
    c.line(monthNext_.x + 6, headerY + 6, monthNext_.x + 14, headerY + 12, theme_.secondary, 1.6f);
    c.line(monthNext_.x + 14, headerY + 12, monthNext_.x + 6, headerY + 18, theme_.secondary, 1.6f);

    wchar_t monthBuf[32];
    swprintf(monthBuf, 32, L"%d 年 %d 月", year_, month_);
    c.text(monthBuf, c.R(60, headerY - 2, W - 120, 24), theme_.text, 13.0f, ui::Canvas::CENTER, true);

    // 星期（周一起始）
    static const wchar_t* week = L"一二三四五六日";
    float startX = cells_[0].x;
    float colW = cells_[0].w + 7;
    for (int i = 0; i < 7; ++i) {
        c.text(std::wstring(1, week[i]), c.R(startX + i * colW, cells_[0].y - 16, cells_[0].w, 14),
               theme_.tertiary, 10.0f, ui::Canvas::CENTER);
    }

    // 日期格
    const std::string today = daykey::today();
    for (int i = 0; i < 42; ++i) {
        const std::string& key = cellKeys_[i];
        if (key.empty()) continue;
        const FRect& r = cells_[i];
        bool checked = checkIn->isChecked(key);
        int minutes = study->secondsOf(key) / 60;
        int level = minutes <= 0 ? 0 : (minutes < 30 ? 1 : minutes < 60 ? 2 : minutes < 120 ? 3 : minutes < 240 ? 4 : 5);
        bool isToday = (key == today);
        bool isSelected = (key == selectedDay_);
        int dayNum = atoi(key.substr(8).c_str());

        Color fill = checked ? (level > 0 ? theme_.heat[level] : theme_.accent) : Color(0, 0, 0, 0);
        if (checked) c.fillRound(c.R(r.x, r.y, r.w, r.h), 8, fill);
        if (level > 0 && !checked) {
            // 有计时没打卡：淡色底
            c.fillRound(c.R(r.x, r.y, r.w, r.h), 8, ui::withAlpha(theme_.heat[level], 40));
        }
        if (isToday && !checked) {
            c.strokeRound(c.R(r.x + 0.5f, r.y + 0.5f, r.w - 1, r.h - 1), 8,
                          ui::withAlpha(theme_.accent, 200), 1.4f);
        }
        if (isSelected) {
            c.strokeRound(c.R(r.x + 0.5f, r.y + 0.5f, r.w - 1, r.h - 1), 8, theme_.text, 1.2f);
        }

        Color numColor = theme_.text;
        if (checked) numColor = (level >= 4) ? ui::rgba(252, 247, 240) : theme_.onAccent;
        else if (isToday) numColor = theme_.accent;
        bool hasStudy = minutes > 0;
        float numRectY = hasStudy ? r.y + 3 : r.y;
        float numRectH = hasStudy ? 20.0f : r.h;
        c.text(std::to_wstring(dayNum), c.R(r.x, numRectY, r.w, numRectH), numColor, 12.5f,
               ui::Canvas::CENTER, checked || isToday);

        if (hasStudy) {
            Color tagColor;
            if (checked) tagColor = (level >= 4) ? ui::rgba(252, 247, 240, 220) : ui::withAlpha(theme_.onAccent, 200);
            else tagColor = ui::mix(theme_.heat[level], theme_.text, 0.35);
            c.text(w(StudyStore::compact(minutes * 60)),
                   c.R(r.x, r.y + r.h - 14, r.w, 11), tagColor, 8.5f, ui::Canvas::CENTER);
        }
    }

    // 底部分隔 + 统计
    float sepY = cells_[41].bottom() + 8;
    c.fillRect(c.R(20, sepY, kWidth - 40, 1), theme_.separator);

    float statTop = sepY + 10;
    CheckInStats st = checkIn->stats();
    std::wstring big = std::to_wstring(st.current);
    c.textAt(big, 20, statTop, theme_.text, 26.0f, true);
    float numW = c.textWidth(big, 26.0f, true);
    c.textAt(L"天", 22 + numW, statTop + 12, theme_.secondary, 10.0f);

    // 打卡按钮
    bool checkedToday = checkIn->checkedToday();
    FRect btn = checkInBtn_;
    if (checkedToday) {
        c.fillRound(c.R(btn.x, btn.y, btn.w, btn.h), 16, ui::withAlpha(theme_.accent, 40));
        c.text(L"✓ 已打卡", c.R(btn.x, btn.y, btn.w, btn.h), theme_.accent, 12.0f,
               ui::Canvas::CENTER, true);
    } else {
        c.fillRound(c.R(btn.x, btn.y, btn.w, btn.h), 16, theme_.accent);
        c.text(L"今天打卡", c.R(btn.x, btn.y, btn.w, btn.h), theme_.onAccent, 12.0f,
               ui::Canvas::CENTER, true);
    }

    // 第二行
    std::string line2;
    if (!selectedDay_.empty()) {
        int y, m, d;
        daykey::parse(selectedDay_, y, m, d);
        std::string when = std::to_string(m) + " 月 " + std::to_string(d) + " 日";
        std::string state = checkIn->isChecked(selectedDay_) ? "已打卡" : "未打卡";
        int mins = study->secondsOf(selectedDay_) / 60;
        line2 = when + " · " + state;
        if (mins > 0) line2 += " · 打卡 " + StudyStore::format(mins * 60);
    } else {
        line2 = "最长 " + std::to_string(st.best) + " 天 · 累计 " + std::to_string(st.total) + " 天";
        int totalSec = study->totalSeconds();
        if (totalSec >= 60) line2 += " · 共打卡 " + StudyStore::format(totalSec);
    }
    c.text(w(line2), c.R(20, statTop + 40, kWidth - 40, 16), theme_.secondary, 10.5f,
           ui::Canvas::LEADING, false, true);
}

void ToolsPanel::paintCountdown(ui::Canvas& c) {
    const float W = kWidth;
    auto rows = countdown->upcoming();

    if (rows.empty()) {
        c.text(L"还没有未来倒计时", c.R(0, listRect_.y, W, listRect_.h), theme_.secondary, 13.0f,
               ui::Canvas::CENTER);
    }

    for (size_t i = 0; i < rows.size(); ++i) {
        float y = listRect_.y + (float)i * 53.0f - scroll_;
        if (y + 52 < listRect_.y || y > listRect_.bottom()) continue;
        const CountdownRow& row = rows[i];

        if (row.days == 0) {
            c.fillRound(c.R(14, y + 4, W - 28, 44), 8, ui::withAlpha(theme_.accent, 22));
        }

        Color titleColor = row.days == 0 ? theme_.accent : theme_.text;
        c.text(w(row.event.title), c.R(20, y + 7, W - 20 - 56 - 60, 18), titleColor, 13.0f,
               ui::Canvas::LEADING, true, true);

        std::string dateText = daykey::fullTitle(row.dateKey);
        if (row.event.yearly) dateText += " · 每年";
        c.text(w(dateText), c.R(20, y + 29, W - 20 - 56, 15), theme_.secondary, 11.0f,
               ui::Canvas::LEADING, false, true);

        std::wstring dayText;
        if (row.days == 0) dayText = L"今天";
        else if (row.days == 1) dayText = L"明天";
        else dayText = std::to_wstring(row.days);
        Color dayColor = row.days == 0 ? theme_.accent : theme_.text;
        float dayRight = W - 20 - 56;
        c.text(dayText, c.R(dayRight - 60, y + 12, 60, 24), dayColor, 19.0f, ui::Canvas::TRAILING,
               true);
        if (row.days >= 2) {
            float numW = c.textWidth(dayText, 19.0f, true);
            c.text(L"天", c.R(dayRight - numW + 2, y + 20, 20, 14), theme_.secondary, 10.0f);
        }

        bool hovered = (hoverRow_ == (int)i);
        if (hovered) {
            c.pencil(c.R(W - 20 - 44, y + 18, 16, 16),
                     hoverAction_ == 0 ? theme_.text : theme_.tertiary);
            c.cross(c.R(W - 20 - 22, y + 18, 16, 16),
                    hoverAction_ == 1 ? theme_.text : theme_.tertiary);
        }

        if (i + 1 < rows.size()) {
            c.fillRect(c.R(20, y + 52, W - 40, 1), theme_.separator);
        }
    }

    // 添加按钮
    bool full = countdown->isFull();
    c.fillRound(c.R(addEventRect_.x, addEventRect_.y, addEventRect_.w, addEventRect_.h), 16,
                full ? ui::withAlpha(theme_.chip, 120) : ui::withAlpha(theme_.accent, 30));
    c.text(full ? L"最多 20 个事件" : L"+ 添加事件",
           c.R(addEventRect_.x, addEventRect_.y, addEventRect_.w, addEventRect_.h),
           full ? theme_.tertiary : theme_.accent, 13.0f, ui::Canvas::CENTER, true);
}

void ToolsPanel::paintSettings(ui::Canvas& c) {
    const float W = kWidth;
    const float pad = 20;
    float y = contentTop_ + 4;

    auto sectionTitle = [&](const std::wstring& s, float atY) {
        c.fillRound(c.R(pad, atY + 5, 5, 5), 2.5f, theme_.accent);
        c.text(s, c.R(pad + 10, atY, 200, 16), theme_.accent, 11.0f, ui::Canvas::LEADING, true);
    };

    // ── 未来倒计时提醒
    sectionTitle(L"未来倒计时提醒", y);
    y += 20;
    c.text(L"开启提醒", c.R(pad, y, 160, 24), theme_.text, 13.0f, ui::Canvas::LEADING,
           settings->cdEnabled);
    c.toggle(c.R(cdSwitch_.x, cdSwitch_.y, cdSwitch_.w, cdSwitch_.h), settings->cdEnabled,
             true, theme_);
    y += 30;

    bool cdOn = settings->cdEnabled;
    c.text(L"开始提醒", c.R(pad, y, 120, 14), cdOn ? theme_.secondary : theme_.tertiary,
           11.0f);
    if (cdOn) {
        c.text(w(settings->rangeText()), c.R(W - pad - 120, y, 120, 14), theme_.accent, 10.5f,
               ui::Canvas::TRAILING);
    }
    y += 16;

    static const wchar_t* leadNames[4] = {L"不限制", L"提前 30 天", L"提前 7 天", L"仅当天"};
    for (int i = 0; i < 4; ++i) {
        c.chip(c.R(leadChips_[i].x, leadChips_[i].y, leadChips_[i].w, leadChips_[i].h), leadNames[i],
               settings->cdLead == i, cdOn, theme_);
    }
    y += 26 + 14;

    c.text(L"提醒间隔", c.R(pad, y, 140, 14), cdOn ? theme_.secondary : theme_.tertiary, 11.0f);
    if (cdOn) {
        c.text(w(settings->intervalText()), c.R(W - pad - 160, y, 160, 14), theme_.accent, 10.5f,
               ui::Canvas::TRAILING);
    }
    y += 16;

    struct Preset { int minutes; const wchar_t* name; };
    const Preset cdPresets[4] = {{30, L"30 分钟"}, {60, L"1 小时"}, {1440, L"每天"}, {4320, L"每 3 天"}};
    for (int i = 0; i < 5; ++i) {
        std::wstring label = (i < 4) ? cdPresets[i].name : L"自定义";
        bool sel = (i < 4) ? (!settings->isIntervalCustom() && settings->cdIntervalMinutes == cdPresets[i].minutes)
                           : settings->isIntervalCustom();
        c.chip(c.R(cdIntervalChips_[i].x, cdIntervalChips_[i].y, cdIntervalChips_[i].w,
                   cdIntervalChips_[i].h),
               label, sel, cdOn, theme_);
    }
    y += 26 + 8;

    // 预览
    auto rows = countdown->upcoming();
    std::wstring preview;
    Color previewColor = theme_.tertiary;
    if (rows.empty()) {
        preview = L"最近：还没有未来倒计时";
    } else {
        const CountdownRow& first = rows.front();
        preview = L"最近：" + ui::widen(first.event.title) + L" · " +
                  std::to_wstring(first.days) + L" 天后";
        if (!cdOn) {
            preview += L" · 已关闭播报";
        } else if (settings->inRange(first.days)) {
            preview += L" · 在提醒范围内";
            previewColor = theme_.accent;
        } else {
            preview += L" · 不在提醒范围内";
        }
    }
    c.text(preview, c.R(pad, y, W - pad * 2, 16), previewColor, 10.5f, ui::Canvas::LEADING, false, true);
    y += 18 + 12;

    c.fillRect(c.R(pad, y, W - pad * 2, 1), theme_.separator);
    y += 14;

    // ── 打卡时长提醒
    sectionTitle(L"打卡时长提醒", y);
    y += 20;
    c.text(L"打卡时播报", c.R(pad, y, 180, 24), theme_.text, 13.0f, ui::Canvas::LEADING,
           settings->studyEnabled);
    c.toggle(c.R(studySwitch_.x, studySwitch_.y, studySwitch_.w, studySwitch_.h),
             settings->studyEnabled, true, theme_);
    y += 30;

    bool stOn = settings->studyEnabled;
    c.text(L"播报间隔", c.R(pad, y, 140, 14), stOn ? theme_.secondary : theme_.tertiary, 11.0f);
    if (stOn) {
        c.text(w(settings->studyIntervalText()), c.R(W - pad - 160, y, 160, 14), theme_.accent,
               10.5f, ui::Canvas::TRAILING);
    }
    y += 16;

    const int studyPresets[4] = {5, 10, 15, 30};
    for (int i = 0; i < 5; ++i) {
        std::wstring label = (i < 4) ? ui::widen(ReminderSettings::studyLabel(studyPresets[i]))
                                     : L"自定义";
        bool sel = (i < 4)
                       ? (settings->studyIntervalMinutes == studyPresets[i])
                       : !(settings->studyIntervalMinutes == 5 || settings->studyIntervalMinutes == 10 ||
                           settings->studyIntervalMinutes == 15 || settings->studyIntervalMinutes == 30);
        c.chip(c.R(studyChips_[i].x, studyChips_[i].y, studyChips_[i].w, studyChips_[i].h), label,
               sel, stOn, theme_);
    }
    y += 26 + 10;

    c.text(L"关闭后猫不再主动说话；托盘图标里的", c.R(pad, y, W - pad * 2, 14), theme_.tertiary,
           9.5f);
    c.text(L"「提醒一下未来倒计时」仍可手动播报。", c.R(pad, y + 14, W - pad * 2, 14),
           theme_.tertiary, 9.5f);
}

// ---------------------------------------------------------------- 命中与交互
const ToolsPanel::Hit* ToolsPanel::hitAt(float x, float y) const {
    for (const auto& h : hits_) {
        if (h.rect.contains(x, y)) return &h;
    }
    return nullptr;
}

void ToolsPanel::closeTabDialogs() {
    suppressClose_ = false;
    SetActiveWindow(hwnd_);
    SetForegroundWindow(hwnd_);
}

void ToolsPanel::presentEventForm(const CountdownEvent* editing) {
    if (!editing && countdown->isFull()) return;
    suppressClose_ = true;
    EventDlgCtx ctx;
    ctx.store = countdown;
    ctx.editingId = editing ? editing->id : std::string();

    int dw = 300, dh = 210;
    HWND dlg = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_DLGMODALFRAME,
                               L"DesktopPetEventDlg", L"未来倒计时",
                               WS_POPUP | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, dw,
                               dh, hwnd_, nullptr, inst_, &ctx);
    if (!dlg) { suppressClose_ = false; return; }
    centerOver(dlg, hwnd_);
    EnableWindow(hwnd_, FALSE);
    runModalLoop(dlg, [&] { return ctx.done; });
    EnableWindow(hwnd_, TRUE);
    if (IsWindow(dlg)) DestroyWindow(dlg);

    closeTabDialogs();
    if (ctx.ok) {
        refresh();
        if (onEventsChanged) onEventsChanged();
    }
}

void ToolsPanel::presentDeleteConfirm(const CountdownEvent& e) {
    auto rows = countdown->upcoming();
    std::string when = daykey::fullTitle(e.dateKey);
    std::wstring msg = L"删除「" + ui::widen(e.title) + L"」？\n\n" + ui::widen(when);
    if (e.yearly) msg += L" · 每年重复";
    msg += L"\n删除后就不再提醒了。";

    suppressClose_ = true;
    int r = MessageBoxW(hwnd_, msg.c_str(), L"删除未来倒计时",
                        MB_YESNO | MB_ICONWARNING | MB_DEFBUTTON2);
    suppressClose_ = false;
    SetForegroundWindow(hwnd_);
    if (r != IDYES) return;

    countdown->remove(e.id);
    refresh();
    if (onEventsChanged) onEventsChanged();
}

void ToolsPanel::presentCustomStudyInterval() {
    suppressClose_ = true;
    NumberDlgCtx ctx;
    ctx.min = 1;
    ctx.max = 240;
    ctx.note = L"打卡计时中，每过这么久猫就报一次已打卡时长（1–240 分钟）。";

    HWND dlg = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_DLGMODALFRAME,
                               L"DesktopPetNumberDlg", L"自定义打卡播报间隔",
                               WS_POPUP | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, 300,
                               150, hwnd_, nullptr, inst_, &ctx);
    if (!dlg) { suppressClose_ = false; return; }
    SetWindowTextW(GetDlgItem(dlg, 2001), std::to_wstring(settings->studyIntervalMinutes).c_str());
    centerOver(dlg, hwnd_);
    EnableWindow(hwnd_, FALSE);
    runModalLoop(dlg, [&] { return ctx.done; });
    EnableWindow(hwnd_, TRUE);
    if (IsWindow(dlg)) DestroyWindow(dlg);
    closeTabDialogs();

    if (ctx.ok) {
        settings->studyIntervalMinutes = ReminderSettings::clampStudy(ctx.value);
        settings->save();
        refresh();
        if (onSettingsChanged) onSettingsChanged();
    }
}

void ToolsPanel::presentCustomCountdownInterval() {
    suppressClose_ = true;
    NumberDlgCtx ctx;
    ctx.min = 5;
    ctx.max = 43200;
    ctx.note = L"每隔这么久，猫就冒泡念一次最近的日子（5–43200 分钟，最长 30 天）。";

    HWND dlg = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_DLGMODALFRAME,
                               L"DesktopPetNumberDlg", L"自定义未来倒计时播报间隔",
                               WS_POPUP | WS_CAPTION | WS_SYSMENU, CW_USEDEFAULT, CW_USEDEFAULT, 300,
                               150, hwnd_, nullptr, inst_, &ctx);
    if (!dlg) { suppressClose_ = false; return; }
    SetWindowTextW(GetDlgItem(dlg, 2001), std::to_wstring(settings->cdIntervalMinutes).c_str());
    centerOver(dlg, hwnd_);
    EnableWindow(hwnd_, FALSE);
    runModalLoop(dlg, [&] { return ctx.done; });
    EnableWindow(hwnd_, TRUE);
    if (IsWindow(dlg)) DestroyWindow(dlg);
    closeTabDialogs();

    if (ctx.ok) {
        settings->cdIntervalMinutes = ReminderSettings::clampCountdown(ctx.value);
        settings->save();
        refresh();
        if (onSettingsChanged) onSettingsChanged();
    }
}

void ToolsPanel::activate(const Hit& hit) {
    switch (hit.kind) {
        case HIT_TAB:
            setTab(hit.index);
            return;
        case HIT_DAY_CELL: {
            const std::string& key = cellKeys_[hit.index];
            if (key.empty()) return;
            selectedDay_ = (selectedDay_ == key) ? std::string() : key;
            refresh();
            return;
        }
        case HIT_CHECKIN_BTN: {
            if (checkIn->checkInToday()) {
                if (onCheckIn) onCheckIn();
            } else if (onDuplicate) {
                onDuplicate();
            }
            refresh();
            return;
        }
        case HIT_STUDY_TOGGLE:
            if (study->running()) study->pause();
            else study->start();
            refresh();
            return;
        case HIT_PREV_MONTH:
            if (--month_ < 1) { month_ = 12; --year_; }
            refresh();
            return;
        case HIT_NEXT_MONTH:
            if (++month_ > 12) { month_ = 1; ++year_; }
            refresh();
            return;
        case HIT_ADD_EVENT:
            presentEventForm(nullptr);
            return;
        case HIT_ROW_EDIT: {
            auto rows = countdown->upcoming();
            if (hit.index >= 0 && hit.index < (int)rows.size()) presentEventForm(&rows[hit.index].event);
            return;
        }
        case HIT_ROW_DELETE: {
            auto rows = countdown->upcoming();
            if (hit.index >= 0 && hit.index < (int)rows.size())
                presentDeleteConfirm(rows[hit.index].event);
            return;
        }
        case HIT_SWITCH_CD:
            settings->cdEnabled = !settings->cdEnabled;
            settings->save();
            refresh();
            if (onSettingsChanged) onSettingsChanged();
            return;
        case HIT_SWITCH_STUDY:
            settings->studyEnabled = !settings->studyEnabled;
            settings->save();
            refresh();
            if (onSettingsChanged) onSettingsChanged();
            return;
        case HIT_CHIP_CD_LEAD:
            settings->cdLead = hit.index;
            settings->save();
            refresh();
            if (onSettingsChanged) onSettingsChanged();
            return;
        case HIT_CHIP_CD_INTERVAL: {
            static const int presets[4] = {30, 60, 1440, 4320};
            if (hit.index < 4) {
                settings->cdIntervalMinutes = presets[hit.index];
                settings->save();
                refresh();
                if (onSettingsChanged) onSettingsChanged();
            } else {
                presentCustomCountdownInterval();
            }
            return;
        }
        case HIT_CHIP_STUDY_INTERVAL: {
            static const int presets[4] = {5, 10, 15, 30};
            if (hit.index < 4) {
                settings->studyIntervalMinutes = presets[hit.index];
                settings->save();
                refresh();
                if (onSettingsChanged) onSettingsChanged();
            } else {
                presentCustomStudyInterval();
            }
            return;
        }
        default:
            return;
    }
}

// ---------------------------------------------------------------- 窗口过程
LRESULT CALLBACK ToolsPanel::wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    ToolsPanel* a = (ToolsPanel*)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    switch (msg) {
        case WM_NCCREATE: {
            CREATESTRUCTW* cs = (CREATESTRUCTW*)lp;
            ToolsPanel* self = (ToolsPanel*)cs->lpCreateParams;
            SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)self);
            return TRUE;
        }
        case WM_MOUSEMOVE: {
            if (!a) break;
            float mx = (float)GET_X_LPARAM(lp) / a->dpi;
            float my = (float)GET_Y_LPARAM(lp) / a->dpi;
            if (mx == a->mx_ && my == a->my_) return 0;
            a->mx_ = mx;
            a->my_ = my;
            int newRow = -1, newAction = -1;
            if (a->tab_ == TAB_COUNTDOWN) {
                auto rows = a->countdown->upcoming();
                for (size_t i = 0; i < rows.size(); ++i) {
                    float y = a->listRect_.y + (float)i * 53.0f - a->scroll_;
                    if (my >= y && my <= y + 52) { newRow = (int)i; break; }
                }
                if (newRow >= 0) {
                    float rowY = a->listRect_.y + (float)newRow * 53.0f - a->scroll_;
                    FRect editR = {kWidth - 20.0f - 44.0f, rowY + 18, 16, 16};
                    FRect delR = {kWidth - 20.0f - 22.0f, rowY + 18, 16, 16};
                    if (editR.contains(mx, my)) newAction = 0;
                    else if (delR.contains(mx, my)) newAction = 1;
                }
            }
            if (newRow != a->hoverRow_ || newAction != a->hoverAction_) {
                a->hoverRow_ = newRow;
                a->hoverAction_ = newAction;
                a->paint();
            }
            return 0;
        }
        case WM_LBUTTONUP: {
            if (!a) break;
            if (a->suppressClose_) return 0;
            float mx = (float)GET_X_LPARAM(lp) / a->dpi;
            float my = (float)GET_Y_LPARAM(lp) / a->dpi;
            if (const Hit* hit = a->hitAt(mx, my)) a->activate(*hit);
            return 0;
        }
        case WM_MOUSEWHEEL: {
            if (!a || a->tab_ != TAB_COUNTDOWN) break;
            int delta = GET_WHEEL_DELTA_WPARAM(wp);
            a->scroll_ -= (float)(delta / WHEEL_DELTA) * 40.0f;
            if (a->scroll_ < 0) a->scroll_ = 0;
            if (a->scroll_ > a->rowScrollMax_) a->scroll_ = (float)a->rowScrollMax_;
            a->layout();
            a->paint();
            return 0;
        }
        case WM_TIMER:
            if (a && wp == 1) {
                if (a->study && a->study->running()) a->paint();
                a->study->flushIfDue();
            }
            return 0;
        case WM_KEYDOWN:
            if (a && wp == VK_ESCAPE) { a->hide(); return 0; }
            break;
        case WM_ACTIVATE:
            if (a && LOWORD(wp) == WA_INACTIVE && !a->suppressClose_) a->hide();
            return 0;
        case WM_DPICHANGED: {
            if (!a) break;
            RECT* r = (RECT*)lp;
            a->dpi = HIWORD(wp) / 96.0f;
            a->x_ = (float)r->left;
            a->y_ = (float)r->top;
            a->ensureSurface();
            SetWindowPos(hwnd, HWND_TOPMOST, r->left, r->top, r->right - r->left,
                         r->bottom - r->top, SWP_NOACTIVATE);
            a->refresh();
            return 0;
        }
        default:
            break;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}
