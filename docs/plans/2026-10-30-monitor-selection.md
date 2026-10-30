# Physical monitor selection

Goal: choose a remote monitor's current desktop from the macOS viewer without changing legacy StreamSource encoding.

Protocol: optional WindowList.displays and desktopDisplayID; new selectDisplay kind 45 carries a JSON UInt32 display ID. Older clients keep using desktop and ignore catalog additions. The viewer sends kind 45 only for advertised displays, falling back to one Desktop card on old hosts.

Host: catalog connected displays by stable CG display ID, name and logical size; exclude Sill's staging displays. Keep the chosen desktop independent of window staging. Reuse existing desktop capture and encoder paths; pin input/pointer geometry to the captured display. Publish topology changes, reject unknown IDs without switching, preserve a display pick queued during capture restart, and fall back when a selected monitor disappears.

Viewer: add monitor cards before app cards, distinguish their selection while keeping source desktop, retain the chosen monitor on picture retry and when returning from an app for Spaces gestures, and clear monitor metadata on disconnect.

Verification: build host/viewer, run existing viewer and host checks where applicable, protocol round-trip/legacy-decoding scratch checks and local synthetic integration. No new permanent tests per user preference. No actual multi-monitor capture/input or hotplug validation in this session. Do not install or operate a modified host on the remote Mac. Commit and push to floydkim/sill main only after approval.
