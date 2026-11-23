# Privacy policy

Effective date: November 23, 2026

Product: Locked Gaze

Maintainer: albond

Contact: [albond.dev@proton.me](mailto:albond.dev@proton.me)

## Camera processing

Locked Gaze uses the camera you select to correct eye contact on your Mac.
Frames are processed locally and passed through temporary memory buffers to
the Locked Gaze virtual camera. The application does not record your camera
feed or upload frames for processing. It does not require an account and
does not include advertising, analytics, or a third-party telemetry service.

## Virtual camera output

Other applications that you allow to use the Locked Gaze virtual camera can
receive its output. Your video-call application may transmit or record that
video according to its own settings and privacy policy. Locked Gaze's local
processing does not prevent a receiving application from doing so.

## Browser extensions

On Macs whose management blocks the virtual camera, Locked Gaze can supply its
video to web meetings through its Safari extension or its Chrome extension and
helper. They are off until you turn them on. Frames travel only on your Mac,
from Locked Gaze to your browser, over a local system channel that checks that
both ends are Locked Gaze components; nothing is sent over the network by
Locked Gaze, the helper or the extensions. The browser sends Locked Gaze only
requests to start and stop.

The extensions run only on supported meeting sites (Google Meet, Microsoft
Teams, Zoom, Webex, Jitsi, Whereby, Slack, Discord and Preply) and on other
sites you turn on with the extension's toolbar button, after the browser asks
you to grant access to that site. There they add Locked Gaze Camera to the
site's camera list. The browser keeps the list of sites you turned on. A site
receives its video only after you allow that site to use your camera in the
browser, and the meeting service may then transmit or record it according to
its own settings and privacy policy.
The extensions do not read page content, collect browsing history or send data
to the maintainer.

To connect Google Chrome, Locked Gaze saves two items where you choose: a small
file in Chrome's settings folder that tells Chrome where the helper is, and the
extension folder. Locked Gaze remembers the folder's location to update it
after app updates.

## Permissions and local settings

Camera permission allows access to your selected camera. Camera Extension
approval enables the virtual camera to supply output to other applications.
You control these permissions in macOS System Settings.

The application stores your selected camera identifier, the selected mode when
it is Browser, whether this Mac blocks the virtual camera, and the location of a
saved Chrome extension folder in local preferences.
It also shares an activation-state flag locally with its Control Center
extension. These settings are not sent to the maintainer.

macOS may retain operational logs, such as extension errors or publisher
connection status. Locked Gaze does not intentionally include camera images
in these logs. System diagnostics and Apple's diagnostic sharing settings
are controlled separately by macOS.

## Links, support, and donations

Opening the GitHub link launches your browser. GitHub and any donation or
wallet service you choose have their own privacy practices. Cryptocurrency
transactions may be publicly visible on their network.

If you email the maintainer or submit a GitHub issue, the information you
choose to provide is used to respond and investigate the report. Public
issues are visible to others. Do not include private camera images, secrets,
or personal meeting information. Support correspondence is retained only
as needed to handle the request; contact the address above about deletion.

## Your choices

Deactivate Locked Gaze or quit it to stop its camera processing. Revoke
camera permission or disable its Camera Extension in System Settings to
remove the corresponding access. Turn off or remove the Locked Gaze browser
extensions in Safari or Chrome at any time. You may uninstall the application
at any time. Contact the maintainer for questions about this policy.

## Changes

This policy will be updated when the application's data practices change.
The effective date above identifies the current revision.
