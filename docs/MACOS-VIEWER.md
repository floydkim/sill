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

The local build is `.build/Sill Viewer.app`. The script signs it ad hoc;
this is a local development build, not a notarized distribution. For a stable
signing identity across rebuilds, set `SILL_VIEWER_SIGN_IDENTITY` to your own
Apple Development identity before running the script.

## Connect two Macs

1. On the **host Mac**, install and open the upstream Sill app. Grant Screen
   Recording, Accessibility, and Local Network when requested. Keep it awake
   and logged in. Alternatively build the host with `Scripts/make-app.sh`.
2. On the **viewer Mac**, launch Sill Viewer and allow Local Network discovery.
   Both Macs should initially be on the same LAN.
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
A discovered LAN host uses its advertised port automatically.

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
automatic route migration, USB auto-pairing and automatic reconnect. Existing
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
- Two physical Macs, long sessions, perceived latency, audio and IME behavior
  were not tested. Native UI inspection was unavailable because the local GUI
  automation service timed out; app process launch was confirmed.
