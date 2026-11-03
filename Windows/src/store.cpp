#include "store.h"

#include <algorithm>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>

// 平台提供「本地今天」；Windows 侧用 GetLocalTime，测试用固定日期
void platformLocalDate(int& y, int& m, int& d);

// ---------------------------------------------------------------- 日期
namespace {

// Howard Hinnant 的 civil 算法：公历 <-> 天数，避免时区和 86400 硬除法
long long daysFromCivil(int y, unsigned m, unsigned d) {
    y -= m <= 2;
    const long long era = (y >= 0 ? y : y - 399) / 400;
    const unsigned yoe = (unsigned)(y - era * 400);
    const unsigned doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) / 5 + d - 1;
    const unsigned doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097LL + (long long)doe - 719468;
}

void civilFromDays(long long z, int& y, unsigned& m, unsigned& d) {
    z += 719468;
    const long long era = (z >= 0 ? z : z - 146096) / 146097;
    const unsigned doe = (unsigned)(z - era * 146097);
    const unsigned yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    y = (int)yoe + (int)(era * 400);
    const unsigned doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const unsigned mp = (5 * doy + 2) / 153;
    d = doy - (153 * mp + 2) / 5 + 1;
    m = mp + (mp < 10 ? 3 : -9);
    y += (m <= 2);
}

bool isLeap(int y) { return (y % 4 == 0 && y % 100 != 0) || y % 400 == 0; }

}  // namespace

namespace daykey {

int daysInMonth(int y, int m) {
    static const int kDays[12] = {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31};
    if (m < 1 || m > 12) return 30;
    if (m == 2 && isLeap(y)) return 29;
    return kDays[m - 1];
}

bool parse(const std::string& key, int& y, int& m, int& d) {
    if (key.size() != 10 || key[4] != '-' || key[7] != '-') return false;
    for (int i = 0; i < 10; ++i) {
        if (i == 4 || i == 7) continue;
        if (key[i] < '0' || key[i] > '9') return false;
    }
    y = atoi(key.substr(0, 4).c_str());
    m = atoi(key.substr(5, 2).c_str());
    d = atoi(key.substr(8, 2).c_str());
    if (y < 1970 || y > 3000 || m < 1 || m > 12 || d < 1) return false;
    if (d > daysInMonth(y, m)) return false;      // 2 月 30 日这类直接判脏
    return true;
}

std::string make(int y, int m, int d) {
    char buf[16];
    snprintf(buf, sizeof(buf), "%04d-%02d-%02d", y, m, d);
    return std::string(buf);
}

std::string fromParts(int y, int m, int d) { return make(y, m, d); }

std::string today() {
    int y = 1970, m = 1, d = 1;
    platformLocalDate(y, m, d);
    return make(y, m, d);
}

std::string offset(const std::string& key, int days) {
    int y, m, d;
    if (!parse(key, y, m, d)) return std::string();
    long long z = daysFromCivil(y, (unsigned)m, (unsigned)d) + days;
    int ny; unsigned nm, nd;
    civilFromDays(z, ny, nm, nd);
    return make(ny, nm, nd);
}

int daysBetween(const std::string& a, const std::string& b) {
    int ay, am, ad, by, bm, bd;
    if (!parse(a, ay, am, ad) || !parse(b, by, bm, bd)) return 0;
    long long za = daysFromCivil(ay, (unsigned)am, (unsigned)ad);
    long long zb = daysFromCivil(by, (unsigned)bm, (unsigned)bd);
    return (int)(zb - za);
}

int dayOfWeek(const std::string& key) {   // 0 = 周一 … 6 = 周日
    int y, m, d;
    if (!parse(key, y, m, d)) return 0;
    long long z = daysFromCivil(y, (unsigned)m, (unsigned)d);
    // 1970-01-01 是周四 → (z + 3) % 7 == 0 表示周一
    int w = (int)(((z % 7) + 7 + 3) % 7);
    return w;
}

std::string fullTitle(const std::string& key) {
    int y, m, d;
    if (!parse(key, y, m, d)) return key;
    char buf[64];
    snprintf(buf, sizeof(buf), "%d 年 %d 月 %d 日", y, m, d);
    return std::string(buf);
}

}  // namespace daykey

// ---------------------------------------------------------------- 打卡
void CheckInStore::load() {
    days_.clear();
    std::string raw = kvGet("checkinDates", "");
    size_t i = 0;
    while (i <= raw.size()) {
        size_t j = raw.find(',', i);
        if (j == std::string::npos) j = raw.size();
        std::string one = raw.substr(i, j - i);
        int y, m, d;
        if (!one.empty() && daykey::parse(one, y, m, d)) days_.insert(one);
        if (j == raw.size()) break;
        i = j + 1;
    }
}

