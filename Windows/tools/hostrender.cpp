// 宿主机模拟 Windows 端的整窗渲染：验证猫在窗口中的位置、朝向镜像、粒子布局
// 与 src/main.cpp 的 render() 保持同样的布局参数
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static const int kGridW = 64, kGridH = 64;
static const int kPanelW = 344, kPanelH = 412;

struct FrameData { std::vector<unsigned char> idx; };
static int g_alphaN = 0;
static std::vector<FrameData> g_frames;
static std::map<std::string, int> g_frameIndex;
struct Palette { std::vector<unsigned int> argb; };
static std::vector<Palette> g_pals;

static unsigned short g_pick16(const unsigned char* p) { return (unsigned short)(p[0] | (p[1] << 8)); }

static bool load(const unsigned char* d, size_t n) {
    if (n < 16 || memcmp(d, "PXP1", 4) != 0) return false;
    size_t p = 4;
    int w = d[p++], h = d[p++];
    if (w != kGridW || h != kGridH) return false;
    g_alphaN = d[p++];
    p += g_alphaN;
    int fc = g_pick16(d + p); p += 2;
    g_frames.resize(fc);
    for (int i = 0; i < fc; ++i) {
        int nl = d[p++];
        std::string name((const char*)d + p, nl); p += nl;
        g_frames[i].idx.assign(d + p, d + p + kGridW * kGridH);
        p += kGridW * kGridH;
        g_frameIndex[name] = i;
    }
    int pc = d[p++];
    g_pals.resize(pc);
    for (int i = 0; i < pc; ++i) {
        int nl = d[p++]; p += nl;
        g_pals[i].argb.resize(g_alphaN);
        for (int c = 0; c < g_alphaN; ++c) {
            unsigned int a = d[p + 3], r = d[p], g = d[p + 1], b = d[p + 2];
            g_pals[i].argb[c] = (a << 24) | (r << 16) | (g << 8) | b;
            p += 4;
        }
    }
    return true;
}

static const char kHeart[8][10] = {
    ".##...##.", "####.####", "#########", "#########",
    ".#######.", "..#####..", "...###...", "....#....",
};

struct Canvas {
    int w, h;
    std::vector<unsigned char> rgba;   // 预乘 RGBA
    Canvas(int W, int H) : w(W), h(H), rgba((size_t)W * H * 4, 0) {}
    void blend(int x, int y, unsigned int rgb, int a) {
        if (x < 0 || y < 0 || x >= w || y >= h || a <= 0) return;
        unsigned char* q = &rgba[((size_t)y * w + x) * 4];
        int sr = ((rgb >> 16) & 0xFF) * a / 255, sg = ((rgb >> 8) & 0xFF) * a / 255, sb = (rgb & 0xFF) * a / 255;
        int n = 255 - a;
        q[0] = (unsigned char)(sb + q[0] * n / 255);
        q[1] = (unsigned char)(sg + q[1] * n / 255);
        q[2] = (unsigned char)(sr + q[2] * n / 255);
        q[3] = (unsigned char)(a + q[3] * n / 255);
    }
};

static void drawFrame(Canvas& cv, const std::string& name, int facing, int palIdx,
                      int pixel, int petX, int petY) {
    auto it = g_frameIndex.find(name);
    if (it == g_frameIndex.end()) { printf("missing %s\n", name.c_str()); return; }
    const auto& f = g_frames[it->second];
    const auto& pal = g_pals[palIdx];
    for (int ay = 0; ay < kGridH; ++ay)
        for (int ax = 0; ax < kGridW; ++ax) {
            int sx = facing < 0 ? (kGridW - 1 - ax) : ax;
            unsigned char ci = f.idx[ay * kGridW + sx];
            if (ci == 0) continue;
            unsigned int c = pal.argb[ci];
            if ((c >> 24) == 0) continue;
            int x0 = petX + ax * pixel, y0 = petY + ay * pixel;
            for (int y = 0; y < pixel; ++y)
                for (int x = 0; x < pixel; ++x) {
                    unsigned char* q = &cv.rgba[((size_t)(y0 + y) * cv.w + x0 + x) * 4];
                    q[0] = c & 0xFF; q[1] = (c >> 8) & 0xFF; q[2] = (c >> 16) & 0xFF; q[3] = 255;
                }
        }
}

