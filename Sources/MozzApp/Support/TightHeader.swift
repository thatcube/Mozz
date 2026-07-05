import SwiftUI

/// A tight, scroll-away screen header: the large title with the Settings avatar
/// aligned to its trailing edge on one line, sitting right under the status bar
/// like Apple Music. Placed as the first item in a screen's scroll content.
///
/// We use this instead of the native SwiftUI large title because the native
/// large title's top inset is significantly larger than Apple Music's (it's a
/// UIKit app with a custom-tightened bar) and SwiftUI exposes no way to reduce
/// it — negative offsets just clip the text. A custom header in the scroll
/// content sits exactly where we want and keeps the title position identical on
/// every tab. Screens using this hide the navigation bar via `hideNavigationBar()`.
struct TightHeader: View {
    let title: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.largeTitle.bold())
            Spacer(minLength: 12)
            SettingsAvatar().alignmentGuide(.firstTextBaseline) { $0[.bottom] }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 4)
    }
}
