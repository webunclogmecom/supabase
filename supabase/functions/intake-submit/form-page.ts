// ============================================================================
// form-page.ts — the collector form, step 4.2 of the build plan
// ============================================================================
// Served as HTML from GET on intake-submit itself. That choice is the whole reason
// the Client App's "Create link" already emits
// `<supabase url>/functions/v1/intake-submit?t=<token>`: no new origin, no DNS, no
// entry in audit.log_change's Origin CASE, and no second deploy target. The page
// talks to the same URL it was served from, so it cannot point at the wrong project.
// (Since 2026-09-25 the GET 302s to planner.unclogme.app/intake.html, which is this
// page built by scripts/intake-collector/build.mjs; the served copy here is unused.)
//
// NO BUILD STEP, NO FRAMEWORK, NO CDN. One string. A driver opens this in a parking
// lot on a phone that may be on one bar; every byte here is the whole download.
//
// 🛑 MOBILE FIRST, THEN PC (Fred, 2026-09-25). The base styles are the phone layout
//    (360-390px, one hand, outdoors): 44px+ touch targets, 16px+ inputs (iOS zooms
//    below that), a slim fixed bar. Wider screens only add space in @media blocks.
//    Check every change at 360, 390, 768 and 1280.
//
// 🛑 IT SHIPS NO KEY. The endpoint is verify_jwt=false and answers with no apikey
//    header, so the page needs no credential and must never be given one. If someone
//    later adds an anon key to this file, the token stops being the only gate.
//
// DRAFT SAFETY. Answers are written to localStorage under the token on every change.
// Fred's decision 6 put this on unauthenticated phones outdoors; a dropped connection
// or a backgrounded tab must not cost a survey that took 20 minutes.
//
// ⚠ ANSWER SHAPE. Values are sent BARE ({ "access_entry.gate": "yes" }). index.ts
//   wraps anything that is not already { value } before it is stored, so the shape
//   public.fn_intake_answered reads is produced in exactly one place, server-side.
//
// ⚠ PHOTOS. The answer value holds ONLY paths the SERVER handed back from `upload`,
//   so a photo that failed halfway can never make a question look answered. The
//   local blob preview is display data and is stripped before submit.
//
// ⚠ RE-RENDER. render() rebuilds the question list on every answer (visibility can
//   change). It puts focus and the caret back on the control that had them, and a
//   typed field re-renders one tick AFTER blur, so tapping from one field to the next
//   keeps the keyboard on the new field.
//
// ⚠ TEST HOOKS (scratchpad collector-test.mjs, see docs/reference/client-intake-system.md
//   rule 17): #ttl #sub #main #foot #who #send #cnt; one .q per question with its
//   <label> as a direct child; Yes / No buttons; input[type=file] and a .note
//   "N photo(s) attached"; "Use my location" and a .pin "Pinned at <lat>, <lng>";
//   errors are .err. The two build.mjs anchors (the charset line and the EP line)
//   must stay byte for byte.
// ============================================================================

