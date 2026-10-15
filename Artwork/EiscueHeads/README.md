# Eiscue head studies

Three editable vector studies follow the project owner's existing Eiscue artwork:
`eiscue-ice.svg`, `eiscue-ink.svg`, and `eiscue-pixel.svg`. They have transparent
backgrounds and self-contained CSS animation, with no scripts or remote resources.
These derivatives do not make a licensing claim for the character or source art.

Change the root SVG's `data-state` to `asleep`, `ready`, or `connecting` to preview
closed eyes, blinking with a gentle gaze, or a quicker searching gaze. Reduced
motion disables looping animation. The ink version adapts to the system color
scheme. Static SVG viewers may show only the initial pose.

The app draws matching native vector studies in
`Apps/Eiscue/Features/EiscueHeadView.swift`, without a web view or video decoder.
The welcome and device views use actual connection readiness. The sticker gallery
has an explicit preview selector; it does not change the device connection.
The native animation pauses when disconnected, backgrounded, or Reduce Motion is
enabled. Keep these design exports and the native drawing visually consistent
when editing a study. Existing PNG stickers remain unchanged.
