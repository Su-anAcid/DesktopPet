// 数据层单测：在 macOS 上 clang++ 直接编译运行（不依赖 Windows）
#include <cstdio>
#include <cstdlib>
#include <map>
#include <string>
#include <vector>

#include "../src/store.h"

// ---- 内存版持久化 ----
static std::map<std::string, std::string> g_kv;
std::string kvGet(const std::string& n, const std::string& f) {
    auto it = g_kv.find(n);
    return it == g_kv.end() ? f : it->second;
}
void kvSet(const std::string& n, const std::string& v) { g_kv[n] = v; }
void kvErase(const std::string& n) { g_kv.erase(n); }
int kvGetInt(const std::string& n, int f) {
    auto it = g_kv.find(n);
    return it == g_kv.end() ? f : atoi(it->second.c_str());
}
void kvSetInt(const std::string& n, int v) { g_kv[n] = std::to_string(v); }

// ---- 固定「今天」 ----
static int g_y = 2026, g_m = 11, g_d = 3;
void platformLocalDate(int& y, int& m, int& d) { y = g_y; m = g_m; d = g_d; }

static int passed = 0, failed = 0;
static void check(bool cond, const std::string& name) {
    if (cond) { ++passed; }
    else { ++failed; printf("❌ %s\n", name.c_str()); }
}

