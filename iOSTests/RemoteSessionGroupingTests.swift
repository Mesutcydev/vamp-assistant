import Foundation
import XCTest
@testable import BeetCodeRemoteIOS

@MainActor
final class RemoteSessionGroupingTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func session(_ title: String, at date: Date) -> RemoteSessionSummary {
        RemoteSessionSummary(
            id: UUID(),
            title: title,
            workspace: "vamp-assistant",
            workspacePath: "/Users/me/vamp-assistant",
            mode: "code",
            messageCount: 3,
            updatedAt: date.timeIntervalSince1970,
            isRunning: false,
            phase: "idle",
            queueState: nil)
    }

    /// Noon, so "yesterday" and "earlier" cannot drift across a day boundary
    /// because of the hour the test happens to run.
    private var now: Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: 5, hour: 12))!
    }

    func testGroupsByDayAndKeepsOrder() {
        let sessions = [
            session("running now", at: now.addingTimeInterval(-60)),
            session("this morning", at: now.addingTimeInterval(-5 * 3600)),
            session("yesterday", at: now.addingTimeInterval(-26 * 3600)),
            session("last week", at: now.addingTimeInterval(-8 * 24 * 3600)),
        ]
        let sections = SessionDaySection.group(sessions, calendar: calendar, now: now)
        XCTAssertEqual(sections.map(\.id), ["today", "yesterday", "earlier"])
        XCTAssertEqual(sections[0].sessions.map(\.title), ["running now", "this morning"])
        XCTAssertEqual(sections[1].sessions.map(\.title), ["yesterday"])
        XCTAssertEqual(sections[2].sessions.map(\.title), ["last week"])
    }

    /// An empty bucket must not render as an empty section header.
    func testEmptyBucketsAreDropped() {
        let sections = SessionDaySection.group(
            [session("old", at: now.addingTimeInterval(-30 * 24 * 3600))],
            calendar: calendar,
            now: now)
        XCTAssertEqual(sections.map(\.id), ["earlier"])
    }

    func testNoSessionsProducesNoSections() {
        XCTAssertTrue(SessionDaySection.group([], calendar: calendar, now: now).isEmpty)
    }

    /// Just after midnight, the session from twenty minutes ago is still
    /// "Today" and the one from two hours ago is "Yesterday" — the case a
    /// naive 24-hour window gets wrong.
    func testDayBoundaryUsesCalendarDaysNotElapsedHours() {
        let justAfterMidnight = calendar.date(
            from: DateComponents(year: 2026, month: 9, day: 5, hour: 0, minute: 20))!
        let sections = SessionDaySection.group(
            [
                session("after midnight", at: justAfterMidnight.addingTimeInterval(-10 * 60)),
                session("before midnight", at: justAfterMidnight.addingTimeInterval(-2 * 3600)),
            ],
            calendar: calendar,
            now: justAfterMidnight)
        XCTAssertEqual(sections.map(\.id), ["today", "yesterday"])
        XCTAssertEqual(sections[0].sessions.map(\.title), ["after midnight"])
        XCTAssertEqual(sections[1].sessions.map(\.title), ["before midnight"])
    }
}