export const FORM_HTML = String.raw`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<meta name="color-scheme" content="only light">
<meta name="theme-color" content="#ffffff">
<title>Site survey</title>
<style>
:root{color-scheme:only light;--bg:#f4f4f5;--card:#fff;--ink:#18181b;--ink2:#3f3f46;--mut:#52525b;--line:#e4e4e7;--line2:#8e8e96;--or:#f14714;--or2:#c93a0f;--ort:#fff4ef;--ok:#15803d;--okt:#f0fdf4;--bad:#b91c1c;--badt:#fef2f2}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
html{-webkit-text-size-adjust:100%;text-size-adjust:100%}
body{margin:0;overflow-wrap:anywhere;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;}
button{font:inherit;color:inherit;cursor:pointer;touch-action:manipulation}
button:focus-visible,input:focus-visible,textarea:focus-visible{outline:3px solid var(--ink);outline-offset:2px}
button:active{filter:brightness(.96)}
svg{display:block;flex:none}
.wrap{width:100%;max-width:680px;margin:0 auto;padding-left:max(16px,env(safe-area-inset-left));padding-right:max(16px,env(safe-area-inset-right))}
.hide{display:none!important}
#main [data-f],#who{scroll-margin-bottom:calc(var(--fh,80px) + 16px)}
header{background:#fff;border-top:4px solid var(--or);border-bottom:1px solid var(--line);padding-top:calc(14px + env(safe-area-inset-top));padding-bottom:18px}
.brand{display:flex;align-items:center;gap:8px;font-size:12px;font-weight:800;letter-spacing:.09em;text-transform:uppercase;color:var(--or2)}
.brand i{width:8px;height:8px;border-radius:50%;background:var(--or)}
header h1{margin:8px 0 0;font-size:22px;line-height:1.25;font-weight:800;color:var(--ink);overflow-wrap:anywhere}
header p{margin:4px 0 0;font-size:15px;color:var(--mut);overflow-wrap:anywhere}
.intro{margin:18px 2px 0;font-size:15px;color:var(--ink2)}
.card,.q{background:var(--card);border:1px solid var(--line);border-radius:16px;padding:16px;margin-top:10px}
.q>label,.card>label{display:block;font-size:17px;font-weight:700;line-height:1.35;margin-bottom:12px;overflow-wrap:anywhere}
.tag{font-size:14px;font-weight:500;color:var(--mut)}
.hint{margin:8px 2px 0;font-size:14px;color:var(--mut)}
.sec{margin-top:32px}
.sech{display:flex;align-items:baseline;justify-content:space-between;gap:12px;margin:0 2px 2px}
.sech h2{margin:0;font-size:19px;font-weight:800;color:var(--ink)}
.sech span{font-size:13px;font-weight:600;color:var(--mut);white-space:nowrap}
.sech span.done{color:var(--ok)}
input[type=text],input[type=number],input[type=time],textarea{display:block;width:100%;min-width:0;font:inherit;font-size:16px;min-height:52px;padding:12px 14px;border:1.5px solid var(--line2);border-radius:12px;background:#fff;color:var(--ink);-webkit-appearance:none;appearance:none}
textarea{min-height:104px;resize:vertical}
input:focus,textarea:focus{outline:none;border-color:var(--or);box-shadow:0 0 0 3px rgba(241,71,20,.18)}
input::placeholder,textarea::placeholder{color:#a1a1aa}
.opts{display:grid;gap:8px}
.yn{display:grid;grid-template-columns:1fr 1fr;gap:8px}
.opt{display:flex;align-items:center;gap:12px;width:100%;min-width:0;min-height:54px;padding:12px 14px;border:1.5px solid var(--line2);border-radius:12px;background:#fff;text-align:left;font-size:16px;font-weight:600}
.yn .opt{justify-content:center}
.dot{flex:none;width:22px;height:22px;border-radius:50%;border:2px solid var(--line2);display:grid;place-items:center;background:#fff}
.opt[aria-pressed=true]{border-color:var(--or);background:var(--ort);color:var(--ink)}
.opt[aria-pressed=true] .dot{border-color:var(--or);background:var(--or);color:#fff}
.step{display:grid;grid-template-columns:56px minmax(0,1fr) 56px;gap:8px;max-width:280px}
.step button{min-height:54px;border:1.5px solid var(--line2);border-radius:12px;background:#fff;font-size:26px;font-weight:600;line-height:1;display:grid;place-items:center}
.step button:disabled,.step button[aria-disabled=true]{opacity:.35;cursor:default}
.step input{text-align:center;font-size:20px;font-weight:700}
.act{display:flex;align-items:center;justify-content:center;gap:10px;width:100%;min-height:54px;padding:12px 16px;border:1.5px solid transparent;border-radius:12px;background:var(--bg);font-size:16px;font-weight:700}
.act svg{color:var(--or)}
.pin{margin-top:10px;font-size:14px;color:var(--mut)}
.pin.set{color:var(--ok);font-weight:600}
.gst{margin-top:4px;font-size:14px;color:var(--mut)}
.map{height:280px;border-radius:12px;overflow:hidden;border:1px solid var(--line);background:#e4e4e7;margin-bottom:10px}
.map.wait{display:grid;place-items:center;color:var(--mut);font-size:14px;font-weight:600}
.act:disabled{opacity:.6;cursor:default}
.days{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:6px}
.day{min-height:48px;padding:0;border:1.5px solid var(--line2);border-radius:10px;background:#fff;font-size:14px;font-weight:700;white-space:nowrap;overflow-wrap:normal}
.day[aria-pressed=true]{background:var(--or2);border-color:var(--or2);color:#fff}
.hl{margin-top:14px}
.hh{display:grid;grid-template-columns:44px minmax(0,1fr) 22px minmax(0,1fr);gap:6px;font-size:12px;font-weight:700;text-transform:uppercase;letter-spacing:.06em;color:var(--mut);margin:0 0 6px}
.hr{display:grid;grid-template-columns:44px minmax(0,1fr) 22px minmax(0,1fr);gap:6px;align-items:center;margin-bottom:8px}
.hr .dn{font-weight:700;font-size:15px}
.hr .to{text-align:center;color:var(--mut);font-size:13px}
.hr input[type=time]{padding:10px 6px;text-align:center;min-height:48px}
.hr .rh{grid-column:2/-1;margin-top:-2px;font-size:13px;font-weight:600;color:var(--ok)}
.hr .rh:empty{display:none}
.chips{display:flex;flex-wrap:wrap;gap:8px;margin-top:12px}
.chip{min-height:44px;padding:10px 16px;border:1.5px solid var(--line2);border-radius:999px;background:#fff;font-size:15px;font-weight:600}
.ph{display:grid;grid-template-columns:repeat(auto-fill,minmax(80px,1fr));gap:8px;margin-top:12px}
.ph .t{aspect-ratio:1;border-radius:10px;overflow:hidden;background:#f4f4f5;border:1px solid var(--line);display:grid;place-items:center;color:var(--mut);font-size:12px;font-weight:600;text-align:center}
.ph img{width:100%;height:100%;object-fit:cover;display:block}
.note{margin:8px 2px 0;font-size:14px;color:var(--mut)}
.note.ok{color:var(--ok);font-weight:600}
.err{display:flex;align-items:flex-start;gap:10px;background:var(--badt);border:1px solid #fecaca;color:var(--bad);border-radius:12px;padding:12px 12px 12px 14px;margin:10px 0 0;font-size:15px;font-weight:600}
.err span{flex:1}
.err button{flex:none;min-height:44px;min-width:56px;padding:4px 12px;border:1px solid #fecaca;border-radius:8px;background:#fff;font-size:13px;font-weight:700;color:var(--bad)}
footer{position:sticky;bottom:0;z-index:5;margin-top:28px;background:#fff;border-top:1px solid var(--line);box-shadow:0 -6px 20px rgba(24,24,27,.06);padding-top:10px;padding-bottom:calc(10px + env(safe-area-inset-bottom))}
#fmsg .err{margin:0 0 10px}
.bar{display:flex;align-items:center;gap:14px}
.prog{flex:1;min-width:0;min-height:48px;display:flex;flex-direction:column;justify-content:center;padding:0;border:0;background:none;text-align:left}
#cnt{font-size:14px;font-weight:700;color:var(--ink2);line-height:1.3;overflow-wrap:normal}
.pb{height:6px;border-radius:99px;background:var(--line);margin-top:7px;overflow:hidden}
.pb i{display:block;height:100%;width:0;background:var(--or);border-radius:inherit;transition:width .25s}
#send{flex:none;min-height:56px;min-width:132px;padding:0 24px;border:0;border-radius:14px;background:var(--or);color:#fff;font-size:19px;font-weight:800}
#send:active{background:var(--or2)}
#send:disabled{background:var(--line);color:var(--ink2);cursor:default}
.ph .t.send{background:var(--ort);color:var(--or2)}
.q.flash{border-color:var(--or);box-shadow:0 0 0 3px rgba(241,71,20,.2)}
.cf{background:var(--ort);border:1px solid #fbc4ae;border-radius:12px;padding:12px 14px;margin:0 0 10px;font-size:15px;font-weight:600}
.cf .row{display:flex;gap:8px;margin-top:10px}
.cf button{flex:1;min-height:48px;border-radius:10px;font-weight:700;font-size:15px}
.cf .go{border:0;background:var(--or2);color:#fff}
.cf .no{border:1.5px solid var(--line2);background:#fff}
.off{background:#fffbeb;border:1px solid #fde68a;color:#92400e;border-radius:12px;padding:12px 14px;margin-top:14px;font-size:15px;font-weight:600}
.big{text-align:center;padding:48px 8px}
.big .ic{width:64px;height:64px;border-radius:50%;margin:0 auto 16px;display:grid;place-items:center;background:var(--okt);color:var(--ok)}
.big h2{margin:0 0 8px;font-size:22px}
.big p{margin:6px 0;color:var(--ink2)}
@media (max-width:399px){.hh,.hr{grid-template-columns:minmax(0,1fr) 22px minmax(0,1fr)}.hh span:first-child{display:none}.hr .dn{grid-column:1/-1;margin-top:4px}.hr .rh{grid-column:1/-1}}
@media (max-width:359px){.days{gap:4px}.day{font-size:13px}}
@media (min-width:600px){.opts{grid-template-columns:1fr 1fr}.days{gap:8px}.ph{grid-template-columns:repeat(auto-fill,minmax(104px,1fr))}}
@media (hover:hover){.opt:hover,.day:hover,.chip:hover,.step button:hover{border-color:#a1a1aa}.opt[aria-pressed=true]:hover,.day[aria-pressed=true]:hover{border-color:var(--or2)}.act:hover{background:var(--line)}#send:hover:not(:disabled){background:var(--or2)}}
@media (min-width:768px){
header{padding-bottom:26px}header h1{font-size:28px}
.map{height:360px}
.card,.q{padding:20px 22px;margin-top:12px}
.sec{margin-top:36px}
.intro{font-size:16px}
footer{padding-top:14px;padding-bottom:calc(14px + env(safe-area-inset-bottom))}
#send{min-width:180px}
}
@media (max-height:500px){footer{position:static}}
@media (prefers-reduced-motion:reduce){.pb i{transition:none}}
</style></head>
<body>
<header><div class="wrap">
  <div class="brand"><i></i>UnclogMe · Site survey</div>
  <h1 id="ttl">Site survey</h1><p id="sub">Loading...</p>
</div></header>
<main id="main" class="wrap">
  <div id="pre" class="hide">
    <p class="intro">UnclogMe asked for a few details about this site. Answer what you can. Your answers save on this device as you go, so you can come back to this page.</p>
    <div class="card"><label for="who">Your name</label><input type="text" id="who" placeholder="First and last name" autocomplete="name" autocapitalize="words" maxlength="120" enterkeyhint="done"><div class="hint">So the office knows who filled this in.</div><div id="whoerr"></div></div>
  </div>
  <div id="qs"></div>
</main>
<footer id="foot" class="hide"><div class="wrap">
  <div id="fmsg"></div>
  <div class="bar"><button class="prog" id="prog" type="button" title="Show the next question to answer"><div id="cnt" aria-live="polite"></div><div class="pb" aria-hidden="true"><i id="pfill"></i></div></button><button id="send" type="button">Submit</button></div>
</div></footer>
<script>
var EP=location.pathname, TOKEN=new URLSearchParams(location.search).get('t')||'';
var F=null, A={}, DAYS=['mon','tue','wed','thu','fri','sat','sun'], busy=0, ERR={}, PEND={}, GEO={}, SENDING=false, LEFT=0, DONE=false, CF=null, WAIT=null;
var DAYN={mon:'Mon',tue:'Tue',wed:'Wed',thu:'Thu',fri:'Fri',sat:'Sat',sun:'Sun'};
var KEY='intake-draft-'+TOKEN;
var IC={
  check:'<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>',
  big:'<svg width="32" height="32" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6 9 17l-5-5"/></svg>',
  cam:'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/></svg>',
  pin:'<svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M12 21s-7-6.3-7-11a7 7 0 1 1 14 0c0 4.7-7 11-7 11z"/><circle cx="12" cy="10" r="2.5"/></svg>'
};
function api(b){b.token=TOKEN;return fetch(EP,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}).then(function(r){return r.json().then(function(j){j._s=r.status;return j})})}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function save(){if(DONE)return;try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){}}
function load(){try{var v=localStorage.getItem(KEY);if(v)A=JSON.parse(v)||{}}catch(e){A={}}}
function byAttr(name,val,root){ var es=(root||document).querySelectorAll('['+name+']'); for(var i=0;i<es.length;i++){ if(es[i].getAttribute(name)===val) return es[i] } return null }
function glide(n){ try{ n.scrollIntoView({behavior:(window.matchMedia&&matchMedia('(prefers-reduced-motion: reduce)').matches)?'auto':'smooth',block:'center'}) }catch(e){ n.scrollIntoView() } }
function el(tag,cls,txt){var e=document.createElement(tag);if(cls)e.className=cls;if(txt!=null)e.textContent=txt;return e}
// An error stays until the collector dismisses it or fixes the thing it is about; it never fades out.
function errBox(msg,onClose){var d=el('div','err');d.setAttribute('role','alert');d.appendChild(el('span','',msg));var x=el('button','','OK');x.type='button';x.onclick=onClose||function(){d.remove()};d.appendChild(x);return d}
function show(m){CF=null;WAIT=null;var box=document.getElementById('fmsg');if(!box||document.getElementById('foot').classList.contains('hide')){var e0=errBox(m);document.getElementById('main').prepend(e0);return e0}box.innerHTML='';var e1=errBox(m,function(){box.innerHTML='';WAIT=null});box.appendChild(e1);return e1}
function waitText(gb){ return busy>0?(gb?'Wait for the photos and the location to finish, then submit.':'Wait for the photos to finish sending, then submit.'):'Wait for the location to finish, then submit.' }

// show_if is "<key>=<value>" (the value may be empty: the parent was left blank) or "<key>>N" (the
// parent is a number above N). The operator is the FIRST "=" or ">", both sides trimmed, and a
// follow-up is shown only if its parent was itself shown. public.fn_intake_applicable and the Client
// App's Schedule dialog read it exactly the same way: change all three together.
var HHMM=/^([01][0-9]|2[0-3]):[0-5][0-9]$/, NUM=/^\s*-?[0-9]+(\.[0-9]+)?\s*$/, THRESHOLD=/^-?[0-9]+(\.[0-9]+)?$/;
function cond(show){
  if(!show) return null;
  var e=show.indexOf('='), g=show.indexOf('>');
  var p=(e<0&&g<0)?-1:(e<0?g:(g<0?e:Math.min(e,g)));
  if(p<0) return null;
  return {k:show.slice(0,p).trim(), op:show.charAt(p), v:show.slice(p+1).trim()};
}
function findQ(k){
  var sec=(F&&F.form&&F.form.sections)||[];
  for(var i=0;i<sec.length;i++){var qs=sec[i].questions||[];for(var j=0;j<qs.length;j++){var q=qs[j];if(q&&typeof q==='object'&&q.key===k)return q}}
  return null;
}
function visible(q, depth){
  depth=depth||0;
  if(depth>=10) return true;                       // a cycle in an authored tree: stay visible
  var c=cond(q&&q.show_if); if(!c) return true;
  var raw=A[c.k], got=(raw==null)?'':String(raw);
  if(c.op==='='){ if(got.trim()!==c.v) return false; }
  else { if(!(NUM.test(got)&&THRESHOLD.test(c.v)&&Number(got)>Number(c.v))) return false; }
  var parent=findQ(c.k);
  return parent ? visible(parent, depth+1) : true;
}
function setA(k,v){ if(v===''||v==null) delete A[k]; else A[k]=v; save(); render(); }
// Rebuilding the list while a pointer is down replaces the control under it, and that click is lost
// (measured on a PC: typing a count, then clicking anything). A rebuild asked for then waits until the
// pointer is released and its click has run.
var PRESS=0, PT=0, QUEUE=[], FT=null;          // PRESS: 0 idle, 1 pointer down, 2 released, waiting for its click
function afterPress(fn){ if(PRESS&&Date.now()-PT<4000) QUEUE.push(fn); else setTimeout(fn,0) }
function flush(){ PRESS=0; clearTimeout(FT); var q=QUEUE; QUEUE=[]; if(q.length) setTimeout(function(){ q.forEach(function(f){f()}) },0) }
document.addEventListener('pointerdown',function(e){ if(e.button>0) return; PRESS=1; PT=Date.now(); clearTimeout(FT); FT=setTimeout(flush,4000) },true);
// After release, wait for the click (a phone fires it after pointerup); if none comes (a scroll, a drag), go anyway.
document.addEventListener('pointerup',function(){ if(PRESS){ PRESS=2; clearTimeout(FT); FT=setTimeout(flush,450) } },true);
document.addEventListener('pointercancel',flush,true);
document.addEventListener('click',function(){ if(PRESS===2) flush() });
// Keys some other question's show_if reads. Only an answer to one of these can show or hide a question.
function isParent(k){
  var sec=(F&&F.form&&F.form.sections)||[];
  for(var i=0;i<sec.length;i++){var qs=sec[i].questions||[];for(var j=0;j<qs.length;j++){var c=cond(qs[j]&&qs[j].show_if);if(c&&c.k===k)return true}}
  return false;
}
// A typed answer. Rebuilding the list on every blur used to swallow the next tap (the button under the
// finger was replaced mid-tap), so a typed answer only rebuilds when it can show or hide a question,
// and then one tick later, after the next control has focus; render() gives focus back to its copy.
function typed(k,v){
  if(v===''||v==null) delete A[k]; else A[k]=v; save();
  if(isParent(k)) afterPress(render); else counts();
}

function counts(){
  if(!F||DONE) return;
  var req={}; (F.requested||[]).forEach(function(k){req[k]=1});
  // 'shown' counts the questions that decide Complete: visible and not optional, the same set
  // public.fn_intake_missing counts. An optional question is still rendered and still sent.
  var shown=0, answered=0;
  ((F.form||{}).sections||[]).forEach(function(s){
    var sShown=0, sAns=0;
    (s.questions||[]).forEach(function(q){ if(!req[q.key]||!visible(q)||q.optional) return; shown++; sShown++; if(isAns(q)){ answered++; sAns++ } });
    var sc=byAttr('data-sc',String(s.id||s.title));
    if(sc){ sc.textContent=sShown?(sAns===sShown?'Done':sAns+' of '+sShown):''; sc.className=(sShown&&sAns===sShown)?'done':'' }
  });
  LEFT=shown-answered;
  document.getElementById('cnt').textContent=answered+' of '+shown+' answered'+(busy?', uploading '+busy+'...':'');
  document.getElementById('pfill').style.width=(shown?Math.round(100*answered/shown):0)+'%';
  var sb=document.getElementById('send');
  var gb=geoBusy();
  if(!SENDING){ sb.disabled=busy>0||gb; sb.textContent=busy?'Sending...':(gb?'Locating...':'Submit') }
  if(WAIT){ if(busy===0&&!gb){ var fw=document.getElementById('fmsg'); if(fw) fw.innerHTML=''; WAIT=null } else WAIT.textContent=waitText(gb) }
  if(CF){ if(LEFT>0) CF.textContent=cfText(); else { var fm0=document.getElementById('fmsg'); if(fm0) fm0.innerHTML=''; CF=null } }
}
function geoBusy(){ for(var k in GEO){ if(GEO[k]&&GEO[k].busy){ var gq=findQ(k); if(gq&&visible(gq)) return true } } return false }
function cfText(){ return LEFT+(LEFT===1?' question is':' questions are')+' still blank. Once you submit, this form cannot be changed.' }
// The first visible question that still needs an answer (the ones that decide Complete).
function nextBlank(){
  var req={}; (F.requested||[]).forEach(function(k){req[k]=1});
  var secs=(F.form||{}).sections||[];
  for(var i=0;i<secs.length;i++){var qs=secs[i].questions||[];for(var j=0;j<qs.length;j++){var q=qs[j];
    if(req[q.key]&&visible(q)&&!q.optional&&!isAns(q)) return byAttr('data-q',q.key)}}
  return null;
}
function goBlank(){
  var c=nextBlank(); if(!c) return false;
  glide(c);
  c.classList.add('flash'); setTimeout(function(){c.classList.remove('flash')},1400);
  return true;
}

function render(){
  if(!F||DONE) return;
  var ae=document.activeElement, fk=(ae&&ae.getAttribute)?ae.getAttribute('data-f'):null, s0=null, s1=null;
  if(fk){ try{ s0=ae.selectionStart; s1=ae.selectionEnd }catch(e){} }
  var m=document.getElementById('qs'); m.innerHTML='';
  var req={}; (F.requested||[]).forEach(function(k){req[k]=1});
  var rendered=0;
  ((F.form||{}).sections||[]).forEach(function(s){
    var qs=(s.questions||[]).filter(function(q){return req[q.key]&&visible(q)});
    if(!qs.length) return;
    var sec=el('section','sec'), hd=el('div','sech');
    hd.appendChild(el('h2','',s.title));
    var sc=el('span'); sc.setAttribute('data-sc',String(s.id||s.title)); hd.appendChild(sc); sec.appendChild(hd);
    qs.forEach(function(q){ rendered++; sec.appendChild(field(q)) });
    m.appendChild(sec);
  });
  if(!rendered) m.innerHTML='<div class="big"><h2>Nothing to collect</h2><p>This form has no questions on it. Tell the office.</p></div>';
  counts();
  if(fk){
    var n=byAttr('data-f',fk);
    // At a limit the same control can be gone or disabled (- at 0, + at the maximum, "Every day" once all
    // seven are ticked): keep the keyboard in the same question instead of dropping it to the page, and
    // prefer a button (focusing the number box would open the phone keyboard).
    if(!n||n.disabled){ var qk=fk.split(/[:=]/)[0], card=byAttr('data-q',qk); n=null;
      if(card){ var cs=card.querySelectorAll('[data-f]'); for(var pass=0;pass<2&&!n;pass++){ for(var ci=0;ci<cs.length;ci++){ if(!cs[ci].disabled&&(pass||cs[ci].tagName==='BUTTON')){ n=cs[ci]; break } } } } }
    if(n){ try{ n.focus({preventScroll:true}); if(s0!=null&&n.setSelectionRange&&n.getAttribute('data-f')===fk) n.setSelectionRange(s0,s1) }catch(e){} }
  }
}
function isAns(q){var v=A[q.key];if(v==null)return false;if(q.type==='weekly_hours'){if(typeof v!=='object'||Array.isArray(v))return false;var ks=Object.keys(v);return ks.length>0&&ks.every(function(d){var w=v[d]||{};return HHMM.test(w.open||'')&&HHMM.test(w.close||'')})}if(typeof v==='string')return v.trim()!=='';if(Array.isArray(v))return v.length>0;if(typeof v==='object')return Object.keys(v).length>0;return true}

// A satellite map per pin question (Fred, 2026-09-25: "a pin that we can move, like the Picture Planner
// has"). Loaded only when a pin question is on screen AND the load reply carries a key; with no key, a
// refused key or no signal the question keeps just "Use my location". render() rebuilds the list on every
// answer, so each map is built once and its node moved into the new card (a new map would refetch tiles
// and lose the zoom). Measured 2026-09-25: Maps sends Google the page origin and path, never the fragment,
// so the #code stays on the phone.
var MAPS={}, GM=0;                               // GM: 0 not loaded, 1 loading, 2 ready, -1 unavailable
function gmLoad(){
  if(GM) return; GM=1;
  var fail=function(){ GM=-1; afterPress(render) };
  window.gm_authFailure=fail;                    // Google calls this when the key is refused
  window.gmReady=function(){ GM=2; afterPress(render) };
  var s=document.createElement('script'); s.async=true; s.onerror=fail;
  s.src='https://maps.googleapis.com/maps/api/js?key='+encodeURIComponent(F.maps_key)+'&callback=gmReady&v=weekly&loading=async';
  document.head.appendChild(s);
}
function pinIcon(k){
  var gt=/gt_location$/.test(k), c=gt?'#dc2626':'#f14714', t=gt?'GT':'T';
  var svg='<svg xmlns="http://www.w3.org/2000/svg" width="40" height="52" viewBox="0 0 40 52"><path d="M20 50S37 30 37 19a17 17 0 0 0-34 0c0 11 17 31 17 31z" fill="'+c+'" stroke="#fff" stroke-width="3"/><text x="20" y="24" font-family="Arial,sans-serif" font-size="'+(gt?13:17)+'" font-weight="800" fill="#fff" text-anchor="middle">'+t+'</text></svg>';
  return {url:'data:image/svg+xml;charset=UTF-8,'+encodeURIComponent(svg),scaledSize:new google.maps.Size(40,52),anchor:new google.maps.Point(20,50)};
}
function mapFor(q,v){
  if(!F||!F.maps_key||GM<0) return null;
  if(GM!==2){ gmLoad(); return el('div','map wait','Loading the map...') }
  var p=F.property||{}, home=(p.lat!=null&&p.lng!=null)?{lat:Number(p.lat),lng:Number(p.lng)}:null;
  var pos=(v&&v.lat!=null)?{lat:Number(v.lat),lng:Number(v.lng)}:null, at=pos?pos.lat+','+pos.lng:'';
  var M=MAPS[q.key];
  if(!M){
    var box=el('div','map'); box.setAttribute('aria-label',q.label+': map. Tap where it is to drop the pin.');
    var map=new google.maps.Map(box,{center:pos||home||{lat:25.77,lng:-80.19},zoom:pos?20:(home?19:11),mapTypeId:'hybrid',tilt:0,
      gestureHandling:'cooperative',clickableIcons:false,disableDefaultUI:true,zoomControl:true,fullscreenControl:true});
    // ponytail: google.maps.Marker is deprecated (still supported); AdvancedMarkerElement needs a map id.
    var mk=new google.maps.Marker({map:pos?map:null,position:pos,draggable:true,icon:pinIcon(q.key),title:q.label});
    var put=function(ll){
      if(DONE) return;
      A[q.key]={lat:Number(ll.lat().toFixed(6)),lng:Number(ll.lng().toFixed(6))};   // placed by hand: no GPS accuracy
      M.at=A[q.key].lat+','+A[q.key].lng; delete GEO[q.key]; save(); afterPress(render);
    };
    map.addListener('click',function(e){ if(e.latLng){ mk.setPosition(e.latLng); mk.setMap(map); put(e.latLng) } });
    mk.addListener('dragend',function(e){ if(e.latLng) put(e.latLng) });
    M=MAPS[q.key]={box:box,map:map,mk:mk,at:at};
  }
  // A pin set another way (Use my location, a restored draft) moves the marker and brings it into view.
  if(at!==M.at){ M.at=at; if(pos){ M.mk.setPosition(pos); M.mk.setMap(M.map); M.map.panTo(pos); if(M.map.getZoom()<19) M.map.setZoom(20) } else M.mk.setMap(null) }
  return M.box;
}

var NID=0;
function toggle(q,value,text,cls,cur){
  var b=el('button','opt'+(cls?' '+cls:'')); b.type='button'; b.setAttribute('data-f',q.key+'='+value);
  var on=cur===value; b.setAttribute('aria-pressed',on?'true':'false');
  var dot=el('span','dot'); dot.setAttribute('aria-hidden','true'); if(on) dot.innerHTML=IC.check;
  b.appendChild(dot); b.appendChild(el('span','',text));
  b.onclick=function(){ if(A[q.key]!==value) setA(q.key,value) };
  return b;
}
function hint(w){ if(!w||!HHMM.test(w.open||'')||!HHMM.test(w.close||'')) return ''; return w.open===w.close?'Any time':(w.close<w.open?'Overnight, closes '+hrs12(w.close)+' the next day':'') }
function hrs12(t){var h=Number(t.slice(0,2)),mi=t.slice(3);return (h%12||12)+':'+mi+' '+(h<12?'AM':'PM')}

function field(q){
  var d=el('div','q'), id='f'+(++NID); d.setAttribute('data-q',q.key);
  var lab=el('label'); lab.id=id+'l'; lab.textContent=q.label;
  if(q.optional){ lab.appendChild(document.createTextNode(' ')); lab.appendChild(el('span','tag','(optional)')) }
  d.appendChild(lab);
  var t=q.type, v=A[q.key];
  if(ERR[q.key]) d.appendChild(errBox(ERR[q.key],function(){delete ERR[q.key];render()}));
  if(t==='yes_no'){
    var w=el('div','yn'); w.setAttribute('role','group'); w.setAttribute('aria-labelledby',lab.id);
    w.appendChild(toggle(q,'yes','Yes','',v)); w.appendChild(toggle(q,'no','No','',v));
    d.appendChild(w);
  } else if(t==='choice'){
    var w2=el('div','opts'); w2.setAttribute('role','group'); w2.setAttribute('aria-labelledby',lab.id);
    (q.options||[]).forEach(function(o){ w2.appendChild(toggle(q,o,o,'',v)) });
    d.appendChild(w2);
  } else if(t==='number'){
    var mn=typeof q.min==='number'?q.min:0, mx=typeof q.max==='number'?q.max:null;
    var n=el('input'); n.type='number'; n.id=id; lab.htmlFor=id; n.inputMode='numeric'; n.step='1'; n.min=String(mn); if(mx!=null) n.max=String(mx);
    n.setAttribute('data-f',q.key); n.value=(v==null?'':v); n.addEventListener('wheel',function(){ if(document.activeElement===n) n.blur() },{passive:true});
    if(mx==null||mx<=100){
      // Small counts get - and + buttons: no keyboard needed on a phone. From empty, - answers the
      // lowest value (0: none) and + answers one.
      var st=el('div','step'); st.setAttribute('role','group'); st.setAttribute('aria-labelledby',lab.id);
      var minus=el('button','','−'); minus.type='button'; minus.setAttribute('aria-label','One less'); minus.setAttribute('data-f',q.key+':-');
      var plus=el('button','','+'); plus.type='button'; plus.setAttribute('aria-label','One more'); plus.setAttribute('data-f',q.key+':+');
      var num=function(){ return (n.value===''||isNaN(Number(n.value)))?null:Number(n.value) };
      var sync=function(){ var c0=num(); minus.setAttribute('aria-disabled',(c0!=null&&c0<=mn)?'true':'false'); plus.setAttribute('aria-disabled',(mx!=null&&c0!=null&&c0>=mx)?'true':'false') };
      minus.onclick=function(){ var c0=num(); if(c0==null) setA(q.key,mn); else if(c0>mn) setA(q.key,c0-1) };
      plus.onclick=function(){ var c0=num(), nx=(c0==null)?Math.max(mn,1):c0+1; if(mx==null||nx<=mx) setA(q.key,nx) };
      n.onchange=function(){ typed(q.key,n.value===''?'':Number(n.value)); sync() };
      sync();
      st.appendChild(minus); st.appendChild(n); st.appendChild(plus); d.appendChild(st);
    } else {
      n.onchange=function(){ typed(q.key,n.value===''?'':Number(n.value)) };
      d.appendChild(n);
    }
  } else if(t==='text'&&q.single_line){
    var x1=el('input'); x1.type='text'; x1.autocomplete='off'; x1.setAttribute('enterkeyhint','next'); x1.id=id; lab.htmlFor=id; x1.setAttribute('data-f',q.key); x1.value=(v==null?'':v); if(typeof q.max_chars==='number') x1.maxLength=q.max_chars;
    x1.oninput=function(){A[q.key]=x1.value;save();counts()}; x1.onblur=function(){typed(q.key,x1.value)}; d.appendChild(x1);
  } else if(t==='text'){
    var x=el('textarea'); x.id=id; lab.htmlFor=id; x.setAttribute('data-f',q.key); x.maxLength=4000; x.value=(v==null?'':v);
    x.oninput=function(){A[q.key]=x.value;save();counts()}; x.onblur=function(){typed(q.key,x.value)}; d.appendChild(x);
  } else if(t==='weekly_hours'){
    var cur2=(v&&typeof v==='object'&&!Array.isArray(v))?v:{};
    // A newly ticked day copies the hours of the first day already ticked, so Mon to Fri is five taps.
    var tpl=function(){ for(var i=0;i<DAYS.length;i++){ var w0=cur2[DAYS[i]]; if(w0) return {open:w0.open,close:w0.close} } return {open:'08:00',close:'17:00'} };
    var commit=function(){ setA(q.key, Object.keys(cur2).length?cur2:'') };
    var dz=el('div','days'); dz.setAttribute('role','group'); dz.setAttribute('aria-labelledby',lab.id);
    DAYS.forEach(function(day){
      var b=el('button','day',DAYN[day]); b.type='button'; b.setAttribute('data-f',q.key+':'+day);
      b.setAttribute('aria-pressed',cur2[day]?'true':'false');
      b.onclick=function(){ if(cur2[day]) delete cur2[day]; else cur2[day]=tpl(); commit() };
      dz.appendChild(b);
    });
    d.appendChild(dz);
    var on=DAYS.filter(function(day){return !!cur2[day]});
    if(on.length){
      var hl=el('div','hl'), hh=el('div','hh'); hh.setAttribute('aria-hidden','true');
      hh.appendChild(el('span','','Day')); hh.appendChild(el('span','','Opens')); hh.appendChild(el('span')); hh.appendChild(el('span','','Closes'));
      hl.appendChild(hh);
      on.forEach(function(day){
        var row=el('div','hr'), w1=cur2[day];
        row.appendChild(el('span','dn',DAYN[day]));
        var o=el('input'); o.type='time'; o.value=w1.open||''; o.setAttribute('aria-label',DAYN[day]+' opens'); o.setAttribute('data-f',q.key+':'+day+':o');
        var c=el('input'); c.type='time'; c.value=w1.close||''; c.setAttribute('aria-label',DAYN[day]+' closes'); c.setAttribute('data-f',q.key+':'+day+':c');
        var rh=el('span','rh');
        // A time edit saves in place: rebuilding on every segment put the caret back on the hour and
        // turned a typed 09:30 into 00:00. Only the hint under the row changes.
        o.onchange=c.onchange=function(){ if(!cur2[day]) return; cur2[day]={open:o.value,close:c.value}; A[q.key]=cur2; save(); counts(); rh.textContent=hint(cur2[day]) };
        row.appendChild(o); row.appendChild(el('span','to','to')); row.appendChild(c);
        rh.textContent=hint(w1); row.appendChild(rh);
        hl.appendChild(row);
      });
      d.appendChild(hl);
    }
    var ch=el('div','chips');
    var all=el('button','chip','Every day'); all.type='button'; all.setAttribute('data-f',q.key+':all');
    all.onclick=function(){ var t0=tpl(); DAYS.forEach(function(day){ if(!cur2[day]) cur2[day]={open:t0.open,close:t0.close} }); commit() };
    var any=el('button','chip','Open 24 hours'); any.type='button'; any.setAttribute('data-f',q.key+':any');
    any.onclick=function(){ var ds=on.length?on:DAYS; ds.forEach(function(day){ cur2[day]={open:'00:00',close:'00:00'} }); commit() };
    if(on.length<7) ch.appendChild(all);
    ch.appendChild(any); d.appendChild(ch);
    d.appendChild(el('div','note','Tap the days we can come, then set the times. A closing time earlier than the opening time means overnight.'));
  } else if(t==='gps_pin'){
    var pinned=v&&v.lat!=null, G=GEO[q.key]||{};
    if(G.err) d.appendChild(errBox(G.err,function(){ delete GEO[q.key].err; render() }));
    var mw=mapFor(q,v); if(mw) d.appendChild(mw);
    var b3=el('button','act'); b3.type='button'; b3.setAttribute('data-f',q.key+':gps'); b3.setAttribute('aria-describedby',lab.id); b3.innerHTML=IC.pin;
    b3.appendChild(el('span','',G.busy?'Finding your spot...':(pinned?'Use my location again':'Use my location'))); b3.disabled=!!G.busy;
    var out=el('div','pin'+(pinned&&!G.busy?' set':'')); out.setAttribute('role','status');
    out.textContent=G.busy?'Finding your spot...':(pinned?('Pinned at '+Number(v.lat).toFixed(6)+', '+Number(v.lng).toFixed(6)):(mw?'Tap the map where it is, then drag the pin to the exact spot. Or stand next to it and use your location.':'Stand next to it, then tap.'));
    var gst=el('div','gst');
    gst.textContent=G.busy?(G.acc!=null?'Accurate to about '+G.acc+' m so far.':''):((pinned&&v.accuracy_m)?'Accurate to about '+v.accuracy_m+' m.':'');
    // The first fix outdoors is often a rough cell or Wi-Fi position. Listen for up to 20 seconds, keep
    // the most precise fix, and stop early once it is within 15 m. The state lives in GEO, so a redraw
    // (a photo finishing, another answer) keeps "Finding your spot..." and any error on screen.
    b3.onclick=function(){
      if(!navigator.geolocation){ GEO[q.key]={err:'This phone or browser will not share a location.'}; render(); return }
      var st={busy:true,acc:null}, best=null, done=false, wid=null, tm=null; GEO[q.key]=st;
      var stop=function(){ done=true; if(wid!=null) navigator.geolocation.clearWatch(wid); clearTimeout(tm); st.busy=false };
      var finish=function(){
        if(done) return; stop();
        if(DONE) return;
        if(best){ delete GEO[q.key]; A[q.key]={lat:best.latitude,lng:best.longitude,accuracy_m:Math.round(best.accuracy||0)}; save(); afterPress(render) }
        else { st.err='Could not find this spot. Step outside if you can, then tap again.'; afterPress(render) }
      };
      wid=navigator.geolocation.watchPosition(function(p){
        if(done) return;
        if(!best||p.coords.accuracy<best.accuracy) best={latitude:p.coords.latitude,longitude:p.coords.longitude,accuracy:p.coords.accuracy};
        st.acc=Math.round(best.accuracy); afterPress(render);
        if(best.accuracy<=15) finish();
      },function(e){
        if(done||best) return; stop(); if(DONE) return;
        st.err=(e&&e.code===1)?'This page is not allowed to use your location. Allow location for this page in your browser or phone settings, then tap again.':'Could not find this spot. Step outside if you can, then tap again.';
        afterPress(render);
      },{enableHighAccuracy:true,maximumAge:0,timeout:20000});
      tm=setTimeout(finish,20000);
      render();
    };
    d.appendChild(b3); d.appendChild(out); d.appendChild(gst);
  } else if(t==='photos'){
    var list=Array.isArray(v)?v:[];
    var f=el('input'); f.type='file'; f.accept='image/*'; f.multiple=true; f.className='hide'; f.setAttribute('aria-hidden','true'); f.tabIndex=-1;
    f.onchange=function(){ var fs=[].slice.call(f.files||[]); f.value=''; fs.forEach(function(file){up(q.key,file)}) };
    var fb=el('button','act'); fb.type='button'; fb.setAttribute('data-f',q.key+':ph'); fb.setAttribute('aria-describedby',lab.id); fb.innerHTML=IC.cam; fb.appendChild(el('span','',list.length?'Add more photos':'Take or add photos')); fb.onclick=function(){f.click()};
    d.appendChild(fb); d.appendChild(f);
    var pend=PEND[q.key]||0;
    if(list.length||pend){
      var g=el('div','ph');
      for(var k=0;k<pend;k++) g.appendChild(el('div','t send','Sending...'));
      list.forEach(function(p,i){
        var tl=el('div','t');
        // The preview is a blob: URL that dies when the page reloads; the photo itself is safe on the
        // server. Show a plain "Photo N saved" tile instead of a broken image.
        var gone=function(){ tl.innerHTML=''; tl.textContent='Photo '+(i+1)+' saved'; if(p&&p.preview){ delete p.preview; save() } };
        if(p&&p.preview){ var im=el('img'); im.alt='Photo '+(i+1); im.onerror=gone; im.src=p.preview; tl.appendChild(im) } else gone();
        g.appendChild(tl);
      });
      d.appendChild(g);
    }
    d.appendChild(el('div','note'+(list.length?' ok':''),list.length?(list.length+' photo'+(list.length>1?'s':'')+' attached'):'No photos yet.'));
  }
  return d;
}

// Upload is three hops: ask for a signed URL, PUT the bytes, then tell the server to
// link it. Only a path the server issued is ever stored in the answer.
function plain(m){ var e=new Error(m); e.plain=true; return e }
function up(key,file){
  busy++; PEND[key]=(PEND[key]||0)+1;
  var fm=document.getElementById('fmsg'); if(CF&&fm){ fm.innerHTML=''; CF=null }
  render();
  api({op:'upload',content_type:file.type||'image/jpeg'}).then(function(r){
    if(!r.ok) throw plain(r.message||'The photo was not accepted. Try again.');
    return fetch(r.signed_url,{method:'PUT',headers:{'Content-Type':file.type||'image/jpeg'},body:file}).then(function(p){
      if(!p.ok) throw plain('The photo did not upload. Try again.');
      return api({op:'attach',path:r.path,role:key,content_type:file.type||'image/jpeg'}).then(function(a){
        if(!a.ok) throw plain(a.message||'Could not attach the photo. Try again.');
        var cur=Array.isArray(A[key])?A[key]:[];
        cur.push({path:r.path,preview:URL.createObjectURL(file)});
        A[key]=cur; delete ERR[key]; save();
      });
    });
  }).catch(function(e){ ERR[key]=(e&&e.plain&&e.message)?e.message:'The photo did not upload. Check your signal and try again.' })
    .then(function(){ busy--; PEND[key]=Math.max(0,(PEND[key]||0)-1); afterPress(render) });
}

function submit(sure){
  var wEl=document.getElementById('who'), who=(wEl.value||'').trim(), we=document.getElementById('whoerr');
  if(!who){
    we.innerHTML=''; we.appendChild(errBox('Put your name so the office knows who collected this.',function(){we.innerHTML=''}));
    glide(wEl); wEl.setAttribute('aria-invalid','true'); wEl.focus({preventScroll:true}); return
  }
  we.innerHTML='';
  var fm=document.getElementById('fmsg'); fm.innerHTML=''; CF=null;
  if(busy>0||geoBusy()){ var wb=show(waitText(geoBusy())); WAIT=wb&&wb.querySelector('span'); return }
  if(LEFT>0&&!sure){
    var box=el('div','cf'); box.setAttribute('role','alert');
    CF=el('div','',cfText()); box.appendChild(CF);
    var row=el('div','row'), keep=el('button','no','Keep answering'), go=el('button','go','Submit anyway');
    keep.type='button'; go.type='button';
    keep.onclick=function(){ fm.innerHTML=''; CF=null; goBlank() };
    go.onclick=function(){ fm.innerHTML=''; CF=null; submit(true) };
    row.appendChild(keep); row.appendChild(go); box.appendChild(row); fm.appendChild(box);
    try{ box.scrollIntoView({block:'nearest'}) }catch(e){}
    return
  }
  // Send only answers to questions the collector can SEE now. A follow-up keeps what was typed into it
  // when its parent changes (a lock-box code typed, then "How do we get in?" switched to Key); that
  // leftover must not reach the immutable record. The office compare and accept refuse it too.
  var out={}, req={};
  (F.requested||[]).forEach(function(k){req[k]=1});
  ((F.form||{}).sections||[]).forEach(function(s){ (s.questions||[]).forEach(function(q){
    if(!q||typeof q!=='object'||!req[q.key]||!visible(q)||!(q.key in A)) return;
    var v=A[q.key];
    out[q.key]=Array.isArray(v)?v.map(function(p){return (p&&p.path)?p.path:p}):v;
  }) });
  var b=document.getElementById('send'); SENDING=true; b.disabled=true; b.textContent='Submitting...';
  api({op:'submit',collector:who,answers:out}).then(function(r){
    if(!r.ok){ SENDING=false; b.disabled=false; b.textContent='Submit'; show(r.message||'Could not submit.'); return }
    try{localStorage.removeItem(KEY);localStorage.removeItem(KEY+'-who');localStorage.removeItem(KEY+'-form')}catch(e){}
    DONE=true;
    document.getElementById('foot').className='hide';
    document.getElementById('main').innerHTML='<div class="big"><div class="ic">'+IC.big+'</div><h2 tabindex="-1">Thank you</h2><p>'+
      (r.status==='Complete'?'Everything the office asked for is in.':'Sent. The office can see what is still missing.')+
      '</p><p class="note">You can close this page.</p></div>';
    window.scrollTo(0,0); try{document.querySelector('.big h2').focus()}catch(e){}
  }).catch(function(){ SENDING=false; b.disabled=false; b.textContent='Submit'; show('No connection. Your answers are saved on this device, try again in a moment.') });
}

load();
// A copy of the questions is kept on the phone (a separate key: the draft key and its shape are
// unchanged), so reloading in a dead zone still shows the form instead of "No connection".
function start(r,offline){
  F=r;
  var p=r.property||{};
  document.getElementById('ttl').textContent=p.address||'Site survey';
  document.getElementById('sub').textContent=[p.name,p.city].filter(Boolean).join(' - ')||'Site survey';
  if(r.already_submitted){ DONE=true; document.getElementById('main').innerHTML='<div class="big"><div class="ic">'+IC.big+'</div><h2>Already submitted</h2><p>This form was sent in. Ask the office if something needs changing.</p></div>'; return }
  var wEl=document.getElementById('who');
  try{ wEl.value=localStorage.getItem(KEY+'-who')||'' }catch(e){}
  wEl.oninput=function(){ try{localStorage.setItem(KEY+'-who',wEl.value)}catch(e){} if(wEl.value.trim()){ document.getElementById('whoerr').innerHTML=''; wEl.removeAttribute('aria-invalid') } };
  if(offline){ var o=el('div','off','No signal right now. Keep answering: your answers stay on this device. Submit when you have signal.'); o.setAttribute('role','status'); document.getElementById('pre').prepend(o) }
  document.getElementById('pre').className='';
  document.getElementById('foot').className='';
  var ft=document.getElementById('foot'), fh=function(){ document.documentElement.style.setProperty('--fh',(getComputedStyle(ft).position==='sticky'?ft.offsetHeight:0)+'px') };
  fh(); try{ new ResizeObserver(fh).observe(ft) }catch(e){} window.addEventListener('resize',fh);
  document.addEventListener('focusin',function(e){
    var t=e.target; if(PRESS||!t||ft.contains(t)||getComputedStyle(ft).position!=='sticky') return;   // never mid-tap: moving the page loses the click
    var r=t.getBoundingClientRect(), top=ft.getBoundingClientRect().top-12;
    if(r.bottom>top) window.scrollBy(0,Math.min(r.bottom-top,Math.max(0,r.top-12)));
  });
  document.getElementById('send').onclick=function(){ submit(false) };
  document.getElementById('prog').onclick=function(){ goBlank() };
  render();
}
api({op:'load'}).then(function(r){
  if(!r.ok){ try{localStorage.removeItem(KEY+'-form')}catch(e){} document.getElementById('sub').textContent=''; document.getElementById('main').innerHTML='<div class="big"><h2>'+esc(r.message)+'</h2></div>'; return }
  try{ localStorage.setItem(KEY+'-form',JSON.stringify(r)) }catch(e){}
  start(r,false);
}).catch(function(){
  var c=null; try{ c=JSON.parse(localStorage.getItem(KEY+'-form')||'null') }catch(e){}
  if(c&&c.ok&&c.form&&!(c.expires_at&&new Date(c.expires_at)<new Date())){ start(c,true); return }
  document.getElementById('main').innerHTML='<div class="big"><h2>No connection</h2><p>Check your signal and reload.</p></div>';
});
</script></body></html>`
