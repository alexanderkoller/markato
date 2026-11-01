#!/usr/bin/env python3
"""Generate the website and complete performance charts from the documented data."""
from pathlib import Path
from math import log2
from xml.sax.saxutils import escape

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "docs" / "assets"

APPS = [
    ("markato", "Markato", "app-markato", "url(#markato)"),
    ("markviewer", "MarkViewer", "app", "#a97fe5"),
    ("macdown", "MacDown", "app", "#6f899c"),
    ("md3000", "MD 3000", "app", "#587286"),
    ("md2", "MD 2.0", "app", "#91a7b6"),
]

M5_APPS = [
    ("markato", "Markato", "app-markato", "url(#markato)"),
    ("markviewer", "MarkViewer", "app", "#a97fe5"),
    ("macdown", "MacDown 0.7.3", "app", "#6f899c"),
    ("md3000", "MD 3000", "app", "#587286"),
    ("md2", "MD2 pre-rel.", "app", "#91a7b6"),
    ("md2030", "MD2 0.3.0", "app", "#d49b65"),
]

PANELS = [
    ("64 KB", "Open", 400, "ms", {
        "markato": (55.8, "55.8 ms"), "markviewer": (244.8, "244.8 ms"),
        "macdown": (211.4, "211.4 ms"), "md3000": (205.8, "205.8 ms"),
        "md2": (361.3, "361.3 ms"),
    }),
    ("1 MB", "Open", 25000, "s", {
        "markato": (74.3, "74.3 ms"), "markviewer": (20384.8, "20.38 s"),
        "macdown": (1526.2, "1.53 s"), "md3000": (2542.0, "2.54 s"),
        "md2": (637.5, "637.5 ms"),
    }),
    ("8 MB", "Open", 12000, "s", {
        "markato": (256.3, "256.3 ms"), "markviewer": ("timeout", ">60 s"),
        "macdown": (11872.3, "11.87 s"), "md3000": ("timeout", ">60 s"),
        "md2": (2480.7, "2.48 s"),
    }),
    ("64 KB", "Edit", 125, "ms", {
        "markato": (14.6, "14.6 ms"), "markviewer": (112.3, "112.3 ms"),
        "macdown": (36.2, "36.2 ms"), "md3000": (52.7, "52.7 ms"),
        "md2": (27.7, "27.7 ms"),
    }),
    ("1 MB", "Edit", 25000, "s", {
        "markato": (11.9, "11.9 ms"), "markviewer": (23748.5, "23.75 s"),
        "macdown": (147.1, "147.1 ms"), "md3000": (2004.1, "2.00 s"),
        "md2": (49.7, "49.7 ms"),
    }),
    ("8 MB", "Edit", 250, "ms", {
        "markato": (7.0, "7.0 ms"), "markviewer": ("untested", "NOT TESTED · OPEN TIMED OUT"),
        "macdown": ("timeout", ">60 s"), "md3000": ("untested", "NOT TESTED · OPEN TIMED OUT"),
        "md2": (228.9, "228.9 ms"),
    }),
]

