"""The Hermès-inspired system: paper, ink, one orange, and a lot of air.

Restraint is the idea, so the values are deliberately few: two grounds, three
ink tiers, one rule weight, one accent used once per screen. Every pair is
contrast-checked — the accent is #C24A16 on paper (4.5:1, and 4.9:1 under
white) and #FF8A3D at night (8:1). The brighter orange people picture fails
on white, so it would only ever have been decoration.
"""

LIGHT = dict(
    ground="#F8F5EF", raised="#FFFFFF", ink="#1A1714",
    ink2="rgba(26,23,20,0.62)", ink3="rgba(26,23,20,0.45)",
    rule="rgba(26,23,20,0.14)", rule2="rgba(26,23,20,0.30)",
    accent="#C24A16", glass="rgba(255,255,255,0.66)", shadow="rgba(26,23,20,0.10)",
)

DARK = dict(
    ground="#131211", raised="#1B1917", ink="#F2EEE7",
    ink2="rgba(242,238,231,0.62)", ink3="rgba(242,238,231,0.42)",
    rule="rgba(242,238,231,0.13)", rule2="rgba(242,238,231,0.26)",
    accent="#FF8A3D", glass="rgba(35,32,29,0.62)", shadow="rgba(0,0,0,0.45)",
)

SERIF = "'Iowan Old Style', 'New York', Georgia, 'Times New Roman', serif"
SANS = "-apple-system, BlinkMacSystemFont, 'SF Pro Text', system-ui, sans-serif"
MONO = "ui-monospace, 'SF Mono', Menlo, monospace"

def head(t, w=390, h=844):
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
    body {{ margin: 0; font-family: {SANS}; -webkit-font-smoothing: antialiased; }}
    a {{ color: {t['accent']}; }} a:hover {{ color: {t['ink']}; }}
    .screen {{ position: relative; width: {w}px; height: {h}px; overflow: hidden;
      background: {t['ground']}; color: {t['ink']}; }}
    .layer {{ position: relative; height: 100%; display: flex; flex-direction: column; }}
    .rule {{ height: 1px; background: {t['rule']}; }}
    .rule-strong {{ height: 1px; background: {t['rule2']}; }}
    .t1 {{ font-family: {SERIF}; font-size: 34px; line-height: 40px; letter-spacing: -0.4px; }}
    .t2 {{ font-family: {SERIF}; font-size: 23px; line-height: 29px; letter-spacing: -0.2px; }}
    .label {{ font-size: 10px; font-weight: 600; letter-spacing: 1.4px;
      text-transform: uppercase; color: {t['ink3']}; }}
    .body {{ font-size: 16px; line-height: 24px; letter-spacing: -0.2px; }}
    .sub {{ font-size: 15px; color: {t['ink2']}; letter-spacing: -0.1px; }}
    .fn {{ font-size: 13px; color: {t['ink2']}; }}
    .c2 {{ font-size: 11px; color: {t['ink3']}; }}
    .mono {{ font-family: {MONO}; font-size: 12.5px; }}
    .num {{ font-family: {SERIF}; font-size: 13px; color: {t['ink3']};
      font-variant-numeric: tabular-nums; }}
    .glass {{ background: {t['glass']}; -webkit-backdrop-filter: blur(20px) saturate(1.3);
      backdrop-filter: blur(20px) saturate(1.3); }}
    .row {{ display: flex; align-items: center; gap: 14px; min-height: 60px; }}
    .dot {{ width: 5px; height: 5px; border-radius: 3px; background: {t['accent']}; }}
  </style>
