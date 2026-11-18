import Foundation

/// Schedules in plain words (docs/scheduler.md): the simple pickers, the Hermes schedule each one
/// makes, reading a Hermes schedule back into a picker, and describing any schedule for people.
public enum ScheduleWords {
    /// The simple pickers.
    public enum Choice: Equatable {
        /// Every N minutes (shown as hours when it divides evenly).
        case every(minutes: Int)
        case daily(hour: Int, minute: Int)
        case weekdays(hour: Int, minute: Int)
        /// Chosen days of the week (0 = Sunday … 6 = Saturday).
        case days(Set<Int>, hour: Int, minute: Int)
        /// A day of the month (1–28 keeps every month).
        case monthly(day: Int, hour: Int, minute: Int)
        case once(Date)

        /// What Hermes is given.
        public func hermesSchedule(calendar: Calendar = .current) -> String {
            switch self {
            case .every(let minutes):
                return minutes % 60 == 0 ? "every \(minutes / 60)h" : "every \(minutes)m"
            case .daily(let h, let m):
                return "\(m) \(h) * * *"
            case .weekdays(let h, let m):
                return "\(m) \(h) * * 1-5"
            case .days(let days, let h, let m):
                let list = days.isEmpty ? "*" : days.sorted().map(String.init).joined(separator: ",")
                return "\(m) \(h) * * \(list)"
            case .monthly(let day, let h, let m):
                return "\(m) \(h) \(day) * *"
            case .once(let date):
                // Hermes reads a time without an offset on its own clock.
                let c = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                return String(format: "%04d-%02d-%02dT%02d:%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0, c.hour ?? 0, c.minute ?? 0)
            }
        }
    }

    /// A job's schedule as a picker, when it's one of the simple shapes (else edit it as words).
    public static func choice(for when: ScheduleWhen) -> Choice? {
        switch when.kind {
        case "interval":
            return when.minutes.map { .every(minutes: $0) }
        case "once":
            return when.run_at.flatMap(date(from:)).map { .once($0) }
        case "cron":
            guard let expr = when.expr, let cron = Cron(expr) else { return nil }
            guard cron.month == "*", let minute = Int(cron.minute), let hour = Int(cron.hour) else { return nil }
            if cron.dayOfMonth == "*" {
                if cron.dayOfWeek == "*" { return .daily(hour: hour, minute: minute) }
                if cron.dayOfWeek == "1-5" { return .weekdays(hour: hour, minute: minute) }
                if let days = cron.weekdays { return .days(days, hour: hour, minute: minute) }
            } else if cron.dayOfWeek == "*", let day = Int(cron.dayOfMonth) {
                return .monthly(day: day, hour: hour, minute: minute)
            }
            return nil
        default:
            return nil
        }
    }

    /// The words a schedule is edited as ("every 2h", "0 9 * * 1-5", "2026-12-01T09:00").
    public static func text(for when: ScheduleWhen) -> String {
        switch when.kind {
        case "interval": return when.minutes.map { Choice.every(minutes: $0).hermesSchedule() } ?? when.display
        case "cron": return when.expr ?? when.display
        case "once": return when.run_at.flatMap(date(from:)).map { Choice.once($0).hermesSchedule() } ?? when.display
        default: return when.display
        }
    }

    /// "Every 2 hours", "Weekdays at 9:00", "Mondays and Thursdays at 8:30", "Once, 1 Dec at 9:00".
    public static func describe(_ when: ScheduleWhen, calendar: Calendar = .current, locale: Locale = .current) -> String {
        if let choice = choice(for: when) { return describe(choice, calendar: calendar, locale: locale) }
        return when.display.prefix(1).uppercased() + when.display.dropFirst()
    }

