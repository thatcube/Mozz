# Mozz

Free forever open source music app for Plex and Jellyfin.

## Project direction

Mozz will support both **iOS** and **tvOS** as native Swift apps.

Keeping both apps in the same repository makes sense for this project:

- shared domain and playback logic can be reused
- feature parity across platforms is easier to maintain
- release/version management stays in one place

Planned structure:

- `/apps/ios` — native iOS app target
- `/apps/tvos` — native tvOS app target
- `/packages` — shared Swift packages used by both apps

Mozz may reuse ideas and infrastructure from Plozz where that improves delivery, while remaining a dedicated music-first app.

## License

This project is licensed under **GPL-3.0** with an additional **App Store Exception**. See `/LICENSE` for full terms.
