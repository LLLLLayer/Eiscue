#!/usr/bin/env python3
"""Generate self-contained, projected-cube SVG studies matching EiscueHeadView."""

import argparse
import math
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / "Artwork/EiscueHeads"
PITCH = math.radians(18)
HALF_WIDTH, HALF_HEIGHT, HALF_DEPTH = 70, 64, 50
CENTER = (120, 119)
TUFT = [(-2, -67), (17, -103), (32, -85), (59, -97), (71, -79), (33, -61), (18, -78), (7, -64)]
PIXEL_TUFT = [(-2, -67), (-2, -79), (10, -79), (10, -103), (22, -103), (22, -91),
              (34, -91), (34, -79), (46, -79), (46, -91), (70, -91), (70, -79),
              (34, -61), (18, -78), (7, -64)]
STATES = {"asleep": (10, 22, 0), "ready": (7, 28, 3), "connecting": (4, 36, 6)}


def number(value):
    return f"{value:.5f}".rstrip("0").rstrip(".") if abs(value) >= 0.000005 else "0"


def project(x, y, z, yaw):
    angle = math.radians(yaw)
    return (CENTER[0] + math.cos(angle) * x + math.sin(angle) * z,
            CENTER[1] + math.cos(PITCH) * y + math.sin(PITCH) * (-math.sin(angle) * x + math.cos(angle) * z))


def path(vertices, yaw):
    points = [project(*vertex, yaw) for vertex in vertices]
    return "M" + "L".join(" ".join(number(value) for value in point) for point in points) + "Z"


def geometry(style, yaw):
    w, h, d = HALF_WIDTH, HALF_HEIGHT, HALF_DEPTH
    faces = {
        "top": [(-w, -h, -d), (w, -h, -d), (w, -h, d), (-w, -h, d)],
        "front": [(-w, -h, d), (w, -h, d), (w, h, d), (-w, h, d)],
        "tuft": [(x, y, -5) for x, y in (PIXEL_TUFT if style == "pixel" else TUFT)],
    }
    # A hidden side collapses onto its front edge, which the front face covers.
    # Separate side paths avoid a line sweeping across the face as yaw crosses zero.
    for name, x, visible in [("left", -w, yaw > 0), ("right", w, yaw < 0)]:
        rear = -d if visible else d
        faces[name] = [(x, -h, rear), (x, -h, d), (x, h, d), (x, h, rear)]
    result = {name: path(vertices, yaw) for name, vertices in faces.items()}
    angle = math.radians(yaw)
    origin = project(-w, -h, d, yaw)
    result["plane"] = "matrix(" + ",".join(number(value) for value in (
        math.cos(angle), -math.sin(angle) * math.sin(PITCH), 0, math.cos(PITCH), *origin)) + ")"
    return result


def phases(amplitude):
    zero = math.asin(8 / amplitude) / (2 * math.pi)
    return sorted(set([index / 40 for index in range(41)] + [zero, 0.5 - zero]))


def animation_rules(style):
    rules = []
    for state, (period, amplitude, gaze) in STATES.items():
        frames = [(phase, math.sin(phase * 2 * math.pi)) for phase in phases(amplitude)]
        projected = [(phase, turn, geometry(style, -8 + turn * amplitude)) for phase, turn in frames]
        for name in ("top", "left", "right", "front", "tuft", "plane", "gaze"):
            declarations = []
            for phase, turn, values in projected:
                if name == "gaze":
                    value = f"transform:translateX({number(turn * gaze)}px)"
                elif name == "plane":
                    value = f"transform:{values[name]}"
                else:
                    value = f'd:path("{values[name]}")'
                    if name in ("left", "right"):
                        yaw = -8 + turn * amplitude
                        visible = yaw > 0 if name == "left" else yaw < 0
                        value += ";visibility:" + ("visible" if visible else "hidden")
                declarations.append(f"{number(phase * 100)}%{{{value}}}")
            rules.append(f"@keyframes {state}-{name}{{" + "".join(declarations) + "}")
            rules.append(f'[data-state="{state}"] .project-{name}'
                         f'{{animation:{state}-{name} {period}s linear infinite;}}')
    return "\n".join(rules)


