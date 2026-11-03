// DesktopPet for Windows
// 原生 Win32 + 分层窗口（UpdateLayeredWindow）实现，无任何运行时依赖。
// 精灵帧由 macOS 版同一份绘制代码导出（assets/pet.dat），所以两边美术完全一致。
// 数据层在 store.cpp（纯 C++，可单测），UI 在 tools.cpp / bubble.cpp。

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <commctrl.h>
#include <shellapi.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <climits>
#include <ctime>
#include <map>
#include <random>
#include <string>
#include <vector>

#include "bubble.h"
#include "store.h"
#include "tools.h"
#include "ui.h"

#ifdef PET_EMBED
#include "pet_data.h"      // 数据直接编进 exe（无 windres 时的单文件方案）
#endif

// ---------------- 常量（与 macOS 版对齐） ----------------
static const int kGridW = 64;
static const int kGridH = 64;
static const int kPanelW = 344;      // 逻辑像素
static const int kPanelH = 412;
static const int kPetYFromBottom = 10;
static const double kSpeed = 50.0;   // 逻辑像素 / 秒
static const float kRise = 46.0f;
static const float kParticleLife = 1.4f;
static const int kIconRes = 102;

enum PetState { ST_WALKING, ST_IDLE, ST_SLEEPING, ST_STRETCHING, ST_TRANSITION };

// ---------------- 帧数据 ----------------
struct FrameData { std::vector<unsigned char> idx; };

static int g_alphaN = 0;
static std::string g_alphabet;
static std::vector<FrameData> g_frames;
static std::map<std::string, int> g_frameIndex;

struct Palette {
    std::wstring name;
    std::vector<unsigned int> argb;
};
static std::vector<Palette> g_pals;

static unsigned int g_pick32(const unsigned char* p) {
    return (unsigned int)p[0] | ((unsigned int)p[1] << 8) |
           ((unsigned int)p[2] << 16) | ((unsigned int)p[3] << 24);
}
static unsigned short g_pick16(const unsigned char* p) {
    return (unsigned short)(p[0] | (p[1] << 8));
}

static bool loadSpriteData(const unsigned char* d, size_t n) {
    size_t p = 0;
    if (n < 16 || memcmp(d, "PXP1", 4) != 0) return false;
    p = 4;
    int w = d[p++], h = d[p++];
    if (w != kGridW || h != kGridH) return false;
    g_alphaN = d[p++];
    g_alphabet.assign((const char*)d + p, g_alphaN);
    p += g_alphaN;

    int frameCount = g_pick16(d + p); p += 2;
    g_frames.resize(frameCount);
    for (int i = 0; i < frameCount; ++i) {
        int nameLen = d[p++];
        std::string name((const char*)d + p, nameLen);
        p += nameLen;
        g_frames[i].idx.assign(d + p, d + p + kGridW * kGridH);
        g_frames[i].idx.shrink_to_fit();
        p += kGridW * kGridH;
        g_frameIndex[name] = i;
    }

    int palCount = d[p++];
    g_pals.resize(palCount);
    for (int i = 0; i < palCount; ++i) {
        int nameLen = d[p++];
        std::string nm((const char*)d + p, nameLen);
        p += nameLen;
        int wn = MultiByteToWideChar(CP_UTF8, 0, nm.c_str(), (int)nm.size(), NULL, 0);
        g_pals[i].name.assign(wn, L'\0');
        MultiByteToWideChar(CP_UTF8, 0, nm.c_str(), (int)nm.size(), &g_pals[i].name[0], wn);
        g_pals[i].argb.resize(g_alphaN);
        for (int c = 0; c < g_alphaN; ++c) {
            unsigned int a = d[p + 3], r = d[p], g = d[p + 1], b = d[p + 2];
            g_pals[i].argb[c] = (a << 24) | (r << 16) | (g << 8) | b;
            p += 4;
        }
    }
    return !g_frames.empty() && !g_pals.empty();
}

static const FrameData* findFrame(const std::string& name) {
    auto it = g_frameIndex.find(name);
    if (it != g_frameIndex.end()) return &g_frames[it->second];
    size_t us = name.find('_');
    if (us != std::string::npos) {
        auto jt = g_frameIndex.find(name.substr(0, us));
        if (jt != g_frameIndex.end()) return &g_frames[jt->second];
    }
    auto st = g_frameIndex.find("sitA");
    return st != g_frameIndex.end() ? &g_frames[st->second] : nullptr;
}

// ---------------- 粒子 ----------------
struct Particle {
    float x, y;
    const char* mask;
    int mw, mh;
    unsigned int color;
    float age, life;
    int scale;
};

static const char kHeartMask[8][10] = {
    ".##...##.", "####.####", "#########", "#########",
    ".#######.", "..#####..", "...###...", "....#....",
};
static const char kZMask[6][6] = {
    "#####", "...#.", "..#..", ".#...", "#....", "#####",
};

// ---------------- 持久化：注册表 ----------------
static const wchar_t* kRegRoot = L"Software\\DesktopPet";

std::string kvGet(const std::string& name, const std::string& fallback) {
    std::wstring wname = ui::widen(name);
    DWORD type = 0, size = 0;
    if (RegGetValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str(), RRF_RT_REG_SZ, &type, nullptr, &size) !=
            ERROR_SUCCESS || size == 0) {
        return fallback;
    }
    std::vector<wchar_t> buf(size / sizeof(wchar_t) + 2, L'\0');
    if (RegGetValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str(), RRF_RT_REG_SZ, &type, buf.data(),
                     &size) != ERROR_SUCCESS) {
        return fallback;
    }
    std::wstring wv(buf.data());
    return ui::narrow(wv);
}

void kvSet(const std::string& name, const std::string& value) {
    std::wstring wname = ui::widen(name);
    std::wstring wvalue = ui::widen(value);
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str(), REG_SZ, wvalue.c_str(),
                    (DWORD)((wvalue.size() + 1) * sizeof(wchar_t)));
}

void kvErase(const std::string& name) {
    std::wstring wname = ui::widen(name);
    RegDeleteKeyValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str());
}

int kvGetInt(const std::string& name, int fallback) {
    std::wstring wname = ui::widen(name);
    DWORD value = 0, size = sizeof(value);
    if (RegGetValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str(), RRF_RT_REG_DWORD, nullptr, &value,
                     &size) != ERROR_SUCCESS) {
        return fallback;
    }
    return (int)value;
}

