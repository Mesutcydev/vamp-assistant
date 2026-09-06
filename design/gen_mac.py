"""macOS artboards, drawn on the same ramp the iOS canvas uses.

Everything here is lifted from App/Theme.swift (the greys are the phone's to
the byte) and the shipping window structure: sidebar region, transcript,
StatusBarView, and the composer — which is drawn exactly as it stands today,
because the composer is the one part of the Mac app we are not changing.
"""
from kit import head, TAIL, ico, MONO
from tokens import DARK, LIGHT

W, H = 1320, 856


def shell(t, body, title):
    """Window chrome: traffic lights, unified toolbar, then the content row."""
    return head(t, W, H) + f'''<div class="screen" style="width:{W}px;height:{H}px;border-radius:12px">
  <div class="atmos"></div>
  <div class="layer">{body}</div>
</div>''' + TAIL


def lights():
    return ('<div style="display:flex;gap:8px;padding-right:6px">'
            + ''.join(f'<div style="width:12px;height:12px;border-radius:6px;background:{c}"></div>'
                      for c in ('#FF5F57', '#FEBC2E', '#28C840')) + '</div>')


def toolbar(t, title, right):
    return f'''<div style="height:52px;flex:none;display:flex;align-items:center;gap:14px;
      padding:0 16px;border-bottom:0.75px solid {t['sep']};background:{t['glass2']};
      -webkit-backdrop-filter:blur(24px);backdrop-filter:blur(24px)">
      {lights()}
      {ico('window', t['text2'], 17)}
      <div style="font-size:14px;font-weight:600;letter-spacing:-0.2px">{title}</div>
      <div style="flex:1"></div>
      {right}
    </div>'''


def tbtn(t, name, label=None):
    inner = ico(name, t['text2'], 16)
    if label:
        inner += f'<div style="font-size:12.5px;color:{t["text2"]};font-weight:500">{label}</div>'
    return (f'<div style="display:flex;align-items:center;gap:6px;height:28px;padding:0 10px;'
            f'border-radius:8px;background:{t["well"]}">{inner}</div>')


# ---------------------------------------------------------------- sidebar

def sidebar(t, selected=0):
    def row(name, meta, sel=False, running=False):
        bg = f'background:{t["well"]};' if sel else ''
        dot = (f'<div style="width:6px;height:6px;border-radius:3px;background:{t["bright"]};flex:none"></div>'
               if running else '<div style="width:6px;flex:none"></div>')
        return f'''<div style="{bg}display:flex;align-items:center;gap:9px;padding:9px 10px;border-radius:8px">
          {dot}
          <div style="flex:1;min-width:0">
            <div style="font-size:13px;font-weight:500;letter-spacing:-0.1px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{name}</div>
            <div style="font-size:11px;color:{t['text3']};margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{meta}</div>
          </div>
        </div>'''

    def cap(text, pad='16px 10px 5px'):
        return f'<div class="cap" style="font-size:10px;padding:{pad}">{text}</div>'

    rows = [
        ('Fix the composer layout', 'Editing · vamp-assistant', True, True),
        ('Audit the pairing flow', '8 messages', False, False),
    ]
    yest = [
        ('Explain the checkpoint format', '31 messages', False, False),
        ('Port the diff viewer', 'forgesign · 112 messages', False, False),
        ('Trim the settings tabs', 'vamp-assistant · 14 messages', False, False),
    ]
    return f'''<div style="width:262px;flex:none;border-right:0.75px solid {t['sep']};
      display:flex;flex-direction:column;padding:0 8px;background:{t['glass']}">
      <div style="display:flex;align-items:center;gap:8px;padding:12px 10px 6px">
        {ico('folder', t['text3'], 15)}
        <div class="cap" style="font-size:10px;flex:1">WORKSPACE</div>
        {ico('chevdown', t['text3'], 13, 2)}
      </div>
      <div style="font-size:13.5px;font-weight:600;padding:0 10px 10px">vamp-assistant</div>
      <div style="display:flex;align-items:center;gap:7px;height:30px;padding:0 10px;border-radius:8px;background:{t['well']}">
        {ico('search', t['text3'], 14)}<div style="font-size:12.5px;color:{t['text3']}">Search chats</div>
      </div>
      {cap('TODAY')}
      {''.join(row(*r) for r in rows)}
      {cap('YESTERDAY')}
      {''.join(row(*r) for r in yest)}
      <div style="flex:1"></div>
      <div class="div" style="margin:0 4px"></div>
      <div style="display:flex;align-items:center;gap:9px;padding:11px 10px 13px">
        <div style="width:7px;height:7px;border-radius:4px;background:{t['green']}"></div>
        <div style="font-size:12px;color:{t['text2']};flex:1">Codex · connected</div>
        {ico('gear', t['text3'], 15)}
      </div>
    </div>'''


