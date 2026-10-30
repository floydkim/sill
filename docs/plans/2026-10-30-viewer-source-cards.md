# Viewer source cards and Spaces

**Goal:** Browse remote windows in a horizontal screenshot-card strip and navigate remote macOS Spaces while retaining the official v0.5.1 host.

**Architecture:** Reuse the existing windowList, thumbnail (kind 3), selectSource (kind 6), and gesture (kind 28) messages. Keep a thumbnail only for each current window. Gate Spaces controls on WindowList.gestures. Select Desktop before sending Mission Control or a Space-switch gesture, following the released iOS client's ordering. No host changes or private APIs.

**Tech stack:** SwiftUI, AppKit NSImage, existing StreamProtocol.

## Scope and limits

Show Desktop plus host-provided windows as horizontally scrolling cards, with a screenshot when available and an app/title fallback. Highlight the selected card and keep it visible on selection. Add previous Space, Mission Control, and next Space controls. The host exposes current-Space windows, not a complete inventory or screenshots of every Space. Navigation changes the host's active Space.

## Implementation

1. ViewerClient.swift: decode/cache thumbnails, evict removed window IDs, advertise host gesture capability to UI, send a supported gesture after selecting Desktop, clear new state on disconnect.
2. ViewerApp.swift: replace Picker with a horizontal LazyHStack of cards; add capability-gated Spaces controls; release held remote input before UI source/navigation actions.
3. Verify release build and existing viewer tests; manually check real-host thumbnails, horizontal scrolling, source switching, and supported Spaces navigation. Add no test scenarios per user request.
4. Document actual validation and compatibility limits, update installed viewer and viewer-only ZIP. Propose the new Korean Conventional Commit after implementation; commit only on approval.

## Video quality extension

Reuse HostSettingsState and HostSettingsChange (kinds 16/17), matching the official client's QualityPreset values, Standard/Retina capture scale, 60/120 fps limit and prioritizeSpeed toggle. A toolbar popover shows host-reported settings and actual RunningStream values, with home/away context. Send only the changed field and a monotonically increasing token; serialize changes until its acknowledgement or an eight-second timeout. Do not optimistically claim settings were applied. Keep host preferences on connection and clear session state on disconnect. Advertise the local display frame-rate capability through the existing viewport message so 120 fps is not inadvertently capped at 60 by the viewer.

Validation: release build, existing viewer tests, real-host setting acknowledgement and running-stream changes; restore the remote host's initial preferences after manual checks. No new test scenarios. Leave all new feature commits pending user approval.