void kvSetInt(const std::string& name, int value) {
    std::wstring wname = ui::widen(name);
    DWORD v = (DWORD)value;
    RegSetKeyValueW(HKEY_CURRENT_USER, kRegRoot, wname.c_str(), REG_DWORD, &v, sizeof(v));
}

void platformLocalDate(int& y, int& m, int& d) {
    SYSTEMTIME st;
    GetLocalTime(&st);
    y = st.wYear;
    m = st.wMonth;
    d = st.wDay;
}

// ---------------- 菜单命令 ----------------
enum {
    ID_TRAY_SHOW = 2001,
    ID_TRAY_RESET_POS,
    ID_TRAY_CHECKIN,
    ID_TRAY_COUNTDOWN,
    ID_TRAY_SETTINGS,
    ID_TRAY_BUBBLE_NOW,
    ID_TRAY_SLEEP,
    ID_TRAY_PIN,
    ID_TRAY_LICK,
    ID_TRAY_AUTOSTART,
    ID_TRAY_ABOUT,
    ID_TRAY_EXIT,
    ID_PALETTE_BASE = 2100,   // + 索引
    ID_SIZE_BASE = 2200,
    ID_TEMPO_BASE = 2300,
};

// ---------------- 应用 ----------------
class PetApp {
public:
    bool init(HINSTANCE hInst);
    void tick();

private:
    enum { WM_APP_TICK = WM_APP + 1, WM_APP_TRAY = WM_APP + 2 };

    HINSTANCE hInst_ = nullptr;
    HWND hwnd_ = nullptr;
    HDC memDC_ = nullptr;
    HBITMAP dib_ = nullptr;
    void* bits_ = nullptr;
    int dibW_ = 0, dibH_ = 0;

    double dpiScale_ = 1.0;
    int pixel_ = 5;
    int petSize_ = 320;
    int petX_ = 12, petY_ = 82;
    int winX_ = 0, winY_ = 0;

    PetState state_ = ST_IDLE;
    int facing_ = 1;
    int ticksLeft_ = 120;
    long tickCount_ = 0;
    int paletteIndex_ = 0;
    int sizeIndex_ = 2;
    bool pinned_ = false;
    bool lickEnabled_ = true;
    int tempoIndex_ = 1;
    int loveTicks_ = 0;
    int happyTicks_ = 0;
    PetState stretchNext_ = ST_WALKING;
    bool hidden_ = false;
    int pendingBubbleTimer_ = 0;

    struct SeqStep { std::string pose; int ticks; };
    std::vector<SeqStep> seq_;
    int seqIdx_ = 0, seqLeft_ = 0;
    PetState nextAfterSeq_ = ST_IDLE;

    const double tempoScales_[3] = {1.35, 1.0, 0.75};

    std::vector<Particle> particles_;
    std::string currentPose_ = "sitA";

    bool dragging_ = false;
    bool dragMoved_ = false;
    POINT dragStart_ = {0, 0};
    int dragWinX_ = 0, dragWinY_ = 0;

    std::mt19937 rng_{std::random_device{}()};
    ULONGLONG lastTick_ = 0;
    ULONGLONG lastSecondAt_ = 0;

    // 小工具
    CheckInStore checkIn_;
    CountdownStore countdown_;
    StudyStore study_;
    ReminderSettings settings_;
    ToolsPanel tools_;
    PetBubble bubble_;
    bool trayAdded_ = false;
    NOTIFYICONDATAW nid_ = {};
    unsigned int accentArgb_ = 0xFFB648;
    bool lightTheme_ = false;

    std::string cachedDay_;
    std::string lastBubbleDay_;
    unsigned long long lastBubbleAt_ = 0;
    int studyAnnounceBase_ = 0;

    // 初始化
    bool createWindow();
    bool createSurface(int w, int h);
    void layoutPet();
    void positionAtBottomRight();
    void clampToScreen();
    void restorePosition();
    void savePosition();
    void addTrayIcon();
    void removeTrayIcon();
    void refreshAccent();

    // 状态机
    void nextState();
    void enter(PetState s, int ticks);
    void play(const std::vector<SeqStep>& seq, PetState target);
    void advanceTransition();
    void endTransition();
    std::vector<SeqStep> sitDownSeq();
    std::vector<SeqStep> standUpSeq();
    void moveStep();
    void updatePose();
    void pat();
    void spawnHearts();
    void spawnZ();
    void updateParticles(float dt);

    // 渲染
    void render();
    void blendPixel(int x, int y, unsigned int rgb, int alpha);

    // 交互
    HMENU buildTrayMenu();
    void handleCommand(int id);
    void showTrayMenu();
    void toggleSleep();
    void togglePin();
    void toggleTools(int tab);
    void showAbout();
    bool autostartEnabled() const;
    void setAutostart(bool on);

    // 播报
    void oncePerSecond();
    void maybeShowCountdownBubble(bool force);
    void maybeShowStudyBubble();
    void presentBubble(const std::wstring& title, const std::wstring& message,
                       const std::wstring& hint, int tab);
    RECT catRect() const;
    bool catHidden() const { return hidden_; }

    static LRESULT CALLBACK wndProc(HWND, UINT, WPARAM, LPARAM);
    static PetApp* self_;

    int rnd(int a, int b) {
        std::uniform_int_distribution<int> d(a, b);
        return d(rng_);
    }
};

PetApp* PetApp::self_ = nullptr;

// ---------------- 窗口与表面 ----------------
bool PetApp::createWindow() {
    WNDCLASSEXW wc = {};
    wc.cbSize = sizeof(wc);
    wc.lpfnWndProc = &PetApp::wndProc;
    wc.hInstance = hInst_;
    wc.hCursor = LoadCursor(NULL, IDC_ARROW);
    wc.lpszClassName = L"DesktopPetWnd";
    if (!RegisterClassExW(&wc) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) return false;

    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"DesktopPetWnd", L"DesktopPet", WS_POPUP,
        0, 0, 100, 100, NULL, NULL, hInst_, NULL);
    if (!hwnd_) return false;

    layoutPet();
    restorePosition();
    if (!createSurface(dibW_, dibH_)) return false;

    ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
    SetTimer(hwnd_, 1, 33, NULL);
    return true;
}

