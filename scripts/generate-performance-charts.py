#!/usr/bin/env python3
"""Generate the website and complete performance charts from the documented data."""
from pathlib import Path
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


def tick_label(value, maximum, unit):
    if value == 0:
        return "0"
    if unit == "ms":
        return f"{value:g} ms"
    seconds = value / 1000
    return f"{seconds:g} s"


def panel(label, operation, maximum, unit, values, x, y):
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

    for index, (key, name, app_class, fill) in enumerate(APPS):
        row_y = 28 + index * 49
        bar_y = row_y - 19
        value, formatted = values[key]
        lines.append(f'<text class="{app_class}" x="0" y="{row_y}">{escape(name)}</text>')
        if value == "timeout":
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{plot_width}" height="25" rx="12" fill="url(#timeout)"/>')
            lines.append(f'<text class="value-timeout" x="{left + plot_width - 10}" y="{row_y}" text-anchor="end">{escape(formatted)}</text>')
        elif value == "untested":
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{plot_width}" height="25" rx="12" fill="url(#untested)"/>')
            lines.append(f'<text class="value-untested" x="{left + plot_width / 2}" y="{row_y}" text-anchor="middle">{escape(formatted)}</text>')
        else:
            width = max(8, plot_width * value / maximum)
            lines.append(f'<rect x="{left}" y="{bar_y}" width="{width:.1f}" height="25" rx="12" fill="{fill}"/>')
            value_class = "value-markato" if key == "markato" else "value"
            if width > 335:
                lines.append(f'<text class="{value_class}" x="{left + width - 8:.1f}" y="{row_y}" text-anchor="end">{escape(formatted)}</text>')
            else:
                lines.append(f'<text class="{value_class}" x="{left + width + 9:.1f}" y="{row_y}">{escape(formatted)}</text>')
    lines.extend(['</g>', '</g>'])
    return "\n".join(lines)


def complete_chart():
    positions = [(56, 235), (695, 235), (1334, 235), (56, 695), (695, 695), (1334, 695)]
    panels = "\n".join(panel(*spec, *position) for spec, position in zip(PANELS, positions))
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="2000" height="1250" viewBox="0 0 2000 1250" role="img" aria-labelledby="title desc">
  <title id="title">Complete Markato benchmark comparison</title>
  <desc id="desc">Six linear-scale horizontal bar charts compare Markato, MarkViewer, MacDown 0.7.3, MacDown 3000, and MacDown 2.0 open and edit latency for 64 KB, 1 MB, and 8 MB Markdown documents.</desc>
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
    <text x="76" y="78" fill="#80ffb7" font-size="23" font-weight="700" letter-spacing="3.5">MARKATO PERFORMANCE</text>
    <text x="76" y="143" fill="#fff" font-size="52" font-weight="760" letter-spacing="-1">Complete benchmark comparison</text>
    <text x="76" y="187" fill="#aabfcd" font-size="22">End-to-end latency until the requested view is visibly painted · linear scales · lower is better</text>
    {panels}
    <g transform="translate(76 1195)">
      <rect x="0" y="-18" width="24" height="14" rx="7" fill="url(#markato)"/><text x="36" y="-5" fill="#aabfcd" font-size="16">Markato</text>
      <rect x="138" y="-18" width="24" height="14" rx="7" fill="#a97fe5"/><text x="174" y="-5" fill="#aabfcd" font-size="16">MarkViewer</text>
      <rect x="330" y="-18" width="24" height="14" rx="7" fill="url(#timeout)"/><text x="366" y="-5" fill="#aabfcd" font-size="16">60-second operation limit</text>
      <rect x="666" y="-18" width="24" height="14" rx="7" fill="url(#untested)"/><text x="702" y="-5" fill="#aabfcd" font-size="16">not tested: prerequisite open timed out</text>
      <text x="1870" y="-5" fill="#708797" font-size="15" text-anchor="end">Apple M4 Pro, 14-core · macOS 26.6.2 · medians where completed</text>
    </g>
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