M5_PANELS = [
    ("64 KB", "Open", 400, "ms", {
        "markato": (111.2, "111.2 ms"), "markviewer": (210.7, "210.7 ms"),
        "macdown": (243.5, "243.5 ms"), "md3000": (187.5, "187.5 ms"),
        "md2": (310.7, "310.7 ms"), "md2030": (290.9, "290.9 ms"),
    }),
    ("1 MB", "Open", 5000, "s", {
        "markato": (372.5, "372.5 ms"), "markviewer": (18972.2, "18.97 s"),
        "macdown": (1683.9, "1.68 s"), "md3000": (2123.6, "2.12 s"),
        "md2": (543.0, "543.0 ms"), "md2030": (542.3, "542.3 ms"),
    }),
    ("8 MB", "Open", 60000, "s", {
        "markato": (2433.5, "2.43 s"), "markviewer": ("timeout", ">60 s"),
        "macdown": (12775.7, "12.78 s"), "md3000": (50635.0, "50.64 s*"),
        "md2": (2073.8, "2.07 s"), "md2030": (2728.1, "2.73 s"),
    }),
    ("64 KB", "Edit", 150, "ms", {
        "markato": (53.4, "53.4 ms"), "markviewer": (129.8, "129.8 ms"),
        "macdown": (34.2, "34.2 ms"), "md3000": (45.6, "45.6 ms"),
        "md2": (35.9, "35.9 ms"), "md2030": (34.4, "34.4 ms"),
    }),
    ("1 MB", "Edit", 1000, "s", {
        "markato": (49.5, "49.5 ms"), "markviewer": (10448.9, "10.45 s"),
        "macdown": (231.6, "231.6 ms"), "md3000": (907.6, "907.6 ms"),
        "md2": (53.6, "53.6 ms"), "md2030": (36.4, "36.4 ms"),
    }),
    ("8 MB", "Edit", 2000, "s", {
        "markato": (54.3, "54.3 ms"), "markviewer": ("untested", "NOT TESTED · OPEN TIMED OUT"),
        "macdown": (1827.7, "1.83 s"), "md3000": ("timeout", ">60 s"),
        "md2": (167.3, "167.3 ms"), "md2030": (130.3, "130.3 ms"),
    }),
]


def tick_label(value, maximum, unit):
    if value == 0:
        return "0"
    if unit == "ms":
        return f"{value:g} ms"
    seconds = value / 1000
    return f"{seconds:g} s"


