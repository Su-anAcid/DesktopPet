// 数据层：打卡 / 未来倒计时 / 打卡时长 / 提醒设置
// 刻意不依赖 windows.h —— 这一层在 macOS 上也能用 clang++ 编译跑单测。
#pragma once

#include <array>
#include <map>
#include <set>
#include <string>
#include <vector>

// ---- 持久化（平台实现：Windows 用注册表，测试里用内存 map）----
std::string kvGet(const std::string& name, const std::string& fallback);
void kvSet(const std::string& name, const std::string& value);
void kvErase(const std::string& name);
int kvGetInt(const std::string& name, int fallback);
void kvSetInt(const std::string& name, int value);

// ---- 日期（本地自然日，yyyy-MM-dd）----
namespace daykey {
bool parse(const std::string& key, int& y, int& m, int& d);
std::string make(int y, int m, int d);
std::string today();
std::string fromParts(int y, int m, int d);
std::string offset(const std::string& key, int days);
int daysBetween(const std::string& a, const std::string& b);   // b - a
int dayOfWeek(const std::string& key);                         // 0 = 周一
std::string fullTitle(const std::string& key);                 // 2026 年 11 月 3 日
int daysInMonth(int y, int m);
}  // namespace daykey

// ---- 打卡 ----
struct CheckInStats {
    int total = 0;     // 累计天数（不含未来）
    int best = 0;      // 历史最长连续
    int current = 0;   // 当前连续（今天没打但昨天打了仍算）
};

class CheckInStore {
public:
    void load();
    void save();

    bool isChecked(const std::string& key) const;
    bool checkedToday() const;
    bool checkInToday();          // 已打过返回 false 且不写数据
    CheckInStats stats() const;

    // 周一起始的 42 格；空位为空字符串
    std::array<std::string, 42> monthGrid(int year, int month) const;

    const std::set<std::string>& allDays() const { return days_; }

private:
    std::set<std::string> days_;
};

// ---- 未来倒计时 ----
struct CountdownEvent {
    std::string id;
    std::string title;
    std::string dateKey;   // 每年重复时是首次那年的日期
    bool yearly = false;
};

struct CountdownRow {
    CountdownEvent event;
    std::string dateKey;   // 下一次发生的日期
    int days = 0;
};

class CountdownStore {
public:
    static const int kMaxCount = 20;

    void load();
    void save();

    const std::vector<CountdownEvent>& events() const { return events_; }
    bool isFull() const { return (int)events_.size() >= kMaxCount; }
    const CountdownEvent* find(const std::string& id) const;

    bool contains(const std::string& title, const std::string& dateKey,
                  const std::string& excludeId = std::string()) const;
    bool add(const std::string& title, const std::string& dateKey, bool yearly);
    bool update(const std::string& id, const std::string& title,
                const std::string& dateKey, bool yearly);
    void remove(const std::string& id);

    // 未到期的事件，按剩余天数升序
    std::vector<CountdownRow> upcoming() const;
    std::vector<CountdownEvent> todayEvents() const;

    // 下一次发生日期（每年重复自动滚到今年 / 明年；2/29 平年落 2/28）
    bool nextOccurrence(const CountdownEvent& e, std::string& outKey, int& outDays) const;

private:
    std::vector<CountdownEvent> events_;
};

// ---- 打卡时长 ----
class StudyStore {
public:
    static const int kMaxStepSeconds = 2;   // 单次 tick 最多计 2 秒，防休眠灌水

    void load();
    void save();

    bool running() const { return running_; }
    void start();
    void pause();                            // 结算并落盘
    void tick(double dtSeconds);             // 主循环驱动
    void flushIfDue();

    int secondsOf(const std::string& key) const;
    int todaySeconds() const { return secondsOf(daykey::today()); }
    int totalSeconds() const;

    // 「45 分钟」「1 小时 20 分」这类紧凑写法；0 返回 "0 分钟"
    static std::string format(int seconds);
    static std::string compact(int seconds);   // 45m / 1.5h

private:
    std::map<std::string, int> seconds_;
    bool running_ = false;
    double carry_ = 0.0;
    unsigned long long lastFlush_ = 0;
    bool dirty_ = false;
};

// ---- 提醒设置 ----
enum CountdownLead {
    LEAD_UNLIMITED = 0,   // 不限制
    LEAD_30_DAYS = 1,
    LEAD_7_DAYS = 2,      // 默认
    LEAD_SAME_DAY = 3,
};

struct ReminderSettings {
    bool cdEnabled = true;
    int cdLead = LEAD_7_DAYS;
    int cdIntervalMinutes = 1440;      // 30 / 60 / 1440 / 4320 / 自定义
    bool studyEnabled = true;
    int studyIntervalMinutes = 15;     // 5 / 10 / 15 / 30 / 自定义

    void load();
    void save() const;

    int leadLimitDays() const;         // 不限制返回 -1
    bool inRange(int daysLeft) const;
    std::string rangeText() const;
    std::string intervalText() const;  // 每 30 分钟一次 / 每天一次
    bool isIntervalCustom() const;
    std::string studyIntervalText() const;   // 每 15 分钟播报

    static std::string intervalLabel(int minutes);   // 30 分钟 / 1 小时 / 每天 / 每 3 天
    static std::string studyLabel(int minutes);
    static int clampCountdown(int minutes);
    static int clampStudy(int minutes);
};