void CheckInStore::save() {
    std::string out;
    for (const auto& k : days_) {
        if (!out.empty()) out += ",";
        out += k;
    }
    kvSet("checkinDates", out);
}

bool CheckInStore::isChecked(const std::string& key) const { return days_.count(key) > 0; }

bool CheckInStore::checkedToday() const { return isChecked(daykey::today()); }

bool CheckInStore::checkInToday() {
    std::string t = daykey::today();
    if (days_.count(t)) return false;
    days_.insert(t);
    save();
    return true;
}

CheckInStats CheckInStore::stats() const {
    const std::string today = daykey::today();
    std::vector<std::string> past;
    for (const auto& k : days_) {
        if (daykey::daysBetween(k, today) >= 0) past.push_back(k);
    }
    std::sort(past.begin(), past.end());

    CheckInStats st;
    st.total = (int)past.size();

    int longest = 0, run = 0;
    for (size_t i = 0; i < past.size(); ++i) {
        if (i > 0 && daykey::daysBetween(past[i - 1], past[i]) == 1) ++run;
        else run = 1;
        longest = std::max(longest, run);
    }

    auto streakFrom = [&](const std::string& start) {
        int count = 0;
        std::string cur = start;
        while (!cur.empty() && days_.count(cur)) {
            ++count;
            cur = daykey::offset(cur, -1);
        }
        return count;
    };

    if (days_.count(today)) {
        st.current = streakFrom(today);
    } else {
        std::string y = daykey::offset(today, -1);
        st.current = (!y.empty() && days_.count(y)) ? streakFrom(y) : 0;
    }
    st.best = std::max(longest, st.current);
    return st;
}

std::array<std::string, 42> CheckInStore::monthGrid(int year, int month) const {
    std::array<std::string, 42> cells;
    cells.fill(std::string());
    std::string first = daykey::make(year, month, 1);
    int lead = daykey::dayOfWeek(first);          // 周一起始
    int count = daykey::daysInMonth(year, month);
    for (int d = 1; d <= count; ++d) {
        int idx = lead + d - 1;
        if (idx >= 0 && idx < 42) cells[idx] = daykey::make(year, month, d);
    }
    return cells;
}

// ---------------------------------------------------------------- 未来倒计时
namespace {
std::string sanitizeField(const std::string& s) {
    std::string out;
    for (char c : s) {
        if (c == '\t' || c == '\n' || c == '\r' || c == ';') continue;
        out.push_back(c);
    }
    return out;
}
std::vector<std::string> splitKeep(const std::string& s, char sep) {
    std::vector<std::string> out;
    size_t i = 0;
    while (true) {
        size_t j = s.find(sep, i);
        if (j == std::string::npos) { out.push_back(s.substr(i)); break; }
        out.push_back(s.substr(i, j - i));
        i = j + 1;
    }
    return out;
}
unsigned long long nextId() {
    static unsigned long long counter = 0;
    unsigned long long t = (unsigned long long)std::chrono::system_clock::now().time_since_epoch().count();
    return t * 1000 + (counter++ % 1000);
}
}  // namespace

void CountdownStore::load() {
    events_.clear();
    std::string raw = kvGet("countdownEvents", "");
    for (const auto& line : splitKeep(raw, '\n')) {
        if (line.empty()) continue;
        auto f = splitKeep(line, '\t');
        if (f.size() < 4) continue;
        int y, m, d;
        if (!daykey::parse(f[2], y, m, d)) continue;
        CountdownEvent e;
        e.id = f[0];
        e.title = f[1];
        e.dateKey = f[2];
        e.yearly = f[3] == "1";
        if (e.id.empty() || e.title.empty()) continue;
        events_.push_back(e);
    }
}

void CountdownStore::save() {
    std::string out;
    for (const auto& e : events_) {
        if (!out.empty()) out += "\n";
        out += e.id + "\t" + e.title + "\t" + e.dateKey + "\t" + (e.yearly ? "1" : "0");
    }
    kvSet("countdownEvents", out);
}

const CountdownEvent* CountdownStore::find(const std::string& id) const {
    for (const auto& e : events_) {
        if (e.id == id) return &e;
    }
    return nullptr;
}

bool CountdownStore::contains(const std::string& title, const std::string& dateKey,
                              const std::string& excludeId) const {
    for (const auto& e : events_) {
        if (!excludeId.empty() && e.id == excludeId) continue;
        if (e.title == title && e.dateKey == dateKey) return true;
    }
    return false;
}

