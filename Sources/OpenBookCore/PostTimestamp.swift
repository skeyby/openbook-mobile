import Foundation

/// Display policy only: the original API timestamp remains unchanged for pagination.
public enum PostTimestamp {
    public static func text(for date: Date, now: Date, locale: Locale = Locale(identifier: "it_IT"), timeZone: TimeZone = .current) -> String {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0, elapsed < 86_400 else {
            return date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone)
                .day().month().year().hour().minute())
        }
        guard elapsed >= 1 else { return "Adesso" }
        let components: DateComponents
        if elapsed < 60 {
            components = DateComponents(second: -Int(elapsed))
        } else if elapsed < 3_600 {
            components = DateComponents(minute: -Int(elapsed / 60))
        } else {
            components = DateComponents(hour: -Int(elapsed / 3_600))
        }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        formatter.dateTimeStyle = .numeric
        return formatter.localizedString(from: components)
    }

    /// Wake only when the displayed unit changes; stop once the date is absolute.
    public static func nextUpdate(for date: Date, after now: Date) -> Date? {
        let elapsed = now.timeIntervalSince(date)
        guard elapsed >= 0, elapsed < 86_400 else { return nil }
        let unit: TimeInterval = elapsed < 60 ? 1 : elapsed < 3_600 ? 60 : 3_600
        return date.addingTimeInterval((floor(elapsed / unit) + 1) * unit)
    }
}
