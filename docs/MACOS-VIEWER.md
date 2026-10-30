# Sill Viewer for macOS

This fork adds a native macOS client: one Mac runs the existing Sill host,
and another runs **Sill Viewer** to view and control it. The viewer does not
replace the menu bar host app. macOS 14+; build with Xcode selected as the
active developer directory. No third-party dependencies.

## Build and launch

```sh
cd ~/projects/sill
Scripts/make-viewer-app.sh --open
```

The local build is `.build/Sill Viewer.app`. The script uses an available Apple Development identity, with ad hoc signing
as a fallback. Override it with `SILL_VIEWER_SIGN_IDENTITY` if needed. This is
a development build, not a notarized distribution. Stable signing keeps
Keychain access consistent across rebuilds. The app and CLI keep separate
Keychain identities, so command-line checks cannot claim the app's key.
The app shows its window before loading credentials to keep Keychain waits
visible.

To build a viewer-only ZIP for the current Mac:

```sh
Scripts/package-macos.sh
```

The result is `.build/Sill-Viewer-macOS.zip`, with `Sill Viewer.app`, the license
and Korean setup instructions. Keep the official host installed on the remote Mac.
The default build targets the current Mac architecture (Apple silicon here).

## Connect two Macs

1. On the **host Mac**, install and open the upstream Sill app. Grant Screen
   Recording, Accessibility, and Local Network when requested. Keep it awake
   and logged in. Do not replace the remote host with a development build to
   match the viewer. The compatibility baseline is the official v0.5.1 (563),
   protocol 1.
2. On the **viewer Mac**, launch Sill Viewer and allow Local Network discovery.
   Both Macs should initially be on the same LAN. Use **Refresh** after changing
   networks or granting Local Network permission.
3. Choose the host under **Nearby Macs**. Enter the 12-digit pairing code
   displayed on the host. If Sill does not show one automatically, choose
   **Pair iPhone or iPad…** in the host's menu; this same pairing flow also
   accepts the Mac viewer.
4. Select **Desktop** or a window from **Show**. Click the picture to focus
   remote keyboard input. Mouse, drag, right-click, scrolling, navigation keys
   and Command/Control shortcuts go to the host while the picture has focus.
   Use the toolbar's **Disconnect** button to leave the session.
5. Saved Macs reconnect without another code. **Remove** forgets the local
   record; revoke the viewer on the host under Sill's Settings → Devices to
   remove its authorization there too.

The viewer itself does not record the local screen or inject local input and
does not need Screen Recording or Accessibility permission. It composes text
with the local input method and sends committed Unicode. IME candidates appear
near the last pointer position, rather than the remote text caret. Composition
behavior and system-reserved shortcuts need verification on two real Macs.
The first version uses the native cursor shape for this viewer's own pointer;
movement of a mouse attached to the host is not displayed as a second pointer.

## Address or VPN

**Connect by address** accepts a name/IP and optional port. The default 7455
is the host's **Remote Access** port: enable Remote Access and manually open a
pairing code on the host before the first connection by address. Use your
existing VPN (for example Tailscale) when the Macs are on different networks.
A discovered LAN host uses its advertised port automatically. If discovery stays
empty, enabling Remote Access also provides a direct-address path on the same LAN.

All connections require TLS 1.3. Plain development hosts are refused.
Typed-code pairing checks both proofs and binds them to the certificates from
the actual TLS connection. The viewer identity, verified host keys and pairing
records live in Keychain, separately from the host app's records. A changed
host key fails closed; remove the saved Mac and pair again after confirming
that the host was reinstalled. No accounts or relay server are added.

## Validation

```sh
swift test --filter 'SillViewerTests.ViewerTests/'
Tests/checks/run-all.sh message-reader
python3 Scripts/test-viewer-stream.py
```

The integration script launches a synthetic host bound to loopback, pairs with
a real code, renders its HEVC test pattern, disconnects and reconnects with the
saved host key. It never captures your screen or sends input events. It removes
the temporary saved Mac afterward; the viewer's own Keychain identity remains.

