import Foundation
import Testing
@testable import OpenBookCore

@Suite struct PostTimestampTests {
    private let published = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func relativeUnitsUseCompletedSecondsMinutesAndHours() {
        for (age, expected) in [(0.5, "Adesso"), (1, "1 secondo fa"), (50, "50 secondi fa"),
                                (59.9, "59 secondi fa"), (60, "1 minuto fa"), (1_200, "20 minuti fa"),
                                (3_599.9, "59 minuti fa"), (3_600, "1 ora fa"),
                                (28_800, "8 ore fa"), (86_399.9, "23 ore fa")] {
            #expect(PostTimestamp.text(for: published, now: published.addingTimeInterval(age)) == expected)
        }
    }

    @Test func exactly24HoursOlderAndFutureDatesUseAbsoluteLocalDate() {
        let zone = TimeZone(secondsFromGMT: 7_200)!
        let expected = published.formatted(Date.FormatStyle(locale: Locale(identifier: "it_IT"), timeZone: zone)
            .day().month().year().hour().minute())
        for age in [TimeInterval(-60), 86_400, 200_000] {
            #expect(PostTimestamp.text(for: published, now: published.addingTimeInterval(age), timeZone: zone) == expected)
            #expect(PostTimestamp.nextUpdate(for: published, after: published.addingTimeInterval(age)) == nil)
        }
        #expect(PostTimestamp.text(for: published, now: published.addingTimeInterval(86_400), timeZone: .gmt) != expected)
    }

    @Test func updateScheduleAlignsToUnitChangesAnd24HourBoundary() {
        for (age, nextAge) in [(0.2, 1.0), (59.9, 60), (60, 120), (1_201, 1_260),
                               (3_599, 3_600), (3_600, 7_200), (86_399, 86_400)] {
            #expect(PostTimestamp.nextUpdate(for: published, after: published.addingTimeInterval(age)) == published.addingTimeInterval(nextAge))
        }
    }
}
