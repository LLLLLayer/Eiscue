# Eiscue head studies

Three editable vector studies follow the project owner's existing Eiscue artwork:
`eiscue-ice.svg`, `eiscue-ink.svg`, and `eiscue-pixel.svg`. They have transparent
backgrounds and self-contained CSS animation, with no scripts or remote resources.
These derivatives do not make a licensing claim for the character or source art.

Change the root SVG's `data-state` to `asleep`, `ready`, `connecting`, or `failed`
to preview a slow turn with closed eyes, a turning head with a gentle gaze, a quicker searching
turn, or static worried brows and small filled eyes. The failed expression
corresponds to the native `.concerned` state and uses no badge or looping
animation. The ink version adapts to the system color scheme.

The head uses orthographic cube projection. Turning changes the visible side,
its width, the shared face edges, and the face artwork's affine projection.
The top, left, right, front, and tuft paths have matching geometry keyframes;
the eyes, highlights, and beak use the projected front plane. There is no
whole-image perspective rotation or tilt. Asleep sweeps yaw from −30° to +14°
over 10 seconds, keeping its eyes closed without blinking or changing gaze.
Ready sweeps yaw from −36° to +20° over 7 seconds, and connecting from −44° to
+28° over 4 seconds. Their gaze follows the same phase. Both sides
can become visible as the head turns through center.
Hidden sides have no visible stroke; side joins are rounded to prevent spikes
at the side-switch crossing while the pixel front and tuft remain angular.

Failed heads use a fixed −20° yaw. Reduced Motion disables all
animation and uses the same static geometry; connecting retains its fixed
sideways gaze to distinguish it from ready. A browser supporting animated CSS
`d: path(...)` properties is needed for the SVG motion. Other SVG viewers retain
the editable static −20° pose. The app draws native paths and has no dependency
on browser animation support.

The app draws matching native vector studies in
`Apps/Eiscue/Features/EiscueHeadView.swift`, without a web view or video decoder.
The welcome and device views use actual connection readiness. The sticker gallery
has an explicit preview selector; it does not change the device connection.
The disconnected head keeps its closed eyes and slow turn. Native animation
pauses when failed, backgrounded, or Reduce
Motion is enabled. Worried brows use broader strokes to preserve the expression
in the 32-point toolbar face. Keep these design exports and the native drawing
visually consistent when editing a study. Existing PNG stickers remain unchanged.

## Regeneration and geometry checks

`Scripts/generate-eiscue-heads.py` is the editable source for the exports. It uses
the native view's half-width 70, half-height 64, half-depth 50, pitch 18°, center
(120, 119), canonical 140 × 128 front artwork, and tuft plane at z = −5.
For a world point (x, y, z), the projected coordinates at yaw θ are:

```text
X = 120 + cos(θ) × x + sin(θ) × z
Y = 119 + cos(18°) × y + sin(18°) × (−sin(θ) × x + cos(θ) × z)
```

Run `python3 Scripts/generate-eiscue-heads.py` after editing the generator.
Run `python3 Scripts/generate-eiscue-heads.py --check` to compare the exports
without changing files and print sampled face widths. Forty samples per cycle,
plus exact side-switch crossings, keep path and face-plane interpolation aligned.

Local Chromium rendering verified actual ready frames at phases 0, 0.25, and
0.75 for all three styles: the visible side widths were 13.92, 34.20, and 58.78
vector units, with the middle pose showing the left side and the others the
right. Front widths changed from 138.64 to 131.56 to 113.26 units. These are
rendered geometry checks, not physical-device acceptance.