def panel(label, operation, maximum, unit, values, x, y, apps=APPS):
    left, plot_width = 132, 426
    lines = [
        f'<g transform="translate({x} {y})">',
        '<rect class="panel" width="610" height="430" rx="22"/>',
        f'<text class="subheading" x="28" y="42">{label}</text>',
        f'<text class="heading" x="28" y="78">{operation}</text>',
        '<g transform="translate(28 104)">',
        '<g class="axis">',
    ]
    for index in range(5):
        tick_x = left + plot_width * index / 4
        lines.append(f'<line x1="{tick_x:.1f}" y1="0" x2="{tick_x:.1f}" y2="258"/>')
    lines.extend(['</g>', '<g class="tick" text-anchor="middle">'])
    for index in range(5):
        value = maximum * index / 4
        tick_x = left + plot_width * index / 4
        lines.append(f'<text x="{tick_x:.1f}" y="280">{tick_label(value, maximum, unit)}</text>')
    lines.append('</g>')

    row_gap = 49 if len(apps) == 5 else 42
    bar_height = 25 if len(apps) == 5 else 22
    bar_radius = 12 if len(apps) == 5 else 11
    for index, (key, name, app_class, fill) in enumerate(apps):
        row_y = 28 + index * row_gap
        bar_y = row_y - (19 if len(apps) == 5 else 18)
        value, formatted = values[key]
        lines.append(f'<text class="{app_class}" x="0" y="{row_y}">{escape(name)}</text>')
        if value == "timeout":
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{plot_width}" height="{bar_height}" rx="{bar_radius}" fill="url(#timeout)"/>')
            lines.append(f'<text class="value-timeout" x="{left + plot_width - 10}" y="{row_y}" text-anchor="end">{escape(formatted)}</text>')
        elif value == "untested":
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{plot_width}" height="{bar_height}" rx="{bar_radius}" fill="url(#untested)"/>')
            lines.append(f'<text class="value-untested" x="{left + plot_width / 2}" y="{row_y}" text-anchor="middle">{escape(formatted)}</text>')
        else:
            unclipped_width = plot_width * value / maximum
            width = min(plot_width, max(8, unclipped_width))
            clipped = unclipped_width > plot_width
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{width:.1f}" height="{bar_height}" rx="{bar_radius}" fill="{fill}"/>')
            value_class = "value-markato" if key == "markato" else "value"
            if width > 335:
                suffix = "  ›" if clipped else ""
                lines.append(f'<text class="{value_class}" x="{left + width - 8:.1f}" y="{row_y}" text-anchor="end">{escape(formatted + suffix)}</text>')
            else:
                lines.append(f'<text class="{value_class}" x="{left + width + 9:.1f}" y="{row_y}">{escape(formatted)}</text>')
    lines.extend(['</g>', '</g>'])
    return "\n".join(lines)


def complete_chart(
    panels=PANELS,
    heading="Complete benchmark comparison",
    footer="Apple M4 Pro, 14-core · macOS 26.6.2 · medians where completed",
    note="",
    eyebrow=True,
    apps=APPS,
    description="Six linear-scale horizontal bar charts compare Markato, MarkViewer, MacDown 0.7.3, MacDown 3000, and MacDown 2.0 open and edit latency for 64 KB, 1 MB, and 8 MB Markdown documents.",
):
    positions = [(56, 235), (695, 235), (1334, 235), (56, 695), (695, 695), (1334, 695)]
    rendered_panels = "\n".join(panel(*spec, *position, apps=apps) for spec, position in zip(panels, positions))
    note_line = (f'\n    <text x="76" y="1227" fill="#708797" font-size="13">'
                 f'{escape(note)}</text>') if note else ""
    if eyebrow:
        header = (f'<text x="76" y="78" fill="#80ffb7" font-size="23" font-weight="700" letter-spacing="3.5">MARKATO PERFORMANCE</text>\n'
                  f'    <text x="76" y="143" fill="#fff" font-size="52" font-weight="760" letter-spacing="-1">{escape(heading)}</text>\n'
                  f'    <text x="76" y="187" fill="#aabfcd" font-size="22">End-to-end latency until the requested view is visibly painted · linear scales · lower is better</text>')
    else:
        header = (f'<text x="76" y="110" fill="#fff" font-size="52" font-weight="760" letter-spacing="-1">{escape(heading)}</text>\n'
                  f'    <text x="76" y="160" fill="#aabfcd" font-size="22">End-to-end latency until the requested view is visibly painted · linear scales · lower is better</text>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="1250" viewBox="0 0 2000 1250" role="img" aria-labelledby="title desc">
  <title id="title">Complete Markato benchmark comparison</title>
  <desc id="desc">{escape(description)}</desc>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#07111d"/><stop offset="1" stop-color="#102333"/></linearGradient>
    <linearGradient id="markato" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#45e0ff"/><stop offset="1" stop-color="#80ffb7"/></linearGradient>
    <pattern id="timeout" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="14" height="14" fill="#344f62"/><rect width="5" height="14" fill="#d7ff64" fill-opacity=".52"/></pattern>
    <pattern id="untested" width="14" height="14" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="14" height="14" fill="#243847"/><rect width="3" height="14" fill="#7890a0" fill-opacity=".6"/></pattern>
    <style>
      .panel {{ fill:#0d1b2a; fill-opacity:.78; stroke:#466276; stroke-opacity:.42 }}
      .heading {{ fill:#fff; font-size:27px; font-weight:730 }} .subheading {{ fill:#80ffb7; font-size:17px; font-weight:700; letter-spacing:2px }}
      .app {{ fill:#b9cad6; font-size:17px }} .app-markato {{ fill:#fff; font-size:17px; font-weight:700 }}
      .value {{ fill:#dce7ed; font-size:15px; font-weight:650 }} .value-markato {{ fill:#80ffb7; font-size:15px; font-weight:740 }}
      .value-timeout {{ fill:#d7ff64; font-size:15px; font-weight:720 }} .value-untested {{ fill:#dce7ed; font-size:13px; font-weight:720 }}
      .axis {{ stroke:#a8bdca; stroke-opacity:.16 }} .tick {{ fill:#708999; font-size:13px }}
    </style>
  </defs>
  <rect width="2000" height="1250" fill="url(#bg)"/><circle cx="1800" cy="80" r="510" fill="#45e0ff" fill-opacity=".035"/><circle cx="1430" cy="1230" r="590" fill="#80ffb7" fill-opacity=".025"/>
  <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
    {header}
    {rendered_panels}
    <g transform="translate(76 1195)">
      <rect x="0" y="-18" width="24" height="14" rx="7" fill="url(#markato)"/><text x="36" y="-5" fill="#aabfcd" font-size="16">Markato</text>
      <rect x="138" y="-18" width="24" height="14" rx="7" fill="#a97fe5"/><text x="174" y="-5" fill="#aabfcd" font-size="16">MarkViewer</text>
      <rect x="330" y="-18" width="24" height="14" rx="7" fill="url(#timeout)"/><text x="366" y="-5" fill="#aabfcd" font-size="16">60-second operation limit</text>
      <rect x="666" y="-18" width="24" height="14" rx="7" fill="url(#untested)"/><text x="702" y="-5" fill="#aabfcd" font-size="16">not tested: prerequisite open timed out</text>
      <text x="1870" y="-5" fill="#708797" font-size="15" text-anchor="end">{escape(footer)}</text>
    </g>{note_line}
  </g>
</svg>'''


def marker(shape, x, y, color, size=8):
    if shape == "ring":
        return f'<circle cx="{x}" cy="{y}" r="{size}" fill="#091624" stroke="{color}" stroke-width="4"/>'
    if shape == "square":
        return f'<rect x="{x-size}" y="{y-size}" width="{2*size}" height="{2*size}" rx="2" fill="{color}"/>'
    if shape == "diamond":
        return f'<path d="M {x} {y-size-1} L {x+size+1} {y} L {x} {y+size+1} L {x-size-1} {y} Z" fill="{color}"/>'
    if shape == "triangle":
        return f'<path d="M {x} {y-size-2} L {x+size+2} {y+size} L {x-size-2} {y+size} Z" fill="{color}"/>'
    if shape == "cross":
        return (f'<path d="M {x-size} {y-size} L {x+size} {y+size} M {x+size} {y-size} L {x-size} {y+size}" '
                f'stroke="{color}" stroke-width="4" stroke-linecap="round"/>')
    if shape == "plus":
        return (f'<path d="M {x-size} {y} L {x+size} {y} M {x} {y-size} L {x} {y+size}" '
                f'stroke="{color}" stroke-width="4" stroke-linecap="round"/>')
    return f'<circle cx="{x}" cy="{y}" r="{size}" fill="{color}"/>'


LINE_APPS = [
    ("markato", "Markato", "#55ead8", "circle"),
    ("markviewer", "MarkViewer", "#a97fe5", "square"),
    ("macdown", "MacDown 0.7.3", "#7f9aab", "diamond"),
    ("md3000", "MacDown 3000", "#5f7c90", "triangle"),
    ("md2", "MD2 pre-release", "#a8bdca", "ring"),
    ("md2030", "MD2 0.3.0", "#d49b65", "plus"),
]


def line_panel(operation, panel_specs, cutoff_seconds, x, y):
    width, height = 916, 700
    plot_x, plot_y, plot_width, plot_height = 106, 118, 750, 450
    sizes = [65536, 1048576, 8388608]
    log_min, log_max = log2(sizes[0]), log2(sizes[-1])
    x_positions = [plot_x + plot_width * (log2(size)-log_min)/(log_max-log_min) for size in sizes]
    lines = [
        f'<g transform="translate({x} {y})">',
        f'<rect class="panel" width="{width}" height="{height}" rx="22"/>',
        f'<text class="panel-heading" x="30" y="53">{operation}</text>',
        f'<text class="cutoff" x="{width-30}" y="53" text-anchor="end">axis cutoff: {cutoff_seconds:g} s</text>',
        f'<rect class="plot-frame" x="{plot_x}" y="{plot_y}" width="{plot_width}" height="{plot_height}"/>',
    ]
    for index in range(5):
        value = cutoff_seconds * index / 4
        tick_y = plot_y + plot_height - plot_height * index / 4
        lines.append(f'<line class="grid" x1="{plot_x}" y1="{tick_y:.1f}" x2="{plot_x+plot_width}" y2="{tick_y:.1f}"/>')
        lines.append(f'<text class="tick" x="{plot_x-16}" y="{tick_y+5:.1f}" text-anchor="end">{value:g}</text>')
    for label, tick_x in zip(("64 KB", "1 MB", "8 MB"), x_positions):
        lines.append(f'<line class="grid" x1="{tick_x:.1f}" y1="{plot_y}" x2="{tick_x:.1f}" y2="{plot_y+plot_height}"/>')
        lines.append(f'<text class="tick" x="{tick_x:.1f}" y="{plot_y+plot_height+34}" text-anchor="middle">{label}</text>')
    lines.append(f'<text class="axis-title" x="24" y="{plot_y+plot_height/2}" text-anchor="middle" transform="rotate(-90 24 {plot_y+plot_height/2})">Latency (seconds)</text>')
    lines.append(f'<text class="axis-title" x="{plot_x+plot_width/2}" y="{plot_y+plot_height+75}" text-anchor="middle">Document size (log scale)</text>')

    for series_index, (key, _name, color, shape) in enumerate(LINE_APPS):
        points = []
        states = []
        for spec, point_x in zip(panel_specs, x_positions):
            value, _formatted = spec[4][key]
            if isinstance(value, (int, float)):
                seconds = value / 1000
                clipped = seconds > cutoff_seconds
                point_y = plot_y if clipped else plot_y + plot_height * (1-seconds/cutoff_seconds)
                points.append((point_x, point_y))
                states.append((point_x, point_y, clipped, None))
            else:
                points.append(None)
                states.append((point_x, plot_y, False, value))
        segment = []
        for point in points + [None]:
            if point is not None:
                segment.append(point)
            elif len(segment) >= 2:
                path = " ".join(("M" if index == 0 else "L") + f" {px:.1f} {py:.1f}" for index, (px, py) in enumerate(segment))
                lines.append(f'<path d="{path}" fill="none" stroke="{color}" stroke-width="4" stroke-linejoin="round" stroke-linecap="round"/>')
                segment = []
            else:
                segment = []
        for point_x, point_y, clipped, state in states:
            if state == "timeout":
                offset_x = point_x + (series_index-2)*5
                lines.append(marker("cross", offset_x, plot_y+10, color, 7))
            elif state == "untested":
                offset_x = point_x + (series_index-2)*5
                lines.append(f'<line x1="{offset_x-8}" y1="{plot_y+10}" x2="{offset_x+8}" y2="{plot_y+10}" stroke="{color}" stroke-width="4" stroke-linecap="round"/>')
            elif clipped:
                offset_x = point_x + (series_index-2)*5
                lines.append(marker("triangle", offset_x, point_y+7, color, 7))
            else:
                lines.append(marker(shape, point_x, point_y, color, 7))
    lines.append(f'<text class="status" x="{plot_x}" y="{height-24}">▲ above cutoff   × timed out   — not tested</text>')
    lines.append('</g>')
    return "\n".join(lines)


def line_chart():
    open_panel = line_panel("Open", M5_PANELS[:3], 5, 56, 190)
    edit_panel = line_panel("Edit", M5_PANELS[3:], 2, 1028, 190)
    legend = []
    legend_x = 80
    for key, name, color, shape in LINE_APPS:
        legend.append(marker(shape, legend_x, 970, color, 7))
        legend.append(f'<text class="legend" x="{legend_x+19}" y="976">{escape(name)}</text>')
        legend_x += 205 if key not in ("macdown", "md2") else 245
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="1050" viewBox="0 0 2000 1050" role="img" aria-labelledby="line-title line-desc">
  <title id="line-title">Markato performance by document size</title>
  <desc id="line-desc">Two line charts compare open and edit latency across 64 KB, 1 MB, and 8 MB Markdown documents for Markato and five competing editor builds. The open chart is cut off at five seconds and the edit chart at two seconds.</desc>
  <defs><linearGradient id="line-bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#07111d"/><stop offset="1" stop-color="#102333"/></linearGradient></defs>
  <style>
    .panel {{ fill:#0d1b2a; fill-opacity:.78; stroke:#466276; stroke-opacity:.42 }}
    .plot-frame {{ fill:#091624; stroke:#7890a0; stroke-opacity:.28 }}
    .grid {{ stroke:#a8bdca; stroke-opacity:.15 }}
    .panel-heading {{ fill:#fff; font-size:30px; font-weight:730 }}
    .cutoff,.tick,.status {{ fill:#7890a0; font-size:14px }}
    .axis-title {{ fill:#aabfcd; font-size:16px; font-weight:650 }}
    .legend {{ fill:#b9cad6; font-size:16px }}
  </style>
  <rect width="2000" height="1050" fill="url(#line-bg)"/><circle cx="1810" cy="50" r="500" fill="#45e0ff" fill-opacity=".035"/>
  <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
    <text x="76" y="94" fill="#fff" font-size="52" font-weight="760" letter-spacing="-1">Markato performance by document size</text>
    <text x="76" y="142" fill="#aabfcd" font-size="22">End-to-end latency until the requested view is visibly painted · lower is better</text>
    {open_panel}
    {edit_panel}
    {''.join(legend)}
    <text x="1920" y="976" fill="#708797" font-size="15" text-anchor="end">Apple M5, 10-core · macOS 27.2</text>
  </g>
</svg>'''


def hero_chart():
    return '''<svg xmlns="http://www.w3.org/2000/svg" width="1600" height="960" viewBox="0 0 1600 960" role="img" aria-labelledby="title desc">
  <title id="title">8 MB Markdown open performance</title>
  <desc id="desc">A linear-scale horizontal bar chart comparing end-to-end open latency. Markato takes 0.26 seconds, MacDown 2.0 takes 2.48 seconds, MacDown 0.7.3 takes 11.87 seconds, and both MarkViewer and MacDown 3000 exceed the 60-second timeout.</desc>
  <defs>
    <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#07111d"/><stop offset="1" stop-color="#102333"/></linearGradient>
    <linearGradient id="markato" x1="0" y1="0" x2="1" y2="0"><stop offset="0" stop-color="#45e0ff"/><stop offset="1" stop-color="#80ffb7"/></linearGradient>
    <pattern id="timeout" width="18" height="18" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><rect width="18" height="18" fill="#354f62"/><rect width="7" height="18" fill="#d7ff64" fill-opacity=".48"/></pattern>
    <filter id="glow" x="-100%" y="-100%" width="300%" height="300%"><feGaussianBlur stdDeviation="7" result="blur"/><feMerge><feMergeNode in="blur"/><feMergeNode in="SourceGraphic"/></feMerge></filter>
  </defs>
  <rect width="1600" height="960" fill="url(#bg)"/><circle cx="1425" cy="40" r="430" fill="#45e0ff" fill-opacity=".045"/><circle cx="1250" cy="960" r="520" fill="#80ffb7" fill-opacity=".035"/>
  <g font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif">
    <text x="86" y="82" fill="#80ffb7" font-size="24" font-weight="700" letter-spacing="3.5">MARKATO PERFORMANCE</text>
    <text x="86" y="153" fill="#fff" font-size="57" font-weight="760" letter-spacing="-1.5">8 MB Markdown open time</text>
    <text x="86" y="200" fill="#aabfcd" font-size="24">End-to-end latency until the first H1 is visible · linear scale · lower is better</text>
    <g transform="translate(86 278)">
      <g stroke="#a8bdca" stroke-opacity=".18"><line x1="290" y1="0" x2="290" y2="470"/><line x1="515" y1="0" x2="515" y2="470"/><line x1="740" y1="0" x2="740" y2="470"/><line x1="965" y1="0" x2="965" y2="470"/><line x1="1190" y1="0" x2="1190" y2="470"/></g>
      <g fill="#7f98a8" font-size="18" text-anchor="middle"><text x="290" y="-18">0</text><text x="515" y="-18">3 s</text><text x="740" y="-18">6 s</text><text x="965" y="-18">9 s</text><text x="1190" y="-18">12 s</text></g>
      <text x="0" y="52" fill="#fff" font-size="23" font-weight="720">Markato</text><rect x="290" y="21" width="19" height="48" rx="10" fill="url(#markato)" filter="url(#glow)"/><text x="330" y="53" fill="#80ffb7" font-size="24" font-weight="760">0.26 s</text>
      <text x="0" y="143" fill="#c1d0da" font-size="23">MacDown 2.0</text><rect x="290" y="112" width="186" height="48" rx="13" fill="#91a7b6"/><text x="497" y="144" fill="#e3ebf0" font-size="23" font-weight="650">2.48 s</text>
      <text x="0" y="234" fill="#c1d0da" font-size="23">MacDown 0.7.3</text><rect x="290" y="203" width="890" height="48" rx="13" fill="#6f899c"/><text x="1201" y="235" fill="#e3ebf0" font-size="23" font-weight="650">11.87 s</text>
      <text x="0" y="325" fill="#c1d0da" font-size="23">MarkViewer</text><rect x="290" y="294" width="900" height="48" rx="13" fill="url(#timeout)"/><path d="M1160 287 l30 31 -30 31" fill="#07111d"/><text x="1211" y="327" fill="#d7ff64" font-size="23" font-weight="720">&gt;60 s timeout</text>
      <text x="0" y="416" fill="#c1d0da" font-size="23">MacDown 3000</text><rect x="290" y="385" width="900" height="48" rx="13" fill="url(#timeout)"/><path d="M1160 378 l30 31 -30 31" fill="#07111d"/><text x="1211" y="418" fill="#d7ff64" font-size="23" font-weight="720">&gt;60 s timeout</text>
    </g>
    <g transform="translate(86 806)"><rect width="663" height="76" rx="18" fill="#0d1b2a" stroke="#45e0ff" stroke-opacity=".34"/><text x="28" y="49" fill="#fff" font-size="26" font-weight="720">9.7× faster than MacDown 2.0</text><rect x="687" width="594" height="76" rx="18" fill="#0d1b2a" stroke="#45e0ff" stroke-opacity=".34"/><text x="715" y="49" fill="#fff" font-size="26" font-weight="720">MarkViewer did not open in 60 s</text></g>
    <text x="86" y="927" fill="#708797" font-size="16">Median of 3 fresh-process opens where completed · Apple M4 Pro, 14-core · macOS 26.6.2 · 1120 × 760 pt</text>
  </g>
</svg>'''


ASSETS.mkdir(parents=True, exist_ok=True)
(ASSETS / "markato-performance.svg").write_text(hero_chart())
(ASSETS / "markato-performance-all.svg").write_text(complete_chart())
(ASSETS / "markato-performance-m5.svg").write_text(complete_chart(
    panels=M5_PANELS,
    heading="Markato performance",
    footer="Apple M5, 10-core · macOS 27.2 · medians where completed",
    note="* MacDown 3000's 8 MB open is one completed observation; its first edit timed out.",
    eyebrow=False,
    apps=M5_APPS,
    description="Six linear-scale horizontal bar charts compare Markato, MarkViewer, MacDown 0.7.3, MacDown 3000, and two MacDown 2 builds at 64 KB, 1 MB, and 8 MB.",
))
(ASSETS / "markato-performance-lines-m5.svg").write_text(line_chart())