For hardware acceptance, verify these on two Macs: discovery and pairing;
switch a window/Desktop and resize the viewer; drag across letterboxing;
right-click; scroll and momentum; Korean text composition; Command-C/V and
navigation keys; release a held key or drag when focus changes; disconnect and
reconnect. Check perceived latency and a long-running session separately.

This first version excludes audio playback, clipboard synchronization,
automatic route migration, USB auto-pairing and automatic reconnect after a
network disconnect. While connected without a picture, the viewer reselects the
requested source every 10 seconds; a vanished window falls back to Desktop.
This uses the released host’s selectSource message, not the unreleased kind 44.
It can recover once capture becomes available again; it does not guarantee
control of a locked host. Existing
host/iOS code and wire messages stay unchanged. Every host connection still
shares the host's one active source, as in upstream Sill.

## Verified in this checkout (2026-10-30)

- Release viewer build and ad hoc bundle signature verification passed.
- Four focused scenarios passed (letterboxing, physical HID mapping, modifier
  keys, and authenticated pairing responses).
- The real synthetic-host integration passed: typed-code TLS pairing, at least
  12 submitted frames with the AV display layer rendering, input cleanup while
  the session is still connected, and reconnect using the saved pin.
- The existing message-reader checks passed.
- The built app was opened and inspected through its native UI. Manual typed-code
  pairing to a real synthetic host and HEVC test-pattern display were confirmed.
- Startup Keychain blocking was reproduced using a process sample and fixed by
  separating the app/CLI credential namespaces and using stable development signing.
- The user confirmed a successful connection between two Macs. Perceived latency,
  audio and IME behavior still need independent verification.
- Native UI verification confirmed that the current Mac disappeared while the
  other available Mac remained listed. The current Mac is intentionally excluded from Nearby Macs by comparing the
  service's resolved IPv4/IPv6 addresses with local network interfaces.
- The follow-up prioritized building and operating the app; no new tests were added.

## Official-release compatibility correction (2026-10-30)

The GitHub latest release is v0.5.1; its tag has revision count 563, matching
the remote Mac's log. A newer development build number is not a host upgrade
requirement. The viewer keeps protocol 1 and changes only the current Mac.

The released host does not define kind 44. The viewer now recovers by reselecting
the requested source at most once per 10-second picture timeout, using kind 6.
A host report of no active source no longer erases the viewer's selection.
The timeout warning clears when the picture returns. The ZIP contains only the
viewer, so it cannot be mistaken for a requirement to replace the official host.

Validation: release viewer build, bundle signature, and native UI pairing plus
HEVC test-pattern display against a CLI host built from the exact v0.5.1 tag.
The temporary pairing was removed; the user's existing remote pairing remains.
Actual lock/unlock recovery on the remote Mac still needs confirmation. No new
test code was added.

## Resize correction (2026-10-30)

The AV display layer is now the NSView's backing layer. AppKit updates its
geometry and backing scale together with the view, instead of relying on
manual sublayer sizing from layout(). Video still uses aspect fit, so input
coordinates and the displayed video rectangle stay aligned.

Validated by displaying the official v0.5.1 host's synthetic stream in the
installed app, zooming the window to the display size and restoring it. The
picture followed both sizes rather than remaining in the top-left corner.
The specific remote Chrome-window case still needs confirmation when the
remote picture is available. No new test scenarios were added; the existing
rendering check was updated to locate the backing display layer.

## Released-host window padding (2026-10-30)

The remote Orca stream reproduced the reported problem: the decoded pixel buffer
was 5120×2816, with actual window contents in its top-left 2560×1408. The view
and display layer already had the correct bounds. Resizing the layer alone
cannot correct padding encoded into the video.

The viewer now checks window streams once per video format using the advertised
window dimensions and the decoded buffer (macOS 14.4+). It compensates only when
both outer regions are black and both inner window edges contain visible pixels.
Desktop streams remain unchanged. Ambiguous dark windows retain normal aspect
fit. Display geometry, pointer coordinates and scrolling use the same corrected
content rectangle. The remote host and its settings are unchanged.

The display layer is again a clipped sublayer, explicitly sized during layout,
so the padded canvas can extend outside the visible content rectangle. The
previous backing-layer-only approach is superseded by this correction.

