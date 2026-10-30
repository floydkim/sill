# macOS Viewer Implementation Plan

**Goal:** Connect one Mac to an existing Sill host on another Mac, pair securely, view a window or desktop, and send mouse and keyboard input.

**Architecture:** Add a separate SillViewer SwiftPM executable and app bundle. Reuse StreamProtocol and the iOS MessageReader without changing the host's wire format. Use AppKit input and AVSampleBufferDisplayLayer rendering. Store the viewer identity and verified host pins in Keychain, separately from the host and iOS apps.

**Tech Stack:** Swift, AppKit, SwiftUI, Network, Security, AVFoundation. No new dependencies.

The user approved the previously proposed LAN MVP. A native target is smaller and clearer than porting the UIKit app or maintaining a Catalyst fork. No commits without user approval.

1. Add scenario tests for letterboxed pointer coordinates, keyboard mapping and pairing proof validation; verify they fail before implementation.
2. Implement the viewer target, Bonjour discovery, typed-code pairing with mutual proofs, pinned TLS sessions and bounded message reading.
3. Add native HEVC display, source selection, pointer/scroll and keyboard/IME input. Disconnect releases held input; stale callbacks cannot affect another session.
4. Add an app-bundle build script and usage documentation.
5. Run focused tests, build both viewer and existing host, and run a synthetic-host encrypted streaming smoke test. Inspect the UI locally. Two-Mac hardware, Korean IME and latency remain hardware acceptance checks.

First version excludes audio, automatic route migration, USB auto-pairing, clipboard sync and extra iOS UI. Manual address entry can use an existing VPN. No host settings changes are needed.