</helmet>
"""

TAIL = """</x-dc>
</body>
</html>
"""

def ico(name, c, s=20, sw=1.25):
    """Hairline icons, drawn at the weight of the rules they sit among."""
    p = {
      "compose": '<path d="M4 20h16"/><path d="M14.5 5.5l4 4L9 19H5v-4z"/>',
      "search": '<circle cx="11" cy="11" r="6"/><path d="M15.5 15.5L20 20"/>',
      "chevron": '<path d="M9 5l7 7-7 7"/>',
      "chevdown": '<path d="M5 9l7 7 7-7"/>',
      "back": '<path d="M15 5l-7 7 7 7"/>',
      "display": '<rect x="3" y="4.5" width="18" height="12" rx="1.5"/><path d="M9 20h6M12 16.5V20"/>',
      "people": '<circle cx="9" cy="9" r="3"/><path d="M3.5 19c0-3 2.5-5 5.5-5s5.5 2 5.5 5"/><path d="M16 7.5a2.6 2.6 0 010 5"/><path d="M17.5 19c0-2-.7-3.6-1.8-4.6 2.7.2 4.8 2.1 4.8 4.6"/>',
      "share": '<path d="M12 15V4"/><path d="M8 8l4-4 4 4"/><path d="M5 14v4a2 2 0 002 2h10a2 2 0 002-2v-4"/>',
      "gear": '<circle cx="12" cy="12" r="3"/><path d="M12 3.5v2M12 18.5v2M20.5 12h-2M5.5 12h-2M18 6l-1.4 1.4M7.4 16.6L6 18M18 18l-1.4-1.4M7.4 7.4L6 6"/>',
      "plus": '<path d="M12 5v14M5 12h14"/>',
      "arrowup": '<path d="M12 19V5"/><path d="M6 11l6-6 6 6"/>',
      "check": '<path d="M5 12.5l4.5 4.5L19 7.5"/>',
      "cpu": '<rect x="7" y="7" width="10" height="10" rx="1.5"/><path d="M10 3v3M14 3v3M10 18v3M14 18v3M3 10h3M3 14h3M18 10h3M18 14h3"/>',
      "folder": '<path d="M3 7a2 2 0 012-2h4l2 2h8a2 2 0 012 2v8a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
      "bubble": '<path d="M4 6a2 2 0 012-2h12a2 2 0 012 2v7a2 2 0 01-2 2H9l-5 4z"/>',
      "hammer": '<path d="M13.5 6.5l4-4 4 4-4 4z"/><path d="M11.3 8.7L4 16v4h4l7.3-7.3"/>',
      "loupe": '<circle cx="10.5" cy="10.5" r="5.5"/><path d="M14.6 14.6L20 20"/>',
      "compass": '<circle cx="12" cy="12" r="8"/><path d="M15.2 8.8l-1.9 4.5-4.5 1.9 1.9-4.5z"/>',
      "book": '<path d="M4 5.5A2.5 2.5 0 016.5 3H20v15H6.5A2.5 2.5 0 004 20.5z"/><path d="M4 5.5v15"/>',
      "stop": '<rect x="7.5" y="7.5" width="9" height="9" rx="1"/>',
      "dots": '<circle cx="6" cy="12" r="1.2"/><circle cx="12" cy="12" r="1.2"/><circle cx="18" cy="12" r="1.2"/>',
      "brain": '<path d="M9 4.5A3 3 0 006 7.5 2.6 2.6 0 004.5 10 2.6 2.6 0 006 12.4 3 3 0 009 15.5"/><path d="M15 4.5a3 3 0 013 3 2.6 2.6 0 011.5 2.5A2.6 2.6 0 0118 12.4a3 3 0 01-3 3"/><path d="M12 4v16"/>',
      "box": '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M4 7.5l8 4.5 8-4.5M12 12v9"/>',
      "window": '<rect x="3" y="5" width="18" height="14" rx="1.5"/><path d="M3 9h18"/>',
    }[name]
    return (f'<svg width="{s}" height="{s}" viewBox="0 0 24 24" fill="none" stroke="{c}" '
            f'stroke-width="{sw}" stroke-linecap="round" stroke-linejoin="round">{p}</svg>')
