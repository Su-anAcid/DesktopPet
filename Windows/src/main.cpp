// DesktopPet for Windows
// 原生 Win32 + 分层窗口（UpdateLayeredWindow）实现，无任何运行时依赖。
// 精灵帧由 macOS 版同一份绘制代码导出（assets/pet.dat），所以两边美术完全一致。

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <shellapi.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <map>
#include <random>
#include <string>
#include <vector>

#ifdef PET_EMBED
#include "pet_data.h"      // 数据直接编进 exe（无 windres 时的单文件方案）
#endif

// ---------------- 常量（与 macOS 版对齐） ----------------
static const int kGridW = 64;
static const int kGridH = 64;
static const int kPanelW = 344;      // 逻辑像素
static const int kPanelH = 412;      // 比猫高出一截，给爱心/Z 留上浮空间
static const int kPetYFromBottom = 10;
static const double kSpeed = 50.0;   // 逻辑像素 / 秒
static const float kRise = 46.0f;    // 粒子上浮高度（逻辑像素）
static const float kParticleLife = 1.4f;

enum PetState { ST_WALKING, ST_IDLE, ST_SLEEPING, ST_STRETCHING, ST_TRANSITION };

// ---------------- 帧数据 ----------------
struct FrameData { std::vector<unsigned char> idx; };

static int g_alphaN = 0;
static std::string g_alphabet;
static std::vector<FrameData> g_frames;
static std::map<std::string, int> g_frameIndex;

struct Palette {
    std::wstring name;
    std::vector<unsigned int> argb;   // 0xAARRGGBB，按字符表索引
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
    // 缺表情变体时退回基础姿态：stretchA_love -> stretchA
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
    unsigned int color;   // 0xRRGGBB
    float age, life;
    int scale;
};

// 粒子像素图形：必须用二维数组保证行内存连续（渲染按 row*宽 偏移取行）
static const char kHeartMask[8][10] = {
    ".##...##.",
    "####.####",
    "#########",
    "#########",
    ".#######.",
    "..#####..",
    "...###...",
    "....#....",
};
static const char kZMask[6][6] = {
    "#####",
    "...#.",
    "..#..",
    ".#...",
    "#....",
    "#####",
};

// ---------------- 应用 ----------------
class PetApp {
public:
    bool init(HINSTANCE hInst);
    void tick();

private:
    enum { WM_APP_TICK = WM_APP + 1 };

    HINSTANCE hInst_ = nullptr;
    HWND hwnd_ = nullptr;
    HDC memDC_ = nullptr;
    HBITMAP dib_ = nullptr;
    void* bits_ = nullptr;
    int dibW_ = 0, dibH_ = 0;

    double dpiScale_ = 1.0;
    int pixel_ = 5;        // 每个艺术像素占多少物理像素
    int petSize_ = 320;
    int petX_ = 12, petY_ = 82;
    int winX_ = 0, winY_ = 0;

    // 状态机
    PetState state_ = ST_IDLE;
    int facing_ = 1;
    int ticksLeft_ = 120;
    long tickCount_ = 0;
    int paletteIndex_ = 0;
    int sizeIndex_ = 2;
    bool pinned_ = false;
    bool lickEnabled_ = true;
    int loveTicks_ = 0;
    int happyTicks_ = 0;
    PetState stretchNext_ = ST_WALKING;

    struct SeqStep { std::string pose; int ticks; };
    std::vector<SeqStep> seq_;
    int seqIdx_ = 0, seqLeft_ = 0;
    PetState nextAfterSeq_ = ST_IDLE;

    int tempoIndex_ = 1;
    const double tempoScales_[3] = { 1.35, 1.0, 0.75 };

    std::vector<Particle> particles_;
    std::string currentPose_ = "sitA";

    // 拖拽状态
    bool dragging_ = false;
    bool dragMoved_ = false;
    POINT dragStart_ = { 0, 0 };
    int dragWinX_ = 0, dragWinY_ = 0;

    std::mt19937 rng_{ std::random_device{}() };
    ULONGLONG lastTick_ = 0;

    // —— 初始化 ——
    bool createWindow();
    bool createSurface(int w, int h);
    void layoutPet();
    void positionAtBottomRight();
    void clampToScreen();

    // —— 状态机 ——
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

    // —— 渲染 ——
    void render();
    void blendPixel(int x, int y, unsigned int rgb, int alpha);