bool CountdownStore::add(const std::string& title, const std::string& dateKey, bool yearly) {
    if (isFull()) return false;
    if (title.empty() || contains(title, dateKey)) return false;
    CountdownEvent e;
    e.id = std::to_string(nextId());
    e.title = sanitizeField(title);
    e.dateKey = dateKey;
    e.yearly = yearly;
    events_.push_back(e);
    save();
    return true;
}

bool CountdownStore::update(const std::string& id, const std::string& title,
                            const std::string& dateKey, bool yearly) {
    if (title.empty() || contains(title, dateKey, id)) return false;
    for (auto& e : events_) {
        if (e.id != id) continue;
        e.title = sanitizeField(title);
        e.dateKey = dateKey;
        e.yearly = yearly;
        save();
        return true;
    }
    return false;
}

void CountdownStore::remove(const std::string& id) {
    for (size_t i = 0; i < events_.size(); ++i) {
        if (events_[i].id == id) {
            events_.erase(events_.begin() + i);
            save();
            return;
        }
    }
}

bool CountdownStore::nextOccurrence(const CountdownEvent& e, std::string& outKey, int& outDays) const {
    int y, m, d;
    if (!daykey::parse(e.dateKey, y, m, d)) return false;
    const std::string today = daykey::today();

    if (!e.yearly) {
        outKey = e.dateKey;
        outDays = daykey::daysBetween(today, outKey);
        return true;
    }

    int ty, tm, td;
    daykey::parse(today, ty, tm, td);
    // 2/29 在平年落到 2/28
    for (int year = ty; year <= ty + 1; ++year) {
        int dd = d;
        if (dd > daykey::daysInMonth(year, m)) dd = daykey::daysInMonth(year, m);
        std::string cand = daykey::make(year, m, dd);
        if (daykey::daysBetween(today, cand) >= 0) {
            outKey = cand;
            outDays = daykey::daysBetween(today, cand);
            return true;
        }
    }
    return false;
}

std::vector<CountdownRow> CountdownStore::upcoming() const {
    std::vector<CountdownRow> rows;
    for (const auto& e : events_) {
        CountdownRow r;
        r.event = e;
        if (!nextOccurrence(e, r.dateKey, r.days)) continue;
        if (r.days < 0) continue;          // 已过去的一次性事件不再展示
        rows.push_back(r);
    }
    std::sort(rows.begin(), rows.end(), [](const CountdownRow& a, const CountdownRow& b) {
        if (a.days != b.days) return a.days < b.days;
        return a.event.title < b.event.title;
    });
    return rows;
}

std::vector<CountdownEvent> CountdownStore::todayEvents() const {
    std::vector<CountdownEvent> out;
    for (const auto& r : upcoming()) {
        if (r.days == 0) out.push_back(r.event);
    }
    return out;
}

// ---------------------------------------------------------------- 打卡时长
namespace {
unsigned long long nowMs() {
    using namespace std::chrono;
    return (unsigned long long)duration_cast<milliseconds>(steady_clock::now().time_since_epoch()).count();
}
}  // namespace

void StudyStore::load() {
    seconds_.clear();
    std::string raw = kvGet("studySeconds", "");
    for (const auto& chunk : splitKeep(raw, ';')) {
        size_t eq = chunk.find('=');
        if (eq == std::string::npos) continue;
        std::string key = chunk.substr(0, eq);
        int y, m, d;
        if (!daykey::parse(key, y, m, d)) continue;
        int v = atoi(chunk.substr(eq + 1).c_str());
        if (v > 0) seconds_[key] = v;
    }
}

void StudyStore::save() {
    std::string out;
    for (const auto& kv : seconds_) {
        if (kv.second <= 0) continue;
        if (!out.empty()) out += ";";
        out += kv.first + "=" + std::to_string(kv.second);
    }
    kvSet("studySeconds", out);
    lastFlush_ = nowMs();
    dirty_ = false;
}

void StudyStore::start() {
    if (running_) return;
    running_ = true;
    carry_ = 0.0;
    lastFlush_ = nowMs();
}

void StudyStore::pause() {
    if (!running_) return;
    running_ = false;
    save();
}

void StudyStore::tick(double dtSeconds) {
    if (!running_ || dtSeconds <= 0) return;
    if (dtSeconds > (double)kMaxStepSeconds) dtSeconds = (double)kMaxStepSeconds;
    carry_ += dtSeconds;
    int whole = (int)carry_;
    if (whole <= 0) return;
    carry_ -= (double)whole;
    seconds_[daykey::today()] += whole;
    dirty_ = true;
}

void StudyStore::flushIfDue() {
    if (!running_ || !dirty_) return;
    if (nowMs() - lastFlush_ >= 15000ULL) save();
}

int StudyStore::secondsOf(const std::string& key) const {
    auto it = seconds_.find(key);
    return it == seconds_.end() ? 0 : it->second;
}