bool PetApp::createSurface(int w, int h) {
    if (memDC_) { DeleteDC(memDC_); memDC_ = nullptr; }
    if (dib_) { DeleteObject(dib_); dib_ = nullptr; bits_ = nullptr; }
    dibW_ = w; dibH_ = h;

    HDC screen = GetDC(NULL);
    memDC_ = CreateCompatibleDC(screen);
    ReleaseDC(NULL, screen);

    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    dib_ = CreateDIBSection(memDC_, &bi, DIB_RGB_COLORS, &bits_, NULL, 0);
    if (!dib_) return false;
    SelectObject(memDC_, dib_);
    SetWindowPos(hwnd_, NULL, winX_, winY_, w, h, SWP_NOZORDER | SWP_NOACTIVATE);
    return true;
}

void PetApp::layoutPet() {
    pixel_ = (int)lround(5.0 * (sizeIndex_ == 0 ? 0.6 : sizeIndex_ == 1 ? 0.8 : 1.0) * dpiScale_);
    if (pixel_ < 1) pixel_ = 1;
    petSize_ = kGridW * pixel_;

    int w = (int)lround(kPanelW * dpiScale_);
    int h = (int)lround(kPanelH * dpiScale_);
    petX_ = (w - petSize_) / 2;
    petY_ = h - (int)lround(kPetYFromBottom * dpiScale_) - petSize_;
    dibW_ = w;
    dibH_ = h;
}

void PetApp::positionAtBottomRight() {
    int w = (int)lround(kPanelW * dpiScale_);
    int h = (int)lround(kPanelH * dpiScale_);
    MONITORINFO mi = {sizeof(mi)};
    HWND probe = hwnd_ ? hwnd_ : GetDesktopWindow();
    HMONITOR mon = MonitorFromWindow(probe, MONITOR_DEFAULTTOPRIMARY);
    GetMonitorInfoW(mon, &mi);
    winX_ = mi.rcWork.right - w - (int)lround(60 * dpiScale_);
    winY_ = mi.rcWork.bottom - h - (int)lround(8 * dpiScale_);
    if (hwnd_) SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, w, h, SWP_NOACTIVATE);
}

void PetApp::clampToScreen() {
    MONITORINFO mi = {sizeof(mi)};
    HMONITOR mon = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(mon, &mi);
    int w = (int)lround(kPanelW * dpiScale_);
    int h = (int)lround(kPanelH * dpiScale_);
    if (winX_ < mi.rcWork.left) winX_ = mi.rcWork.left;
    if (winX_ + w > mi.rcWork.right) winX_ = mi.rcWork.right - w;
    if (winY_ < mi.rcWork.top) winY_ = mi.rcWork.top;
    if (winY_ + h > mi.rcWork.bottom) winY_ = mi.rcWork.bottom - h;
    SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
}

void PetApp::restorePosition() {
    int x = kvGetInt("winX", INT_MIN), y = kvGetInt("winY", INT_MIN);
    if (x == INT_MIN || y == INT_MIN) {
        positionAtBottomRight();
        return;
    }
    winX_ = x;
    winY_ = y;
    // 位置可能来自旧显示器：越界就回右下角
    POINT pt = {x + (int)lround(kPanelW * dpiScale_) / 2, y + (int)lround(kPanelH * dpiScale_) / 2};
    HMONITOR mon = MonitorFromPoint(pt, MONITOR_DEFAULTTONULL);
    if (!mon) {
        positionAtBottomRight();
        return;
    }
    clampToScreen();
}

void PetApp::savePosition() {
    kvSetInt("winX", winX_);
    kvSetInt("winY", winY_);
}

// ---------------- 状态机 ----------------
std::vector<PetApp::SeqStep> PetApp::sitDownSeq() {
    std::vector<SeqStep> s;
    s.push_back({"walk1", 5});
    s.push_back({"quarterStand", 12});
    s.push_back({"quarterRise", 9});
    s.push_back({"quarterCrouch", 11});
    if (lickEnabled_) {
        int rounds = rnd(2, 3);
        for (int r = 0; r < rounds; ++r) {
            s.push_back({"lickA", 7});
            s.push_back({"lickB", 6});
            s.push_back({"lickC", 7});
            s.push_back({"lickD", 6});
            if (r < rounds - 1) s.push_back({"lickC", 5});
        }
    }
    s.push_back({"quarterLow", 9});
    s.push_back({"quarterSweepA_closed", 8});
    s.push_back({"quarterSweepB_closed", 10});
    return s;
}

std::vector<PetApp::SeqStep> PetApp::standUpSeq() {
    return {
        {"quarterLow", 10}, {"quarterCrouch", 11}, {"quarterRise", 10},
        {"quarterStand", 12}, {"lookL", 13}, {"lookR", 13}, {"walk1", 8},
    };
}

void PetApp::play(const std::vector<SeqStep>& seq, PetState target) {
    double k = tempoScales_[tempoIndex_];
    seq_.clear();
    int total = 0;
    for (const auto& s : seq) {
        int t = (int)lround(s.ticks * k);
        if (t < 2) t = 2;
        seq_.push_back({s.pose, t});
        total += t;
    }
    seqIdx_ = 0;
    seqLeft_ = seq_.empty() ? 1 : seq_[0].ticks;
    nextAfterSeq_ = target;
    state_ = ST_TRANSITION;
    ticksLeft_ = total;
}

void PetApp::advanceTransition() {
    if (seq_.empty()) { endTransition(); return; }
    --seqLeft_;
    if (seqLeft_ > 0) return;
    ++seqIdx_;
    if (seqIdx_ >= (int)seq_.size()) endTransition();
    else seqLeft_ = seq_[seqIdx_].ticks;
}

void PetApp::endTransition() {
    PetState target = nextAfterSeq_;
    seq_.clear();
    seqIdx_ = 0;
    if (target == ST_WALKING) enter(ST_WALKING, rnd(120, 300));
    else if (target == ST_SLEEPING) enter(ST_SLEEPING, rnd(300, 700));
    else enter(ST_IDLE, rnd(90, 260));
}

void PetApp::nextState() {
    switch (state_) {
        case ST_WALKING: play(sitDownSeq(), ST_IDLE); break;
        case ST_IDLE:
            if (rnd(0, 99) < 30) enter(ST_SLEEPING, rnd(300, 700));
            else play(standUpSeq(), ST_WALKING);
            break;
        case ST_SLEEPING:
            stretchNext_ = ST_WALKING;
            enter(ST_STRETCHING, 44);
            break;
        case ST_STRETCHING:
            if (stretchNext_ == ST_IDLE) enter(ST_IDLE, rnd(90, 180));
            else play(standUpSeq(), ST_WALKING);
            break;
        case ST_TRANSITION: endTransition(); break;
    }
}

