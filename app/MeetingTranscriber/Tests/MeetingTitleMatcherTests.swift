@testable import MeetingTranscriber
import XCTest

final class MeetingTitleMatcherTests: XCTestCase {
    private let teams = MeetingTitleMatcher(pattern: .teams)

    func test_isIdleTitle_matchesTeamsIdleTabs() {
        XCTAssertTrue(teams.isIdleTitle("Calendar | Contoso | user@contoso.com | Microsoft Teams"))
        XCTAssertTrue(teams.isIdleTitle("Microsoft Teams"))
        XCTAssertTrue(teams.isIdleTitle("Chat | Contoso"))
        XCTAssertFalse(teams.isIdleTitle("Sprint Review | Microsoft Teams"))
        XCTAssertFalse(teams.isIdleTitle("Jane Doe | Microsoft Teams"))
    }

    func test_isIdleTitle_matchesBareTeamsTabTitles() {
        // Teams dropped the ` | Microsoft Teams` suffix (October 2026): the main
        // window now reads just the tab name.
        for tab in ["Calendar", "Chat", "Activity", "Teams", "Files", "Assignments", "Settings", "Calls", "People", "Notifications"] {
            XCTAssertTrue(teams.isIdleTitle(tab), tab)
        }
    }

    func test_isIdleTitle_keepsSuffixedTabFormsIdle() {
        for tab in ["Calendar", "Chat", "Activity", "Teams", "Files", "Assignments", "Settings", "Calls", "People", "Notifications"] {
            XCTAssertTrue(teams.isIdleTitle("\(tab) | Microsoft Teams"), tab)
        }
    }

    func test_isIdleTitle_doesNotMatchMeetingContainingTabWord() {
        XCTAssertFalse(teams.isIdleTitle("Calendar review"))
        XCTAssertFalse(teams.isIdleTitle("Team Chat sync"))
        XCTAssertFalse(teams.isIdleTitle("Settings review | Microsoft Teams"))
    }

    func test_selectWindowTitle_skipsBareCalendarTabAheadOfMeetingWindow() {
        for tab in ["Calendar", "Calls"] {
            let windows = [tab, "BOSS - Planning [USE THIS]"].map { title in
                ["kCGWindowOwnerName": "Microsoft Teams", "kCGWindowName": title] as [String: Any]
            }
            XCTAssertEqual(teams.selectWindowTitle(from: windows), "BOSS - Planning [USE THIS]", tab)
        }
    }

    func test_selectWindowTitle_returnsNilWhenOnlyBareTabWindows() {
        let windows = ["Calendar", "Chat"].map { title in
            ["kCGWindowOwnerName": "Microsoft Teams", "kCGWindowName": title] as [String: Any]
        }
        XCTAssertNil(teams.selectWindowTitle(from: windows))
    }

    func test_isMeetingTitle_matchesRealMeetingWindows() {
        XCTAssertTrue(teams.isMeetingTitle("Sprint Review | Microsoft Teams"))
        // The Calendar-tab title ALSO matches the meeting regex — this is exactly
        // why idle titles must be excluded *before* meeting classification.
        XCTAssertTrue(teams.isMeetingTitle("Calendar | Contoso | Microsoft Teams"))
        XCTAssertTrue(MeetingTitleMatcher(pattern: .zoom).isMeetingTitle("Zoom Meeting"))
        XCTAssertFalse(teams.isMeetingTitle("Home"))
        XCTAssertFalse(teams.isMeetingTitle(""))
    }

    func test_invalidRegexIsDroppedNotCrashed() {
        let bad = AppMeetingPattern(
            appName: "X", ownerNames: ["X"],
            meetingPatterns: ["[unterminated"], idlePatterns: ["(also bad"],
        )
        let matcher = MeetingTitleMatcher(pattern: bad)
        XCTAssertFalse(matcher.isMeetingTitle("anything"))
        XCTAssertFalse(matcher.isIdleTitle("anything"))
    }
}
