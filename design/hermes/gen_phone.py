from kit import head, TAIL, ico, LIGHT, DARK, SERIF

def sessions(t):
    def row(title, sub, time, running=False):
        mark = '<div class="dot"></div>' if running else '<div style="width:5px"></div>'
        return f'''<div class="row" style="min-height:66px">
            {mark}
            <div style="flex:1;min-width:0">
              <div class="body" style="white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{title}</div>
              <div class="fn" style="margin-top:3px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{sub}</div>
            </div>
            <div class="num">{time}</div>
          </div>
          <div class="rule" style="margin-left:19px"></div>'''
    def action(icon, label):
        return f'''<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:9px;padding:18px 0">
          {ico(icon, t['ink'], 21)}
          <div class="label" style="color:{t['ink2']};letter-spacing:1.1px">{label}</div>
        </div>'''
    return head(t) + f'''<div class="screen">
  <div class="layer" style="padding:0 24px">
    <div style="display:flex;align-items:baseline;justify-content:space-between;padding:18px 0 4px">
      <div class="t1">Sessions</div>
      {ico('compose', t['ink'], 21)}
    </div>
    <div class="fn" style="padding-bottom:20px">vamp-mini · connected</div>

    <div class="rule-strong"></div>
    <div style="display:flex">
      {action('display','Stream')}{action('people','Bots')}{action('share','Share')}{action('gear','Settings')}
    </div>
    <div class="rule-strong"></div>

    <div class="label" style="padding:28px 0 10px">Today</div>
    <div class="rule"></div>
    {row('Fix the composer layout','Editing · vamp-assistant','6.39', running=True)}
    {row('Audit the pairing flow','vamp-assistant · 8 messages','1.40')}

    <div class="label" style="padding:26px 0 10px">Yesterday</div>
    <div class="rule"></div>
    {row('Explain the checkpoint format','Chat · 31 messages','21.40')}
    {row('Port the diff viewer','forgesign · 112 messages','0.40')}

    <div class="label" style="padding:26px 0 10px">Imported</div>
    <div class="rule"></div>
    {row('Hair test timelines','Codex · 14 messages','Tue')}
  </div>
</div>
''' + TAIL

def conversation(t):
    def step(name, meta, done=True):
        return f'''<div style="display:flex;align-items:center;gap:10px;min-height:34px">
          {ico('check', t['ink3'], 13, 1.6) if done else '<div style="width:13px;height:13px;border:1px solid ' + t['ink3'] + ';border-radius:7px"></div>'}
          <div class="mono" style="color:{t['ink2']}">{name}</div>
          <div class="c2" style="flex:1;white-space:nowrap;overflow:hidden;text-overflow:ellipsis">{meta}</div>
        </div>'''
    return head(t) + f'''<div class="screen">
  <div class="layer">
    <div class="glass" style="padding:12px 20px 13px;display:flex;align-items:center;gap:14px;border-bottom:1px solid {t['rule']}">
      {ico('back', t['ink'], 20)}
      <div style="flex:1;text-align:center">
        <div class="t2" style="font-size:17px;line-height:21px">How hair tests work</div>
        <div class="c2" style="margin-top:2px">Ready · Chat · GPT-5</div>
      </div>
      {ico('cpu', t['ink'], 19)}
    </div>

    <div style="flex:1;padding:26px 24px 0;display:flex;flex-direction:column;gap:22px;overflow:hidden">
      <div style="display:flex;justify-content:flex-end">
        <div class="body" style="max-width:78%;padding:12px 16px;border-radius:20px;background:{t['raised']};border:1px solid {t['rule']}">Explain what a hair test measures, and its limits.</div>
      </div>

      <div class="fn" style="display:flex;align-items:center;gap:7px;color:{t['ink3']}">Thought for 4s {ico('chevdown', t['ink3'], 13, 1.6)}</div>

      <div class="body">A hair test looks for drugs and their metabolites locked into the growing shaft — not for anything circulating now.</div>

      <div style="border-left:1px solid {t['rule2']};padding-left:16px">
        {step('web search','5 results · SAMHSA, PubMed')}
        {step('read file','hair-testing.md — 166 lines')}
      </div>

      <div class="body">About 4&nbsp;cm from the scalp covers roughly three months, so it records repeated use rather than last night<span style="display:inline-block;width:1.5px;height:17px;background:{t['accent']};margin-left:3px;vertical-align:-3px"></span></div>
    </div>

    <div style="padding:0 24px 10px;display:flex;align-items:center;gap:10px">
      <div class="c2">Writing · 38s</div>
      <div style="flex:1"></div>
      <div class="fn" style="display:flex;align-items:center;gap:6px;color:{t['ink']}">{ico('stop', t['ink'], 13, 1.4)} Stop</div>
    </div>

    <div class="glass" style="border-top:1px solid {t['rule']};padding:12px 20px 18px;display:flex;align-items:center;gap:12px">
      {ico('plus', t['ink2'], 20)}
      <div class="sub" style="flex:1">Message your assistant…</div>
      <div style="width:34px;height:34px;border-radius:18px;background:{t['accent']};display:flex;align-items:center;justify-content:center">{ico('arrowup', '#fff', 17, 1.6)}</div>
    </div>
  </div>
</div>
''' + TAIL