void PetApp::enter(PetState s, int ticks) {
    state_ = s;
    ticksLeft_ = ticks;
    if (s == ST_WALKING) facing_ = rnd(0, 1) ? 1 : -1;
    if (s == ST_IDLE && rnd(0, 99) < 40) happyTicks_ = ticks;
}

void PetApp::moveStep() {
    double step = kSpeed * dpiScale_ / 30.0;
    winX_ += (int)lround(facing_ * step);
    MONITORINFO mi = {sizeof(mi)};
    HMONITOR mon = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(mon, &mi);
    int w = (int)lround(kPanelW * dpiScale_);
    if (winX_ <= mi.rcWork.left) { winX_ = mi.rcWork.left; facing_ = 1; }
    if (winX_ + w >= mi.rcWork.right) { winX_ = mi.rcWork.right - w; facing_ = -1; }
    SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, 0, 0, SWP_NOSIZE | SWP_NOACTIVATE);
}

void PetApp::updatePose() {
    char buf[64];
    const char* wag = (tickCount_ / 10) % 2 == 0 ? "A" : "B";
    switch (state_) {
        case ST_WALKING:
            snprintf(buf, sizeof(buf), "walk%d%s", (int)((tickCount_ / 7) % 4),
                     (tickCount_ % 137 < 3) ? "_closed" : "");
            currentPose_ = buf;
            break;
        case ST_IDLE:
            if (loveTicks_ > 0) currentPose_ = std::string("love") + wag;
            else if (happyTicks_ > 0) currentPose_ = std::string("happy") + wag;
            else if (tickCount_ % 96 < 4) currentPose_ = std::string("sleep") + wag;
            else currentPose_ = std::string("sit") + wag;
            break;
        case ST_SLEEPING:
            currentPose_ = (tickCount_ / 20) % 2 == 0 ? "sleepA" : "sleepB";
            break;
        case ST_STRETCHING:
            currentPose_ = (tickCount_ / 11) % 2 == 0 ? "stretchA" : "stretchB";
            break;
        case ST_TRANSITION:
            currentPose_ = seq_.empty() ? "sitA" : seq_[std::min(seqIdx_, (int)seq_.size() - 1)].pose;
            break;
    }
}

void PetApp::pat() {
    spawnHearts();
    loveTicks_ = 100;
    switch (state_) {
        case ST_WALKING: play(sitDownSeq(), ST_IDLE); break;
        case ST_SLEEPING:
            stretchNext_ = ST_IDLE;
            enter(ST_STRETCHING, 36);
            break;
        default: break;
    }
}

void PetApp::spawnHearts() {
    int count = rnd(1, 3);
    for (int i = 0; i < count; ++i) {
        Particle p = {};
        p.x = (float)(petX_ + petSize_ * (0.25 + (rnd(0, 100) / 100.0) * 0.5));
        p.y = (float)petY_ - 6.0f * (float)dpiScale_ - i * 12.0f * (float)dpiScale_;
        p.mask = (const char*)kHeartMask;
        p.mw = 9;
        p.mh = 8;
        p.color = (i % 2 == 0) ? 0xFF5C7A : 0xFF86A0;
        p.age = -0.12f * i;
        p.life = kParticleLife;
        p.scale = (int)lround((2 + (i % 2)) * dpiScale_);
        particles_.push_back(p);
    }
}

void PetApp::spawnZ() {
    Particle p = {};
    float side = facing_ < 0 ? 0.15f : 0.85f;
    p.x = (float)(petX_ + petSize_ * side);
    p.y = (float)petY_ - 4.0f * (float)dpiScale_;
    p.mask = (const char*)kZMask;
    p.mw = 5;
    p.mh = 6;
    p.color = 0xE6F0FF;
    p.age = 0;
    p.life = kParticleLife;
    p.scale = (int)lround((2 + (rnd(0, 1))) * dpiScale_);
    particles_.push_back(p);
}

void PetApp::updateParticles(float dt) {
    for (size_t i = 0; i < particles_.size();) {
        particles_[i].age += dt;
        if (particles_[i].age >= particles_[i].life) particles_.erase(particles_.begin() + i);
        else ++i;
    }
}

// ---------------- 渲染 ----------------
void PetApp::blendPixel(int x, int y, unsigned int rgb, int alpha) {
    if (x < 0 || y < 0 || x >= dibW_ || y >= dibH_) return;
    unsigned char* q = (unsigned char*)bits_ + ((size_t)y * dibW_ + x) * 4;
    if (alpha >= 255) {
        q[0] = rgb & 0xFF;
        q[1] = (rgb >> 8) & 0xFF;
        q[2] = (rgb >> 16) & 0xFF;
        q[3] = 255;
        return;
    }
    int sr = ((rgb >> 16) & 0xFF) * alpha / 255;
    int sg = ((rgb >> 8) & 0xFF) * alpha / 255;
    int sb = (rgb & 0xFF) * alpha / 255;
    int da = q[3];
    int n = 255 - alpha;
    q[0] = (unsigned char)(sb + q[0] * n / 255);
    q[1] = (unsigned char)(sg + q[1] * n / 255);
    q[2] = (unsigned char)(sr + q[2] * n / 255);
    q[3] = (unsigned char)(alpha + da * n / 255);
}

