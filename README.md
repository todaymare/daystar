# Daystar

Daystar is a native macOS menu bar app that turns NASA's Astronomy Picture of the Day into your desktop wallpaper. Version 2 brings a searchable library, real download feedback, and reliable wallpaper navigation.

## Features

- Fetch today's APOD or explore a rotating archive.
- Browse a searchable Recents/Favorites library with previews, image credits, cache status, and the current wallpaper marked.
- Reapply cached images offline and move backward/forward through wallpaper history.
- Follow actual download progress, cancel an update, and see completion or an actionable error.
- Keep track of background work with a twinkling menu-bar star; Reduce Motion disables the animation.
- Choose wallpaper presentation: fill, fit, center, or stretch.
- Handle video and other non-image APODs according to your preference.
- Update automatically on an hourly, three-hour, six-hour, twelve-hour, or daily schedule.
- Apply the wallpaper across every connected display.
- Optionally launch at login.
- Read full APOD explanations and set the displayed image directly from its detail window.
- Configure an optional NASA API key in Settings; no Daystar account is required.

## Using Daystar

Open Daystar, choose a wallpaper source in the welcome window, and select **Start Daystar**. The star in the menu bar contains wallpaper actions, source and schedule controls, the library, and settings.

- **Set Wallpaper Now** reapplies the current APOD, downloading it if necessary. **Next Wallpaper** follows forward history or fetches another entry from your selected source.
- Manual menu-bar actions open a small activity window with download progress and **Cancel**. Closing that window does not cancel the update.
- **Previous Wallpaper** is available when there is an earlier history entry. Applying images from the library adds them to history; navigating existing history does not create duplicate navigation events.
- Search the library by title or date, switch between Recents and Favorites, or open an image's details.
- Automatic updates run only while Daystar is open. Enable **Launch at Login** to start Daystar when you sign in.
- Open the app again from Finder to bring up the library. In Daystar windows, **⌘L** opens the library, **⌘,** opens settings, and **⌘Q** quits.

Only one wallpaper update runs at a time. Conflicting controls are disabled while an update is active; failures and cancellation preserve the last successfully applied wallpaper.

## Requirements

- macOS 13 or later.
- Swift 6 or Xcode 16 or later to build from source.
- Network access to the NASA APOD API and the APOD media URL.

The app uses NASA's `DEMO_KEY` by default. Add a personal key in **Settings → App & NASA → NASA API key**, then choose **Save Key**. An empty field or **Reset to DEMO_KEY** restores the built-in key. Saving a key applies it to subsequent requests; it does not validate the key or start a download.

## Build from source

```sh
git clone https://github.com/todaymare/daystar.git
cd daystar
swift test
./Scripts/build-app.sh
open "build/Daystar.app"
```

The build script creates an unsigned application bundle at `build/Daystar.app`, including the Daystar icon. Version values can be supplied for local or CI builds:

```sh
VERSION=2.0.1 BUILD_NUMBER=42 ./Scripts/build-app.sh
```

Unsigned builds may require approval in **System Settings → Privacy & Security** the first time they are opened.

## Data and privacy

APOD metadata, display history, favorites, and downloaded images are stored locally under:

```text
~/Library/Application Support/APOD Wallpaper/
```

Daystar deliberately retains the original storage directory, preference keys, and bundle identifier so existing APOD Wallpaper favorites, history, and settings remain available. The public application and executable are named Daystar.

**Clear Downloaded Image Cache** asks for confirmation and removes only cached images, not favorites, history, or settings. Missing images are downloaded again when selected.

The app sends requests to NASA's APOD API and the image URLs returned by that API. It does not include analytics or a remote account system.

The optional NASA key is stored in local macOS preferences. Daystar's settings do not send it anywhere except NASA API requests.

## Version 2.0

- Renamed the application and executable to Daystar; added a custom app icon.
- Fixed Recents' row-constraint crash and viewport-pinned scrolling layout.
- Added searchable Recents/Favorites, cached previews, current-wallpaper badges, synchronized favorite actions, and richer details.
- Unified refresh, history navigation, and reapplication under one cancellable operation lifecycle.
- Added byte-based download progress, persistent activity feedback, and a Reduce Motion-aware menu-bar animation.
- Preserved the current selection and cache on failed application or canceled downloads; corrected Recents ordering during history navigation.
- Added NASA-key configuration, truthful cache/login error feedback, safer cache confirmation, and native window keyboard shortcuts.

## Development

Run the test suite with:

```sh
swift test
```

GitHub Actions runs the tests and produces an unsigned app bundle for pushes and pull requests.

## License

This project is available under the [MIT License](LICENSE).