def new_session(t):
    def cell(icon, value):
        return f'''<div style="flex:1;display:flex;flex-direction:column;align-items:center;gap:8px;padding:16px 4px">
          {ico(icon, t['ink'], 20)}
          <div class="c2" style="color:{t['ink2']};text-align:center;line-height:14px">{value}</div>
        </div>'''
    def starter(txt):
        return f'''<div style="display:flex;align-items:center;gap:12px;min-height:52px">
          <div class="body" style="flex:1;color:{t['ink2']}">{txt}</div>
          <div style="transform:rotate(-45deg)">{ico('arrowup', t['ink3'], 15, 1.4)}</div>
        </div><div class="rule"></div>'''
    return head(t) + f'''<div class="screen">
  <div class="layer">
    <div style="display:flex;align-items:center;justify-content:space-between;padding:16px 24px 0">
      <div class="fn" style="color:{t['accent']}">Cancel</div>
      <div class="label">New session</div>
      <div style="width:44px"></div>
    </div>

    <div style="padding:22px 24px 0">
      <div class="t1" style="font-size:30px;line-height:36px">What should<br>it work on?</div>
    </div>

    <div style="padding:26px 24px 0">
      <div class="rule-strong"></div>
      <div style="display:flex">
        {cell('bubble','Chat only')}{cell('bubble','Assistant')}{cell('cpu','Qwen3.5 9B')}{cell('brain','Auto')}
      </div>
      <div class="rule-strong"></div>
    </div>

    <div style="padding:28px 24px 0">
      <div class="label" style="padding-bottom:8px">Or start from</div>
      <div class="rule"></div>
      {starter('Plan this task')}
      {starter('Explain this project')}
      {starter('Review my changes')}
    </div>

    <div style="flex:1"></div>
    <div class="glass" style="border-top:1px solid {t['rule']};padding:12px 20px 18px;display:flex;align-items:center;gap:12px">
      <div class="sub" style="flex:1">What should it work on?</div>
      <div style="width:34px;height:34px;border-radius:18px;background:{t['accent']};display:flex;align-items:center;justify-content:center">{ico('arrowup','#fff',17,1.6)}</div>
    </div>
  </div>
</div>
''' + TAIL

def bots(t):
    def row(icon, name, role, status, active=False):
        return f'''<div class="row" style="min-height:64px">
            {ico(icon, t['accent'] if active else t['ink'], 20)}
            <div style="flex:1;min-width:0">
              <div class="body">{name}</div>
              <div class="fn" style="margin-top:2px">{role}</div>
            </div>
            <div class="c2" style="color:{t['accent'] if active else t['ink3']}">{status}</div>
          </div>
          <div class="rule" style="margin-left:34px"></div>'''
    return head(t) + f'''<div class="screen">
  <div class="layer" style="padding:0 24px">
    <div style="display:flex;align-items:baseline;justify-content:space-between;padding:18px 0 4px">
      <div class="t1">Bots</div>
      <div class="fn" style="color:{t['accent']}">Done</div>
    </div>
    <div class="fn" style="padding-bottom:22px">Five specialists, each with its own brief.</div>

    <div class="label" style="padding-bottom:10px">Running</div>
    <div class="rule-strong"></div>
    <div class="row" style="min-height:64px">
      {ico('hammer', t['accent'], 20)}
      <div style="flex:1">
        <div class="body">Builder</div>
        <div class="fn" style="margin-top:2px;color:{t['accent']}">Editing · 2 files · 38s</div>
      </div>
      <div class="fn" style="color:{t['ink']}">Stop</div>
    </div>
    <div class="rule-strong"></div>

    <div class="label" style="padding:26px 0 10px">Team</div>
    <div class="rule"></div>
    {row('bubble','Assistant','Balanced, no brief','Chat only')}
    {row('hammer','Builder','Builds and fixes','Editing', active=True)}
    {row('loupe','Reviewer','Diffs and risks','Idle')}
    {row('compass','Navigator','Drives the browser','Idle')}
    {row('book','Researcher','Sources and synthesis','Idle')}

    <div class="label" style="padding:26px 0 10px">Together</div>
    <div class="rule"></div>
    <div class="row" style="min-height:60px">
      {ico('people', t['ink'], 20)}
      <div style="flex:1"><div class="body">Delegate one outcome</div></div>
      {ico('chevron', t['ink3'], 15, 1.4)}
    </div>
    <div class="rule"></div>
  </div>
</div>
''' + TAIL

if __name__ == "__main__":
    open("Main.dc.html","w").write(sessions(LIGHT))
    open("SessionsNight.dc.html","w").write(sessions(DARK))
    open("Conversation.dc.html","w").write(conversation(LIGHT))
    open("NewSession.dc.html","w").write(new_session(LIGHT))
    open("Bots.dc.html","w").write(bots(LIGHT))
    print("ok")