    // —— 交互 ——
    HMENU buildMenu();
    void applyPalette(int i);
    void applySize(int i);
    void toggleSleep();
    void togglePin();

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
    if (!RegisterClassExW(&wc)) return false;

    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        L"DesktopPetWnd", L"DesktopPet", WS_POPUP,
        0, 0, 100, 100, NULL, NULL, hInst_, NULL);
    if (!hwnd_) return false;

    layoutPet();
    positionAtBottomRight();
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
    bi.bmiHeader.biHeight = -h;          // top-down
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
    MONITORINFO mi = { sizeof(mi) };
    HWND probe = hwnd_ ? hwnd_ : GetDesktopWindow();
    HMONITOR mon = MonitorFromWindow(probe, MONITOR_DEFAULTTOPRIMARY);
    GetMonitorInfoW(mon, &mi);
    winX_ = mi.rcWork.right - w - (int)lround(60 * dpiScale_);
    winY_ = mi.rcWork.bottom - h - (int)lround(8 * dpiScale_);
    if (hwnd_) SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, w, h, SWP_NOACTIVATE);
}

void PetApp::clampToScreen() {
    MONITORINFO mi = { sizeof(mi) };
    HMONITOR mon = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(mon, &mi);
    int w = (int)lround(kPanelW * dpiScale_);
    int h = (int)lround(kPanelH * dpiScale_);
    if (winX_ < mi.rcWork.left) winX_ = mi.rcWork.left;
    if (winX_ + w > mi.rcWork.right) winX_ = mi.rcWork.right - w;
    if (winY_ < mi.rcWork.top) winY_ = mi.rcWork.top;
    if (winY_ + h > mi.rcWork.bottom) winY_ = mi.rcWork.bottom - h;
    SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
}

// ---------------- 状态机 ----------------
std::vector<PetApp::SeqStep> PetApp::sitDownSeq() {
    std::vector<SeqStep> s;
    s.push_back({ "walk1", 5 });
    s.push_back({ "quarterStand", 12 });
    s.push_back({ "quarterRise", 9 });
    s.push_back({ "quarterCrouch", 11 });
    if (lickEnabled_) {
        int rounds = rnd(2, 3);
        for (int r = 0; r < rounds; ++r) {
            s.push_back({ "lickA", 7 });
            s.push_back({ "lickB", 6 });
            s.push_back({ "lickC", 7 });
            s.push_back({ "lickD", 6 });
            if (r < rounds - 1) s.push_back({ "lickC", 5 });
        }
    }
    s.push_back({ "quarterLow", 9 });
    s.push_back({ "quarterSweepA_closed", 8 });
    s.push_back({ "quarterSweepB_closed", 10 });
    return s;
}

std::vector<PetApp::SeqStep> PetApp::standUpSeq() {
    return {
        { "quarterLow", 10 }, { "quarterCrouch", 11 }, { "quarterRise", 10 },
        { "quarterStand", 12 }, { "lookL", 13 }, { "lookR", 13 }, { "walk1", 8 },
    };
}

void PetApp::play(const std::vector<SeqStep>& seq, PetState target) {
    double k = tempoScales_[tempoIndex_];
    seq_.clear();
    int total = 0;
    for (const auto& s : seq) {
        int t = (int)lround(s.ticks * k);
        if (t < 2) t = 2;
        seq_.push_back({ s.pose, t });
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
    case ST_WALKING:
        play(sitDownSeq(), ST_IDLE);
        break;
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
    case ST_TRANSITION:
        endTransition();
        break;
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
    MONITORINFO mi = { sizeof(mi) };
    HMONITOR mon = MonitorFromWindow(hwnd_, MONITOR_DEFAULTTONEAREST);
    GetMonitorInfoW(mon, &mi);
    int w = (int)lround(kPanelW * dpiScale_);
    if (winX_ <= mi.rcWork.left) { winX_ = mi.rcWork.left; facing_ = 1; }
    if (winX_ + w >= mi.rcWork.right) { winX_ = mi.rcWork.right - w; facing_ = -1; }
    SetWindowPos(hwnd_, HWND_TOPMOST, winX_, winY_, 0, 0,
                 SWP_NOSIZE | SWP_NOACTIVATE);
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
        currentPose_ = seq_.empty() ? "sitA"
                                    : seq_[std::min(seqIdx_, (int)seq_.size() - 1)].pose;
        break;
    }
}

