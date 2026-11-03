// 小工具面板：打卡日历 / 未来倒计时 / 提醒设置
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <functional>
#include <string>
#include <vector>

#include "store.h"
#include "ui.h"

struct FRect {
    float x = 0, y = 0, w = 0, h = 0;
    bool contains(float px, float py) const {
        return px >= x && px <= x + w && py >= y && py <= y + h;
    }
    float right() const { return x + w; }
    float bottom() const { return y + h; }
};

class ToolsPanel {
public:
    enum Tab { TAB_CHECKIN = 0, TAB_COUNTDOWN = 1, TAB_SETTINGS = 2 };
    static const int kWidth = 320;
    static const int kHeight = 448;
    static const int kTabCount = 3;

    bool create(HINSTANCE inst, HWND owner);
    HWND hwnd() const { return hwnd_; }

    void show(int tab, const RECT& anchor);   // anchor: 猫窗口在屏幕上的矩形
    void hide();
    bool visible() const { return visible_; }
    void toggle(const RECT& anchor);
    void setTab(int tab);
    int tab() const { return tab_; }

    void refresh();
    void refreshDay();
    void applyTheme();

    // 依赖
    CheckInStore* checkIn = nullptr;
    CountdownStore* countdown = nullptr;
    StudyStore* study = nullptr;
    ReminderSettings* settings = nullptr;
    unsigned int accentArgb = 0;
    bool lightTheme = false;
    float dpi = 1.0f;

    // 回调
    std::function<void()> onCheckIn;
    std::function<void()> onDuplicate;
    std::function<void()> onEventsChanged;
    std::function<void()> onSettingsChanged;

private:
    enum HitKind {
        HIT_NONE = 0,
        HIT_TAB,
        HIT_DAY_CELL,
        HIT_CHECKIN_BTN,
        HIT_PREV_MONTH,
        HIT_NEXT_MONTH,
        HIT_STUDY_TOGGLE,
        HIT_ADD_EVENT,
        HIT_ROW_EDIT,
        HIT_ROW_DELETE,
        HIT_SWITCH_CD,
        HIT_SWITCH_STUDY,
        HIT_CHIP_CD_LEAD,
        HIT_CHIP_CD_INTERVAL,
        HIT_CHIP_STUDY_INTERVAL,
    };
    struct Hit {
        HitKind kind = HIT_NONE;
        int index = 0;
        FRect rect;
    };

    static LRESULT CALLBACK wndProc(HWND, UINT, WPARAM, LPARAM);
    static ToolsPanel* self_;

    void layout();
    void paint();
    void paintCheckIn(ui::Canvas& c);
    void paintCountdown(ui::Canvas& c);
    void paintSettings(ui::Canvas& c);
    void activate(const Hit& hit);
    const Hit* hitAt(float x, float y) const;
    void positionNear(const RECT& anchor);
    void ensureSurface();
    void closeTabDialogs();

    // 对话框
    void presentEventForm(const CountdownEvent* editing);
    void presentDeleteConfirm(const CountdownEvent& e);
    void presentCustomStudyInterval();
    void presentCustomCountdownInterval();

    HWND hwnd_ = nullptr;
    HWND owner_ = nullptr;
    HINSTANCE inst_ = nullptr;
    ui::Surface* surface_ = nullptr;
    ui::Theme theme_;
    bool visible_ = false;
    bool suppressClose_ = false;
    unsigned long long lastClosedAt_ = 0;
    int tab_ = TAB_CHECKIN;

    float x_ = 0, y_ = 0, w_ = 0, h_ = 0;     // 面板在屏幕上的位置
    float mx_ = -1, my_ = -1;                 // 鼠标（逻辑坐标）

    // 打卡状态
    int year_ = 2026, month_ = 11;
    std::string selectedDay_;
    bool hoverCheckInBtn_ = false;

    // 倒计时滚动
    float scroll_ = 0;
    int hoverRow_ = -1;
    int hoverAction_ = -1;

    std::vector<Hit> hits_;

    // 布局缓存
    FRect tabRects_[kTabCount];
    FRect bandRect_;
    bool bandVisible_ = false;
    std::string bandText_;
    FRect monthPrev_, monthNext_;
    FRect cells_[42];
    std::string cellKeys_[42];
    FRect checkInBtn_;
    FRect studyBtn_;
    FRect addEventRect_;
    FRect listRect_;
    FRect cdSwitch_, studySwitch_;
    FRect leadChips_[4];
    FRect cdIntervalChips_[5];
    FRect studyChips_[5];
    float contentTop_ = 40.0f;
    int rowScrollMax_ = 0;
};
