import sys
from kit import head, TAIL, ico, FONT, MONO
from tokens import DARK, LIGHT

def sessions(t, name):
    a = t['accent']; br = t['bright']
    def action(icon, label):
        return f'''<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:5px;padding:10px 0;border-radius:14px;background:{t['glass']};min-height:60px;justify-content:center">
          {ico(icon, br, 19)}
          <div style="font-size:11px;font-weight:500;color:{t['text2']}">{label}</div>
        </div>'''
    def srow(title, sub, time, running=False, last=False):
        dot = f'<div style="width:7px;height:7px;border-radius:4px;background:{br};flex:none"></div>' if running else '<div style="width:7px;flex:none"></div>'
        return f'''<div style="display:flex;align-items:center;gap:10px;padding:11px 14px">
            {dot}
            <div style="flex:1;min-width:0">
              <div class="h" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{title}</div>
              <div class="sub" style="margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{sub}</div>
            </div>
            <div class="sub" style="flex:none;font-variant-numeric:tabular-nums">{time}</div>
            {ico('chevron', t['text3'], 14, 2)}
          </div>''' + ('' if last else f'<div class="div" style="margin-left:31px"></div>')
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer">
    <div style="display:flex;align-items:flex-end;justify-content:space-between;padding:14px 18px 8px">
      <div class="t1">Sessions</div>
      <div class="navpill">{ico('compose', br, 18)}</div>
    </div>

    <div style="padding:6px 18px 12px">
      <div class="well" style="display:flex;align-items:center;gap:8px;height:38px;padding:0 12px;border-radius:19px;border:0.75px solid {t['rim']}">
        {ico('search', t['text3'], 17)}<div class="sub" style="color:{t['text3']}">Search sessions</div>
      </div>
    </div>

    <div style="padding:0 18px">
      <div class="glass">
        <div class="row">
          <div style="width:9px;height:9px;border-radius:5px;background:{t['green']}"></div>
          <div class="b" style="flex:1">vamp-mini</div>
          <div class="sub">Connected</div>
          {ico('chevron', t['text3'], 14, 2)}
        </div>
        <div class="div"></div>
        <div style="display:flex;gap:8px;padding:8px">
          {action('display','Stream')}{action('people','Bots')}{action('share','Share')}{action('gear','Settings')}
        </div>
      </div>
    </div>

    <div class="cap" style="padding:22px 20px 8px">Today</div>
    <div style="padding:0 18px">
      <div class="glass" style="padding:2px 0">
        {srow('Fix the composer layout','Editing · vamp-assistant','6:39 AM',running=True)}
        {srow('Audit the pairing flow','vamp-assistant · 8 messages','1:40 AM',last=True)}
      </div>
    </div>

    <div class="cap" style="padding:20px 20px 8px">Yesterday</div>
    <div style="padding:0 18px">
      <div class="glass" style="padding:2px 0">
        {srow('Explain the checkpoint format','Chat · 31 messages','9:40 PM')}
        {srow('Port the diff viewer','forgesign · 112 messages','12:40 AM',last=True)}
      </div>
    </div>

    <div class="cap" style="padding:20px 20px 8px">Imported</div>
    <div style="padding:0 18px">
      <div class="glass" style="padding:2px 0">
        {srow('Hair test timelines','Codex · 14 messages','Tue',last=True)}
      </div>
    </div>
  </div>
