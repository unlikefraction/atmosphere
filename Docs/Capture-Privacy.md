# Capture privacy on macOS

## What Atmosphere can and cannot promise

Atmosphere asks AppKit for legacy window-content protection with
`NSWindow.sharingType = .none`. This is the same broad mechanism exposed by
Tauri's `contentProtected` option and used by Pluely's open-source macOS build.
It can still help with some older or cooperative capture paths, but it is not a
security boundary.

Apple now describes `NSWindow.SharingType.none` as a legacy value that macOS no
longer uses and says it should not be used as a way to omit content from
capture: [NSWindow.SharingType.none](https://developer.apple.com/documentation/appkit/nswindow/sharingtype-swift.enum/none).

Apple DTS has also stated that there is currently no public API by which a
normal macOS app can prevent its content from being captured:
[ScreenCaptureKit forum response](https://developer.apple.com/forums/thread/792152).

Therefore Atmosphere does **not** claim to be invisible in every screenshot,
recording, mirroring session, or screen share.

## Why ScreenCaptureKit does not solve this from the overlay

ScreenCaptureKit lets the *capturing application* create an
[`SCContentFilter`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
that excludes selected applications or windows. Likewise, the system sharing
picker has configuration for excluded window and bundle identifiers:
[`SCContentSharingPickerConfiguration`](https://developer.apple.com/documentation/screencapturekit/sccontentsharingpickerconfiguration).

Those choices belong to Zoom, Teams, OBS, QuickTime, a browser, or whichever
process performs the capture. Atmosphere cannot alter another process's filter
or force that process to cooperate.

## Practical privacy rules

1. Share a specific window or application, not an entire display. A filtered
   window share normally contains only the selected content and therefore does
   not include an unrelated floating panel.
2. Press `⌘ + \` or `Esc` before switching to a full-display share.
3. Use **Clear and hide** from the overlay menu when the visible transcript is
   sensitive.
4. Assume full-display capture, display mirroring, remote desktop, privileged
   capture software, and a camera pointed at the monitor can see the overlay.
5. Test the exact macOS and conferencing-app versions used in production.

## Suggested test matrix

Test both a single-window share and a whole-display share with:

- macOS Screenshot and QuickTime Player;
- Zoom with and without the macOS system sharing picker;
- Google Meet in the supported browser;
- Microsoft Teams;
- OBS;
- AirPlay/display mirroring; and
- any employer-managed recording or remote-support software.

Repeat the matrix after major macOS or conferencing-app updates. Passing one
version is useful compatibility evidence, not a universal guarantee.

## Window behavior sources

Atmosphere uses an `NSPanel` at the floating window level, runs as an agent app,
and joins Spaces/full-screen applications. Relevant Apple documentation:

- [`canJoinAllApplications`](https://developer.apple.com/documentation/appkit/nswindow/collectionbehavior-swift.struct/canjoinallapplications)
- [`nonactivatingPanel`](https://developer.apple.com/documentation/appkit/nswindow/stylemask-swift.struct/nonactivatingpanel)
- [`LSUIElement`](https://developer.apple.com/documentation/bundleresources/information-property-list/lsuielement)
- [`CGShieldingWindowLevel`](https://developer.apple.com/documentation/coregraphics/cgshieldingwindowlevel%28%29), which Apple discourages for ordinary window placement and which does not provide capture privacy