# ------------------------------------------------------------- transcript

def ledger(t, entries):
    """The tool ledger: a rail of rows, not a stack of boxes."""
    out = []
    for glyph, name, meta in entries:
        out.append(f'''<div style="display:flex;align-items:center;gap:9px;min-height:27px">
          {ico(glyph, t['text3'], 13, 1.6)}
          <div style="font-family:{MONO};font-size:12px;color:{t['text2']}">{name}</div>
          <div style="font-size:11.5px;color:{t['text3']}">{meta}</div>
        </div>''')
    return (f'<div style="border-left:0.75px solid {t["sep"]};padding-left:14px;margin-left:2px">'
            + ''.join(out) + '</div>')


def user_bubble(t, text):
    return f'''<div style="display:flex;justify-content:flex-end">
      <div style="max-width:70%;padding:10px 14px;border-radius:16px;background:{t['well']};
        font-size:14px;line-height:21px;letter-spacing:-0.1px">{text}</div>
    </div>'''


def para(t, text, color=None):
    return (f'<div style="font-size:14.5px;line-height:23px;letter-spacing:-0.1px;'
            f'color:{color or t["text"]}">{text}</div>')


def tasklist(t, items):
    rows = []
    for done, label in items:
        mark = (ico('check', t['text2'], 13, 2) if done
                else f'<div style="width:13px;height:13px;border-radius:3px;border:1px solid {t["sep"]}"></div>')
        col = t['text3'] if done else t['text']
        deco = 'text-decoration:line-through;' if done else ''
        rows.append(f'''<div style="display:flex;align-items:center;gap:10px;min-height:29px">
          {mark}<div style="font-size:13.5px;color:{col};{deco}">{label}</div>
        </div>''')
    return f'''<div style="border:0.75px solid {t['sep']};border-radius:14px;padding:12px 14px">
      <div class="cap" style="font-size:10px;padding-bottom:4px">PLAN · 2 OF 4</div>
      {''.join(rows)}
    </div>'''


def approval(t):
    return f'''<div style="border:0.75px solid {t['sep']};border-radius:14px;padding:14px 16px">
      <div style="display:flex;align-items:center;gap:8px;padding-bottom:8px">
        {ico('pencil', t['text2'], 15)}
        <div style="font-size:13.5px;font-weight:600">Edit RemoteComposerView.swift</div>
      </div>
      <div style="font-family:{MONO};font-size:12px;color:{t['text2']};line-height:19px">
        <span style="color:{t['green']}">+ .toolbar(removing: .keyboard)</span><br>
        <span style="color:{t['red']}">− .keyboardDismissToolbar()</span>
      </div>
      <div style="display:flex;gap:8px;padding-top:12px">
        <div style="height:28px;padding:0 14px;border-radius:8px;background:{t['accent']};color:#fff;
          font-size:12.5px;font-weight:600;display:flex;align-items:center">Allow</div>
        <div style="height:28px;padding:0 14px;border-radius:8px;border:0.75px solid {t['sep']};
          font-size:12.5px;font-weight:500;color:{t['text2']};display:flex;align-items:center">Allow for this chat</div>
        <div style="height:28px;padding:0 14px;border-radius:8px;border:0.75px solid {t['sep']};
          font-size:12.5px;font-weight:500;color:{t['text2']};display:flex;align-items:center">Reject</div>
      </div>
    </div>'''