void PetApp::render() {
    if (!bits_) return;
    memset(bits_, 0, (size_t)dibW_ * dibH_ * 4);

    const FrameData* f = findFrame(currentPose_);
    if (f && !g_pals.empty()) {
        const Palette& pal =
            g_pals[std::max(0, std::min(paletteIndex_, (int)g_pals.size() - 1))];
        const int px = pixel_;
        for (int ay = 0; ay < kGridH; ++ay) {
            int py0 = petY_ + ay * px;
            for (int ax = 0; ax < kGridW; ++ax) {
                int sx = facing_ < 0 ? (kGridW - 1 - ax) : ax;
                unsigned char ci = f->idx[ay * kGridW + sx];
                if (ci == 0) continue;
                unsigned int c = pal.argb[ci];
                if ((c >> 24) == 0) continue;
                int px0 = petX_ + ax * px;
                for (int y = 0; y < px; ++y) {
                    unsigned char* row = (unsigned char*)bits_ + ((size_t)(py0 + y) * dibW_ + px0) * 4;
                    for (int x = 0; x < px; ++x) {
                        row[x * 4 + 0] = c & 0xFF;
                        row[x * 4 + 1] = (c >> 8) & 0xFF;
                        row[x * 4 + 2] = (c >> 16) & 0xFF;
                        row[x * 4 + 3] = 255;
                    }
                }
            }
        }
    }

    for (const auto& p : particles_) {
        if (p.age < 0) continue;
        float t = p.age / p.life;
        if (t > 1) t = 1;
        int alpha = (int)((1.0f - t) * 255.0f);
        if (alpha <= 0) continue;
        float eased = 1.0f - (1.0f - t) * (1.0f - t);
        int baseY = (int)lround(p.y - kRise * dpiScale_ * eased);
        int baseX = (int)lround(p.x);
        for (int my = 0; my < p.mh; ++my) {
            const char* rowStr = p.mask + my * p.mw;
            for (int mx = 0; mx < p.mw; ++mx) {
                if (rowStr[mx] != '#') continue;
                for (int sy = 0; sy < p.scale; ++sy)
                    for (int sx = 0; sx < p.scale; ++sx)
                        blendPixel(baseX + mx * p.scale + sx, baseY + my * p.scale + sy, p.color,
                                   alpha);
            }
        }
    }

    POINT src = {0, 0};
    SIZE size = {dibW_, dibH_};
    POINT dst = {winX_, winY_};
    BLENDFUNCTION bf = {AC_SRC_OVER, 0, 255, AC_SRC_ALPHA};
    UpdateLayeredWindow(hwnd_, NULL, &dst, &size, memDC_, &src, 0, &bf, ULW_ALPHA);
}

// ---------------- tick ----------------
void PetApp::tick() {
    ULONGLONG now = GetTickCount64();
    float dt = 0.033f;
    if (lastTick_) {
        dt = (float)(now - lastTick_) / 1000.0f;
        if (dt > 0.2f) dt = 0.2f;
        if (dt < 0.005f) dt = 0.005f;
    }
    lastTick_ = now;

    ++tickCount_;
    --ticksLeft_;
    if (loveTicks_ > 0) --loveTicks_;
    if (happyTicks_ > 0) --happyTicks_;

    if (!hidden_) {
        if (state_ == ST_WALKING) moveStep();
        if (state_ == ST_SLEEPING && tickCount_ % 110 == 0) spawnZ();
        if (state_ == ST_TRANSITION) advanceTransition();
        else if (ticksLeft_ <= 0) nextState();
        updateParticles(dt);
        updatePose();
        render();
    }

    // 打卡计时
    study_.tick(dt);
    study_.flushIfDue();

    if (now - lastSecondAt_ >= 1000) {
        lastSecondAt_ = now;
        oncePerSecond();
    }

    bubble_.tick();
    if (bubble_.visible()) bubble_.follow(catRect());
}

// ---------------- 托盘 ----------------
void PetApp::addTrayIcon() {
    if (trayAdded_) return;
    nid_ = {};
    nid_.cbSize = sizeof(nid_);
    nid_.hWnd = hwnd_;
    nid_.uID = 1;
    nid_.uFlags = NIF_ICON | NIF_MESSAGE | NIF_TIP;
    nid_.uCallbackMessage = WM_APP_TRAY;
    nid_.hIcon = (HICON)LoadImageW(hInst_, MAKEINTRESOURCEW(kIconRes), IMAGE_ICON, 0, 0,
                                   LR_DEFAULTSIZE);
    if (!nid_.hIcon) nid_.hIcon = LoadIconW(nullptr, IDI_APPLICATION);
    lstrcpynW(nid_.szTip, L"桌面宠物", 128);
    trayAdded_ = Shell_NotifyIconW(NIM_ADD, &nid_) != FALSE;
}

void PetApp::removeTrayIcon() {
    if (!trayAdded_) return;
    Shell_NotifyIconW(NIM_DELETE, &nid_);
    trayAdded_ = false;
}

HMENU PetApp::buildTrayMenu() {
    HMENU m = CreatePopupMenu();
    AppendMenuW(m, MF_STRING, ID_TRAY_SHOW, hidden_ ? L"显示猫咪" : L"隐藏猫咪");
    AppendMenuW(m, MF_STRING, ID_TRAY_RESET_POS, L"回到右下角");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);

    AppendMenuW(m, MF_STRING, ID_TRAY_CHECKIN, L"打卡日历…");
    AppendMenuW(m, MF_STRING, ID_TRAY_COUNTDOWN, L"未来倒计时…");
    AppendMenuW(m, MF_STRING | (countdown_.upcoming().empty() ? MF_GRAYED : 0), ID_TRAY_BUBBLE_NOW,
                L"提醒一下未来倒计时");
    AppendMenuW(m, MF_STRING, ID_TRAY_SETTINGS, L"提醒设置…");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);

    AppendMenuW(m, MF_STRING, ID_TRAY_SLEEP, state_ == ST_SLEEPING ? L"唤醒" : L"睡觉");
    AppendMenuW(m, MF_STRING | (pinned_ ? MF_CHECKED : 0), ID_TRAY_PIN, L"固定位置");
    AppendMenuW(m, MF_STRING | (lickEnabled_ ? MF_CHECKED : 0), ID_TRAY_LICK, L"坐下前舔爪子");
    AppendMenuW(m, MF_STRING | (autostartEnabled() ? MF_CHECKED : 0), ID_TRAY_AUTOSTART,
                L"开机自动启动");
    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);

    HMENU palMenu = CreatePopupMenu();
    for (size_t i = 0; i < g_pals.size(); ++i) {
        AppendMenuW(palMenu, MF_STRING | (paletteIndex_ == (int)i ? MF_CHECKED : 0),
                    ID_PALETTE_BASE + (UINT)i, g_pals[i].name.c_str());
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)palMenu, L"毛色");

    static const wchar_t* sizeTitles[3] = {L"小 (60%)", L"中 (80%)", L"大 (100%)"};
    HMENU sizeMenu = CreatePopupMenu();
    for (int i = 0; i < 3; ++i) {
        AppendMenuW(sizeMenu, MF_STRING | (sizeIndex_ == i ? MF_CHECKED : 0), ID_SIZE_BASE + i,
                    sizeTitles[i]);
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)sizeMenu, L"大小");

    static const wchar_t* tempoTitles[3] = {L"慢", L"正常", L"快"};
    HMENU tempoMenu = CreatePopupMenu();
    for (int i = 0; i < 3; ++i) {
        AppendMenuW(tempoMenu, MF_STRING | (tempoIndex_ == i ? MF_CHECKED : 0), ID_TEMPO_BASE + i,
                    tempoTitles[i]);
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)tempoMenu, L"过渡节奏");

    AppendMenuW(m, MF_SEPARATOR, 0, nullptr);
    AppendMenuW(m, MF_STRING, ID_TRAY_ABOUT, L"关于");
    AppendMenuW(m, MF_STRING, ID_TRAY_EXIT, L"退出");
    return m;
}

