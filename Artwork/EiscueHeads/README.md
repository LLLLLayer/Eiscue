# Eiscue head studies

Three editable vector studies follow the project owner's existing Eiscue artwork:
`eiscue-ice.svg`, `eiscue-ink.svg`, and `eiscue-pixel.svg`. They have transparent
backgrounds and self-contained CSS animation, with no scripts or remote resources.
These derivatives do not make a licensing claim for the character or source art.

Change the root SVG's `data-state` to `asleep`, `ready`, `connecting`, or `failed`
to preview closed eyes, blinking with a gentle gaze and head turn, a quicker searching gaze,
or static worried brows and small filled eyes. The failed expression corresponds
to the native `.concerned` state and uses no badge or looping animation. Reduced
motion disables looping animation; connecting retains a fixed sideways gaze so
it remains distinct from ready. The ink version adapts to the system color
scheme. Static SVG viewers may show only the initial pose.

The head group turns slightly around its vertical axis and tilts with the gaze:
ready uses up to 4° of turn and 0.8° of tilt, while connecting uses 8° and 1.6°.
These small transforms fit within the existing view box without changing layout.
Disconnected and failed heads remain still, including their eyes. SVG perspective
transforms require a browser or viewer with CSS 3D-transform support.

The app draws matching native vector studies in
`Apps/Eiscue/Features/EiscueHeadView.swift`, without a web view or video decoder.
The welcome and device views use actual connection readiness. The sticker gallery
has an explicit preview selector; it does not change the device connection.
The native animation pauses when disconnected, failed, backgrounded, or Reduce
Motion is enabled. Worried brows use broader strokes to preserve the expression
in the 32-point toolbar face. Keep these design exports and the native drawing
visually consistent when editing a study. Existing PNG stickers remain unchanged.
