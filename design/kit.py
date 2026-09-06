from tokens import DARK, LIGHT

FONT = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', 'Helvetica Neue', system-ui, sans-serif"
MONO = "ui-monospace, 'SF Mono', 'JetBrains Mono', Menlo, monospace"

def head(t, w=390, h=844):
    """Page shell: the engraving ground the app draws under every screen."""
    return f"""<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <script src="./support.js"></script>
</head>
<body>
<x-dc>
<helmet>
  <style>
    * {{ box-sizing: border-box; }}
    body {{ margin: 0; font-family: {FONT}; -webkit-font-smoothing: antialiased; }}
    a {{ color: {t['bright']}; }} a:hover {{ color: {t['text']}; }}
    .screen {{ position: relative; width: {w}px; height: {h}px; overflow: hidden;
      background: {t['ground']}; color: {t['text']}; }}
    .atmos {{ position: absolute; inset: 0; background-image: url("atmosphere.jpg");
      background-size: cover; background-position: center; filter: grayscale(1);
      opacity: {t['atmos']}; pointer-events: none; }}
    .layer {{ position: relative; height: 100%; display: flex; flex-direction: column; }}
    .glass {{ background: {t['glass2']}; -webkit-backdrop-filter: blur(24px) saturate(1.4);
      backdrop-filter: blur(24px) saturate(1.4); border: 0.75px solid {t['rim']};
      box-shadow: 0 8px 22px {t['shadow']}, inset 0 0.75px 0 {t['hi']}; border-radius: 18px; }}
    .well {{ background: {t['glass']}; border-radius: 12px; }}
    .cap {{ font-size: 11px; font-weight: 600; letter-spacing: 0.9px; text-transform: uppercase;
      color: {t['text2']}; }}
    .t1 {{ font-size: 34px; font-weight: 700; letter-spacing: -0.8px; line-height: 41px; }}
    .h  {{ font-size: 17px; font-weight: 600; letter-spacing: -0.4px; }}
    .b  {{ font-size: 17px; letter-spacing: -0.4px; line-height: 25px; }}
    .sub {{ font-size: 15px; color: {t['text2']}; letter-spacing: -0.2px; }}
    .fn {{ font-size: 13px; color: {t['text2']}; }}
    .c2 {{ font-size: 11px; color: {t['text3']}; }}
    .mono {{ font-family: {MONO}; font-size: 13px; }}
    .row {{ display: flex; align-items: center; gap: 12px; min-height: 52px; padding: 0 14px; }}
    .div {{ height: 0.75px; background: {t['sep']}; }}
    .stack {{ display: flex; flex-direction: column; }}
    .navpill {{ width: 34px; height: 34px; border-radius: 17px; display: flex; align-items: center;
      justify-content: center; background: {t['glass']}; border: 0.75px solid {t['rim']}; }}
    .chip {{ display: flex; align-items: center; gap: 6px; padding: 7px 12px; border-radius: 999px;
      background: {t['glass']}; border: 0.75px solid {t['rim']}; font-size: 13px; font-weight: 500; }}
  </style>
</helmet>
"""

TAIL = """</x-dc>
</body>
</html>
"""

