// 猫头顶的对话气泡（未来倒计时 / 打卡时长共用）
#pragma once

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <functional>
#include <string>

#include "ui.h"

class PetBubble {
public:
    bool create(HINSTANCE inst);
    void show(const std::wstring& title, const std::wstring& message, const std::wstring& hint,
              const RECT& anchor, unsigned int accentArgb, bool lightTheme,
              std::function<void()> onClick);
    void hide();
    void tick();                      // 到点自动淡出
    void follow(const RECT& anchor);  // 跟着散步的猫走
    bool visible() const { return visible_; }
    void setDpi(float dpi) { dpi_ = dpi; }

private:
    static LRESULT CALLBACK wndProc(HWND, UINT, WPARAM, LPARAM);
    void paint();
    void positionNear(const RECT& anchor);
    std::wstring wrapText(const std::wstring& text, float maxWidth, float size, int maxLines);

    HWND hwnd_ = nullptr;
    ui::Surface* surface_ = nullptr;
    ui::Surface* measure_ = nullptr;
    bool visible_ = false;
    bool tailDown_ = true;            // 气泡在猫上方 → 尾巴朝下
    int w_ = 0, h_ = 0;
    int x_ = 0, y_ = 0;
    unsigned long long hideAt_ = 0;
    float dpi_ = 1.0f;

    std::wstring title_, message_, hint_;
    unsigned int accent_ = 0xFFFFB648;
    bool light_ = false;
    std::function<void()> onClick_;
    RECT anchor_ = {0, 0, 0, 0};
};