int StudyStore::totalSeconds() const {
    int sum = 0;
    for (const auto& kv : seconds_) sum += kv.second;
    return sum;
}

std::string StudyStore::format(int seconds) {
    if (seconds <= 0) return "0 分钟";
    if (seconds < 60) return "不到 1 分钟";
    int total = seconds / 60;
    int h = total / 60, m = total % 60;
    char buf[64];
    if (h == 0) { snprintf(buf, sizeof(buf), "%d 分钟", m); return buf; }
    if (m == 0) { snprintf(buf, sizeof(buf), "%d 小时", h); return buf; }
    snprintf(buf, sizeof(buf), "%d 小时 %d 分", h, m);
    return buf;
}

std::string StudyStore::compact(int seconds) {
    int minutes = seconds / 60;
    if (minutes <= 0) return "";
    char buf[32];
    if (minutes < 60) { snprintf(buf, sizeof(buf), "%dm", minutes); return buf; }
    double hours = minutes / 60.0;
    double rounded = (double)(int)(hours + 0.5);
    if (hours - rounded < 0.05 && rounded - hours < 0.05) {
        snprintf(buf, sizeof(buf), "%dh", (int)rounded);
        return buf;
    }
    snprintf(buf, sizeof(buf), "%.1fh", hours);
    return buf;
}

// ---------------------------------------------------------------- 提醒设置
void ReminderSettings::load() {
    cdEnabled = kvGetInt("cdRemindEnabled", 1) != 0;
    cdLead = kvGetInt("cdRemindLead", LEAD_7_DAYS);
    cdIntervalMinutes = clampCountdown(kvGetInt("cdRemindInterval", 1440));
    studyEnabled = kvGetInt("studyRemindEnabled", 1) != 0;
    studyIntervalMinutes = clampStudy(kvGetInt("studyRemindInterval", 15));
    if (cdLead < LEAD_UNLIMITED || cdLead > LEAD_SAME_DAY) cdLead = LEAD_7_DAYS;
}

void ReminderSettings::save() const {
    kvSetInt("cdRemindEnabled", cdEnabled ? 1 : 0);
    kvSetInt("cdRemindLead", cdLead);
    kvSetInt("cdRemindInterval", cdIntervalMinutes);
    kvSetInt("studyRemindEnabled", studyEnabled ? 1 : 0);
    kvSetInt("studyRemindInterval", studyIntervalMinutes);
}

int ReminderSettings::leadLimitDays() const {
    switch (cdLead) {
        case LEAD_30_DAYS: return 30;
        case LEAD_7_DAYS: return 7;
        case LEAD_SAME_DAY: return 0;
        default: return -1;
    }
}

bool ReminderSettings::inRange(int daysLeft) const {
    if (daysLeft < 0) return false;
    int limit = leadLimitDays();
    return limit < 0 ? true : daysLeft <= limit;
}

std::string ReminderSettings::rangeText() const {
    switch (cdLead) {
        case LEAD_UNLIMITED: return "不限制";
        case LEAD_30_DAYS: return "提前 30 天";
        case LEAD_SAME_DAY: return "仅当天";
        default: return "提前 7 天";
    }
}

std::string ReminderSettings::intervalText() const {
    if (cdIntervalMinutes == 1440) return "每天一次";
    return "每 " + intervalLabel(cdIntervalMinutes) + "一次";
}

bool ReminderSettings::isIntervalCustom() const {
    return !(cdIntervalMinutes == 30 || cdIntervalMinutes == 60 ||
             cdIntervalMinutes == 1440 || cdIntervalMinutes == 4320);
}

std::string ReminderSettings::studyIntervalText() const {
    return "每 " + std::to_string(studyIntervalMinutes) + " 分钟播报";
}

std::string ReminderSettings::intervalLabel(int minutes) {
    if (minutes >= 1440 && minutes % 1440 == 0) {
        int days = minutes / 1440;
        return days == 1 ? "每天" : "每 " + std::to_string(days) + " 天";
    }
    if (minutes >= 60 && minutes % 60 == 0) {
        int hours = minutes / 60;
        return hours == 1 ? "1 小时" : std::to_string(hours) + " 小时";
    }
    return std::to_string(minutes) + " 分钟";
}

std::string ReminderSettings::studyLabel(int minutes) {
    return std::to_string(minutes) + " 分钟";
}

int ReminderSettings::clampCountdown(int minutes) {
    if (minutes < 5) return 5;
    if (minutes > 43200) return 43200;
    return minutes;
}

int ReminderSettings::clampStudy(int minutes) {
    if (minutes < 1) return 1;
    if (minutes > 240) return 240;
    return minutes;
}