void PetApp::pat() {
    spawnHearts();
    loveTicks_ = 100;
    switch (state_) {
    case ST_WALKING:
        play(sitDownSeq(), ST_IDLE);
        break;
    case ST_SLEEPING:
        stretchNext_ = ST_IDLE;
        enter(ST_STRETCHING, 36);
        break;
    default:
        break;
    }
}

void PetApp::spawnHearts() {
    int count = rnd(1, 3);
    for (int i = 0; i < count; ++i) {
        Particle p = {};
        p.x = (float)(petX_ + petSize_ * (0.25 + (rnd(0, 100) / 100.0) * 0.5));
        p.y = (float)petY_ - 6.0f * (float)dpiScale_ - i * 12.0f * (float)dpiScale_;
        p.mask = (const char*)kHeartMask;
        p.mw = 9; p.mh = 8;
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
    p.mw = 5; p.mh = 6;
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
        q[0] = rgb & 0xFF; q[1] = (rgb >> 8) & 0xFF; q[2] = (rgb >> 16) & 0xFF; q[3] = 255;
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
        const Palette& pal = g_pals[std::min(paletteIndex_, (int)g_pals.size() - 1)];
        const int px = pixel_;
        for (int ay = 0; ay < kGridH; ++ay) {
            int py0 = petY_ + ay * px;
            for (int ax = 0; ax < kGridW; ++ax) {
                int sx = facing_ < 0 ? (kGridW - 1 - ax) : ax;
                unsigned char ci = f->idx[ay * kGridW + sx];
                if (ci == 0) continue;                  // 字符表第 0 个是透明 '.'
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

    // 粒子
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
                        blendPixel(baseX + mx * p.scale + sx, baseY + my * p.scale + sy,
                                   p.color, alpha);
            }
        }
    }

    POINT src = { 0, 0 };
    SIZE size = { dibW_, dibH_ };
    POINT dst = { winX_, winY_ };
    BLENDFUNCTION bf = { AC_SRC_OVER, 0, 255, AC_SRC_ALPHA };
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

    if (state_ == ST_WALKING) moveStep();
    if (state_ == ST_SLEEPING && tickCount_ % 110 == 0) spawnZ();

    if (state_ == ST_TRANSITION) advanceTransition();
    else if (ticksLeft_ <= 0) nextState();

    updateParticles(dt);
    updatePose();
    render();
}

// ---------------- 菜单与命令 ----------------
HMENU PetApp::buildMenu() {
    HMENU m = CreatePopupMenu();
    HMENU palMenu = CreatePopupMenu();
    for (size_t i = 0; i < g_pals.size(); ++i) {
        AppendMenuW(palMenu, MF_STRING | (paletteIndex_ == (int)i ? MF_CHECKED : 0),
                    1000 + (UINT)i, g_pals[i].name.c_str());
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)palMenu, L"毛色");

    static const wchar_t* sizeTitles[3] = { L"小 (60%)", L"中 (80%)", L"大 (100%)" };
    HMENU sizeMenu = CreatePopupMenu();
    for (int i = 0; i < 3; ++i) {
        AppendMenuW(sizeMenu, MF_STRING | (sizeIndex_ == i ? MF_CHECKED : 0),
                    1100 + i, sizeTitles[i]);
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)sizeMenu, L"大小");

    static const wchar_t* tempoTitles[3] = { L"慢", L"正常", L"快" };
    HMENU tempoMenu = CreatePopupMenu();
    for (int i = 0; i < 3; ++i) {
        AppendMenuW(tempoMenu, MF_STRING | (tempoIndex_ == i ? MF_CHECKED : 0),
                    1200 + i, tempoTitles[i]);
    }
    AppendMenuW(m, MF_POPUP, (UINT_PTR)tempoMenu, L"过渡节奏");

    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING | (lickEnabled_ ? MF_CHECKED : 0), 1300, L"坐下前舔爪子");
    AppendMenuW(m, MF_STRING, 1301, state_ == ST_SLEEPING ? L"唤醒" : L"睡觉");
    AppendMenuW(m, MF_STRING | (pinned_ ? MF_CHECKED : 0), 1302,
                pinned_ ? L"取消固定位置" : L"固定位置");
    AppendMenuW(m, MF_SEPARATOR, 0, NULL);
    AppendMenuW(m, MF_STRING, 1400, L"退出");
    return m;
}

