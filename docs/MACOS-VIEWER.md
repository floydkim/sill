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