def statusbar(t):
    def seg(glyph, text):
        return (f'<div style="display:flex;align-items:center;gap:6px">{ico(glyph, t["text3"], 13)}'
                f'<div style="font-size:11.5px;color:{t["text2"]}">{text}</div></div>')
    return f'''<div style="height:30px;flex:none;display:flex;align-items:center;gap:18px;
      padding:0 22px;border-top:0.75px solid {t['sep']}">
      <div style="display:flex;align-items:center;gap:6px">
        <div style="width:6px;height:6px;border-radius:3px;background:{t['bright']}"></div>
        <div style="font-size:11.5px;color:{t['text2']}">Editing</div>
      </div>
      {seg('cpu','GPT-5 Codex · 34 tok/s')}
      {seg('folder','vamp-assistant')}
      {seg('diff','3 files changed')}
      <div style="flex:1"></div>
      <div style="font-size:11.5px;color:{t['text3']}">12.4k context</div>
    </div>'''


def composer(t):
    """Drawn as it ships. The Mac composer is deliberately untouched."""
    def pill(glyph, label):
        return (f'<div style="display:flex;align-items:center;gap:5px;height:26px;padding:0 10px;'
                f'border-radius:13px;background:{t["well"]}">{ico(glyph, t["text2"], 13)}'
                f'<div style="font-size:11.5px;color:{t["text2"]};font-weight:500">{label}</div></div>')
    return f'''<div style="flex:none;padding:12px 22px 16px">
      <div style="border:0.75px solid {t['rim']};border-radius:14px;background:{t['glass2']};
        -webkit-backdrop-filter:blur(24px);backdrop-filter:blur(24px);padding:12px 14px 10px">
        <div style="font-size:14px;color:{t['text3']};padding-bottom:12px">Ask, or describe what to change…</div>
        <div style="display:flex;align-items:center;gap:8px">
          {ico('plus', t['text2'], 17)}
          {pill('cpu','GPT-5 Codex')}
          {pill('brain','Extended thinking')}
          {pill('hammer','Agent')}
          <div style="flex:1"></div>
          <div style="font-size:11.5px;color:{t['text3']}">⌘↩ to send</div>
          <div style="width:28px;height:28px;border-radius:14px;background:{t['accent']};
            display:flex;align-items:center;justify-content:center">{ico('arrowup','#FFFFFF',15,2)}</div>
        </div>
      </div>
    </div>'''


def main(t):
    body = f'''
    {toolbar(t, "Fix the composer layout",
             tbtn(t, "safari") + tbtn(t, "camera") + tbtn(t, "pulse") + tbtn(t, "people", "Bots"))}
    <div style="flex:1;display:flex;min-height:0">
      {sidebar(t)}
      <div style="flex:1;display:flex;flex-direction:column;min-width:0">
        <div style="flex:1;padding:30px 0 6px;overflow:hidden">
          <div style="max-width:700px;margin:0 auto;display:flex;flex-direction:column;gap:22px">
            {user_bubble(t, "The keyboard chip overlaps the send button on iOS. Fix it everywhere it happens.")}
            {para(t, "The accessory was attached to the sessions <b>NavigationStack</b>, so it followed the push into the conversation and drew a second trailing button under the composer. Three screens have that shape.")}
            {ledger(t, [("loupe", "grep", "keyboardDismissToolbar — 8 matches"),
                        ("doc", "read", "RemoteSessionViews.swift, RemoteBotsPage.swift"),
                        ("pencil", "edit", "3 files · +7 −4")])}
            {tasklist(t, [(True, "Find every call site"), (True, "Separate the ones with their own bottom action"),
                          (False, "Swap those for interactive scroll dismissal"), (False, "Build and verify on device")])}
            {approval(t)}
          </div>
        </div>
        {statusbar(t)}
        {composer(t)}
      </div>
    </div>'''
    return shell(t, body, "Chat")