int main() {
    // ===== 日期 =====
    check(daykey::today() == "2026-11-03", "today");
    check(daykey::offset("2026-11-03", 1) == "2026-11-04", "offset +1");
    check(daykey::offset("2026-12-31", 1) == "2027-01-01", "跨年");
    check(daykey::offset("2026-03-01", -1) == "2026-02-28", "跨月（平年）");
    check(daykey::offset("2024-03-01", -1) == "2024-02-29", "闰年 2/29");
    check(daykey::daysBetween("2026-11-03", "2026-11-10") == 7, "daysBetween");
    check(daykey::daysBetween("2026-11-10", "2026-11-03") == -7, "daysBetween 负数");
    check(daykey::dayOfWeek("2026-11-03") == 1, "2026-11-03 是周二");   // 周一=0
    check(daykey::dayOfWeek("2026-11-02") == 0, "2026-11-02 是周一");
    check(daykey::fullTitle("2026-11-03") == "2026 年 11 月 3 日", "fullTitle");
    int py = 0, pm = 0, pd = 0;            // 注意：parse 会把 y/m/d 写回，别传全局
    check(!daykey::parse("2026-02-30", py, pm, pd), "2/30 判脏");
    check(!daykey::parse("2026-13-01", py, pm, pd), "13 月判脏");
    check(daykey::parse("2024-02-29", py, pm, pd), "闰年 2/29 合法");
    check(daykey::dayOfWeek("2027-01-01") == 4, "2027-01-01 是周五");
    check(daykey::daysInMonth(2024, 2) == 29 && daykey::daysInMonth(2026, 2) == 28, "2 月天数");

    // ===== 打卡 =====
    CheckInStore ci;
    kvSet("checkinDates", "2026-11-01,2026-11-02,2026-11-03,2026-13-40");
    ci.load();
    check(ci.allDays().size() == 3, "脏日期被丢弃");
    CheckInStats st = ci.stats();
    check(st.total == 3, "累计 3 天");
    check(st.current == 3, "当前连续 3 天");
    check(st.best == 3, "最长 3 天");
    check(!ci.checkInToday(), "今天已打卡");
    check(!ci.checkInToday(), "重复打卡不写数据");

    g_d = 4;
    st = ci.stats();
    check(st.current == 3, "今天没打但昨天打了 → 连击不断");
    check(ci.checkInToday(), "新的一天可打卡");
    st = ci.stats();
    check(st.current == 4 && st.total == 4, "打卡后连续 4 天");
    g_d = 3;

    // 月历：2026-11-01 是周日 → 周一起始时前面空 6 格
    auto grid = ci.monthGrid(2026, 11);
    check(grid[6] == "2026-11-01", "11/1 落在第 7 格（周日）");
    check(grid[5].empty(), "第 6 格为空");
    check(grid[35] == "2026-11-30", "11/30 位置");
    check(grid[36].empty(), "11/30 之后为空");

    // ===== 未来倒计时 =====
    CountdownStore cd;
    kvSet("countdownEvents", "");
    cd.load();
    check(cd.add("期末考试", "2026-11-10", false), "添加一次性事件");
    check(!cd.add("期末考试", "2026-11-10", false), "重复添加被拒");
    check(cd.add("生日", "2020-12-05", true), "添加每年事件");
    check(cd.events().size() == 2, "两个事件");

    std::string key;
    int days = 0;
    const CountdownEvent* bd = nullptr;
    for (const auto& e : cd.events()) if (e.title == "生日") bd = &e;
    check(bd != nullptr, "取到生日");
    bool okNext = cd.nextOccurrence(*bd, key, days);
    check(okNext && key == "2026-12-05", "每年事件滚到今年");
    check(days == 32, "生日 2026-12-05 → 32 天");

    // 2/29 每年重复：平年落 2/28
    CountdownEvent leap{"x", "闰日", "2024-02-29", true};
    check(cd.nextOccurrence(leap, key, days) && key == "2027-02-28", "2/29 平年落 2/28");

    // 排序：期末考试 7 天在生日 32 天前面
    auto rows = cd.upcoming();
    check(rows.size() == 2 && rows[0].event.title == "期末考试" && rows[0].days == 7, "按剩余天数升序");

    // 编辑：改名 + 改日期
    std::string examId;
    for (const auto& e : cd.events()) if (e.title == "期末考试") examId = e.id;
    check(cd.update(examId, "期末考", "2026-11-15", false), "编辑成功");
    check(cd.find(examId)->title == "期末考" && cd.find(examId)->dateKey == "2026-11-15", "编辑已生效");
    check(!cd.update(examId, "生日", "2020-12-05", true), "改成与别的事件撞车 → 拒绝");
    check(cd.find(examId)->title == "期末考", "拒绝后未被破坏");
    check(!cd.contains("期末考", "2026-11-15", examId), "排除自己不算重复");

    // 删除
    cd.remove(examId);
    check(cd.events().size() == 1 && cd.find(examId) == nullptr, "删除生效");

    // 持久化往返（含标题里的分隔符被清洗）
    cd.add("带\tTab 的标题", "2026-12-01", false);
    CountdownStore cd2;
    cd2.load();
    check(cd2.events().size() == 2, "重启后事件仍在");
    bool cleaned = false;
    for (const auto& e : cd2.events()) if (e.dateKey == "2026-12-01") cleaned = e.title.find('\t') == std::string::npos;
    check(cleaned, "标题里的 Tab 被清洗");

    // ===== 打卡时长 =====
    StudyStore ss;
    kvSet("studySeconds", "2026-11-03=900;2026-11-02=3660;bad=10;2026-11-01=0");
    ss.load();
    check(ss.secondsOf("2026-11-03") == 900, "读取今日秒数");
    check(ss.secondsOf("2026-11-01") == 0, "0 秒不入库");
    check(ss.totalSeconds() == 4560, "总秒数");
    check(StudyStore::format(900) == "15 分钟", "format 分钟");
    check(StudyStore::format(3600) == "1 小时", "format 整小时");
    check(StudyStore::format(4800) == "1 小时 20 分", "format 时分");
    check(StudyStore::format(30) == "不到 1 分钟", "format 不足 1 分钟");
    check(StudyStore::compact(900) == "15m", "compact 分钟");
    check(StudyStore::compact(7200) == "2h", "compact 整小时");
    check(StudyStore::compact(5400) == "1.5h", "compact 半小时");
    check(StudyStore::compact(0) == "", "compact 0");

    ss.start();
    ss.tick(1.5);
    ss.tick(1.4);          // 累计 2.9 → 记 2 秒，余 0.9
    check(ss.secondsOf("2026-11-03") == 902, "计时累加取整");
    ss.tick(3600.0);       // 休眠跳变 → 只认 2 秒
    check(ss.secondsOf("2026-11-03") == 904, "单次增量封顶 2 秒");
    ss.pause();
    StudyStore ss2;
    ss2.load();
    check(ss2.secondsOf("2026-11-03") == 904, "暂停时落盘");

    // ===== 提醒设置 =====
    ReminderSettings rs;
    rs.load();
    check(rs.cdEnabled && rs.studyEnabled, "默认都开");
    check(rs.cdLead == LEAD_7_DAYS, "默认提前 7 天");
    check(rs.cdIntervalMinutes == 1440, "默认每天");
    check(rs.studyIntervalMinutes == 15, "默认 15 分钟");
    check(rs.inRange(7) && rs.inRange(0) && !rs.inRange(8), "7 天范围边界");
    rs.cdLead = LEAD_UNLIMITED;
    check(rs.inRange(9999), "不限制");
    rs.cdLead = LEAD_SAME_DAY;
    check(rs.inRange(0) && !rs.inRange(1), "仅当天");
    rs.cdLead = LEAD_30_DAYS;
    check(rs.inRange(30) && !rs.inRange(31), "30 天边界");

    check(ReminderSettings::intervalLabel(30) == "30 分钟", "label 30 分钟");
    check(ReminderSettings::intervalLabel(60) == "1 小时", "label 1 小时");
    check(ReminderSettings::intervalLabel(1440) == "每天", "label 每天");
    check(ReminderSettings::intervalLabel(4320) == "每 3 天", "label 每 3 天");
    check(ReminderSettings::intervalLabel(45) == "45 分钟", "label 自定义");
    rs.cdIntervalMinutes = 30;
    check(rs.intervalText() == "每 30 分钟一次", "phrase 30 分钟");
    rs.cdIntervalMinutes = 1440;
    check(rs.intervalText() == "每天一次", "phrase 每天");
    check(!rs.isIntervalCustom(), "每天是预设");
    rs.cdIntervalMinutes = 45;
    check(rs.isIntervalCustom(), "45 分钟算自定义");

    check(ReminderSettings::clampCountdown(0) == 5, "倒计时下限 5");
    check(ReminderSettings::clampCountdown(999999) == 43200, "倒计时上限 43200");
    check(ReminderSettings::clampStudy(0) == 1, "学习下限 1");
    check(ReminderSettings::clampStudy(999) == 240, "学习上限 240");

    rs.cdIntervalMinutes = 90;
    rs.studyIntervalMinutes = 90;
    rs.cdLead = LEAD_30_DAYS;
    rs.save();
    ReminderSettings rs2;
    rs2.load();
    check(rs2.cdIntervalMinutes == 90 && rs2.studyIntervalMinutes == 90, "设置持久化");
    check(rs2.cdLead == LEAD_30_DAYS, "范围持久化");

    printf("✅ %d 项通过，❌ %d 项失败\n", passed, failed);
    return failed == 0 ? 0 : 1;
}