void PetApp::showTrayMenu() {
    POINT pt;
    GetCursorPos(&pt);
    HMENU m = buildTrayMenu();
    // 托盘菜单必须先拿到前台，否则点外面关不掉
    SetForegroundWindow(hwnd_);
    TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_LEFTALIGN | TPM_BOTTOMALIGN, pt.x, pt.y, 0, hwnd_,
                   nullptr);
    PostMessage(hwnd_, WM_NULL, 0, 0);
    DestroyMenu(m);
}

bool PetApp::autostartEnabled() const {
    wchar_t buf[MAX_PATH * 2] = {};
    DWORD size = sizeof(buf);
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run",
                     L"DesktopPet", RRF_RT_REG_SZ, nullptr, buf, &size) != ERROR_SUCCESS) {
        return false;
    }
    return buf[0] != L'\0';
}

void PetApp::setAutostart(bool on) {
    HKEY key = nullptr;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Run", 0,
                      KEY_SET_VALUE, &key) != ERROR_SUCCESS) {
        return;
    }
    if (on) {
        wchar_t path[MAX_PATH] = {};
        GetModuleFileNameW(nullptr, path, MAX_PATH);
        std::wstring quoted = L"\"" + std::wstring(path) + L"\"";
        RegSetValueExW(key, L"DesktopPet", 0, REG_SZ, (const BYTE*)quoted.c_str(),
                       (DWORD)((quoted.size() + 1) * sizeof(wchar_t)));
    } else {
        RegDeleteValueW(key, L"DesktopPet");
    }
    RegCloseKey(key);
}

void PetApp::toggleSleep() {
    if (state_ == ST_SLEEPING) enter(ST_IDLE, rnd(150, 300));
    else enter(ST_SLEEPING, rnd(400, 800));
}

void PetApp::togglePin() {
    pinned_ = !pinned_;
    kvSetInt("pinned", pinned_ ? 1 : 0);
    if (pinned_) spawnHearts();
}

void PetApp::toggleTools(int tab) {
    RECT r = catRect();
    if (tools_.visible()) tools_.hide();
    else {
        tools_.lightTheme = lightTheme_;
        tools_.accentArgb = accentArgb_;
        tools_.show(tab, r);
    }
}

void PetApp::handleCommand(int id) {
    if (id >= ID_PALETTE_BASE && id < ID_SIZE_BASE) {
        paletteIndex_ = id - ID_PALETTE_BASE;
        kvSetInt("palette", paletteIndex_);
        refreshAccent();
        render();
        tools_.accentArgb = accentArgb_;
        tools_.refresh();
        return;
    }
    if (id >= ID_SIZE_BASE && id < ID_TEMPO_BASE) {
        sizeIndex_ = id - ID_SIZE_BASE;
        kvSetInt("size", sizeIndex_);
        layoutPet();
        createSurface(dibW_, dibH_);
        render();
        return;
    }
    if (id >= ID_TEMPO_BASE && id < ID_TEMPO_BASE + 10) {
        tempoIndex_ = id - ID_TEMPO_BASE;
        kvSetInt("tempo", tempoIndex_);
        return;
    }
    switch (id) {
        case ID_TRAY_SHOW:
            hidden_ = !hidden_;
            ShowWindow(hwnd_, hidden_ ? SW_HIDE : SW_SHOWNOACTIVATE);
            if (!hidden_) render();
            break;
        case ID_TRAY_RESET_POS:
            positionAtBottomRight();
            savePosition();
            break;
        case ID_TRAY_CHECKIN: toggleTools(ToolsPanel::TAB_CHECKIN); break;
        case ID_TRAY_COUNTDOWN: toggleTools(ToolsPanel::TAB_COUNTDOWN); break;
        case ID_TRAY_SETTINGS: toggleTools(ToolsPanel::TAB_SETTINGS); break;
        case ID_TRAY_BUBBLE_NOW: maybeShowCountdownBubble(true); break;
        case ID_TRAY_SLEEP: toggleSleep(); break;
        case ID_TRAY_PIN: togglePin(); break;
        case ID_TRAY_LICK:
            lickEnabled_ = !lickEnabled_;
            kvSetInt("lick", lickEnabled_ ? 1 : 0);
            break;
        case ID_TRAY_AUTOSTART: setAutostart(!autostartEnabled()); break;
        case ID_TRAY_ABOUT: showAbout(); break;
        case ID_TRAY_EXIT: PostMessage(hwnd_, WM_CLOSE, 0, 0); break;
        default: break;
    }
}

void PetApp::showAbout() {
    std::wstring text;
    text += L"一只住在桌面上的像素小猫。它自己散步、发呆、睡觉，顺便帮你记着日子。\n\n";
    text += L"【鼠标操作】\n";
    text += L"• 左键拖动：把猫挪到别处（「固定位置」开启后不可拖动）\n";
    text += L"• 单击：摸猫，冒爱心眼和 ❤\n";
    text += L"• 右键：打开或收起小工具面板（回到上次看的标签页）\n\n";
    text += L"【小工具面板】顶部切换三个标签\n";
    text += L"• 打卡：每天点一次「今天打卡」，猫会开心，月历留痕并统计连续天数；顶部「开始 / 暂停」记录打卡时长，日历格子按时长深浅着色\n";
    text += L"• 未来倒计时：记下生日、上线、考试等日子（列表显示完整年月日），支持每年重复，按剩余天数排序；鼠标移到某一行，右侧出现铅笔（编辑）和 ×（删除，会先确认一次）\n";
    text += L"• 提醒：未来倒计时播报开关、开始提醒的范围、提醒间隔；打卡计时中每过一段时间猫会冒气泡播报「已经打卡了多久」\n\n";
    text += L"【其余设置】右键托盘里的猫头图标\n";
    text += L"显示 / 隐藏猫咪、回到右下角、打卡日历 / 未来倒计时 / 提醒设置、睡觉、固定位置、坐下前舔爪子、开机自动启动、外观（毛色 / 大小 / 节奏）、关于、退出\n\n";
    text += L"数据只存在本机注册表（HKCU\\Software\\DesktopPet），不上传。\n";
    text += L"版本 1.3.0 · MIT License";
    MessageBoxW(nullptr, text.c_str(), L"关于桌面宠物", MB_OK | MB_ICONINFORMATION);
}

