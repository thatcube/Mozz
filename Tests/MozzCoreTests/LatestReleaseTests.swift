import Testing
@testable import MozzCore

@Suite("Latest release ordering")
struct LatestReleaseTests {
    private func r(_ year: Int?, _ addedAt: Double? = nil, _ title: String = "x") -> ReleaseRecency {
        ReleaseRecency(year: year, addedAt: addedAt, title: title)
    }

    @Test("A later year wins")
    func laterYearWins() {
        #expect(LatestRelease.isNewer(r(2024), than: r(2019)))
        #expect(!LatestRelease.isNewer(r(2019), than: r(2024)))
    }

    @Test("A dated release outranks an undated one, in both directions")
    func datedBeatsUndated() {
        #expect(LatestRelease.isNewer(r(1998), than: r(nil)))
        #expect(!LatestRelease.isNewer(r(nil), than: r(1998)))
    }

    @Test("Same year falls through to when the library saw it")
    func sameYearUsesAddedAt() {
        #expect(LatestRelease.isNewer(r(2024, 200), than: r(2024, 100)))
        #expect(!LatestRelease.isNewer(r(2024, 100), than: r(2024, 200)))
    }

    @Test("With neither year nor date the title decides, so the order is stable")
    func fallsBackToTitle() {
        #expect(LatestRelease.isNewer(r(nil, nil, "Aaa"), than: r(nil, nil, "Bbb")))
        #expect(!LatestRelease.isNewer(r(nil, nil, "Bbb"), than: r(nil, nil, "Aaa")))
    }

    @Test("Picks the newest from a list")
    func picksNewest() {
        let releases = [r(2019, nil, "old"), r(2026, nil, "new"), r(2022, nil, "middle")]
        #expect(LatestRelease.newestIndex(releases) == 1)
    }

    @Test("An empty list has no newest release")
    func emptyHasNone() {
        #expect(LatestRelease.newestIndex([]) == nil)
    }

    @Test("A discography with no years at all still has a stable answer")
    func undatedDiscographyIsStable() {
        // The case that actually happens: a self-hosted server returns a whole
        // artist with no year on anything. The answer must not depend on the
        // order the rows arrived in, or two clients disagree.
        let a = [r(nil, nil, "Bbb"), r(nil, nil, "Aaa"), r(nil, nil, "Ccc")]
        let b = [r(nil, nil, "Ccc"), r(nil, nil, "Bbb"), r(nil, nil, "Aaa")]
        #expect(a[LatestRelease.newestIndex(a)!].title == "Aaa")
        #expect(b[LatestRelease.newestIndex(b)!].title == "Aaa")
    }
}
