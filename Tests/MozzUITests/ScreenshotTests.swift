import XCTest

/// Captures App Store screenshots from the running app.
///
/// The screenshots have to come from the real UI: Mozz builds the Now Playing
/// backdrop out of the artwork's own colours, so a composited mock-up would show
/// a gradient the app never produces. The catalogue comes from a fixture
/// directory handed over in `MOZZ_SCREENSHOT_LIBRARY` (see ``ScreenshotLibrary``),
/// which means no server, no login and no sync — the same shots every run.
///
/// Each step is best-effort on purpose. A screenshot run that dies halfway
/// leaves you with nothing and no clue which step broke; instead every capture
/// is attempted, and the ones that couldn't find their control are reported at
/// the end so the failure is obvious but the rest of the set still lands.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!
    private var missed: [String] = []

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
        if let fixture = ProcessInfo.processInfo.environment["MOZZ_SCREENSHOT_LIBRARY"] {
            app.launchEnvironment["MOZZ_SCREENSHOT_LIBRARY"] = fixture
        }
        app.launch()
    }

    func testCaptureScreenshots() {
        // The fixture is seeded during launch, so wait for content rather than a
        // fixed sleep — a cold simulator is far slower than a warm one.
        let library = app.buttons["Library"]
        if !library.waitForExistence(timeout: 60) {
            // Capture whatever *is* on screen; a bare assertion failure here
            // gives no clue whether the app crashed, stalled, or simply fell
            // through to onboarding because the fixture wasn't found.
            capture("00-unexpected-state")
            XCTFail("app never reached the main UI (fixture: "
                    + (ProcessInfo.processInfo.environment["MOZZ_SCREENSHOT_LIBRARY"]
                       ?? "<unset>") + ")")
            return
        }

        capture("01-home")

        tap(library, "Library tab")
        capture("02-library")
        dumpHierarchy("90-library-hierarchy")

        // Go through the Albums row rather than the "Recently Added" carousel:
        // a named list row is a far more stable target than the first button
        // inside a horizontally scrolling shelf.
        let albums = app.buttons["Albums"].firstMatch
        if albums.waitForExistence(timeout: 10) {
            tap(albums, "Albums row")
        } else if app.staticTexts["Albums"].waitForExistence(timeout: 5) {
            tap(app.staticTexts["Albums"].firstMatch, "Albums row")
        } else {
            missed.append("Albums row")
        }
        capture("03-albums")
        dumpHierarchy("91-albums-hierarchy")

        // Start playback from the grid, before opening an album. The fixture's
        // albums are one track each, so playing one leaves nothing up next and
        // the queue shoots empty; the grid's Play enqueues every album. Doing it
        // first also avoids navigating back — the album screen's own back button
        // carries no identifier, and matching it by label hits the one behind it.
        let play = app.buttons["Play"].firstMatch
        if play.waitForExistence(timeout: 10) {
            tap(play, "play")
        } else {
            missed.append("play")
        }

        // First album in the grid. Album cards are labelled "Title, Year", which
        // distinguishes them from the Play/Shuffle bar sharing the same scroll
        // view without hard-coding any album's name.
        let albumCard = app.buttons.matching(
            NSPredicate(format: "label MATCHES %@", ".*, [0-9]{4}")).firstMatch
        if albumCard.waitForExistence(timeout: 10) {
            tap(albumCard, "first album")
            capture("04-album")
            dumpHierarchy("92-album-hierarchy")
        } else {
            missed.append("first album")
        }

        expandPlayer()
        // Shoot the player and the lyrics part-way through the track. At seven
        // seconds in the scrubber is a stub and the lyrics pane has barely
        // started, so both read as "nothing is happening".
        waitUntilElapsed(atLeast: 45)
        capture("05-now-playing")
        dumpHierarchy("93-player-hierarchy")

        let lyrics = app.buttons["Lyrics"].firstMatch
        if lyrics.waitForExistence(timeout: 10) {
            tap(lyrics, "lyrics")
            // The controls fade out after a few seconds and the lyrics take the
            // whole screen; that full-bleed state is the one worth shipping.
            sleep(7)
            capture("06-lyrics")
        } else {
            missed.append("lyrics")
        }

        // Bring the controls back — after the fade above, the Lyrics/Queue bar is
        // gone, so going straight for Queue would find an unhittable button.
        app.tap()
        sleep(2)

        let queue = app.buttons["Queue"].firstMatch
        if queue.waitForExistence(timeout: 5) {
            tap(queue, "queue")
            capture("07-queue")
        } else {
            missed.append("queue")
        }

        if !missed.isEmpty {
            XCTFail("could not reach: \(missed.joined(separator: ", "))")
        }
    }

    // MARK: Helpers

    private func tap(_ element: XCUIElement, _ name: String) {
        guard element.exists else {
            missed.append(name)
            return
        }
        if element.isHittable {
            element.tap()
        } else {
            // SwiftUI reports `isHittable == false` for plenty of genuinely
            // tappable controls — anything sitting under a material/glass overlay,
            // or freshly laid out inside a ScrollView. Tapping the centre of the
            // element's own frame gets the shot instead of losing the rest of the
            // run to a bad hit-test.
            let frame = element.frame
            guard frame.width > 0, frame.height > 0 else {
                missed.append(name)
                return
            }
            element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        }
        // Let the transition settle; SwiftUI animations are not instant and a
        // screenshot taken mid-animation is unusable.
        sleep(2)
    }

    /// Grow the mini player into the full Now Playing screen.
    private func expandPlayer() {
        // Target the island's own tap region by identifier. Matching on the
        // "<title>, <artist>" label instead lands on either an album card or the
        // *expanded* player's title block, which is mounted off-screen below the
        // window while the player is docked — tapping that goes nowhere.
        // `app.buttons[...]`, not a `descendants(matching: .any)` scan: the latter
        // walks the entire tree for every evaluation, and on this screen it was
        // slow enough to blow its own timeout and starve the queries after it.
        // The island carries `.isButton`, so it surfaces as a button.
        let bar = app.buttons["mini-player"]
        guard bar.waitForExistence(timeout: 10) else {
            missed.append("mini player")
            return
        }
        tap(bar, "mini player")
        sleep(2)
    }

    /// Wait until the player's elapsed readout passes `seconds`.
    ///
    /// Polling the label the app itself renders beats sleeping a fixed amount:
    /// the run's own timing drifts with simulator speed, and the whole point is
    /// to land the shot at a known position in the track.
    private func waitUntilElapsed(atLeast seconds: Int) {
        let elapsed = app.staticTexts.matching(
            NSPredicate(format: "label MATCHES %@", "[0-9]+:[0-9]{2}")).firstMatch
        let deadline = Date().addingTimeInterval(Double(seconds) + 30)
        while Date() < deadline {
            guard elapsed.exists else { break }
            let parts = elapsed.label.split(separator: ":")
            if parts.count == 2, let m = Int(parts[0]), let s = Int(parts[1]),
               m * 60 + s >= seconds { return }
            usleep(500_000)
        }
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    /// Attach the element tree. Element queries are the fragile part of a
    /// screenshot test, and without the tree a failure only says "not found"
    /// — which turns every fix into another ten-minute guess.
    private func dumpHierarchy(_ name: String) {
        let dump = XCTAttachment(string: app.debugDescription)
        dump.name = name
        dump.lifetime = .keepAlways
        add(dump)
    }
}