    public static func describe(_ choice: Choice, calendar: Calendar = .current, locale: Locale = .current) -> String {
        switch choice {
        case .every(let minutes):
            if minutes % 60 == 0 {
                let h = minutes / 60
                return h == 1 ? "Every hour" : (h % 24 == 0 ? (h == 24 ? "Every day" : "Every \(h / 24) days") : "Every \(h) hours")
            }
            return minutes == 1 ? "Every minute" : "Every \(minutes) minutes"
        case .daily(let h, let m):
            return "Every day at \(clock(h, m, calendar: calendar, locale: locale))"
        case .weekdays(let h, let m):
            return "Weekdays at \(clock(h, m, calendar: calendar, locale: locale))"
        case .days(let days, let h, let m):
            let names = days.sorted().map { dayName($0, plural: true, calendar: calendar, locale: locale) }
            let list = ListFormatter.localizedString(byJoining: names)
            return "\(list.isEmpty ? "Never" : list) at \(clock(h, m, calendar: calendar, locale: locale))"
        case .monthly(let day, let h, let m):
            return "Monthly on the \(ordinal(day, locale: locale)) at \(clock(h, m, calendar: calendar, locale: locale))"
        case .once(let date):
            return "Once, " + moment(date)
        }
    }

    /// "Wed, Nov 18 at 9:00 AM" (with the year when it isn't this year).
    public static func moment(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()
        if calendar.component(.year, from: date) != calendar.component(.year, from: now) { style = style.year() }
        return date.formatted(style)
    }

    /// "in 11 hours", or "due now" for a time that has come (a run waiting for the scheduler).
    public static func upcoming(_ date: Date, now: Date = .now) -> String {
        date <= now.addingTimeInterval(30) ? "due now" : date.formatted(.relative(presentation: .named))
    }

    /// The next few times a job runs: Hermes' next run, then on from it.
    public static func nextTimes(_ when: ScheduleWhen, first: Date?, preview: [Date], count: Int = 3) -> [Date] {
        guard let first else { return Array(preview.prefix(count)) }
        if when.kind == "once" { return [first] }
        if when.kind == "interval", let minutes = when.minutes, minutes > 0 {
            return (0..<count).map { first.addingTimeInterval(Double($0 * minutes * 60)) }
        }
        return Array(([first] + preview.filter { $0 > first.addingTimeInterval(30) }).prefix(count))
    }

    /// Where a job's results go, in words.
    public static func destination(_ deliver: String) -> String {
        let platform = deliver.split(separator: ":").first.map(String.init) ?? deliver
        switch platform {
        case "lekora": return "Lekora chat"
        case "local", "": return "Kept on the instance"
        case "origin": return "Where it was made"
        case "telegram": return "Telegram"
        case "whatsapp": return "WhatsApp"
        case "imessage": return "iMessage"
        case "sms": return "SMS"
        default: return platform.prefix(1).uppercased() + platform.dropFirst()
        }
    }

    // MARK: - Helpers

    static func clock(_ hour: Int, _ minute: Int, calendar: Calendar, locale: Locale) -> String {
        var c = DateComponents()
        c.hour = hour
        c.minute = minute
        guard let date = calendar.date(from: c) else { return String(format: "%d:%02d", hour, minute) }
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.locale = locale
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    static func dayName(_ day: Int, plural: Bool, calendar: Calendar, locale: Locale) -> String {
        var cal = calendar
        cal.locale = locale
        let names = cal.weekdaySymbols
        let name = names[((day % 7) + 7) % 7]
        return plural ? name + "s" : name
    }

    static func ordinal(_ n: Int, locale: Locale) -> String {
        let f = NumberFormatter()
        f.numberStyle = .ordinal
        f.locale = locale
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    /// Hermes' times (ISO 8601, with an offset, maybe fractional seconds).
    public static func date(from text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: text) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let d = plain.date(from: text) { return d }
        // No offset: the phone's own clock.
        let local = DateFormatter()
        local.locale = Locale(identifier: "en_US_POSIX")
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm"] {
            local.dateFormat = format
            if let d = local.date(from: text) { return d }
        }
        return nil
    }

    /// The five fields of a cron expression.
    struct Cron {
        let minute, hour, dayOfMonth, month, dayOfWeek: String

        init?(_ expr: String) {
            let parts = expr.split(separator: " ").map(String.init)
            guard parts.count == 5 else { return nil }
            (minute, hour, dayOfMonth, month, dayOfWeek) = (parts[0], parts[1], parts[2], parts[3], parts[4])
        }

        /// "1,3,5" or a single day (7 = Sunday too).
        var weekdays: Set<Int>? {
            let items = dayOfWeek.split(separator: ",").map { Int($0) }
            guard !items.isEmpty, items.allSatisfy({ $0 != nil && (0...7).contains($0!) }) else { return nil }
            return Set(items.compactMap { $0.map { $0 % 7 } })
        }
    }
}