// ---------------- 播报 ----------------
RECT PetApp::catRect() const {
    RECT r;
    r.left = winX_ + petX_;
    r.top = winY_ + petY_;
    r.right = r.left + petSize_;
    r.bottom = r.top + petSize_;
    return r;
}

void PetApp::presentBubble(const std::wstring& title, const std::wstring& message,
                           const std::wstring& hint, int tab) {
    bubble_.show(title, message, hint, catRect(), accentArgb_, lightTheme_, [this, tab]() {
        tools_.lightTheme = lightTheme_;
        tools_.accentArgb = accentArgb_;
        tools_.show(tab, catRect());
    });
}

void PetApp::maybeShowCountdownBubble(bool force) {
    if (!force && !settings_.cdEnabled) return;
    auto rows = countdown_.upcoming();
    if (rows.empty()) return;
    const CountdownRow& first = rows.front();

    if (!force && !settings_.inRange(first.days)) return;

    std::string today = daykey::today();
    if (!force) {
        if (first.days == 0) {
            if (lastBubbleDay_ == today) return;
        } else {
            if (lastBubbleAt_ != 0) {
                unsigned long long now = (unsigned long long)time(nullptr);
                if (now - lastBubbleAt_ < (unsigned long long)settings_.cdIntervalMinutes * 60ULL) return;
            }
        }
    }
    lastBubbleDay_ = today;
    lastBubbleAt_ = (unsigned long long)time(nullptr);
    kvSet("countdownBubbleDay", today);
    kvSetInt("countdownBubbleAt", (int)lastBubbleAt_);

    std::wstring title = ui::widen(first.event.title);
    std::wstring message;
    if (first.days == 0) message = L"「" + title + L"」就是今天！";
    else if (first.days == 1) message = L"「" + title + L"」就是明天";
    else message = L"距离「" + title + L"」还有 " + std::to_wstring(first.days) + L" 天";

    std::wstring hint = rows.size() > 1
                            ? L"点我看看另外 " + std::to_wstring(rows.size() - 1) + L" 个日子"
                            : L"点我打开未来倒计时";
    presentBubble(L"未来倒计时提醒", message, hint, ToolsPanel::TAB_COUNTDOWN);
}

void PetApp::maybeShowStudyBubble() {
    if (!settings_.studyEnabled || !study_.running()) return;
    int step = std::max(60, settings_.studyIntervalMinutes * 60);
    int now = study_.todaySeconds();
    if (now < studyAnnounceBase_) studyAnnounceBase_ = (now / step) * step;
    if (now - studyAnnounceBase_ < step) return;
    if (bubble_.visible()) return;      // 让正在说的先说完
    studyAnnounceBase_ = now;

    std::wstring message;
    if (now >= 3600) {
        message = L"已经打卡 " + ui::widen(StudyStore::format(now)) + L" 了，起来走两步？";
    } else {
        message = L"已经打卡 " + ui::widen(StudyStore::format(now)) + L" 啦，再接再厉";
    }
    presentBubble(L"打卡计时", message, L"点我打开打卡日历", ToolsPanel::TAB_CHECKIN);
}

void PetApp::oncePerSecond() {
    if (hidden_) return;
    std::string today = daykey::today();
    if (today != cachedDay_) {
        cachedDay_ = today;
        checkIn_.load();
        countdown_.load();
        tools_.refreshDay();
    }
    maybeShowCountdownBubble(false);
    maybeShowStudyBubble();
}

void PetApp::refreshAccent() {
    accentArgb_ = 0xFFFFB648;
    if (paletteIndex_ >= 0 && paletteIndex_ < (int)g_pals.size()) {
        size_t idx = g_alphabet.find('g');
        if (idx != std::string::npos && idx < g_pals[paletteIndex_].argb.size()) {
            unsigned int c = g_pals[paletteIndex_].argb[idx];
            if ((c >> 24) != 0) accentArgb_ = c | 0xFF000000;
        }
    }
}

// ---------------- 窗口过程 ----------------
LRESULT CALLBACK PetApp::wndProc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
    PetApp* a = self_;
    switch (msg) {
        case WM_LBUTTONDOWN: {
            if (!a) break;
            SetCapture(hwnd);
            GetCursorPos(&a->dragStart_);
            a->dragWinX_ = a->winX_;
            a->dragWinY_ = a->winY_;
            a->dragging_ = true;
            a->dragMoved_ = false;
            return 0;
        }
        case WM_MOUSEMOVE: {
            if (!a || !a->dragging_) break;
            POINT pt;
            GetCursorPos(&pt);
            int dx = pt.x - a->dragStart_.x, dy = pt.y - a->dragStart_.y;
            if (abs(dx) > 2 || abs(dy) > 2) a->dragMoved_ = true;
            if (a->pinned_ || !a->dragMoved_) break;
            a->winX_ = a->dragWinX_ + dx;
            a->winY_ = a->dragWinY_ + dy;
            SetWindowPos(hwnd, HWND_TOPMOST, a->winX_, a->winY_, 0, 0,
                         SWP_NOSIZE | SWP_NOACTIVATE);
            return 0;
        }
        case WM_LBUTTONUP: {
            if (!a) break;
            bool moved = a->dragMoved_;
            a->dragging_ = false;
            a->dragMoved_ = false;
            ReleaseCapture();
            if (moved) {
                a->clampToScreen();
                a->savePosition();
            } else {
                a->pat();
            }
            return 0;
        }
        case WM_RBUTTONUP: {
            if (!a) break;
            a->tools_.lightTheme = a->lightTheme_;
            a->tools_.accentArgb = a->accentArgb_;
            a->toggleTools(a->tools_.tab());
            return 0;
        }
        case WM_APP_TRAY: {
            if (!a) break;
            if (LOWORD(lp) == WM_LBUTTONUP) {
                a->hidden_ = false;
                ShowWindow(hwnd, SW_SHOWNOACTIVATE);
                a->render();
            } else if (LOWORD(lp) == WM_RBUTTONUP) {
                a->showTrayMenu();
            }
            return 0;
        }
        case WM_COMMAND: {
            if (!a) break;
            a->handleCommand(LOWORD(wp));
            return 0;
        }
        case WM_TIMER:
            if (!a) break;
            if (wp == 1) {
                a->tick();
            } else if (wp == 2) {
                KillTimer(hwnd, 2);
                a->maybeShowCountdownBubble(false);
            }
            return 0;
        case WM_DPICHANGED: {
            if (!a) break;
            RECT* r = (RECT*)lp;
            double nd = HIWORD(wp) / 96.0;
            a->dpiScale_ = nd < 1.0 ? 1.0 : nd;
            a->winX_ = r->left;
            a->winY_ = r->top;
            a->layoutPet();
            a->createSurface(a->dibW_, a->dibH_);
            SetWindowPos(hwnd, HWND_TOPMOST, r->left, r->top, r->right - r->left,
                         r->bottom - r->top, SWP_NOACTIVATE);
            a->render();
            return 0;
        }
        case WM_DESTROY:
            if (a) {
                a->study_.pause();
                a->savePosition();
                a->removeTrayIcon();
            }
            KillTimer(hwnd, 1);
            PostQuitMessage(0);
            return 0;
    }
    return DefWindowProcW(hwnd, msg, wp, lp);
}