Validation: the installed release viewer connected to the unchanged remote Mac
host and displayed Desktop → Orca → Chrome → Desktop at the correct aspect-fit
size. Chrome also followed window zoom and restore. Release build, code signature
verification and existing viewer tests passed (4 passed, 1 integration scenario
skipped because its opt-in host environment was absent). No test scenarios were
added. Entirely dark window edges are deliberately not auto-cropped; this
compatibility correction requires macOS 14.4 or newer on the viewer.

## Window cards and Spaces (2026-10-30)

The dropdown is replaced by horizontally scrolling cards with the host's JPEG
window thumbnails, app names, titles and a selected-state outline. A text/icon
fallback appears before a thumbnail arrives. Thumbnails are kept only for current
window IDs and cleared on disconnect.

Previous Space, Mission Control and Next Space use the official host's gesture
protocol (kind 28), enabled only when windowList.gestures advertises support.
A window stream switches to Desktop first so the resulting overview or Space is
visible. This navigates the host's active Space; the protocol does not provide
all Spaces or their screenshots at once. Space arrows depend on the host's enabled
keyboard shortcuts and the host does not acknowledge whether a gesture moved it.

Validation against the unchanged remote Mac: real window thumbnail cards received;
Orca selection via card; horizontal scroll to trailing cards in a resized narrow
window; Mission Control displaying Desktops 3, 4 and 5; Next Space displaying a
different desktop and updating window cards; clicking Desktop 3 in the expanded
Mission Control thumbnails returned to the original Orca desktop. Previous Space was sent but a return
to Desktop 3 was not visually confirmed, so that direction is not claimed as
verified. Release build and bundle signing passed; existing viewer tests passed
(4 passed, 1 opt-in integration test skipped). No new test scenarios were added.

## Video quality controls (2026-10-30)

The Video Quality toolbar popover uses the official client's shared presets:
Low/Efficient/Balanced/High/Pro/Ultra/Extreme (4/8/15/25/40/80/150 Mbps per
60 fps), Standard/Retina capture scale, 60/120 fps limit, and Prioritize Encoding
Speed. Only host-reported state is shown. Each change sends kind 17 with only the
changed field and a monotonically increasing token; controls wait for the host's
matching kind-16 acknowledgement, with an eight-second timeout. Rejected settings
retain the host's actual reported values. No defaults are sent on connection.
The popover shows RunningStream dimensions/fps/bitrate separately from the target,
plus software-encoder and home/away context when reported. The viewport now sends
the viewer window's display frame-rate capability instead of always requesting
60 fps. Host frame-rate limits still apply.

Real-host validation: Retina → Standard changed the running desktop from
5120×2880 to 2560×1440; selecting 60 fps changed the reported stream from 120 to
60 fps; High changed it from 15 to 25 Mbps at 60 fps; the encoding-speed toggle
was acknowledged in both directions. After a host-initiated disconnect, reconnect
loaded its persisted values, then the initial preferences were restored and
confirmed: Balanced 15 Mbps, Retina, 120 fps, encoding-speed priority off. The
current physical display changed during that interval, so restored Retina ran
at 3024×1964, 120 fps and 30 Mbps. The host app binary was unchanged.
Release build, code signature verification and existing viewer tests passed
(4 passed, 1 opt-in integration test skipped). No new test scenarios were added.

## Collapsible screen list and physical monitors (2026-10-30)

Hide Screens / Show Screens in the toolbar collapses or restores the entire
window-card and Spaces-control strip. The existing video surface uses the freed
space without changing source or disconnecting. The choice is saved locally in
viewer.showScreenList. Video Quality and Disconnect remain available.

The official v0.5.1 protocol has only none, window(windowID), and desktop sources.
WindowList carries no display catalog and selectSource accepts no display ID.
WindowCatalog chooses one display; StreamCoordinator captures that display for
Desktop. Spaces gestures switch virtual desktops, not physical monitors. A
viewer-only change cannot select each of two attached monitors' full desktops.
The Desktop card now says Host-selected monitor and explains the restriction.
Individual host-provided window cards remain selectable. Physical display
selection requires a host/protocol extension; the user's requirement to retain
the official host has been respected.

