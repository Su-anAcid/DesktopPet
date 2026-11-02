// 宿主端校验：用与 Windows 版完全相同的解析逻辑读 pet.dat 并渲染 PPM
// 用于在 macOS 上提前验证 src/main.cpp 的解析代码，不用真等 Windows 环境
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>

static const int kGridW = 64, kGridH = 64;
struct FrameData { std::vector<unsigned char> idx; };
static int g_alphaN = 0;
static std::vector<FrameData> g_frames;
static std::map<std::string, int> g_frameIndex;
struct Palette { std::vector<unsigned int> argb; };
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
    p += g_alphaN;  // alphabet
    int frameCount = g_pick16(d + p); p += 2;
    g_frames.resize(frameCount);
    for (int i = 0; i < frameCount; ++i) {
        int nameLen = d[p++];
        std::string name((const char*)d + p, nameLen);
        p += nameLen;
        g_frames[i].idx.assign(d + p, d + p + kGridW * kGridH);
        p += kGridW * kGridH;
        g_frameIndex[name] = i;
    }
    int palCount = d[p++];
    g_pals.resize(palCount);
    for (int i = 0; i < palCount; ++i) {
        int nameLen = d[p++];
        p += nameLen;
        g_pals[i].argb.resize(g_alphaN);
        for (int c = 0; c < g_alphaN; ++c) {
            unsigned int a = d[p + 3], r = d[p], g = d[p + 1], b = d[p + 2];
            g_pals[i].argb[c] = (a << 24) | (r << 16) | (g << 8) | b;
            p += 4;
        }
    }
    return true;
}

int main(int argc, char** argv) {
    if (argc < 3) { printf("usage: hostcheck pet.dat out.ppm\n"); return 1; }
    FILE* fp = fopen(argv[1], "rb");
    if (!fp) { printf("open fail\n"); return 1; }
    fseek(fp, 0, SEEK_END);
    long n = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    std::vector<unsigned char> buf(n);
    fread(buf.data(), 1, n, fp);
    fclose(fp);

    if (!loadSpriteData(buf.data(), buf.size())) { printf("PARSE FAIL\n"); return 1; }
    printf("parsed: %zu frames, %zu palettes, alphaN=%d\n",
           g_frames.size(), g_pals.size(), g_alphaN);

    const char* names[] = { "walk0", "walk1", "walk2", "walk3",
                            "sitA", "lickA", "stretchA", "quarterCrouch" };
    const int scale = 8, gap = 8, cnt = 8;
    int outW = cnt * (kGridW * scale + gap) + gap;
    int outH = kGridH * scale + 2 * gap;
    std::vector<unsigned char> px((size_t)outW * outH * 3);
    for (int y = 0; y < outH; ++y)
        for (int x = 0; x < outW; ++x) {
            unsigned char c = (((x >> 4) + (y >> 4)) % 2 == 0) ? 230 : 205;
            px[((size_t)y * outW + x) * 3 + 0] = c;
            px[((size_t)y * outW + x) * 3 + 1] = c;
            px[((size_t)y * outW + x) * 3 + 2] = c;
        }
    for (int fi = 0; fi < cnt; ++fi) {
        auto it = g_frameIndex.find(names[fi]);
        if (it == g_frameIndex.end()) { printf("missing frame %s\n", names[fi]); return 1; }
        const auto& f = g_frames[it->second];
        const auto& pal = g_pals[0];
        for (int y = 0; y < kGridH; ++y)
            for (int x = 0; x < kGridW; ++x) {
                unsigned char ci = f.idx[y * kGridW + x];
                if (ci == 0) continue;
                unsigned int c = pal.argb[ci];
                if ((c >> 24) == 0) continue;
                for (int sy = 0; sy < scale; ++sy)
                    for (int sx = 0; sx < scale; ++sx) {
                        int ox = gap + fi * (kGridW * scale + gap) + x * scale + sx;
                        int oy = gap + y * scale + sy;
                        unsigned char* q = &px[((size_t)oy * outW + ox) * 3];
                        q[0] = (c >> 16) & 0xFF; q[1] = (c >> 8) & 0xFF; q[2] = c & 0xFF;
                    }
            }
    }
    fp = fopen(argv[2], "wb");
    fprintf(fp, "P6\n%d %d\n255\n", outW, outH);
    fwrite(px.data(), 1, px.size(), fp);
    fclose(fp);
    printf("OK -> %s\n", argv[2]);
    return 0;
}