# ------------------------------------------------------------------ bots

def bots(t):
    def bot(glyph, name, role, model, running=False):
        right = (f'''<div style="display:flex;align-items:center;gap:9px">
            <div style="width:6px;height:6px;border-radius:3px;background:{t['bright']}"></div>
            <div style="font-size:12px;color:{t['text2']};font-variant-numeric:tabular-nums">04:12</div>
            <div style="height:26px;padding:0 12px;border-radius:8px;border:0.75px solid {t['sep']};
              font-size:12px;color:{t['text2']};display:flex;align-items:center">Stop</div>
          </div>''' if running else
                 f'<div style="font-size:12px;color:{t["text3"]}">{model}</div>')
        return f'''<div style="display:flex;align-items:center;gap:13px;min-height:58px">
          {ico(glyph, t['text2'], 19)}
          <div style="flex:1;min-width:0">
            <div style="font-size:14px;font-weight:600;letter-spacing:-0.2px">{name}</div>
            <div style="font-size:12px;color:{t['text3']};margin-top:2px">{role}</div>
          </div>
          {right}
        </div><div class="div"></div>'''

    body = f'''
    {toolbar(t, "Bots", tbtn(t, "people", "Delegate"))}
    <div style="flex:1;display:flex;min-height:0">
      {sidebar(t)}
      <div style="flex:1;min-width:0;padding:26px 0;overflow:hidden">
        <div style="max-width:720px;margin:0 auto">
          <div style="font-size:26px;font-weight:700;letter-spacing:-0.6px">Bots</div>
          <div style="font-size:13.5px;color:{t['text2']};padding-top:5px;max-width:520px;line-height:20px">
            Each one keeps its own model and its own idea of what it is for. Hand it an outcome and it works while you do something else.</div>
          <div class="cap" style="font-size:10px;padding:26px 0 6px">IN FLIGHT</div>
          <div class="div"></div>
          {bot('hammer','Builder','Ships the change end to end','', running=True)}
          <div class="cap" style="font-size:10px;padding:26px 0 6px">ROSTER</div>
          <div class="div"></div>
          {bot('hammer','Builder','Ships the change end to end','GPT-5 Codex')}
          {bot('loupe','Reviewer','Reads the diff before you do','Claude Opus 4.5')}
          {bot('compass','Scout','Finds where a thing lives','Haiku 4.5')}
          {bot('doc','Scribe','Docs, changelogs, release notes','GPT-5 mini')}
          {bot('pulse','Sentry','Watches CI and reports back','Haiku 4.5')}
        </div>
      </div>
    </div>'''
    return shell(t, body, "Bots")


# -------------------------------------------------------------- settings

