import Foundation

enum LocalDateFormatting {
    static func string(
        from date: Date,
        format: String,
        calendar: Calendar
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    static func time(_ date: Date, calendar: Calendar) -> String {
        string(from: date, format: "HH:mm", calendar: calendar)
    }
}
