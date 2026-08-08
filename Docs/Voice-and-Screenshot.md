# Voice and screenshot input

## Controls and nesting

The bare-key controls work only while Atmosphere is visible and has an active
panel. They are based on the physical ANSI key codes, so they remain distinct
from the global `Command + backslash` overlay shortcut:

- bare backslash starts microphone recording;
- bare backslash again stops recording, transcribes, and submits; and
- bare backtick takes a silent screenshot and attaches it without submitting.

Those two bare-key events are reserved while the panel is visible. Atmosphere
consumes them, including key repeats, before they can reach the composer.

Input is one composer bundle rather than three separate modes. Typed text stays
editable. Each backtick press adds another screenshot, up to four. Voice can be
started before or after typing and before or after screenshots. When voice stops,
its transcript is appended to the current draft and Atmosphere submits the draft
plus all pending screenshots exactly once. If a screenshot is still in flight,
the voice submission waits until that capture succeeds or fails. No recorded
audio or no detected speech produces no submission.

Hiding Atmosphere, starting or clearing a conversation, and quitting invalidate
pending capture work and cancel microphone/transcription work. A late screenshot
completion is deleted rather than attached or sent.

## Permission indicators and recovery

The header shows live `Mic on/off` and `Screen on/off/restart` capsules. Granted
and ready states are green and informational. Missing states are orange buttons. For a first-use
microphone request, the Mic button presents the native macOS prompt. If macOS
has already recorded a denial, it opens the Microphone pane in System Settings.
The Screen button performs the public preflight/request sequence and, when
access is still unavailable, opens the Screen Recording pane. Permission errors
beside the composer provide the same direct actions.

macOS exposes no public per-pane opening API, so Atmosphere uses the current
`x-apple.systempreferences` Privacy & Security routes with the legacy route and
the System Settings app as fallbacks. Permission state itself always comes from
the public AVFoundation and Core Graphics APIs. Atmosphere refreshes state when
the overlay appears and when it becomes active. Screen Recording requires one
fresh process after the initial grant, so Atmosphere keeps an orange
`Screen restart` state and provides a clean one-click relaunch instead of
claiming capture is ready too early.

## Voice path and privacy

Atmosphere records mono, 16 kHz, 16-bit PCM WAV only after the user presses bare
backslash. The completed file is uploaded to Deepgram's pre-recorded speech API
with `nova-3-general` and smart formatting, then deleted whether the request
succeeds, fails, or is canceled. Atmosphere evaluates the same recording in a
strict order:

1. English, using `detect_language=en`;
2. Hindi, using `detect_language=hi`;
3. Hinglish, using Nova-3 code-switching with `language=multi`; and
4. Urdu, using `language=ur`.

The first two attempts must return their expected detected language with at
least `0.70` language confidence. Every attempt must contain substantive text
in a compatible writing system with at least `0.65` transcript confidence.
Empty, punctuation-only, mismatched, or low-confidence candidates advance to
the next attempt. If all four miss, the UI reports that no text was detected.
Authentication, quota, network, server, malformed-response, and cancellation
errors stop immediately instead of being disguised as an empty recording.

Deepgram has no separate `hinglish` language code; Nova-3's `multi` mode is its
supported English/Hindi code-switching path. Deepgram documents the authenticated
`POST /v1/listen` flow and raw-file body in its
[pre-recorded audio guide](https://developers.deepgram.com/docs/pre-recorded-audio)
and lists WAV among its
[supported audio formats](https://developers.deepgram.com/docs/supported-audio-formats).
Its [language detection guide](https://developers.deepgram.com/docs/language-detection)
documents restricted detection values and confidence. Its
[model and language table](https://developers.deepgram.com/docs/models-languages-overview/)
documents Nova-3's `multi` and Urdu support.

The Deepgram key is read from `~/.atmosphere/deepgram-api-key` only when a
transcription request is built. Atmosphere never calls Keychain. It requires a
mode `0700` directory and a current-user-owned, regular, non-symlink key file
with mode `0600`; the documented provisioning step also clears extended ACLs.
This plain-text choice prevents rebuild-time Keychain prompts. It protects
normal local-account separation, not processes or backups that already have
access as the current account. Temporary audio also lives in a mode `0700`
directory and each WAV is mode `0600`. A normal stop, hide, reset, or quit
removes it; launch cleanup also removes WAV files left by a crash or force-quit.

## Screenshot path and privacy

Atmosphere uses Apple's
[`SCScreenshotManager`](https://developer.apple.com/documentation/screencapturekit/scscreenshotmanager)
with an
[`SCContentFilter`](https://developer.apple.com/documentation/screencapturekit/sccontentfilter)
for the display containing the panel. The filter excludes Atmosphere's own
application/windows. Cursor and audio capture are disabled. Because this API
returns pixels directly instead of invoking the system screenshot UI, it does
not play the normal screenshot sound.

Screen Recording permission is required. Apple notes in its
[ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos)
that the app must be restarted after the first permission grant; Atmosphere
surfaces a `Restart Atmosphere` action after requesting access.

PNG files use a mode `0700` private directory and mode `0600` files under
`~/Library/Application Support/Atmosphere/Private Captures`. Pending and sent
screenshots in the current in-memory conversation remain only so they can be
previewed in the composer/history and sent as App Server `localImage` inputs.
Removing a pending attachment, starting or clearing the conversation, or
quitting deletes them, and every launch purges files left by an abnormal
termination.

This own-app exclusion applies only to screenshots Atmosphere itself creates.
It does not make the overlay unconditionally invisible to Zoom, Meet, OBS, or
other capture applications; see [Capture privacy on macOS](Capture-Privacy.md).