def svg(style):
    static = geometry(style, -20)
    pixel = style == "pixel"
    ink = style == "ink"
    if pixel:
        opened = '<rect x="31" y="46" width="22" height="36"/><rect x="89" y="46" width="22" height="36"/>'
        closed = "M31 64V69H53V64M89 64V69H111V64"
        worried = "M29 47H40V42H53V38M89 38V42H100V47H113"
        pupils = '<rect x="36" y="58" width="12" height="20"/><rect x="94" y="58" width="12" height="20"/>'
    else:
        opened = '<ellipse cx="42" cy="64" rx="11" ry="18"/><ellipse cx="100" cy="64" rx="11" ry="18"/>'
        closed = "M31 64Q42 73 53 64M89 64Q100 73 111 64"
        worried = "M29 47Q42 46 53 38M89 38Q100 46 113 47"
        pupils = '<ellipse cx="42" cy="68" rx="6" ry="10"/><ellipse cx="100" cy="68" rx="6" ry="10"/>'
    shine = "" if pixel else (
        f'<g fill="white" opacity="{0.25 if ink else 0.8}"><ellipse cx="17" cy="22.5" rx="6" ry="9.5"/>'
        '<ellipse cx="27" cy="37.5" rx="3" ry="4.5"/></g>')
    ink_css = "" if not ink else """
svg{--outline:#2e2e2e;--front:#f7f7f7;--top:#fff;--side:#d6d6d6;--eye:#2e2e2e;--tuft:#2e2e2e}
@media(prefers-color-scheme:dark){svg{--outline:#dbdbdb;--front:#2b2b2b;--top:#3b3b3b;--side:#1f1f1f;--eye:#dbdbdb;--tuft:#dbdbdb}}
"""
    faces = "\n".join(
        f'<path class="project-{name} projected" fill="var(--{color})"'
        + (' visibility="hidden"' if name == "left" else "")
        + f' d="{static[name]}"/>'
        for name, color in [("top", "top"), ("left", "side"), ("right", "side"), ("front", "front"), ("tuft", "tuft")])
    return f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 240 220" data-state="ready" role="img" aria-labelledby="title">
<title id="title">Eiscue — {style} projected animated head</title>
<!-- Generated by Scripts/generate-eiscue-heads.py. Editable vectors; no embedded scripts. -->
<style>
svg{{--outline:#213347;--front:#abe8f7;--top:#e0faff;--side:#63bacc;--eye:#407887;--tuft:#454545;}}
.face{{stroke:var(--outline);stroke-width:{5 if pixel else 4.5};stroke-linecap:round;stroke-linejoin:{"miter" if pixel else "round"};}}
.project-left,.project-right{{stroke-linejoin:round;}}
.project-plane{{transform-origin:0 0;}}
.closed-eyes,.concerned-eyes{{display:none;}}
.open-eyes{{transform-box:fill-box;transform-origin:center;}}
[data-state="ready"] .open-eyes,[data-state="connecting"] .open-eyes{{animation:blink 4.8s linear infinite;}}
[data-state="connecting"] .project-gaze{{transform:translateX(8px);}}
[data-state="asleep"] .open-eyes,[data-state="failed"] .open-eyes{{display:none;}}
[data-state="asleep"] .closed-eyes,[data-state="failed"] .concerned-eyes{{display:inline;}}
@keyframes blink{{0%,80%,87%,100%{{transform:scaleY(1)}}84%{{transform:scaleY(.08)}}}}
{animation_rules(style)}
@media(prefers-reduced-motion:reduce){{.projected,.open-eyes{{animation:none !important;}}}}
{ink_css}</style>
<g class="face">
{faces}
</g>
<g class="project-plane projected" transform="{static["plane"]}">
{shine}
<g class="project-gaze projected" fill="none" stroke="var(--eye)" stroke-width="4" stroke-linecap="round">
  <g class="open-eyes">{opened}</g>
  <path class="closed-eyes" d="{closed}"/>
  <g class="concerned-eyes" stroke-width="6" stroke-linejoin="{"miter" if pixel else "round"}">
    <path d="{worried}"/>
    <g fill="var(--eye)" stroke="none">{pupils}</g>
  </g>
</g>
<path fill="var(--top)" d="M71 88L85 102L71 113L58 101Z"/>
<path fill="var(--side)" opacity=".6" d="M71 88L71 113L58 101Z"/>
<path fill="none" stroke="var(--eye)" stroke-width="3.5" stroke-linejoin="round" d="M71 88L85 102L71 113L58 101Z"/>
</g>
</svg>
'''


def verify_geometry():
    for state, (_, amplitude, _) in STATES.items():
        for phase in phases(amplitude):
            yaw = -8 + amplitude * math.sin(phase * 2 * math.pi)
            for x, y in TUFT + PIXEL_TUFT:
                px, py = project(x, y, -5, yaw)
                assert 3 < px < 237 and 3 < py < 217, (px, py)
        print(state + ":")
        for phase in (0, 0.25, 0.5, 0.75):
            yaw = -8 + amplitude * math.sin(phase * 2 * math.pi)
            side_width = 2 * HALF_DEPTH * abs(math.sin(math.radians(yaw)))
            front_width = 2 * HALF_WIDTH * math.cos(math.radians(yaw))
            print(f"  phase={phase:.2f} yaw={yaw:6.1f}° visible={'right' if yaw < 0 else 'left'} "
                  f"side_width={side_width:.2f} front_width={front_width:.2f}")
            for x in (-HALF_WIDTH, HALF_WIDTH):
                for y in (-HALF_HEIGHT, HALF_HEIGHT):
                    for z in (-HALF_DEPTH, HALF_DEPTH):
                        px, py = project(x, y, z, yaw)
                        assert 3 < px < 237 and 3 < py < 217, (px, py)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Check exports and print projected geometry without writing files.")
    arguments = parser.parse_args()
    for style in ("ice", "ink", "pixel"):
        output = svg(style)
        destination = DESTINATION / f"eiscue-{style}.svg"
        if arguments.check:
            if destination.read_text() != output:
                raise SystemExit(f"Out-of-date export: {destination}")
        else:
            destination.write_text(output)
    verify_geometry()


if __name__ == "__main__":
    main()