void PetApp::applyPalette(int i) {
    if (i >= 0 && i < (int)g_pals.size()) paletteIndex_ = i;
    render();
}

void PetApp::applySize(int i) {
    if (i < 0 || i > 2) return;
    sizeIndex_ = i;
    layoutPet();
    render();
}

void PetApp::toggleSleep() {
    if (state_ == ST_SLEEPING) enter(ST_IDLE, rnd(150, 300));
    else enter(ST_SLEEPING, rnd(400, 800));
}

void PetApp::togglePin() {
    pinned_ = !pinned_;
    if (pinned_) spawnHearts();
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
        POINT pt; GetCursorPos(&pt);
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
        if (moved) a->clampToScreen();
        else a->pat();
        return 0;
    }
    case WM_RBUTTONUP: {
        if (!a) break;
        POINT pt; GetCursorPos(&pt);
        HMENU m = a->buildMenu();
        LONG ex = GetWindowLongW(hwnd, GWL_EXSTYLE);
        SetWindowLongW(hwnd, GWL_EXSTYLE, ex & ~WS_EX_NOACTIVATE);
        // 分层置顶窗口要让菜单不漏掉，必须临时拿到前台；直接 SetForegroundWindow
        // 常被系统拦下，所以用 AttachThreadInput 附着到当前前台线程再设
        HWND fg = GetForegroundWindow();
        DWORD fgThread = fg ? GetWindowThreadProcessId(fg, NULL) : 0;
        DWORD myThread = GetCurrentThreadId();
        bool attached = false;
        if (fgThread && fgThread != myThread) {
            attached = AttachThreadInput(myThread, fgThread, TRUE) != 0;
        }
        SetForegroundWindow(hwnd);
        TrackPopupMenu(m, TPM_RIGHTBUTTON | TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, NULL);
        PostMessage(hwnd, WM_NULL, 0, 0);
        if (attached) AttachThreadInput(myThread, fgThread, FALSE);
        SetWindowLongW(hwnd, GWL_EXSTYLE, ex);
        SetWindowPos(hwnd, HWND_TOPMOST, a->winX_, a->winY_, 0, 0,
                     SWP_NOSIZE | SWP_NOACTIVATE);
        DestroyMenu(m);
        return 0;
    }
    case WM_COMMAND: {
        if (!a) break;
        int id = LOWORD(wp);
        if (id >= 1000 && id < 1100) a->applyPalette(id - 1000);
        else if (id >= 1100 && id < 1200) a->applySize(id - 1100);
        else if (id >= 1200 && id < 1300) a->tempoIndex_ = id - 1200;
        else if (id == 1300) a->lickEnabled_ = !a->lickEnabled_;
        else if (id == 1301) a->toggleSleep();
        else if (id == 1302) a->togglePin();
        else if (id == 1400) PostMessage(hwnd, WM_CLOSE, 0, 0);
        return 0;
    }
    case WM_TIMER:
        if (a && wp == 1) a->tick();
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
        SetWindowPos(hwnd, HWND_TOPMOST, r->left, r->top,
                     r->right - r->left, r->bottom - r->top, SWP_NOACTIVATE);
        a->render();
        return 0;
    }
    case WM_DESTROY:
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

    // DPI 感知（Win10 1703+ 用 Per-Monitor V2，失败则退回系统级）
    typedef BOOL(WINAPI* SetCtxFn)(HANDLE);
    HMODULE user32 = GetModuleHandleW(L"user32.dll");
    if (user32) {
        auto setCtx = (SetCtxFn)GetProcAddress(user32, "SetProcessDpiAwarenessContext");
        if (setCtx) setCtx((HANDLE)-4);          // PER_MONITOR_AWARE_V2
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

    layoutPet();
    if (!createWindow()) return false;

    state_ = ST_IDLE;
    ticksLeft_ = 120;
    updatePose();
    render();
    return true;
}

int WINAPI WinMain(HINSTANCE hInst, HINSTANCE, LPSTR, int) {
    // 单实例：已有实例在跑就退出
    CreateMutexW(NULL, TRUE, L"DesktopPetWinSingleton");
    if (GetLastError() == ERROR_ALREADY_EXISTS) return 0;

    PetApp app;
    if (!app.init(hInst)) return 1;

    MSG msg;
    while (GetMessageW(&msg, NULL, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}