// ---------------- 入口 ----------------
bool PetApp::init(HINSTANCE hInst) {
    hInst_ = hInst;
    self_ = this;

    typedef BOOL(WINAPI * SetCtxFn)(HANDLE);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        auto setCtx = (SetCtxFn)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (setCtx) setCtx((HANDLE)-4);
        else SetProcessDPIAware();
    }

    HRSRC hr = NULL;
    HGLOBAL hg = NULL;
    const unsigned char* data = NULL;
    DWORD sz = 0;
#ifdef PET_EMBED
    data = kPetData;
    sz = (DWORD)kPetDataLen;
#else
    hr = FindResourceW(NULL, MAKEINTRESOURCEW(101), RT_RCDATA);
    if (!hr) {
        MessageBoxW(NULL, L"找不到内嵌的精灵数据资源。", L"DesktopPet", MB_ICONERROR);
        return false;
    }
    hg = LoadResource(NULL, hr);
    sz = SizeofResource(NULL, hr);
    data = (const unsigned char*)LockResource(hg);
#endif
    if (!data || !loadSpriteData(data, sz)) {
        MessageBoxW(NULL, L"精灵数据解析失败（数据版本不匹配）。", L"DesktopPet", MB_ICONERROR);
        return false;
    }

    HDC screen = GetDC(NULL);
    int dpi = GetDeviceCaps(screen, LOGPIXELSX);
    ReleaseDC(NULL, screen);
    dpiScale_ = dpi / 96.0;
    if (dpiScale_ < 1.0) dpiScale_ = 1.0;

    // 读设置
    paletteIndex_ = kvGetInt("palette", 0);
    sizeIndex_ = kvGetInt("size", 2);
    tempoIndex_ = kvGetInt("tempo", 1);
    // 注册表可能被改坏，钳一下再使用
    if (paletteIndex_ < 0) paletteIndex_ = 0;
    if (paletteIndex_ >= (int)g_pals.size()) paletteIndex_ = 0;
    sizeIndex_ = std::max(0, std::min(sizeIndex_, 2));
    tempoIndex_ = std::max(0, std::min(tempoIndex_, 2));
    pinned_ = kvGetInt("pinned", 0) != 0;
    lickEnabled_ = kvGetInt("lick", 1) != 0;
    checkIn_.load();
    countdown_.load();
    study_.load();
    settings_.load();
    lastBubbleDay_ = kvGet("countdownBubbleDay", "");
    lastBubbleAt_ = (unsigned long long)kvGetInt("countdownBubbleAt", 0);
    lightTheme_ = ui::systemUsesLightTheme();
    cachedDay_ = daykey::today();

    layoutPet();
    if (!createWindow()) return false;

    refreshAccent();

    // 小工具面板
    tools_.dpi = (float)dpiScale_;
    tools_.lightTheme = lightTheme_;
    tools_.accentArgb = accentArgb_;
    tools_.checkIn = &checkIn_;
    tools_.countdown = &countdown_;
    tools_.study = &study_;
    tools_.settings = &settings_;
    tools_.onCheckIn = [this]() {
        spawnHearts();
        loveTicks_ = 90;
        if (state_ == ST_SLEEPING) enter(ST_IDLE, 120);
        int streak = checkIn_.stats().current;
        int studied = study_.todaySeconds();
        if (settings_.studyEnabled && studied >= 60) {
            presentBubble(L"今日打卡",
                          L"今天已经打卡 " + ui::widen(StudyStore::format(studied)) + L" 了",
                          L"连续 " + std::to_wstring(streak) + L" 天 · 点我看看日历",
                          ToolsPanel::TAB_CHECKIN);
        }
    };
    tools_.onDuplicate = [this]() { spawnHearts(); };
    tools_.onEventsChanged = [this]() { maybeShowCountdownBubble(true); };
    tools_.onSettingsChanged = [this]() { studyAnnounceBase_ = study_.todaySeconds(); };
    if (!tools_.create(hInst, hwnd_)) return false;

    // 气泡
    bubble_.setDpi((float)dpiScale_);
    if (!bubble_.create(hInst)) return false;

    addTrayIcon();

    state_ = ST_IDLE;
    ticksLeft_ = 120;
    lastSecondAt_ = GetTickCount64();
    updatePose();
    render();

    // 开机先让猫说一句最近的未来倒计时
    studyAnnounceBase_ = study_.todaySeconds();
    SetTimer(hwnd_, 2, 3000, nullptr);
    return true;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    CreateMutexW(NULL, TRUE, L"DesktopPetWinSingleton");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    INITCOMMONCONTROLSEX icc = {sizeof(icc), ICC_DATE_CLASSES | ICC_STANDARD_CLASSES};
    InitCommonControlsEx(&icc);

    Gdiplus::GdiplusStartupInput gdiInput;
    ULONG_PTR gdiToken = 0;
    if (Gdiplus::GdiplusStartup(&gdiToken, &gdiInput, nullptr) != Gdiplus::Ok) return 1;

    PetApp app;
    int code = 1;
    if (app.init(hInst)) {
        MSG msg;
        while (GetMessageW(&msg, NULL, 0, 0) > 0) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        code = 0;
    }

    Gdiplus::GdiplusShutdown(gdiToken);
    return code;
}