static void drawHeart(Canvas& cv, int cx, int topY, int scale, int alpha) {
    for (int my = 0; my < 8; ++my)
        for (int mx = 0; mx < 9; ++mx) {
            if (kHeart[my][mx] != '#') continue;
            for (int sy = 0; sy < scale; ++sy)
                for (int sx = 0; sx < scale; ++sx)
                    cv.blend(cx + mx * scale + sx, topY + my * scale + sy, 0xFF5C7A, alpha);
        }
}

static void save(const Canvas& cv, const char* path, int scale) {
    int W = cv.w * scale, H = cv.h * scale;
    std::vector<unsigned char> px((size_t)W * H * 3);
    for (int y = 0; y < H; ++y)
        for (int x = 0; x < W; ++x) {
            int sx = x / scale, sy = y / scale;
            const unsigned char* q = &cv.rgba[((size_t)sy * cv.w + sx) * 4];
            int a = q[3];
            int ck = (((x >> 4) + (y >> 4)) % 2 == 0) ? 235 : 210;
            unsigned char* d = &px[((size_t)y * W + x) * 3];
            d[0] = (unsigned char)(q[2] + ck * (255 - a) / 255);
            d[1] = (unsigned char)(q[1] + ck * (255 - a) / 255);
            d[2] = (unsigned char)(q[0] + ck * (255 - a) / 255);
        }
    FILE* fp = fopen(path, "wb");
    fprintf(fp, "P6\n%d %d\n255\n", W, H);
    fwrite(px.data(), 1, px.size(), fp);
    fclose(fp);
    printf("-> %s\n", path);
}

int main(int argc, char** argv) {
    FILE* fp = fopen(argv[1], "rb");
    fseek(fp, 0, SEEK_END); long n = ftell(fp); fseek(fp, 0, SEEK_SET);
    std::vector<unsigned char> buf(n);
    fread(buf.data(), 1, n, fp); fclose(fp);
    if (!load(buf.data(), buf.size())) { printf("parse fail\n"); return 1; }

    // 场景 1：100% 大小、朝右趴卧 + 爱心粒子
    {
        int pixel = 5, petSize = kGridW * pixel;
        int petX = (kPanelW - petSize) / 2;
        int petY = kPanelH - 10 - petSize;
        printf("100%%: petX=%d petY=%d petSize=%d\n", petX, petY, petSize);
        Canvas cv(kPanelW, kPanelH);
        drawFrame(cv, "loveA", 1, 0, pixel, petX, petY);
        drawHeart(cv, petX + petSize / 3, petY - 20, 3, 230);
        drawHeart(cv, petX + petSize / 2, petY - 40, 2, 160);
        save(cv, "/tmp/win_scene1.ppm", 1);
    }
    // 场景 2：100% 大小、朝左行走（验证镜像）
    {
        int pixel = 5, petSize = kGridW * pixel;
        int petX = (kPanelW - petSize) / 2;
        int petY = kPanelH - 10 - petSize;
        Canvas cv(kPanelW, kPanelH);
        drawFrame(cv, "walk1", -1, 0, pixel, petX, petY);
        save(cv, "/tmp/win_scene2.ppm", 1);
    }
    // 场景 3：60% 小档（pixel=3），橘猫
    {
        int pixel = 3, petSize = kGridW * pixel;
        int petX = (kPanelW - petSize) / 2;
        int petY = kPanelH - 10 - petSize;
        printf("60%%: petX=%d petY=%d petSize=%d\n", petX, petY, petSize);
        Canvas cv(kPanelW, kPanelH);
        drawFrame(cv, "sitA", 1, 1, pixel, petX, petY);
        save(cv, "/tmp/win_scene3.ppm", 1);
    }
    return 0;
}