</div>
''' + TAIL

def conversation(t):
    a=t['accent']; br=t['bright']
    def tool(nm, summary, expanded=False):
        body = f'''<div class="mono" style="color:{t['text2']};background:{t['glass']};border-radius:10px;padding:9px 11px;margin:2px 0 8px;line-height:18px;font-size:12px">RemoteComposerView.swift<br>@@ -118,7 +118,25 @@<br>+ .popover(isPresented: $showCommands,<br>+          attachmentAnchor: .point(.top))</div>''' if expanded else ''
        return f'''<div>
          <div style="display:flex;align-items:center;gap:8px;min-height:30px">
            {ico('check', t['text3'], 13, 2.4)}
            <div class="mono" style="color:{t['text']};opacity:.82">{nm}</div>
            <div class="fn" style="color:{t['text3']};flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{summary}</div>
            <div style="transform:rotate({'180' if expanded else '0'}deg)">{ico('chevdown', t['text3'], 13, 2.4)}</div>
          </div>{body}
        </div>'''
    return head(t) + f'''<div class="screen">
  <div class="atmos"></div>
  <div class="layer">
    <div style="display:flex;align-items:center;gap:10px;padding:10px 14px 12px;border-bottom:0.75px solid {t['sep']};background:{t['glass2']};-webkit-backdrop-filter:blur(24px);backdrop-filter:blur(24px)">
      <div class="navpill" style="width:32px;height:32px">{ico('back', br, 17)}</div>
      <div style="flex:1;text-align:center">
        <div class="h">How do hair tests work</div>
        <div class="c2" style="margin-top:1px">Ready · Chat · GPT-5</div>
      </div>
      <div class="navpill" style="width:32px;height:32px">{ico('dots', br, 17)}</div>
    </div>

    <div style="flex:1;overflow:hidden;padding:18px 18px 0;display:flex;flex-direction:column;gap:18px">
      <div class="glass" style="padding:12px 14px;border-radius:14px">
        <div class="b">Explain what a hair drug test actually measures, and its limits.</div>
      </div>

      <div style="display:flex;align-items:center;gap:6px">
        <div class="fn" style="color:{t['text3']}">Thought for 4s</div>
        {ico('chevdown', t['text3'], 13, 2.4)}
      </div>

      <div class="b">A hair test looks for drugs and their metabolites locked into the growing shaft, not for anything circulating now.</div>

      <div style="border-left:1.5px solid {t['sep']};padding-left:12px;display:flex;flex-direction:column">
        {tool('web search','5 results · SAMHSA, PubMed')}
        {tool('read file','hair-testing.md — 166 lines', expanded=True)}
      </div>

      <div class="b">About 4&nbsp;cm from the scalp covers roughly three months, so it is a record of repeated use rather than of last night<span style="display:inline-block;width:2px;height:17px;background:{br};margin-left:2px;vertical-align:-3px"></span></div>
    </div>

    <div style="padding:0 18px">
      <div style="display:flex;align-items:center;gap:9px;padding:8px 4px">
        <div style="width:13px;height:13px;border-radius:7px;border:1.6px solid {t['text3']};border-top-color:{br}"></div>
        <div class="fn">Writing</div>
        <div style="flex:1"></div>
        <div class="chip" style="padding:5px 14px">{ico('stop', t['text'], 13, 2)} Stop</div>
      </div>
    </div>

    <div style="padding:6px 12px 14px;display:flex;align-items:flex-end;gap:10px;border-top:0.75px solid {t['sep']};background:{t['glass2']};-webkit-backdrop-filter:blur(24px);backdrop-filter:blur(24px)">
      <div style="width:32px;height:32px;border-radius:16px;background:{t['glass']};border:0.75px solid {t['rim']};display:flex;align-items:center;justify-content:center">{ico('plus', t['text2'], 17)}</div>
      <div style="flex:1;display:flex;align-items:center;gap:8px;padding:0 6px 0 14px;height:38px;border-radius:19px;background:{t['glass']};border:0.75px solid {t['rim']}">
        <div class="b" style="flex:1;color:{t['text3']};font-size:16px">Queue a follow-up or steer…</div>
        <div style="width:30px;height:30px;border-radius:15px;background:{a};display:flex;align-items:center;justify-content:center">{ico('arrowup', '#FFFFFF', 17, 2)}</div>
      </div>
    </div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("Main.dc.html","w").write(sessions(DARK,"dark"))
    open("SessionsLight.dc.html","w").write(sessions(LIGHT,"light"))
    open("Conversation.dc.html","w").write(conversation(DARK))
    print("ok")
