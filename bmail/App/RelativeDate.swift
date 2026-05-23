import Foundation

enum RelativeDate {
    /// Approximate the web client's relativeDate(): time-of-day for today,
    /// weekday for the last week, "MMM d" for this year, otherwise "yyyy-MM-dd".
    static func format(_ unixMs: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixMs) / 1000)
        let cal = Calendar.current
        let now = Date()
        if cal.isDateInToday(date) {
            return timeFormatter.string(from: date)
        }
        let days = cal.dateComponents([.day], from: date, to: now).day ?? 0
        if days >= 0 && days < 7 {
            return weekdayFormatter.string(from: date)
        }
        if cal.component(.year, from: date) == cal.component(.year, from: now) {
            return shortFormatter.string(from: date)
        }
        return longFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "h:mm a"
        return f
    }()
    private static let weekdayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
    private static let shortFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
