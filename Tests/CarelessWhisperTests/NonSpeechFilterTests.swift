import XCTest
@testable import CarelessWhisper

final class NonSpeechFilterTests: XCTestCase {

    // MARK: - Structural patterns (brackets, parens, asterisks)

    func testBracketedTextIsFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("[wind]"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("[eerie music]"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("[birds chirping]"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("[BLANK_AUDIO]"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("[thunder rumbling]"))
    }

    func testParenthesizedTextIsFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("(wind)"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("(eerie music)"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("(silence)"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("(dramatic music playing)"))
    }

    func testAsteriskWrappedTextIsFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("*sighs*"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("*wind blowing*"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("*laughs*"))
    }

    func testMusicNoteSymbolsAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("♪ music ♪"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("♪♪♪"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("🎵 some tune 🎵"))
    }

    // MARK: - Known marker words

    func testEnvironmentalSoundsAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("wind"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("Wind."))
        XCTAssertTrue(AppState.isNonSpeechHallucination("thunder"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("rain"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("crickets"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("birds chirping"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("wind blowing"))
    }

    func testMusicDescriptionsAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("eerie music"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("Eerie music."))
        XCTAssertTrue(AppState.isNonSpeechHallucination("soft music"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("music playing"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("background music"))
    }

    func testHumanNonSpeechSoundsAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("coughing"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("breathing"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("sighs"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("laughter"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("applause"))
    }

    func testSilenceMarkersAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("silence"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("Silence."))
        XCTAssertTrue(AppState.isNonSpeechHallucination("no speech"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("blank audio"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("inaudible"))
    }

    func testCommonWhisperFillerIsFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination("Thank you."))
        XCTAssertTrue(AppState.isNonSpeechHallucination("thanks for watching"))
        XCTAssertTrue(AppState.isNonSpeechHallucination("Thanks for listening."))
    }

    // MARK: - Actual speech should NOT be filtered

    func testActualSpeechPassesThrough() {
        XCTAssertFalse(AppState.isNonSpeechHallucination("Hello world"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("Please fix the bug in the login page"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("git commit minus m fix typo"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("The wind is strong today"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("I love this music"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("Turn up the music please"))
        XCTAssertFalse(AppState.isNonSpeechHallucination("Thank you for your help with the code"))
    }

    func testEmptyAndWhitespaceAreFiltered() {
        XCTAssertTrue(AppState.isNonSpeechHallucination(""))
        XCTAssertTrue(AppState.isNonSpeechHallucination("   "))
        XCTAssertTrue(AppState.isNonSpeechHallucination("\n"))
    }
}
