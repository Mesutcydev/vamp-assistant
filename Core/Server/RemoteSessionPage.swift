import Foundation

/// The browser client is intentionally bundled with the host. A scanned QR
/// therefore opens a complete Beetcode control surface without requiring a
/// second app, a CLI, or a cloud relay.
enum RemoteSessionPage {
    static let html = #"""
<!doctype html>
<html lang="en" data-theme="beet">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="theme-color" content="#7A1F3D">
<title>Beet Code Remote</title>
<style>
:root {
  color-scheme: dark;
  --bg: #111113;
  --panel: #19191d;
  --panel-strong: #222229;
  --line: #34343e;
  --text: #f4f1f3;
  --muted: #a7a1a6;
  --accent: #d14775;
  --accent-bright: #f08bab;
  --accent-wash: #34232b;
  --danger: #f06b78;
  --warning: #f0b85a;
  --success: #5ee1a6;
  --tool: #20252a;
  --radius: 14px;
  --ease-out: cubic-bezier(.23,1,.32,1);
}
* { box-sizing: border-box; }
html, body { height: 100%; }
body {
  margin: 0;
  background: radial-gradient(circle at 8% 0, #321928 0, transparent 34%), var(--bg);
  color: var(--text);
  font: 15px -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
  overflow: hidden;
}
button, input, textarea { font: inherit; }
button { border: 0; color: inherit; cursor: pointer; }
button:disabled { opacity: .48; cursor: default; }
button:focus-visible, input:focus-visible, textarea:focus-visible {
  outline: 2px solid var(--accent-bright);
  outline-offset: 2px;
}
button:not(:disabled):active { transform: scale(.98); }
.shell { display: grid; grid-template-columns: 304px minmax(0, 1fr); height: 100vh; }
.sidebar {
  min-width: 0;
  display: flex;
  flex-direction: column;
  background: rgba(17,17,19,.88);
  border-right: 1px solid var(--line);
}
.brand { padding: 22px 20px 16px; border-bottom: 1px solid var(--line); }
.brand-row { display: flex; align-items: center; gap: 10px; }
.mark {
  width: 28px; height: 28px; border-radius: 9px;
  display: grid; place-items: center;
  background: linear-gradient(135deg, var(--accent-bright), var(--accent));
  color: #1b1015; font-weight: 900;
}
.brand h1 { font-size: 17px; margin: 0; letter-spacing: -.02em; }
.brand p { color: var(--muted); font-size: 12px; margin: 6px 0 0; }
.sessions { flex: 1; min-height: 0; padding: 14px 10px; overflow: auto; }
.sessions-heading {
  display: flex; align-items: center; justify-content: space-between;
  padding: 0 10px 9px;
}
.section-label {
  color: var(--muted); font-size: 11px; font-weight: 700;
  letter-spacing: .12em; text-transform: uppercase;
}
.icon-button {
  width: 30px; height: 30px; border-radius: 9px;
  display: grid; place-items: center;
  background: transparent; color: var(--muted);
  transition: background 160ms var(--ease-out), color 160ms var(--ease-out);
}
.icon-button:hover { background: var(--panel-strong); color: var(--text); }
.session {
  display: block; width: 100%; margin: 2px 0; padding: 11px 10px;
  text-align: left; background: transparent; border-radius: 10px;
  transition: background 160ms var(--ease-out), transform 160ms var(--ease-out);
}
.session:hover, .session.active { background: var(--panel-strong); }
.session.active { box-shadow: inset 3px 0 var(--accent); }
.session-title {
  display: block; overflow: hidden; white-space: nowrap;
  text-overflow: ellipsis; font-weight: 650;
}
.session-meta {
  display: flex; gap: 6px; margin-top: 5px;
  overflow: hidden; color: var(--muted); font-size: 12px;
  white-space: nowrap; text-overflow: ellipsis;
}
.session-status {
  display: inline-block; width: 6px; height: 6px; margin-right: 4px;
  border-radius: 50%; background: var(--warning); vertical-align: middle;
}
.empty-sidebar { padding: 10px; color: var(--muted); font-size: 13px; line-height: 1.45; }
.footer {
  padding: 12px 16px; border-top: 1px solid var(--line);
  color: var(--muted); font-size: 12px; line-height: 1.45;
}
.footer button { padding: 0; background: transparent; color: var(--accent-bright); }
.main { display: flex; flex-direction: column; min-width: 0; min-height: 0; }
.topbar {
  display: flex; align-items: center; justify-content: space-between;
  min-height: 70px; padding: 0 22px;
  background: rgba(17,17,19,.58); border-bottom: 1px solid var(--line);
}
.title-block { min-width: 0; }
.topbar h2 {
  overflow: hidden; margin: 0; font-size: 16px;
  white-space: nowrap; text-overflow: ellipsis;
}
.topbar .sub {
  overflow: hidden; max-width: min(62vw, 620px); margin-top: 5px;
  color: var(--muted); font-size: 12px; white-space: nowrap;
  text-overflow: ellipsis;
}
.top-actions { display: flex; align-items: center; gap: 12px; }
.status {
  display: flex; align-items: center; gap: 7px;
  color: var(--muted); font-size: 12px; white-space: nowrap;
}
.dot { width: 8px; height: 8px; border-radius: 50%; background: #7a7880; }
.dot.live { background: var(--success); box-shadow: 0 0 0 4px rgba(94,225,166,.12); }
.dot.busy { background: var(--warning); box-shadow: 0 0 0 4px rgba(240,184,90,.12); }
.dot.error { background: var(--danger); box-shadow: 0 0 0 4px rgba(240,107,120,.12); }
.notice {
  display: none; margin: 12px auto 0; width: min(900px, calc(100% - 36px));
  padding: 10px 13px; border: 1px solid var(--line); border-radius: 10px;
  color: var(--muted); background: var(--panel); font-size: 13px;
}
.notice.visible { display: block; }
.notice.error { border-color: rgba(240,107,120,.48); color: #ffc5c9; }
.messages {
  flex: 1; min-height: 0; overflow: auto;
  padding: 24px max(18px, calc((100% - 900px) / 2));
  scroll-behavior: smooth;
}
.empty { height: 100%; display: grid; place-items: center; color: var(--muted); text-align: center; }
.empty.home-empty { display: flex; flex-direction: column; justify-content: center; align-items: center; gap: 22px; padding: 8px 0 18px; }
.empty-card { max-width: 420px; line-height: 1.5; }
.empty-card h3 { margin: 0 0 8px; color: var(--text); font-size: 24px; letter-spacing: -.03em; }
.bubble {
  max-width: 850px; margin: 0 auto 16px; padding: 14px 16px;
  border: 1px solid var(--line); border-radius: 16px; background: var(--panel);
  overflow-wrap: anywhere; line-height: 1.48; white-space: pre-wrap;
}
.bubble.user { background: var(--accent-wash); border-color: #613b4c; }
.bubble.live { border-color: rgba(227, 91, 136, .58); box-shadow: 0 0 0 3px rgba(227, 91, 136, .08); }
.bubble.live .role { color: var(--accent-bright); }
.bubble.tool {
  background: var(--tool); color: #c5d0d4;
  font: 12px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace;
}
.bubble .role {
  margin-bottom: 7px; color: var(--muted);
  font-size: 10px; font-weight: 700; letter-spacing: .11em;
  text-transform: uppercase;
}
.interaction {
  width: min(900px, calc(100% - 36px)); margin: 0 auto 12px;
  padding: 14px 16px; border: 1px solid rgba(240,184,90,.48);
  border-radius: var(--radius); background: rgba(61,47,28,.52);
}
.interaction.hidden { display: none; }
.interaction-head { display: flex; align-items: center; gap: 8px; margin-bottom: 9px; }
.interaction-kicker { color: var(--warning); font-size: 12px; font-weight: 750; }
.interaction-tool { color: var(--muted); font: 12px ui-monospace, SFMono-Regular, Menlo, monospace; }
.interaction-summary { margin: 0 0 10px; line-height: 1.45; white-space: pre-wrap; overflow-wrap: anywhere; }
.preview {
  max-height: 170px; overflow: auto; margin: 0 0 12px; padding: 10px;
  border: 1px solid var(--line); border-radius: 9px;
  background: rgba(17,17,19,.56); color: #d7d0d4;
  font: 12px/1.5 ui-monospace, SFMono-Regular, Menlo, monospace;
  white-space: pre-wrap; overflow-wrap: anywhere;
}
.interaction-actions { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.button {
  min-height: 36px; padding: 0 13px; border: 1px solid var(--line);
  border-radius: 10px; background: var(--panel-strong); color: var(--text);
  font-weight: 650; transition: background 160ms var(--ease-out), transform 160ms var(--ease-out);
}
.button:hover { background: #2d2d36; }
.button.primary { border-color: transparent; background: var(--accent); color: white; }
.button.primary:hover { background: #e05b86; }
.button.danger { border-color: transparent; background: var(--danger); color: #241014; }
.button.ghost { border-color: transparent; background: transparent; color: var(--muted); }
.interaction input {
  flex: 1; min-width: 160px; min-height: 36px; padding: 0 11px;
  border: 1px solid var(--line); border-radius: 9px; background: var(--bg); color: var(--text);
}
.composer-wrap {
  padding: 14px max(18px, calc((100% - 900px) / 2));
  border-top: 1px solid var(--line); background: rgba(17,17,19,.9);
}
.composer {
  display: flex; align-items: flex-end; gap: 10px;
  padding: 9px; border: 1px solid var(--line); border-radius: 15px;
  background: var(--panel); transition: border-color 160ms var(--ease-out);
}
.composer:focus-within { border-color: var(--accent); }
textarea {
  flex: 1; min-height: 42px; max-height: 140px; padding: 9px;
  resize: none; border: 0; outline: 0; background: transparent;
  color: var(--text); font-size: 16px; line-height: 1.45;
}
.send, .stop {
  width: 42px; height: 42px; border-radius: 11px;
  font-weight: 800; transition: transform 160ms var(--ease-out), opacity 160ms var(--ease-out);
}
.send { background: linear-gradient(135deg, var(--accent-bright), var(--accent)); color: #1b1015; }
.stop { background: var(--danger); color: #241014; }
.send.hidden, .stop.hidden { display: none; }
.hint { padding: 7px 3px 0; color: var(--muted); font-size: 11px; }
.run-controls { display: flex; flex-wrap: wrap; align-items: center; gap: 12px; padding: 8px 3px 0; }
.run-control { display: inline-flex; align-items: center; gap: 7px; color: var(--muted); font-size: 12px; }
.run-control input { accent-color: var(--accent); }
.chat-model {
  max-width: 180px; min-height: 30px; padding: 4px 8px;
  border: 1px solid var(--line); border-radius: 9px;
  background: var(--panel); color: var(--text); font-size: 12px;
}
.bubble.error { border-color: rgba(255,95,110,.36); background: rgba(255,95,110,.09); }
.bubble.error .role { color: var(--danger); }
.share-overlay {
  position: fixed; inset: 0; z-index: 8; display: grid; place-items: center;
  padding: 22px; background: var(--overlay);
}
.share-overlay.hidden { display: none; }
.bots-overlay {
  position: fixed; inset: 0; z-index: 9; display: grid; place-items: center;
  padding: 22px; background: var(--overlay);
}
.bots-overlay.hidden { display: none; }
.bot-rail { display: flex; flex-wrap: wrap; justify-content: center; gap: 10px; width: min(720px, 100%); }
.bot-tile { flex: 0 0 108px; display: flex; flex-direction: column; align-items: center; gap: 7px; min-height: 132px; padding: 12px 10px 14px; border: 1px solid var(--line); border-radius: 18px; background: linear-gradient(145deg,var(--panel),var(--panel-strong)); transition: transform 160ms var(--ease-out),border-color 160ms var(--ease-out),box-shadow 160ms var(--ease-out); }
.bot-tile:hover { transform: translateY(-1px); border-color: color-mix(in srgb,var(--accent-bright) 48%,var(--line)); box-shadow: 0 10px 26px var(--panel-shadow); }
.bot-tile[aria-pressed="true"] { border-color: var(--accent-bright); box-shadow: inset 0 0 0 1px color-mix(in srgb,var(--accent-bright) 42%,transparent),0 10px 28px var(--panel-shadow); }
.bot-thumb { width: 64px; height: 64px; border-radius: 16px; object-fit: cover; background: #000; }
.bot-tile strong { display: block; font-size: 13px; }
.bot-tile .bot-detail { color: var(--muted); font-size: 11px; line-height: 1.35; }
.bot-field { width: 100%; min-height: 42px; margin-top: 10px; padding: 10px 11px; border: 1px solid var(--line); border-radius: 11px; background: var(--bg); color: var(--text); }
.share-card {
  width: min(520px, 100%); max-height: min(720px, calc(100dvh - 32px)); overflow: auto;
  padding: 20px; border: 1px solid var(--line); border-radius: 20px;
  background: var(--panel); box-shadow: 0 24px 80px var(--panel-shadow);
}
.share-head { display: flex; align-items: flex-start; gap: 12px; margin-bottom: 18px; }
.share-head-copy { flex: 1; min-width: 0; }
.share-head h2 { margin: 0; font-size: 21px; letter-spacing: -.03em; }
.share-head p { margin: 5px 0 0; color: var(--muted); font-size: 13px; line-height: 1.45; }
.share-section + .share-section { margin-top: 20px; }
.share-label { margin-bottom: 9px; color: var(--muted); font-size: 11px; font-weight: 750; letter-spacing: .1em; text-transform: uppercase; }
.share-clipboard {
  width: 100%; min-height: 92px; max-height: 180px; padding: 12px;
  border: 1px solid var(--line); border-radius: 13px; resize: vertical;
  background: var(--input); color: var(--text); line-height: 1.45;
}
.share-actions { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 9px; }
.shared-files { margin-top: 10px; border: 1px solid var(--line); border-radius: 14px; overflow: hidden; }
.shared-file { display: flex; width: 100%; align-items: center; gap: 10px; min-height: 50px; padding: 8px 11px; text-align: left; background: transparent; }
.shared-file + .shared-file { border-top: 1px solid var(--line); }
.shared-file:hover { background: var(--panel-strong); }
.shared-file-icon { width: 32px; height: 32px; display: grid; place-items: center; border-radius: 9px; background: var(--panel-strong); color: var(--accent-bright); }
.shared-file-copy { flex: 1; min-width: 0; }
.shared-file-name { display: block; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 13px; font-weight: 650; }
.shared-file-meta { display: block; margin-top: 2px; color: var(--muted); font-size: 11px; }
.shared-empty { padding: 16px; color: var(--muted); font-size: 13px; line-height: 1.45; }
.overlay {
  position: fixed; inset: 0; z-index: 4; display: grid; place-items: center;
  padding: 22px; background: rgba(0,0,0,.74);
}
.overlay.hidden { display: none; }
.card {
  width: min(430px, 100%); padding: 25px; border: 1px solid var(--line);
  border-radius: 18px; background: var(--panel);
  box-shadow: 0 22px 70px rgba(0,0,0,.45);
}
.card h2 { margin: 22px 0 8px; font-size: 23px; letter-spacing: -.03em; }
.card p { margin: 0 0 18px; color: var(--muted); line-height: 1.5; }
.code { display: flex; gap: 8px; }
.code input {
  flex: 1; min-width: 0; padding: 12px; border: 1px solid var(--line);
  border-radius: 10px; background: var(--bg); color: var(--text);
  font-size: 23px; font-weight: 700; letter-spacing: .24em; text-align: center;
}
.error { margin-top: 12px; color: #ffc5c9; font-size: 13px; }
.error.hidden { display: none; }
@media (max-width: 720px) {
  body { overflow: hidden; }
  .shell { display: flex; flex-direction: column; }
  .sidebar {
    flex: none; max-height: 176px; border-right: 0; border-bottom: 1px solid var(--line);
  }
  .brand { padding: 12px 14px 9px; }
  .brand p { display: none; }
  .sessions { display: flex; gap: 6px; padding: 8px; overflow-x: auto; }
  .sessions-heading { display: none; }
  .session { flex: 0 0 220px; margin: 0; }
  .footer { display: none; }
  .topbar { min-height: 62px; padding: 0 14px; }
  .topbar .sub { max-width: 55vw; }
  .status { font-size: 0; }
  .status .dot { width: 9px; height: 9px; }
  .messages { padding: 16px 12px; }
  .bubble { margin-bottom: 11px; border-radius: 13px; }
  .interaction, .notice { width: calc(100% - 24px); }
  .composer-wrap { padding: 10px 12px; }
  .hint { padding-top: 6px; }
  .share-overlay { place-items: end center; padding: 0; }
  .share-card { width: 100%; max-height: 84dvh; padding: 18px 16px calc(18px + env(safe-area-inset-bottom, 0px)); border-radius: 22px 22px 0 0; }
  .bot-rail { width: 100%; }
  .bot-tile { flex: 1 1 calc(50% - 10px); }
}
@media (prefers-reduced-motion: reduce) {
  *, *::before, *::after { scroll-behavior: auto !important; transition-duration: 0ms !important; }
}

/* Beet Code's web surface follows the native app's three appearance choices.
   Keep the page's chrome fixed; only the transcript and session list scroll. */
html[data-theme="light"] {
  color-scheme: light;
  --bg: #F6F7F9;
  --panel: #FFFFFF;
  --panel-strong: #E3E6EB;
  --line: #E1E4EA;
  --text: #14161A;
  --muted: #5B616E;
  --muted-strong: #8A909C;
  --accent: #7A1F3D;
  --accent-bright: #8A2647;
  --accent-wash: #F3E5EA;
  --user: #F6EAF0;
  --user-line: #C68EA6;
  --danger: #DC3B4B;
  --warning: #C77700;
  --success: #1EA672;
  --tool: #EEF0F3;
  --tool-text: #414752;
  --input: #FFFFFF;
  --chrome: rgba(246,247,249,.94);
  --body-wash: radial-gradient(circle at 8% 0, rgba(122,31,61,.10) 0, transparent 34%);
  --overlay: rgba(20,22,26,.42);
  --button-hover: #F0F2F5;
  --panel-shadow: rgba(20,22,26,.12);
  --accent-ring: rgba(122,31,61,.16);
  --warning-surface: #FFF4DB;
  --warning-line: rgba(199,119,0,.42);
}
html[data-theme="dark"] {
  color-scheme: dark;
  --bg: #0C0E14;
  --panel: #181C26;
  --panel-strong: #232837;
  --line: #343B4E;
  --text: #F2F4F8;
  --muted: #A3AABB;
  --muted-strong: #717889;
  --accent: #D14775;
  --accent-bright: #E06C92;
  --accent-wash: #3A1D2A;
  --user: #3A1D2A;
  --user-line: #70425A;
  --danger: #FF6B78;
  --warning: #F5B23D;
  --success: #35D6A0;
  --tool: #20252A;
  --tool-text: #C5D0D4;
  --input: #0C0E14;
  --chrome: rgba(12,14,20,.92);
  --body-wash: radial-gradient(circle at 8% 0, rgba(209,71,117,.22) 0, transparent 34%);
  --overlay: rgba(0,0,0,.74);
  --button-hover: #2D3445;
  --panel-shadow: rgba(0,0,0,.45);
  --accent-ring: rgba(209,71,117,.18);
  --warning-surface: #3D2F1C;
  --warning-line: rgba(245,178,61,.48);
}
html[data-theme="beet"] {
  color-scheme: dark;
  --bg: #7A1F3D;
  --panel: #90304E;
  --panel-strong: #5E1630;
  --line: #A84668;
  --text: #FDF2F6;
  --muted: #E7B8C8;
  --muted-strong: #C08CA0;
  --accent: #D14775;
  --accent-bright: #E06C92;
  --accent-wash: #A84462;
  --user: #A84462;
  --user-line: #C45A7C;
  --danger: #FF6B78;
  --warning: #F5B23D;
  --success: #35D6A0;
  --tool: #5E1630;
  --tool-text: #F5DDE5;
  --input: #5E1630;
  --chrome: rgba(94,22,48,.94);
  --body-wash: radial-gradient(circle at 8% 0, rgba(255,174,202,.18) 0, transparent 36%);
  --overlay: rgba(20,3,9,.70);
  --button-hover: #A84462;
  --panel-shadow: rgba(31,5,15,.34);
  --accent-ring: rgba(240,139,171,.20);
  --warning-surface: #6D4325;
  --warning-line: rgba(245,178,61,.52);
}
html, body { width: 100%; min-width: 0; min-height: 100%; -webkit-text-size-adjust: 100%; }
body {
  background: var(--body-wash), var(--bg);
  overscroll-behavior: none;
}
.shell {
  width: 100%;
  height: 100vh;
  height: 100svh;
  min-height: 100vh;
  min-height: 100svh;
  max-height: 100vh;
  max-height: 100svh;
  overflow: hidden;
}
.sidebar {
  overflow: hidden;
  background: var(--chrome);
  box-shadow: 10px 0 30px var(--panel-shadow);
}
.brand { background: var(--chrome); }
.brand-logo {
  display: block;
  flex: 0 0 auto;
  width: 32px;
  height: 32px;
  object-fit: cover;
  border: 1px solid var(--line);
  border-radius: 10px;
  background: #0C0E14;
  box-shadow: 0 4px 14px var(--panel-shadow);
}
.card .brand-logo { width: 40px; height: 40px; border-radius: 12px; }
.main {
  overflow: hidden;
  background: var(--bg);
}
.topbar {
  flex: 0 0 70px;
  background: var(--chrome);
  backdrop-filter: blur(18px) saturate(140%);
}
.top-actions { min-width: 0; }
.appearance-switcher {
  display: flex;
  align-items: center;
  gap: 2px;
  padding: 3px;
  border: 1px solid var(--line);
  border-radius: 11px;
  background: var(--panel-strong);
}
.appearance-option {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 5px;
  min-height: 28px;
  padding: 0 8px;
  border-radius: 8px;
  background: transparent;
  color: var(--muted);
  font-size: 11px;
  font-weight: 700;
  transition: background 160ms var(--ease-out), color 160ms var(--ease-out), transform 120ms var(--ease-out);
}
.appearance-option:hover { background: var(--button-hover); color: var(--text); }
.appearance-option[aria-pressed="true"] {
  background: var(--accent);
  color: #FFFFFF;
  box-shadow: 0 2px 8px var(--accent-ring);
}
.appearance-glyph { font-size: 14px; line-height: 1; }
.messages {
  scroll-behavior: auto;
  overscroll-behavior: contain;
}
.bubble.user { background: var(--user); border-color: var(--user-line); }
.bubble.live { border-color: var(--accent); box-shadow: 0 0 0 3px var(--accent-ring); }
.bubble.tool { background: var(--tool); color: var(--tool-text); }
.interaction { border-color: var(--warning-line); background: var(--warning-surface); }
.preview { background: var(--input); color: var(--tool-text); }
.button { background: var(--panel-strong); }
.button:hover { background: var(--button-hover); }
.button.primary { background: linear-gradient(135deg, var(--accent-bright), var(--accent)); color: #FFFFFF; }
.button.primary:hover { background: var(--accent-bright); }
.interaction input { background: var(--input); }
.composer-wrap {
  flex: 0 0 auto;
  background: var(--chrome);
  backdrop-filter: blur(18px) saturate(140%);
  padding-bottom: calc(14px + env(safe-area-inset-bottom, 0px));
}
.composer {
  height: 62px;
  min-height: 62px;
  max-height: 62px;
  background: var(--panel);
}
textarea {
  height: 42px;
  min-height: 42px;
  max-height: 42px;
  overflow-y: auto;
}
.send { background: linear-gradient(135deg, var(--accent-bright), var(--accent)); color: #FFFFFF; }
.overlay { background: var(--overlay); }
.card { background: var(--panel); box-shadow: 0 22px 70px var(--panel-shadow); }
.code input { background: var(--input); }
.footer { background: var(--chrome); }
.sessions-toggle {
  display: inline-flex;
  align-items: center;
  gap: 6px;
  padding: 0;
  background: transparent;
  color: var(--muted);
  font-size: 11px;
  font-weight: 700;
  letter-spacing: .12em;
  text-transform: uppercase;
}
.sessions-toggle:hover { color: var(--text); }
.sidebar.compact { overflow: hidden; }
.mobile-sessions-button, .mobile-sheet-footer, .session-scrim { display: none; }

@media (max-width: 720px) {
  .shell {
    display: flex;
    flex-direction: column;
  }
  .sidebar {
    position: fixed;
    z-index: 6;
    inset: 0 0 auto 0;
    display: flex;
    width: 100%;
    height: min(72dvh, 620px);
    max-height: none;
    border-right: 0;
    border-bottom: 1px solid var(--line);
    border-radius: 0 0 20px 20px;
    box-shadow: 0 18px 50px var(--panel-shadow);
    transform: translateY(0);
    transition: transform 280ms var(--ease-out);
  }
  .sidebar.compact {
    height: min(72dvh, 620px);
    max-height: none;
    overflow: hidden;
    pointer-events: none;
    transform: translateY(calc(-100% - 24px));
  }
  .brand { padding: calc(14px + env(safe-area-inset-top, 0px)) 16px 10px; }
  .brand p { display: none; }
  .sessions {
    display: block;
    flex: 1 1 auto;
    min-height: 0;
    padding: 8px 10px 10px;
    overflow-x: hidden;
    overflow-y: auto;
  }
  .sessions-heading {
    display: flex;
    align-items: center;
    min-height: 44px;
    padding: 0 6px 4px;
  }
  .sessions-toggle {
    flex: 1 1 auto;
    justify-content: flex-start;
    min-width: 0;
    min-height: 44px;
    padding: 0 10px;
    border-radius: 10px;
    text-align: left;
    touch-action: manipulation;
  }
  .sessions-toggle:active { background: var(--panel-strong); }
  .sessions-toggle::after {
    content: '⌄';
    font-size: 15px;
    letter-spacing: 0;
    line-height: 1;
    text-transform: none;
  }
  .sessions-heading .icon-button {
    flex: 0 0 40px;
    width: 40px;
    height: 40px;
  }
  .session { width: 100%; margin: 2px 0; padding: 10px 9px; }
  .mobile-sheet-footer {
    display: flex;
    align-items: center;
    justify-content: space-between;
    gap: 12px;
    padding: 10px 16px calc(12px + env(safe-area-inset-bottom, 0px));
    border-top: 1px solid var(--line);
    background: var(--chrome);
  }
  .mobile-sheet-footer .footer-revoke {
    min-height: 40px;
    padding: 0 8px;
    background: transparent;
    color: var(--accent-bright);
    font-size: 12px;
    font-weight: 650;
  }
  .footer { display: none; }
  .session-scrim {
    position: fixed;
    z-index: 5;
    inset: 0;
    display: block;
    background: rgba(0,0,0,.28);
    opacity: 0;
    pointer-events: none;
    transition: opacity 220ms var(--ease-out);
  }
  body.sessions-open .session-scrim { opacity: 1; pointer-events: auto; }
  .main { flex: 1 1 0; min-height: 0; }
  .topbar {
    flex: 0 0 58px;
    height: 58px;
    min-height: 58px;
    padding: 0 10px;
    gap: 8px;
  }
  .mobile-sessions-button {
    display: grid;
    flex: 0 0 40px;
    width: 40px;
    height: 40px;
    place-items: center;
    border-radius: 11px;
    background: var(--panel-strong);
    color: var(--text);
    font-size: 18px;
    touch-action: manipulation;
  }
  .title-block { flex: 1 1 auto; min-width: 0; }
  .topbar h2 { font-size: 15px; }
  .topbar .sub { max-width: 52vw; margin-top: 2px; font-size: 11px; }
  .top-actions {
    flex: 0 0 auto;
    gap: 4px;
  }
  .top-actions .icon-button, .top-actions .appearance-switcher { display: none; }
  .mobile-sheet-footer .appearance-switcher { display: flex; }
  .mobile-sheet-footer .appearance-option { min-width: 40px; min-height: 36px; }
  .mobile-sheet-footer .appearance-label { display: none; }
  .status {
    flex: 0 0 14px;
    width: 14px;
    justify-content: center;
    gap: 0;
    font-size: 0;
  }
  .status #status-text { display: none; }
  .status .dot { width: 9px; height: 9px; }
  .messages { padding: 10px 10px 14px; }
  .bubble { padding: 13px 14px; margin-bottom: 10px; font-size: 16px; line-height: 1.52; }
  .interaction, .notice { width: calc(100% - 24px); }
  .composer-wrap { padding: 8px 10px calc(8px + env(safe-area-inset-bottom, 0px)); }
  .composer { height: 58px; min-height: 58px; max-height: 58px; }
  .send, .stop { width: 40px; height: 40px; }
  .hint { display: none; }
}

@supports (height: 100dvh) {
  .shell {
    height: 100dvh;
    min-height: 100dvh;
    max-height: 100dvh;
  }
}

/* The pairing sheet must remain completely inside a narrow phone viewport.
   On touch screens the code and its action become one full-width stack, so
   the primary action never sits outside the hit area. */
.overlay {
  overflow-x: hidden;
  overflow-y: auto;
  overscroll-behavior: contain;
}
.card {
  width: min(430px, calc(100vw - 32px));
  max-width: 100%;
  min-width: 0;
  max-height: calc(100svh - 32px);
  overflow-x: hidden;
  overflow-y: auto;
}
.code .button {
  flex: 0 0 auto;
  min-width: 96px;
  min-height: 44px;
  touch-action: manipulation;
}
@media (max-width: 720px) {
  .overlay {
    place-items: start center;
    padding: calc(16px + env(safe-area-inset-top, 0px)) 12px calc(16px + env(safe-area-inset-bottom, 0px));
  }
  .card {
    width: min(100%, 430px);
    max-height: calc(100svh - 32px);
    padding: 20px;
  }
  .card h2 { margin-top: 18px; }
  .card p { margin-bottom: 16px; }
  .code {
    display: grid;
    grid-template-columns: minmax(0, 1fr);
    gap: 10px;
  }
  .code input {
    width: 100%;
    font-size: 22px;
    letter-spacing: .18em;
  }
  .code .button {
    width: 100%;
    min-height: 48px;
  }
}
</style>
</head>
<body>
<div id="pairing" class="overlay hidden" role="dialog" aria-modal="true" aria-labelledby="pair-title">
  <div class="card">
    <div class="brand-row"><img class="brand-logo" src="/assets/beetlogo.png" alt="Beet Code logo"><h1>Beet Code Remote</h1></div>
    <h2 id="pair-title">Continue a session</h2>
    <p>Pair this browser with your Mac, then choose a saved Beetcode session. Your existing workspace, transcript, and safety settings stay in place.</p>
    <div class="code">
      <input id="pair-code" inputmode="numeric" autocomplete="one-time-code" maxlength="6" pattern="[0-9]{6}" placeholder="000000" aria-label="Six-digit pairing code">
      <button id="pair-button" class="button primary" type="button">Pair</button>
    </div>
    <div id="pair-error" class="error hidden" role="alert"></div>
  </div>
</div>

<div id="bots-panel" class="bots-overlay hidden" role="dialog" aria-modal="true" aria-labelledby="bots-title">
  <div class="share-card">
    <div class="share-head">
      <div class="share-head-copy"><h2 id="bots-title">New session</h2><p id="bots-sub">Choose a model and first task.</p></div>
      <button id="bots-close" class="icon-button" type="button" aria-label="Close bots">×</button>
    </div>
    <select id="bot-model" class="bot-field" aria-label="Bot model"><option value="">Loading models…</option></select>
    <textarea id="bot-prompt" class="bot-field" rows="4" placeholder="What should this bot work on?" aria-label="First bot task"></textarea>
    <div class="share-actions"><button id="bot-start" class="button primary" type="button">Start session</button></div>
  </div>
</div>

<div id="share-panel" class="share-overlay hidden" role="dialog" aria-modal="true" aria-labelledby="share-title">
  <div class="share-card">
    <div class="share-head">
      <div class="share-head-copy"><h2 id="share-title">Share with your Mac</h2><p>Clipboard text and files move directly over your private connection.</p></div>
      <button id="share-close" class="icon-button" type="button" aria-label="Close sharing">×</button>
    </div>
    <section class="share-section">
      <div class="share-label">Clipboard</div>
      <textarea id="share-clipboard" class="share-clipboard" placeholder="Paste text here, or pull the current clipboard from your Mac" aria-label="Shared clipboard text"></textarea>
      <div class="share-actions">
        <button id="clipboard-pull" class="button" type="button">Copy from Mac</button>
        <button id="clipboard-push" class="button primary" type="button">Send to Mac</button>
      </div>
    </section>
    <section class="share-section">
      <div class="share-label">Shared files</div>
      <input id="file-picker" type="file" hidden>
      <button id="file-choose" class="button" type="button">Choose a file to send</button>
      <div id="shared-files" class="shared-files" aria-live="polite"></div>
    </section>
  </div>
</div>

<div class="shell">
  <button id="session-scrim" class="session-scrim" type="button" aria-label="Close sessions"></button>
  <aside class="sidebar" aria-label="Saved sessions">
    <div class="brand">
      <div class="brand-row"><img class="brand-logo" src="/assets/beetlogo.png" alt="Beet Code logo"><h1>Beet Code</h1></div>
      <p>Remote session control</p>
    </div>
    <div class="sessions">
      <div class="sessions-heading">
        <button id="sessions-toggle" class="sessions-toggle" type="button" aria-expanded="true" aria-controls="session-list" aria-label="Sessions">Sessions</button>
        <button id="refresh" class="icon-button" type="button" aria-label="Refresh sessions" title="Refresh sessions">↻</button>
      </div>
      <div id="session-list" role="listbox" aria-label="Saved Beetcode sessions"></div>
    </div>
    <div class="mobile-sheet-footer">
      <div class="appearance-switcher" role="group" aria-label="Appearance">
        <button class="appearance-option" type="button" data-theme-choice="light" aria-label="Light appearance" aria-pressed="false"><span class="appearance-glyph" aria-hidden="true">☼</span><span class="appearance-label">Light</span></button>
        <button class="appearance-option" type="button" data-theme-choice="dark" aria-label="Dark appearance" aria-pressed="false"><span class="appearance-glyph" aria-hidden="true">☾</span><span class="appearance-label">Dark</span></button>
        <button class="appearance-option" type="button" data-theme-choice="beet" aria-label="Beet appearance" aria-pressed="true"><span class="appearance-glyph" aria-hidden="true">B</span><span class="appearance-label">Beet</span></button>
      </div>
      <button id="revoke-mobile" class="footer-revoke" type="button">Revoke browser</button>
    </div>
    <div class="footer"><span id="network-note">Runs on your Mac over Tailscale.</span><br><button id="revoke" type="button">Revoke this browser</button></div>
  </aside>

  <main class="main">
    <header class="topbar">
      <button id="mobile-sessions" class="mobile-sessions-button" type="button" aria-label="Show sessions" aria-expanded="false">☰</button>
      <div class="title-block">
        <h2 id="session-title">Choose a session</h2>
        <div id="session-sub" class="sub">Your saved Beetcode sessions appear here.</div>
      </div>
      <div class="top-actions">
        <button id="bots-open" class="button ghost" type="button" aria-label="Start a new session">New</button>
        <button id="refresh-mobile" class="icon-button" type="button" aria-label="Refresh sessions" title="Refresh sessions">↻</button>
        <button id="share-open" class="icon-button" type="button" aria-label="Share clipboard or files" title="Share clipboard or files">⇄</button>
        <div class="appearance-switcher" role="group" aria-label="Appearance">
          <button class="appearance-option" type="button" data-theme-choice="light" aria-label="Light appearance" aria-pressed="false"><span class="appearance-glyph" aria-hidden="true">☼</span><span class="appearance-label">Light</span></button>
          <button class="appearance-option" type="button" data-theme-choice="dark" aria-label="Dark appearance" aria-pressed="false"><span class="appearance-glyph" aria-hidden="true">☾</span><span class="appearance-label">Dark</span></button>
          <button class="appearance-option" type="button" data-theme-choice="beet" aria-label="Beet appearance" aria-pressed="true"><span class="appearance-glyph" aria-hidden="true">B</span><span class="appearance-label">Beet</span></button>
        </div>
        <div class="status" role="status"><span id="status-dot" class="dot"></span><span id="status-text">Not paired</span></div>
      </div>
    </header>
    <div id="notice" class="notice" role="status" aria-live="polite"></div>
    <section id="messages" class="messages" aria-live="polite" aria-label="Session transcript">
      <div class="empty home-empty">
        <div class="empty-card"><h3>Start a chat, or pick a bot.</h3><div>Bots are optional specialists. New sessions stay focused on the model and first task.</div></div>
        <div id="bot-choice" class="bot-rail" role="listbox" aria-label="Optional bots"></div>
      </div>
    </section>
    <section id="interaction" class="interaction hidden" aria-live="assertive"></section>
    <div class="composer-wrap">
      <div class="composer">
        <textarea id="composer" rows="1" placeholder="Continue this coding task…" disabled aria-label="Next prompt"></textarea>
        <button id="send" class="send" type="button" disabled aria-label="Send prompt">↑</button>
        <button id="stop" class="stop hidden" type="button" aria-label="Stop Beetcode">■</button>
      </div>
      <div class="run-controls" role="group" aria-label="Run controls">
        <select id="chat-model" class="chat-model" aria-label="Model" disabled><option value="">Model</option></select>
        <label class="run-control"><input id="auto-mode" type="checkbox" checked>Auto mode</label>
        <label class="run-control"><input id="full-access" type="checkbox">Full Access</label>
      </div>
      <div class="hint">Enter sends · Shift+Enter adds a line · approvals stay under your control</div>
    </div>
  </main>
</div>

<script>
const TOKEN_KEY = 'beetcode.remote.token';
const THEME_KEY = 'beetcode.remote.appearance';
const CURRENT_SESSION_KEY = 'beetcode.remote.currentSession';
const AUTO_MODE_KEY = 'beetcode.remote.autoMode';
const FULL_ACCESS_KEY = 'beetcode.remote.fullAccess';
const BOTS = [
  { id: 'general', name: 'Beet', detail: 'Balanced assistant', image: '/assets/beetlogo.png', instruction: '' },
  { id: 'builder', name: 'Builder', detail: 'Build and fix', image: '/assets/bot-builder.png', instruction: 'Work as a focused software builder. Inspect the existing project, implement the request completely, preserve unrelated work, and verify the result.' },
  { id: 'reviewer', name: 'Reviewer', detail: 'Diff and risks', image: '/assets/bot-reviewer.png', instruction: 'Work as a careful code reviewer. Identify concrete bugs and regressions first. Do not edit unless asked.' },
  { id: 'navigator', name: 'Navigator', detail: 'Browser control', image: '/assets/bot-navigator.png', instruction: 'Work as a browser navigator. Use the available browser tools directly and keep actions scoped to the request.' },
  { id: 'researcher', name: 'Researcher', detail: 'Sources and synthesis', image: '/assets/bot-researcher.png', instruction: 'Work as a technical researcher. Prefer primary sources and distinguish facts from inference.' }
];
const THEMES = new Set(['light', 'dark', 'beet']);
const POLL_DELAY_MS = 1800;
const HIDDEN_POLL_DELAY_MS = 5000;
const MAX_RETRY_DELAY_MS = 15000;
const FETCH_TIMEOUT_MS = 10000;
const state = {
  token: localStorage.getItem(TOKEN_KEY),
  current: localStorage.getItem(CURRENT_SESSION_KEY),
  busy: false,
  phase: 'idle',
  loadingSession: false,
  polling: false,
  noticeTimer: null,
  interactionKey: null,
  retryDelay: POLL_DELAY_MS,
  consecutiveFailures: 0,
  reconnecting: false,
  sessionsExpanded: false,
  autoMode: localStorage.getItem(AUTO_MODE_KEY) !== 'false',
  fullAccess: localStorage.getItem(FULL_ACCESS_KEY) === 'true',
  streamController: null,
  streamSessionID: null
  ,selectedBot: ''
};
const $ = id => document.getElementById(id);
const text = value => String(value ?? '');
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
$('auto-mode').checked = state.autoMode;
$('full-access').checked = state.fullAccess;

function applyAppearance(theme, persist = true) {
  const value = THEMES.has(theme) ? theme : 'beet';
  document.documentElement.dataset.theme = value;
  document.querySelectorAll('[data-theme-choice]').forEach(button => {
    button.setAttribute('aria-pressed', button.dataset.themeChoice === value ? 'true' : 'false');
  });
  const themeColors = { light: '#F6F7F9', dark: '#0C0E14', beet: '#7A1F3D' };
  document.querySelector('meta[name="theme-color"]').setAttribute('content', themeColors[value]);
  if (persist) localStorage.setItem(THEME_KEY, value);
}

function setStatus(label, kind = '') {
  $('status-text').textContent = label;
  $('status-dot').className = 'dot ' + kind;
}

function showNotice(message, kind = '') {
  const element = $('notice');
  element.textContent = message || '';
  element.className = 'notice' + (message ? ' visible' : '') + (kind ? ' ' + kind : '');
  if (state.noticeTimer) clearTimeout(state.noticeTimer);
  if (message) state.noticeTimer = setTimeout(() => showNotice(''), 7000);
}

function clearToken() {
  state.token = null;
  localStorage.removeItem(TOKEN_KEY);
}

function showPairing(error = '') {
  $('pairing').classList.remove('hidden');
  const errorElement = $('pair-error');
  errorElement.textContent = error;
  errorElement.classList.toggle('hidden', !error);
  setStatus('Pair this browser');
  if (!error) setTimeout(() => $('pair-code').focus(), 0);
}

function hidePairing() {
  $('pairing').classList.add('hidden');
  $('pair-error').classList.add('hidden');
}

function connectionRecovered() {
  state.retryDelay = POLL_DELAY_MS;
  state.consecutiveFailures = 0;
  state.reconnecting = false;
  showNotice('');
  if (!state.current || !state.busy) setStatus('Connected', 'live');
}

function connectionLost() {
  state.consecutiveFailures += 1;
  const exponent = Math.min(state.consecutiveFailures - 1, 3);
  state.retryDelay = Math.min(POLL_DELAY_MS * (2 ** exponent), MAX_RETRY_DELAY_MS);
  state.reconnecting = true;
  if (state.token) {
    setStatus('Reconnecting…', 'busy');
    showNotice('Connection lost. Reconnecting…', 'error');
  }
}

async function refreshNow(quiet = true) {
  if (document.hidden || !state.token || navigator.onLine === false || state.polling) return false;
  state.polling = true;
  try {
    const ok = await refresh(quiet);
    if (ok) connectionRecovered();
    else if (state.token) connectionLost();
    return ok;
  } finally {
    state.polling = false;
  }
}

function resumeConnection() {
  if (document.hidden || !state.token || navigator.onLine === false) return;
  setStatus('Reconnecting…', 'busy');
  void refreshNow(true);
}

function updateSessionListMode() {
  const sidebar = document.querySelector('.sidebar');
  const toggle = $('sessions-toggle');
  const isMobile = window.innerWidth <= 720;
  const compact = Boolean(state.current) && !state.sessionsExpanded;
  const collapsed = compact && isMobile;
  sidebar.classList.toggle('compact', compact);
  document.body.classList.toggle('sessions-open', isMobile && !collapsed);
  toggle.setAttribute('aria-expanded', collapsed ? 'false' : 'true');
  toggle.setAttribute('aria-label', collapsed ? 'Show all sessions' : 'Hide sessions');
  toggle.title = collapsed ? 'Show all sessions' : 'Hide sessions';
  $('mobile-sessions').setAttribute('aria-expanded', collapsed ? 'false' : 'true');
}

function normalizedCode(raw) {
  const value = text(raw).replace(/[\s\-·]/g, '');
  return /^[0-9]{6}$/.test(value) ? value : null;
}

async function api(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (options.body && !headers['Content-Type']) headers['Content-Type'] = 'application/json';
  if (state.token) headers.Authorization = 'Bearer ' + state.token;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), FETCH_TIMEOUT_MS);
  let response;
  try {
    response = await fetch(path, Object.assign({}, options, {
      headers,
      cache: 'no-store',
      signal: controller.signal
    }));
  } catch (error) {
    if (error && error.name === 'AbortError') throw new Error('The connection timed out. Reconnecting…');
    throw error;
  } finally {
    clearTimeout(timeout);
  }
  let body = {};
  try { body = await response.json(); } catch {}
  if (response.status === 401 && path !== '/api/pair') {
    clearToken();
    showPairing(body.error || 'This browser pairing expired.');
  }
  if (!response.ok) throw new Error(body.error || 'Request failed. Try again.');
  return body;
}

async function apiRaw(path, options = {}) {
  const headers = Object.assign({}, options.headers || {});
  if (state.token) headers.Authorization = 'Bearer ' + state.token;
  const response = await fetch(path, Object.assign({}, options, { headers, cache: 'no-store' }));
  if (!response.ok) {
    let message = 'Transfer failed. Try again.';
    try { message = (await response.json()).error || message; } catch {}
    throw new Error(message);
  }
  return response;
}

function setSharePanel(open) {
  $('share-panel').classList.toggle('hidden', !open);
  if (open) {
    void loadSharedFiles();
    setTimeout(() => $('share-clipboard').focus(), 0);
  }
}

function selectedBot() {
  if (!state.selectedBot || state.selectedBot === 'general') return null;
  return BOTS.find(item => item.id === state.selectedBot) || null;
}

function renderBots() {
  const root = $('bot-choice');
  if (!root) return;
  root.replaceChildren();
  for (const bot of BOTS) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'bot-tile';
    button.dataset.bot = bot.id;
    button.setAttribute('role', 'option');
    button.setAttribute('aria-label', bot.name + ', ' + bot.detail);
    const image = document.createElement('img');
    image.className = 'bot-thumb';
    image.src = bot.image;
    image.alt = '';
    const name = document.createElement('strong');
    name.textContent = bot.name;
    const detail = document.createElement('span');
    detail.className = 'bot-detail';
    detail.textContent = bot.id === 'general' ? 'Plain chat' : bot.detail;
    button.append(image, name, detail);
    button.onclick = () => {
      state.selectedBot = bot.id === 'general' ? '' : bot.id;
      void setBotsPanel(true);
    };
    root.append(button);
  }
}

function renderHome() {
  const root = $('messages');
  root.replaceChildren();
  const empty = document.createElement('div');
  empty.className = 'empty home-empty';
  const card = document.createElement('div');
  card.className = 'empty-card';
  const heading = document.createElement('h3');
  heading.textContent = 'Start a chat, or pick a bot.';
  const copy = document.createElement('div');
  copy.textContent = 'Bots are optional specialists. New sessions stay focused on the model and first task.';
  card.append(heading, copy);
  const choice = document.createElement('div');
  choice.id = 'bot-choice';
  choice.className = 'bot-rail';
  choice.setAttribute('role', 'listbox');
  choice.setAttribute('aria-label', 'Choose a bot');
  empty.append(card, choice);
  root.append(empty);
  renderBots();
}

async function setBotsPanel(open) {
  $('bots-panel').classList.toggle('hidden', !open);
  if (!open) return;
  const bot = selectedBot();
  $('bots-title').textContent = bot ? 'Start with ' + bot.name : 'New session';
  $('bots-sub').textContent = bot
    ? bot.detail + '. Choose a model and first task.'
    : 'Plain chat — no specialist bot. Choose a model and first task.';
  try {
    const body = await api('/api/models');
    const select = $('bot-model'); select.replaceChildren();
    for (const model of (body.models || [])) {
      const option = document.createElement('option'); option.value = model.id;
      option.textContent = model.name + ' · ' + model.detail; select.append(option);
    }
    if (!select.options.length) {
      const option = document.createElement('option'); option.value = ''; option.textContent = 'No models available'; select.append(option);
    }
  } catch (error) { showNotice(error.message, 'error'); }
  setTimeout(() => $('bot-prompt').focus(), 0);
}

async function startBotSession() {
  const modelID = $('bot-model').value;
  const prompt = $('bot-prompt').value.trim();
  const bot = selectedBot();
  if (!modelID || !prompt) { showNotice('Choose a model and enter a task.', 'error'); return; }
  const message = prompt;
  $('bot-start').disabled = true;
  try {
    const payload = { modelID, message, autoMode: state.autoMode, fullAccess: state.fullAccess };
    if (bot) payload.botProfileID = bot.id;
    const body = await api('/api/sessions', { method: 'POST', body: JSON.stringify(payload) });
    $('bot-prompt').value = ''; await setBotsPanel(false); await loadSessions();
    if (body.sessionID) await selectSession(body.sessionID);
  } catch (error) { showNotice(error.message, 'error'); }
  finally { $('bot-start').disabled = false; }
}

function fileSizeLabel(bytes) {
  const value = Number(bytes) || 0;
  if (value < 1024) return value + ' B';
  if (value < 1024 * 1024) return (value / 1024).toFixed(1) + ' KB';
  return (value / (1024 * 1024)).toFixed(1) + ' MB';
}

function renderSharedFiles(files) {
  const root = $('shared-files');
  root.replaceChildren();
  if (!files.length) {
    const empty = document.createElement('div');
    empty.className = 'shared-empty';
    empty.textContent = 'Files appear in Downloads › BeetCode Remote on your Mac.';
    root.append(empty);
    return;
  }
  for (const file of files) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'shared-file';
    const icon = document.createElement('span');
    icon.className = 'shared-file-icon';
    icon.textContent = '↓';
    const copy = document.createElement('span');
    copy.className = 'shared-file-copy';
    const name = document.createElement('span');
    name.className = 'shared-file-name';
    name.textContent = text(file.name);
    const meta = document.createElement('span');
    meta.className = 'shared-file-meta';
    meta.textContent = fileSizeLabel(file.size) + ' · tap to download';
    copy.append(name, meta);
    button.append(icon, copy);
    button.onclick = () => downloadSharedFile(file.name);
    root.append(button);
  }
}

async function loadSharedFiles() {
  try {
    const body = await api('/api/files');
    renderSharedFiles(Array.isArray(body.files) ? body.files : []);
  } catch (error) { showNotice(error.message, 'error'); }
}

async function pullClipboard() {
  try {
    const body = await api('/api/clipboard');
    $('share-clipboard').value = text(body.text);
    if (navigator.clipboard && body.text) {
      try { await navigator.clipboard.writeText(body.text); } catch {}
    }
    showNotice(body.text ? 'Mac clipboard copied here.' : 'The Mac clipboard is empty.');
  } catch (error) { showNotice(error.message, 'error'); }
}

async function pushClipboard() {
  let value = $('share-clipboard').value;
  if (!value && navigator.clipboard) {
    try { value = await navigator.clipboard.readText(); } catch {}
  }
  if (!value) { showNotice('Paste some text into the clipboard box first.', 'error'); return; }
  try {
    await api('/api/clipboard', { method: 'PUT', body: JSON.stringify({ text: value }) });
    showNotice('Clipboard sent to your Mac.');
  } catch (error) { showNotice(error.message, 'error'); }
}

async function uploadSharedFile(file) {
  if (!file) return;
  if (file.size <= 0 || file.size > 20 * 1024 * 1024) {
    showNotice('Choose a non-empty file smaller than 20 MB.', 'error');
    return;
  }
  $('file-choose').disabled = true;
  try {
    await apiRaw('/api/files?name=' + encodeURIComponent(file.name), {
      method: 'POST', headers: { 'Content-Type': 'application/octet-stream' }, body: file
    });
    showNotice('File sent to your Mac.');
    await loadSharedFiles();
  } catch (error) { showNotice(error.message, 'error'); }
  finally { $('file-choose').disabled = false; $('file-picker').value = ''; }
}

async function downloadSharedFile(name) {
  try {
    const response = await apiRaw('/api/files/' + encodeURIComponent(name));
    const blob = await response.blob();
    const url = URL.createObjectURL(blob);
    const link = document.createElement('a');
    link.href = url;
    link.download = name;
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 1000);
  } catch (error) { showNotice(error.message, 'error'); }
}

async function pair(rawCode) {
  const code = normalizedCode(rawCode);
  if (!code) {
    showPairing('Enter the six-digit code shown in Beet Code.');
    return;
  }
  $('pair-button').disabled = true;
  try {
    const body = await api('/api/pair', {
      method: 'POST',
      body: JSON.stringify({ code })
    });
    state.token = body.token;
    localStorage.setItem(TOKEN_KEY, body.token);
    history.replaceState({}, '', location.pathname);
    hidePairing();
    setStatus('Connected', 'live');
    await refreshNow(false);
  } catch (error) {
    showPairing(error.message);
  } finally {
    $('pair-button').disabled = false;
  }
}

function formatAge(timestamp) {
  if (!timestamp) return '';
  const date = new Date(Number(timestamp) * 1000);
  if (Number.isNaN(date.getTime())) return '';
  return new Intl.DateTimeFormat(undefined, { month: 'short', day: 'numeric' }).format(date);
}

function phaseLabel(value) {
  const labels = {
    planning: 'planning',
    awaitingPlanApproval: 'waiting for plan approval',
    working: 'working',
    awaitingApproval: 'waiting for approval',
    awaitingQuestion: 'waiting for your answer',
    verifying: 'verifying',
    finished: 'finished',
    idle: 'idle'
  };
  return labels[text(value)] || 'working';
}

function renderSessions(items) {
  const list = $('session-list');
  list.replaceChildren();
  if (!items.length) {
    const empty = document.createElement('div');
    empty.className = 'empty-sidebar';
    empty.textContent = 'No saved sessions yet. Start a task in Beet Code first.';
    list.append(empty);
    updateSessionListMode();
    return;
  }
  for (const item of items) {
    const button = document.createElement('button');
    button.type = 'button';
    button.className = 'session ' + (state.current === item.id ? 'active' : '');
    button.dataset.id = item.id;
    button.setAttribute('role', 'option');
    button.setAttribute('aria-selected', state.current === item.id ? 'true' : 'false');
    const title = document.createElement('span');
    title.className = 'session-title';
    title.textContent = text(item.title);
    const meta = document.createElement('span');
    meta.className = 'session-meta';
    meta.textContent = text(item.workspace) + ' · ' + item.messageCount + ' messages · ' + formatAge(item.updatedAt);
    if (item.isRunning) {
      const indicator = document.createElement('span');
      indicator.className = 'session-status';
      indicator.title = 'Beet Code is ' + phaseLabel(item.phase);
      meta.prepend(indicator);
    }
    button.append(title, meta);
    button.onclick = () => selectSession(item.id);
    list.append(button);
  }
  updateSessionListMode();
}

async function loadSessions() {
  if (!state.token) return;
  const body = await api('/api/sessions');
  const sessions = body.sessions || [];
  renderSessions(sessions);
  if (state.current && !sessions.some(item => item.id === state.current)) {
    if (state.streamController) state.streamController.abort();
    state.streamController = null;
    state.streamSessionID = null;
    state.current = null;
    state.sessionsExpanded = false;
    localStorage.removeItem(CURRENT_SESSION_KEY);
    state.busy = false;
    state.phase = 'idle';
    state.interactionKey = null;
    renderInteraction(null);
    updateComposer();
    $('session-title').textContent = 'Choose a session';
    $('session-sub').textContent = 'Your saved Beetcode sessions appear here.';
    renderHome();
  }
  if (!state.current && sessions.length === 1) await selectSession(sessions[0].id);
}

function renderEmptyTranscript(title, body) {
  const root = $('messages');
  root.replaceChildren();
  const empty = document.createElement('div');
  empty.className = 'empty';
  const card = document.createElement('div');
  card.className = 'empty-card';
  const heading = document.createElement('h3');
  heading.textContent = text(title);
  const copy = document.createElement('div');
  copy.textContent = text(body);
  card.append(heading, copy);
  empty.append(card);
  root.append(empty);
}

function roleLabel(message) {
  const tool = text(message.toolName).replace(/^dynamic:/, '').replaceAll('_', ' ');
  if (message.role === 'toolResult') return tool || 'tool result';
  if (message.role === 'toolCall') return tool || 'tool call';
  if (message.role === 'assistant') return 'Beet Code';
  if (message.role === 'user') return 'You';
  return message.role || 'message';
}

function readableToolContent(message) {
  const raw = text(message.content).trim();
  if (raw === '{}') return '';
  if (message.role !== 'toolResult' || !raw.startsWith('[')) return text(message.content);
  try {
    const items = JSON.parse(raw);
    if (Array.isArray(items)) {
      const values = items.map(item => item && typeof item.text === 'string' ? item.text : '').filter(Boolean);
      if (values.length) return values.join('\n');
    }
  } catch {}
  return text(message.content);
}

function renderMessages(record) {
  const root = $('messages');
  const wasAtBottom = root.scrollHeight - root.scrollTop - root.clientHeight < 56;
  const messages = Array.isArray(record.messages) ? record.messages : [];
  const liveText = text(record.streamingText).trim();
  if (!messages.length && !liveText) {
    renderEmptyTranscript('No messages yet.', 'Send a prompt below to continue this session.');
    return;
  }
  root.replaceChildren();
  for (const message of messages) {
    const bubble = document.createElement('article');
    bubble.className = 'bubble ' + (message.role === 'user' ? 'user' : (message.role === 'toolCall' || message.role === 'toolResult' ? 'tool' : (message.role === 'error' ? 'error' : '')));
    const role = document.createElement('div');
    role.className = 'role';
    role.textContent = roleLabel(message);
    const content = document.createElement('div');
    content.textContent = readableToolContent(message);
    bubble.append(role, content);
    root.append(bubble);
  }
  if (record.isRunning && liveText) {
    const bubble = document.createElement('article');
    bubble.className = 'bubble live';
    bubble.setAttribute('aria-label', 'Live Beetcode response');
    const role = document.createElement('div');
    role.className = 'role';
    role.textContent = 'Beet Code · ' + phaseLabel(record.phase);
    const content = document.createElement('div');
    content.textContent = liveText;
    bubble.append(role, content);
    root.append(bubble);
  }
  if (record.error && !messages.some(message => message.role === 'error')) {
    const bubble = document.createElement('article');
    bubble.className = 'bubble error';
    const role = document.createElement('div');
    role.className = 'role';
    role.textContent = text(record.error.title || 'Chat failed');
    const content = document.createElement('div');
    content.textContent = text(record.error.message);
    bubble.append(role, content);
    root.append(bubble);
  }
  if (wasAtBottom) root.scrollTop = root.scrollHeight;
}

async function loadStatus() {
  const body = await api('/api/status');
  state.phase = text(body.phase || state.phase);
  const localNetwork = body.networkKind === 'localNetwork';
  $('network-note').textContent = localNetwork
    ? 'Local-network fallback is enabled. Use a trusted private network.'
    : 'Runs on your Mac over Tailscale.';
}

function previewText(preview) {
  if (!preview) return '';
  if (preview.kind === 'diff') return 'Edit ' + text(preview.path) + '\n+' + preview.added + '  −' + preview.removed + '\n\n' + text(preview.content);
  if (preview.kind === 'command') return 'Run command\n\n' + text(preview.content);
  return text(preview.content);
}

function updateComposer() {
  const hasSession = Boolean(state.token && state.current);
  const unavailable = !hasSession || state.busy || state.loadingSession;
  $('composer').disabled = unavailable;
  $('send').disabled = unavailable;
  $('send').classList.toggle('hidden', state.busy);
  $('stop').classList.toggle('hidden', !hasSession || !state.busy);
  $('chat-model').disabled = unavailable;
}

async function loadSession(quiet = false, lockComposer = true) {
  if (!state.current || !state.token) return null;
  if (lockComposer) {
    state.loadingSession = true;
    updateComposer();
  }
  try {
    const record = await api('/api/sessions/' + encodeURIComponent(state.current));
    applySessionRecord(record);
    if (state.streamSessionID !== state.current) startSessionStream(state.current);
    return record;
  } catch (error) {
    if (!quiet) showNotice(error.message, 'error');
    return null;
  } finally {
    if (lockComposer) {
      state.loadingSession = false;
      updateComposer();
    }
  }
}

async function loadChatModels() {
  const select = $('chat-model');
  if (!select || select.dataset.loaded === '1') return;
  try {
    const body = await api('/api/models');
    select.replaceChildren();
    for (const model of (body.models || [])) {
      const option = document.createElement('option');
      option.value = model.id;
      option.textContent = model.name + ' · ' + model.detail;
      select.append(option);
    }
    if (!select.options.length) {
      const option = document.createElement('option');
      option.value = '';
      option.textContent = 'Model';
      select.append(option);
    }
    select.dataset.loaded = '1';
  } catch {}
}

function matchChatModel(modelID) {
  const select = $('chat-model');
  if (!select || !modelID) return;
  const short = String(modelID).replace(/^openai-codex:/, '');
  const match = Array.from(select.options).find(option =>
    option.value === modelID || option.value.endsWith('|' + short) || option.textContent.indexOf(short) === 0);
  if (match) select.value = match.value;
}

function applySessionRecord(record) {
  if (!record || record.id !== state.current) return;
  $('session-title').textContent = record.title || 'Session';
  $('session-sub').textContent = text(record.workspace) + ' · ' + (record.modelID || 'Beet Code');
  const select = $('chat-model');
  if (select && select.dataset.session !== record.id) {
    void loadChatModels().then(() => {
      matchChatModel(record.modelID);
      select.dataset.session = record.id;
    });
  }
  state.busy = Boolean(record.isRunning);
  state.phase = text(record.phase || (state.busy ? 'working' : 'idle'));
  updateComposer();
  setStatus(state.busy ? 'Beet Code · ' + phaseLabel(state.phase) : 'Connected', state.busy ? 'busy' : 'live');
  renderMessages(record);
  renderInteraction(record.pending);
}

async function startSessionStream(id) {
  if (state.streamController) state.streamController.abort();
  const controller = new AbortController();
  state.streamController = controller;
  state.streamSessionID = id;
  try {
    const response = await fetch('/api/sessions/' + encodeURIComponent(id) + '/events', {
      headers: { 'Authorization': 'Bearer ' + state.token, 'Accept': 'text/event-stream' },
      cache: 'no-store',
      signal: controller.signal
    });
    if (!response.ok || !response.body) throw new Error('Live stream unavailable.');
    const reader = response.body.getReader();
    const decoder = new TextDecoder();
    let buffer = '';
    while (state.current === id && !controller.signal.aborted) {
      const chunk = await reader.read();
      if (chunk.done) break;
      buffer += decoder.decode(chunk.value, { stream: true });
      let frameEnd;
      while ((frameEnd = buffer.indexOf('\n\n')) >= 0) {
        const frame = buffer.slice(0, frameEnd);
        buffer = buffer.slice(frameEnd + 2);
        const line = frame.split('\n').find(value => value.startsWith('data:'));
        if (line) applySessionRecord(JSON.parse(line.slice(5).trim()));
      }
    }
  } catch (error) {
    if (!controller.signal.aborted && state.current === id) {
      await sleep(800);
      if (state.current === id) startSessionStream(id);
    }
  } finally {
    if (state.streamController === controller) {
      state.streamController = null;
      state.streamSessionID = null;
    }
  }
}

async function selectSession(id) {
  state.current = id;
  state.sessionsExpanded = false;
  localStorage.setItem(CURRENT_SESSION_KEY, id);
  state.interactionKey = null;
  updateSessionListMode();
  document.querySelectorAll('.session').forEach(item => {
    const selected = item.dataset.id === id;
    item.classList.toggle('active', selected);
    item.setAttribute('aria-selected', selected ? 'true' : 'false');
  });
  updateComposer();
  await loadSession();
}

function renderInteraction(pending) {
  const root = $('interaction');
  const key = pending ? JSON.stringify(pending) : '';
  if (key === state.interactionKey) return;
  state.interactionKey = key;
  root.replaceChildren();
  root.classList.toggle('hidden', !pending || !pending.kind);
  if (!pending || !pending.kind) return;

  const head = document.createElement('div');
  head.className = 'interaction-head';
  const kicker = document.createElement('span');
  kicker.className = 'interaction-kicker';
  kicker.textContent = pending.kind === 'approval' ? 'Approval needed' : (pending.kind === 'question' ? 'Beet Code has a question' : 'Plan ready');
  head.append(kicker);
  if (pending.toolName) {
    const tool = document.createElement('span');
    tool.className = 'interaction-tool';
    tool.textContent = pending.toolName;
    head.append(tool);
  }
  root.append(head);

  if (pending.kind === 'approval') {
    const summary = document.createElement('p');
    summary.className = 'interaction-summary';
    summary.textContent = text(pending.summary);
    root.append(summary);
    if (pending.preview && pending.preview.kind !== 'none') {
      const preview = document.createElement('pre');
      preview.className = 'preview';
      preview.textContent = previewText(pending.preview);
      root.append(preview);
    }
    const actions = document.createElement('div');
    actions.className = 'interaction-actions';
    actions.append(actionButton('Approve', 'primary', () => resolveApproval(pending, true, false)));
    actions.append(actionButton(pending.toolName === 'run_command' ? 'Always allow safe commands' : 'Always allow edits', '', () => resolveApproval(pending, true, true)));
    actions.append(actionButton('Decline', 'ghost', () => resolveApproval(pending, false, false)));
    root.append(actions);
    return;
  }

  if (pending.kind === 'question') {
    const question = document.createElement('p');
    question.className = 'interaction-summary';
    question.textContent = text(pending.content);
    root.append(question);
    const actions = document.createElement('div');
    actions.className = 'interaction-actions';
    const input = document.createElement('input');
    input.id = 'question-answer';
    input.placeholder = 'Type your answer…';
    input.autocomplete = 'off';
    const answer = actionButton('Answer', 'primary', () => resolveQuestion(pending, input.value));
    input.onkeydown = event => { if (event.key === 'Enter') resolveQuestion(pending, input.value); };
    actions.append(input, answer);
    root.append(actions);
    setTimeout(() => input.focus(), 0);
    return;
  }

  const plan = document.createElement('pre');
  plan.className = 'preview';
  plan.textContent = text(pending.content);
  root.append(plan);
  const actions = document.createElement('div');
  actions.className = 'interaction-actions';
  actions.append(actionButton('Approve plan', 'primary', () => resolvePlan(pending, 'approve')));
  const input = document.createElement('input');
  input.id = 'plan-feedback';
  input.placeholder = 'Optional revision feedback…';
  input.autocomplete = 'off';
  const revise = actionButton('Send revision', '', () => resolvePlan(pending, 'revise', input.value));
  input.onkeydown = event => { if (event.key === 'Enter') resolvePlan(pending, 'revise', input.value); };
  actions.append(input, revise);
  root.append(actions);
}

function actionButton(label, kind, action) {
  const button = document.createElement('button');
  button.type = 'button';
  button.className = 'button ' + kind;
  button.textContent = label;
  button.onclick = action;
  return button;
}

async function resolveApproval(pending, approved, always) {
  try {
    await api('/api/sessions/' + encodeURIComponent(state.current) + '/approval', {
      method: 'POST',
      body: JSON.stringify({ requestID: pending.requestID, approved, always })
    });
    await loadSession();
  } catch (error) { showNotice(error.message, 'error'); }
}

async function resolveQuestion(pending, answer) {
  const value = text(answer).trim();
  if (!value) { showNotice('Answer the question before sending.', 'error'); return; }
  try {
    await api('/api/sessions/' + encodeURIComponent(state.current) + '/question', {
      method: 'POST',
      body: JSON.stringify({ requestID: pending.requestID, answer: value })
    });
    await loadSession();
  } catch (error) { showNotice(error.message, 'error'); }
}

async function resolvePlan(pending, action, feedback = '') {
  if (action === 'revise' && !text(feedback).trim()) {
    showNotice('Add feedback for the revised plan.', 'error');
    return;
  }
  try {
    await api('/api/sessions/' + encodeURIComponent(state.current) + '/plan', {
      method: 'POST',
      body: JSON.stringify({ requestID: pending.requestID, action, feedback: text(feedback).trim() })
    });
    await loadSession();
  } catch (error) { showNotice(error.message, 'error'); }
}

async function send() {
  const input = $('composer');
  const message = input.value.trim();
  if (!message || !state.current || state.busy) return;
  state.busy = true;
  updateComposer();
  setStatus('Sending…', 'busy');
  try {
    const payload = { message, autoMode: state.autoMode, fullAccess: state.fullAccess };
    const modelID = $('chat-model').value;
    if (modelID) payload.modelID = modelID;
    await api('/api/sessions/' + encodeURIComponent(state.current) + '/messages', {
      method: 'POST',
      body: JSON.stringify(payload)
    });
    input.value = '';
    await loadSession();
  } catch (error) {
    state.busy = false;
    state.phase = 'idle';
    updateComposer();
    showNotice(error.message, 'error');
    setStatus('Connected', 'live');
  }
}

async function stop() {
  if (!state.current || !state.busy) return;
  try {
    await api('/api/sessions/' + encodeURIComponent(state.current) + '/stop', { method: 'POST' });
    setStatus('Stopping…', 'busy');
    await loadSession();
  } catch (error) { showNotice(error.message, 'error'); }
}

async function refresh(quiet = false) {
  if (!state.token) return false;
  try {
    await loadStatus();
    await loadSessions();
    if (state.current) {
      // Background refreshes must never disable a focused mobile composer.
      const record = await loadSession(quiet, false);
      if (!record && state.token) return false;
    }
    if (!state.current && state.token) setStatus('Connected', 'live');
    return true;
  } catch (error) {
    if (!quiet) showNotice(error.message, 'error');
    if (state.token) setStatus('Connection problem', 'error');
    return false;
  }
}

async function poll() {
  while (true) {
    if (state.token && !state.polling && !document.hidden && navigator.onLine !== false) {
      state.polling = true;
      try {
        const ok = await refresh(true);
        if (ok) connectionRecovered();
        else if (state.token) connectionLost();
      } finally {
        state.polling = false;
      }
    }
    await sleep(document.hidden ? HIDDEN_POLL_DELAY_MS : state.retryDelay);
  }
}

$('pair-button').onclick = () => pair($('pair-code').value);
$('pair-code').oninput = event => { event.target.value = event.target.value.replace(/[^0-9]/g, '').slice(0, 6); };
$('pair-code').onkeydown = event => { if (event.key === 'Enter') pair(event.target.value); };
$('send').onclick = send;
$('bots-open').onclick = () => {
  state.selectedBot = '';
  void setBotsPanel(true);
};
$('bots-close').onclick = () => void setBotsPanel(false);
$('bot-start').onclick = startBotSession;
$('auto-mode').onchange = event => {
  state.autoMode = Boolean(event.target.checked);
  localStorage.setItem(AUTO_MODE_KEY, String(state.autoMode));
};
$('full-access').onchange = event => {
  state.fullAccess = Boolean(event.target.checked);
  localStorage.setItem(FULL_ACCESS_KEY, String(state.fullAccess));
};
$('stop').onclick = stop;
$('refresh').onclick = () => refreshNow(false);
$('refresh-mobile').onclick = () => refreshNow(false);
$('share-open').onclick = () => setSharePanel(true);
$('share-close').onclick = () => setSharePanel(false);
$('share-panel').onclick = event => { if (event.target === $('share-panel')) setSharePanel(false); };
$('clipboard-pull').onclick = pullClipboard;
$('clipboard-push').onclick = pushClipboard;
$('file-choose').onclick = () => $('file-picker').click();
$('file-picker').onchange = event => uploadSharedFile(event.target.files && event.target.files[0]);
$('sessions-toggle').onclick = () => {
  if (!state.current) return;
  state.sessionsExpanded = !state.sessionsExpanded;
  updateSessionListMode();
};
$('mobile-sessions').onclick = () => {
  state.sessionsExpanded = true;
  updateSessionListMode();
};
$('session-scrim').onclick = () => {
  if (!state.current) return;
  state.sessionsExpanded = false;
  updateSessionListMode();
};
document.querySelectorAll('[data-theme-choice]').forEach(button => {
  button.onclick = () => applyAppearance(button.dataset.themeChoice);
});
$('composer').onkeydown = event => {
  if (event.key === 'Enter' && !event.shiftKey) { event.preventDefault(); send(); }
};
async function revokeBrowser() {
  try {
    await api('/api/revoke', { method: 'POST' });
    clearToken();
    state.current = null;
    state.sessionsExpanded = false;
    localStorage.removeItem(CURRENT_SESSION_KEY);
    state.busy = false;
    updateSessionListMode();
    updateComposer();
    showPairing('This browser was revoked. Pair it again from Beet Code.');
  } catch (error) { showNotice(error.message, 'error'); }
}
$('revoke').onclick = revokeBrowser;
$('revoke-mobile').onclick = revokeBrowser;

document.addEventListener('visibilitychange', () => {
  if (document.hidden) {
    if (state.token) setStatus('Waiting in background', 'busy');
  } else {
    resumeConnection();
  }
});
window.addEventListener('pagehide', () => {
  if (state.token) setStatus('Waiting in background', 'busy');
});
window.addEventListener('pageshow', resumeConnection);
window.addEventListener('focus', resumeConnection);
window.addEventListener('online', resumeConnection);
window.addEventListener('resize', updateSessionListMode);
window.addEventListener('offline', () => {
  if (!state.token) return;
  state.reconnecting = true;
  setStatus('Offline', 'error');
  showNotice('No network connection. We’ll reconnect when you’re back online.', 'error');
});

$('bots-panel').onclick = event => { if (event.target === $('bots-panel')) void setBotsPanel(false); };

(async () => {
  applyAppearance(localStorage.getItem(THEME_KEY), false);
  renderBots();
  const pairCode = new URLSearchParams(location.search).get('pair');
  // Scanning a new QR must replace an existing browser token for this host.
  if (pairCode) {
    clearToken();
    showPairing();
    $('pair-code').value = pairCode;
    await pair(pairCode);
  } else if (!state.token) {
    showPairing();
  } else {
    hidePairing();
    updateComposer();
    await refreshNow(false);
  }
  poll();
})();
</script>
</body>
</html>
"""#
}