Validation: release build, code signing, and existing viewer tests passed (4
passed, 1 opt-in integration test skipped). The remote test host was absent
from discovery and two connections timed out. A loopback-only synthetic host
built from v0.5.1 verified hide/show, continued video rendering, expansion into
the freed space, and the saved local preference. Its temporary pairing was
removed and the test host stopped. No new test code or host changes were made.

## Virtual Display setting (2026-10-30)

The renamed Video Settings popover includes the official client's Virtual Display
switch. It sends HostSettingsChange.virtualDisplay through the existing token /
acknowledgement path. On moves the selected app window to the host's invisible
virtual display; off uses its original display. This controls app-window staging,
not the enumeration or selection of physical monitors or macOS Spaces.

Match the original client's availability rule: when unavailable and off, on is
disabled; when already on, off remains available. Show the host's failure note,
and show RunningStream.onVirtualDisplay separately for a window source so a
requested setting is not mistaken for successful staging. Host preferences are
never overwritten on connection.

Validation: release build, code signing and existing viewer tests passed (4
passed, 1 opt-in integration test skipped). A loopback-only synthetic v0.5.1 host
with the AppKit virtual-display capability acknowledged off and on and the UI
followed both values. Only its Desktop test pattern streamed: no real window
was selected or moved. The remote test host was not discovered, so actual
remote window relocation/fallback remains unverified. Temporary pairing removed
and test host stopped; no new test code was added.

## Per-monitor desktop selection (2026-10-30)

The custom host now advertises WindowList.displays (ID, name, logical dimensions,
main-display flag) and desktopDisplayID. The viewer renders a card for each
advertised monitor before its app-window cards. Selecting one sends kind 45,
selectDisplay, with the JSON UInt32 ID. The host validates it against its current
capture catalog and restarts the existing Desktop pipeline on that display.
The display shows its current macOS Space; this is independent of the Virtual
Display setting used to stage an app window.

Compatibility: StreamSource remains none/window/desktop and protocol 1 is
unchanged. Older clients ignore the optional catalog fields and retain their
Desktop control. New viewers do not send kind 45 to older hosts, which retain a
single Desktop card. Both custom host and viewer are needed for monitor cards.
The chosen display lasts for this host process, survives app-window selections,
and is reused by the viewer's picture retry / return-to-Desktop path.

The catalog excludes Sill's staging displays, publishes monitor topology/name/
size changes even when window information is unchanged, and falls back to an
available desktop when the selected display disappears. Input and pointer
geometry stay pinned to the display used to build the current capture rather
than an upcoming catalog selection. An explicit monitor pick arriving during a
capture restart is retained. Unknown IDs leave capture unchanged and return the
current catalog. Desktop capture keeps the existing exclusions for Sill's own
windows and pairing UI.

Validation in this session:
- SillHost, bundled Sill.app and bundled Sill Viewer.app release builds passed;
  both app signatures verified.
- A scratch protocol check passed for a two-monitor catalog, selection ID round
  trips, the new header kind, decoding a legacy catalog and ignoring new fields
  with a legacy catalog decoder. This is a protocol check, not monitor capture.
- Existing encrypted synthetic integration passed pairing, HEVC rendering and
  pinned reconnect with SILL_TEST_NO_SCREEN=1 (no real capture, input or window
  movement). No permanent test code was added.

Hardware validation remains outstanding: two monitors with different resolutions
and backing scales; monitors to the left/above the main display (negative global
coordinates); source changes during restarts; input at each monitor's corners;
returning from a staged app; disconnect/reconnect of the selected display. Spaces
shortcuts keep the host's existing global gesture behavior. The remote Mac was
not accessed or modified in this session.

On the remote Mac after the change is committed/pushed, run git pull --ff-only
in ~/projects/sill and Scripts/make-app.sh --install --open. Rebuild the viewer
from the same fork. Installing this development host over the official app may
require regranting screen recording/accessibility and pairing again, as described
in the repository's build instructions.

Additional existing checks passed: viewer unit scenarios (4), CatalogLook cases
(64), and the window-restore rule/model checks (41,936 checks across fixed cases
and 5,000 model sessions). These guard existing behavior; they do not replace
actual monitor-selection and hotplug validation.