def ico(name, c, s=20, sw=1.6):
    """Stroke icons on a 24 grid — one family, scaled and recolored by use."""
    p = {
      "compose": '<path d="M4 20h16"/><path d="M14.5 5.5l4 4L9 19H5v-4z"/>',
      "search": '<circle cx="11" cy="11" r="6"/><path d="M15.5 15.5L20 20"/>',
      "chevron": '<path d="M9 5l7 7-7 7"/>',
      "chevdown": '<path d="M5 9l7 7 7-7"/>',
      "back": '<path d="M15 5l-7 7 7 7"/>',
      "display": '<rect x="3" y="4" width="18" height="12" rx="2"/><path d="M9 20h6M12 16v4"/>',
      "people": '<circle cx="9" cy="9" r="3"/><path d="M3.5 19c0-3 2.5-5 5.5-5s5.5 2 5.5 5"/><path d="M16 7.5a2.6 2.6 0 010 5"/><path d="M17.5 19c0-2-.7-3.6-1.8-4.6 2.7.2 4.8 2.1 4.8 4.6"/>',
      "share": '<path d="M12 15V4"/><path d="M8 8l4-4 4 4"/><path d="M5 14v4a2 2 0 002 2h10a2 2 0 002-2v-4"/>',
      "gear": '<circle cx="12" cy="12" r="3.2"/><path d="M12 3v2.2M12 18.8V21M21 12h-2.2M5.2 12H3M18.4 5.6l-1.6 1.6M7.2 16.8l-1.6 1.6M18.4 18.4l-1.6-1.6M7.2 7.2L5.6 5.6"/>',
      "plus": '<path d="M12 5v14M5 12h14"/>',
      "arrowup": '<path d="M12 19V5"/><path d="M6 11l6-6 6 6"/>',
      "check": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
      "xmark": '<path d="M6 6l12 12M18 6L6 18"/>',
      "cpu": '<rect x="7" y="7" width="10" height="10" rx="2"/><path d="M10 3v3M14 3v3M10 18v3M14 18v3M3 10h3M3 14h3M18 10h3M18 14h3"/>',
      "folder": '<path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
      "bubble": '<path d="M4 6a2 2 0 012-2h12a2 2 0 012 2v7a2 2 0 01-2 2H9l-5 4z"/>',
      "person": '<circle cx="12" cy="9" r="3.2"/><path d="M5.5 20c0-3.4 2.9-6 6.5-6s6.5 2.6 6.5 6"/>',
      "box": '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
      "brain": '<path d="M9 4.5A3 3 0 006 7.5 2.6 2.6 0 004.5 10 2.6 2.6 0 006 12.4 3 3 0 009 15.5"/><path d="M15 4.5a3 3 0 013 3 2.6 2.6 0 011.5 2.5A2.6 2.6 0 0118 12.4a3 3 0 01-3 3"/><path d="M12 4v16"/>',
      "safari": '<circle cx="12" cy="12" r="8.2"/><path d="M15 9l-1.6 4.4L9 15l1.6-4.4z"/>',
      "doc": '<path d="M6 3h7l5 5v13H6z"/><path d="M13 3v5h5"/>',
      "camera": '<rect x="3" y="6.5" width="18" height="12" rx="2.4"/><circle cx="12" cy="12.5" r="3.2"/>',
      "pulse": '<path d="M3 12h4l2.5-6 4 12L16 12h5"/>',
      "clip": '<path d="M18 8.5l-7.6 7.6a3 3 0 11-4.2-4.2l8-8a4.2 4.2 0 016 6l-8.2 8.2"/>',
      "diff": '<path d="M7 4v10M7 20v-2M17 20V10M17 4v2"/><circle cx="7" cy="17" r="2.4"/><circle cx="17" cy="7" r="2.4"/>',
      "stop": '<rect x="7" y="7" width="10" height="10" rx="2"/>',
      "wifi": '<path d="M4 9.5a12 12 0 0116 0"/><path d="M7.5 13a7 7 0 019 0"/><circle cx="12" cy="17" r="1.4"/>',
      "dots": '<circle cx="6" cy="12" r="1.5"/><circle cx="12" cy="12" r="1.5"/><circle cx="18" cy="12" r="1.5"/>',
      "trash": '<path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13"/>',
      "pencil": '<path d="M4 20h4L20 8l-4-4L4 16z"/>',
      "window": '<rect x="3" y="5" width="18" height="14" rx="2"/><path d="M3 9h18"/>',
    }[name]
    return (f'<svg width="{s}" height="{s}" viewBox="0 0 24 24" fill="none" stroke="{c}" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">{p}</svg>')
