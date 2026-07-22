# Changelog

Notable changes to ASOP File Browser are recorded here. The format is inspired
by [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- Open Phone Control for multiple connected devices at once, with a separate
  battery and shortcut bar for each device window.
- Keep Phone Control from waking devices unless enabled, add per-device stream
  options, and allow each control bar to be repositioned.
- Choose one or more connected displays for screenshots and recordings. Captures
  from multiple devices are combined side by side with black padding.
- Show only supported actions in each Phone Control bar, with direct screenshot
  and recording buttons, battery status, a clear recording indicator, and a
  device-actions menu that can wake the display.

### Changed

- Opening the app again brings its existing window forward instead of starting
  another copy.
- Treat a slow device response as a temporary command failure instead of opening
  Phone Tools setup.
- Wake each selected display immediately before screenshots and recordings begin.
- Remove the short capture warmup from combined recordings so playback starts on content.
- Keep a display's single static frame visible for the rest of a combined
  recording instead of failing the side-by-side export.
- Updated the optional managed Phone Tools download to scrcpy 4.1.
- Added separate Apple silicon and Intel downloads alongside the universal Mac app.

## [1.0.0] - 2026-07-17

### Added

- Browse, preview, organize, and transfer Android files from a Mac.
- Drag and drop between the phone, Finder, and connected devices.
- File Transfer Mode for everyday USB transfers without Developer Options.
- USB and Wi-Fi debugging with Search Everywhere, recoverable Trash, storage
  details, and app management.
- Phone screenshots, screen recording, and phone control.
- Transfer progress, conflict handling, Quick Look, thumbnails, and preview
  cache controls.
- Signed and notarized DMG releases with a branded mounted-volume icon.
- Guarded release automation with build, test, signing, notarization, and launch
  checks before publication.

[Unreleased]: https://github.com/ababilinski/asop-file-browser/compare/1.0.0...HEAD
[1.0.0]: https://github.com/ababilinski/asop-file-browser/releases/tag/1.0.0