def settings(t):
    def tab(glyph, label, sel=False, key=''):
        bg = f'background:{t["well"]};' if sel else ''
        marker = (f'<div style="position:absolute;left:2px;top:50%;transform:translateY(-50%);'
                  f'width:2.5px;height:15px;border-radius:2px;background:{t["accent"]}"></div>' if sel else '')
        return f'''<div style="position:relative;{bg}display:flex;align-items:center;gap:9px;padding:8px 10px;border-radius:8px">
          {marker}
          {ico(glyph, t['accent'] if sel else t['text3'], 14)}
          <div style="flex:1;font-size:13px;font-weight:{600 if sel else 400};color:{t['text'] if sel else t['text2']}">{label}</div>
          <div style="font-size:11px;color:{t['text3']}">{key}</div>
        </div>'''

    def railcap(text):
        return (f'<div class="cap" style="font-size:9.5px;padding:12px 10px 4px;color:{t["text3"]}">'
                f'{text.upper()}</div>')

    def row(label, detail, sub=None, control='chev'):
        ctl = {'chev': ico('chevron', t['text3'], 13, 2),
               'switch': f'<div style="width:38px;height:22px;border-radius:11px;background:{t["accent"]};'
                         f'display:flex;align-items:center;justify-content:flex-end;padding:0 2px">'
                         f'<div style="width:18px;height:18px;border-radius:9px;background:#fff"></div></div>',
               'none': ''}[control]
        subline = (f'<div style="font-size:11.5px;color:{t["text3"]};margin-top:3px;max-width:420px;line-height:17px">{sub}</div>'
                   if sub else '')
        return f'''<div style="display:flex;align-items:center;gap:14px;min-height:52px">
          <div style="flex:1"><div style="font-size:13.5px">{label}</div>{subline}</div>
          <div style="font-size:12.5px;color:{t['text2']}">{detail}</div>
          {ctl}
        </div><div class="div"></div>'''

    def swatch(hexv, sel=False):
        ring = f'box-shadow:0 0 0 2px {t["ground"]},0 0 0 3.5px {t["text2"]};' if sel else ''
        return f'<div style="width:22px;height:22px;border-radius:11px;background:{hexv};{ring}"></div>'

    body = f'''
    {toolbar(t, "Settings", '')}
    <div style="flex:1;display:flex;min-height:0">
      <div style="width:246px;flex:none;border-right:0.75px solid {t['sep']};padding:12px 8px;
        background:{t['glass']};display:flex;flex-direction:column">
        <div style="display:flex;align-items:center;gap:9px;padding:8px 10px;color:{t['text2']}">
          {ico('back', t['text3'], 14, 2)}<div style="font-size:13px">Back to Assistant</div>
        </div>
        <div class="div" style="margin:7px 0"></div>
        {railcap('This app')}
        {tab('gear','General', True, '⌘1')}
        {railcap('Intelligence')}
        {tab('box','Models &amp; Providers', key='⌘2')}
        {tab('cpu','Agent', key='⌘3')}
        {tab('people','Bots', key='⌘4')}
        {railcap('System')}
        {tab('wifi','Network', key='⌘5')}
        {tab('hammer','Plugins', key='⌘6')}
        <div style="flex:1"></div>
        <div class="div"></div>
        <div style="font-size:11px;color:{t['text3']};padding:12px 10px">Vamp Assistant 0.10.29 (83)</div>
      </div>
      <div style="flex:1;min-width:0;padding:26px 0;overflow:hidden">
        <div style="max-width:640px;margin:0 auto">
          <div style="font-size:24px;font-weight:700;letter-spacing:-0.5px">General</div>
          <div class="cap" style="font-size:10px;padding:24px 0 6px">APPEARANCE</div>
          <div class="div"></div>
          {row('Theme','Dark')}
          <div style="display:flex;align-items:center;gap:14px;min-height:52px">
            <div style="flex:1;font-size:13.5px">Accent</div>
            <div style="display:flex;gap:10px">
              {swatch('#686868', True)}{swatch('#6E7F9B')}{swatch('#7C7060')}{swatch('#6F8A72')}
            </div>
          </div>
          <div class="div"></div>
          {row('Atmosphere','On', 'The engraving stays in the margins — never behind a paragraph.', control='switch')}
          {row('Text size','Comfortable')}
          <div class="cap" style="font-size:10px;padding:24px 0 6px">THIS MAC</div>
          <div class="div"></div>
          {row('Remote access','vamp-mini · paired', control='chev')}
          {row('Workspace','~/Developer/vamp-assistant')}
          {row('Launch at login','', control='switch')}
          <div class="cap" style="font-size:10px;padding:24px 0 6px">ABOUT</div>
          <div class="div"></div>
          {row('Version','2.4.0 (89)', control='none')}
          {row('Diagnostics','Open')}
        </div>
      </div>
    </div>'''
    return shell(t, body, "Settings")


if __name__ == '__main__':
    out = {
        'MacMain.dc.html': main(DARK),
        'MacMainLight.dc.html': main(LIGHT),
        'MacBots.dc.html': bots(DARK),
        'MacSettings.dc.html': settings(LIGHT),
    }
    for name, html in out.items():
        open(name, 'w').write(html)
        print(name, len(html))
