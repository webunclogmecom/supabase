// ============================================================================
// form-page.ts — the collector form, step 4.2 of the build plan
// ============================================================================
// Served as HTML from GET on intake-submit itself. That choice is the whole reason
// the Client App's "Create link" already emits
// `<supabase url>/functions/v1/intake-submit?t=<token>`: no new origin, no DNS, no
// entry in audit.log_change's Origin CASE, and no second deploy target. The page
// talks to the same URL it was served from, so it cannot point at the wrong project.
//
// NO BUILD STEP, NO FRAMEWORK, NO CDN. One string. A driver opens this in a parking
// lot on a phone that may be on one bar; every byte here is the whole download.
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
// ============================================================================

export const FORM_HTML = String.raw`<!doctype html>
<html lang="en"><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Site survey</title>
<style>
:root{--bg:#f6f6f7;--card:#fff;--ink:#18181b;--mut:#6b7280;--line:#e4e4e7;--red:#ea3a24}
*{box-sizing:border-box;-webkit-tap-highlight-color:transparent}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,sans-serif;padding-bottom:104px}
header{background:var(--ink);color:#fff;padding:16px 16px 14px}
header h1{margin:0;font-size:17px}header p{margin:4px 0 0;font-size:13px;opacity:.75}
main{padding:12px 12px 0;max-width:620px;margin:0 auto}
.sec{margin:14px 0 0}
.sec>h2{font-size:12px;letter-spacing:.08em;text-transform:uppercase;color:var(--mut);margin:0 0 8px 2px}
.q{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:13px;margin-bottom:9px}
.q>label{display:block;font-weight:600;font-size:15px;margin-bottom:9px}
input[type=text],input[type=number],textarea,select{width:100%;font:inherit;padding:12px;border:1px solid var(--line);border-radius:9px;background:#fff;color:var(--ink)}
textarea{min-height:76px;resize:vertical}
.yn{display:flex;gap:9px}
.yn button{flex:1;padding:14px;font:inherit;font-weight:600;border:1.5px solid var(--line);border-radius:9px;background:#fff;color:var(--ink)}
.yn button[aria-pressed=true]{border-color:var(--ink);background:var(--ink);color:#fff}
.opts{display:flex;flex-direction:column;gap:7px}
.opts button{text-align:left;padding:13px;font:inherit;border:1.5px solid var(--line);border-radius:9px;background:#fff;color:var(--ink)}
.opts button[aria-pressed=true]{border-color:var(--ink);background:var(--ink);color:#fff}
.hrs{display:flex;align-items:center;gap:7px;margin-bottom:7px}
.hrs .d{width:42px;font-size:13px;font-weight:600;text-transform:capitalize}
.hrs input[type=time]{flex:1;font:inherit;padding:9px;border:1px solid var(--line);border-radius:8px;min-width:0}
.hrs input[type=checkbox]{width:22px;height:22px;flex:none}
.ph{display:flex;flex-wrap:wrap;gap:7px;margin-top:9px}
.ph img{width:64px;height:64px;object-fit:cover;border-radius:8px;border:1px solid var(--line)}
.btn{display:block;width:100%;padding:14px;font:inherit;font-weight:600;border-radius:9px;border:1.5px solid var(--line);background:#fff;color:var(--ink)}
.pin{font-size:13px;color:var(--mut);margin-top:8px}
footer{position:fixed;left:0;right:0;bottom:0;background:var(--card);border-top:1px solid var(--line);padding:11px 12px calc(11px + env(safe-area-inset-bottom))}
footer .in{max-width:620px;margin:0 auto}
#send{width:100%;padding:16px;font:inherit;font-size:17px;font-weight:700;border:0;border-radius:11px;background:var(--red);color:#fff;margin-top:9px}
#send:disabled{opacity:.5}
.note{font-size:13px;color:var(--mut);margin:6px 2px 0}
.err{background:#fef2f2;border:1px solid #fecaca;color:#991b1b;border-radius:10px;padding:12px;margin:10px 0;font-size:14px}
.big{text-align:center;padding:48px 20px}.big h2{margin:0 0 8px}
.hide{display:none}
</style></head>
<body>
<header><h1 id="ttl">Site survey</h1><p id="sub">Loading...</p></header>
<main id="main"></main>
<footer id="foot" class="hide"><div class="in">
  <input type="text" id="who" placeholder="Your name" autocomplete="name">
  <div class="note" id="cnt"></div>
  <button id="send">Submit</button>
</div></footer>
<script>
var EP=location.pathname, TOKEN=new URLSearchParams(location.search).get('t')||'';
var F=null, A={}, DAYS=['mon','tue','wed','thu','fri','sat','sun'], busy=0;
var KEY='intake-draft-'+TOKEN;
function api(b){b.token=TOKEN;return fetch(EP,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(b)}).then(function(r){return r.json().then(function(j){j._s=r.status;return j})})}
function esc(s){return String(s==null?'':s).replace(/[&<>"]/g,function(c){return{'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]})}
function save(){try{localStorage.setItem(KEY,JSON.stringify(A))}catch(e){}}
function load(){try{var v=localStorage.getItem(KEY);if(v)A=JSON.parse(v)||{}}catch(e){A={}}}
function show(m){var d=document.createElement('div');d.className='err';d.textContent=m;document.getElementById('main').prepend(d);try{d.scrollIntoView({behavior:'smooth',block:'center'})}catch(e){}}

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

function render(){
  if(!F) return;
  var m=document.getElementById('main'); m.innerHTML='';
  var req={}; (F.requested||[]).forEach(function(k){req[k]=1});
  // `shown` counts the questions that decide Complete: visible and not optional, the same set
  // public.fn_intake_missing counts. An optional question is still rendered and still sent.
  var rendered=0, shown=0, answered=0;
  ((F.form||{}).sections||[]).forEach(function(s){
    var qs=(s.questions||[]).filter(function(q){return req[q.key]&&visible(q)});
    if(!qs.length) return;
    var sec=document.createElement('div'); sec.className='sec';
    var h=document.createElement('h2'); h.textContent=s.title; sec.appendChild(h);
    qs.forEach(function(q){ rendered++; if(!q.optional){ shown++; if(isAns(q)) answered++; } sec.appendChild(field(q)) });
    m.appendChild(sec);
  });
  if(!rendered) m.innerHTML='<div class="big"><h2>Nothing to collect</h2><p>This form has no questions on it. Tell the office.</p></div>';
  document.getElementById('cnt').textContent=answered+' of '+shown+' answered'+(busy?' - uploading '+busy+'...':'');
  document.getElementById('send').disabled=busy>0;
}
function isAns(q){var v=A[q.key];if(v==null)return false;if(q.type==='weekly_hours'){if(typeof v!=='object'||Array.isArray(v))return false;var ks=Object.keys(v);return ks.length>0&&ks.every(function(d){var w=v[d]||{};return HHMM.test(w.open||'')&&HHMM.test(w.close||'')})}if(typeof v==='string')return v.trim()!=='';if(Array.isArray(v))return v.length>0;if(typeof v==='object')return Object.keys(v).length>0;return true}

function field(q){
  var d=document.createElement('div'); d.className='q';
  var lab=document.createElement('label'); lab.textContent=q.label+(q.optional?' (optional)':''); d.appendChild(lab);
  var t=q.type, v=A[q.key];
  if(t==='yes_no'){
    var w=document.createElement('div'); w.className='yn';
    ['yes','no'].forEach(function(o){
      var b=document.createElement('button'); b.type='button'; b.textContent=(o==='yes'?'Yes':'No');
      b.setAttribute('aria-pressed', v===o?'true':'false');
      b.onclick=function(){setA(q.key, v===o?'':o)}; w.appendChild(b);
    }); d.appendChild(w);
  } else if(t==='choice'){
    var w2=document.createElement('div'); w2.className='opts';
    (q.options||[]).forEach(function(o){
      var b=document.createElement('button'); b.type='button'; b.textContent=o;
      b.setAttribute('aria-pressed', v===o?'true':'false');
      b.onclick=function(){setA(q.key, v===o?'':o)}; w2.appendChild(b);
    }); d.appendChild(w2);
  } else if(t==='number'){
    var n=document.createElement('input'); n.type='number'; n.inputMode='numeric'; n.step='1'; n.min=String(typeof q.min==='number'?q.min:0); if(typeof q.max==='number') n.max=String(q.max);
    n.value=(v==null?'':v); n.onchange=function(){setA(q.key, n.value===''?'':Number(n.value))}; d.appendChild(n);
  } else if(t==='text'&&q.single_line){
    var x1=document.createElement('input'); x1.type='text'; x1.value=(v==null?'':v); if(typeof q.max_chars==='number') x1.maxLength=q.max_chars;
    x1.oninput=function(){A[q.key]=x1.value;save()}; x1.onblur=function(){setA(q.key,x1.value)}; d.appendChild(x1);
  } else if(t==='text'){
    var x=document.createElement('textarea'); x.maxLength=4000; x.value=(v==null?'':v);
    x.oninput=function(){A[q.key]=x.value;save()}; x.onblur=function(){setA(q.key,x.value)}; d.appendChild(x);
  } else if(t==='weekly_hours'){
    var cur=(v&&typeof v==='object'&&!Array.isArray(v))?v:{};
    DAYS.forEach(function(day){
      var row=document.createElement('div'); row.className='hrs';
      var on=!!cur[day];
      var cb=document.createElement('input'); cb.type='checkbox'; cb.checked=on;
      var nm=document.createElement('span'); nm.className='d'; nm.textContent=day;
      var o=document.createElement('input'); o.type='time'; o.value=on?(cur[day].open||''):''; o.disabled=!on;
      var c=document.createElement('input'); c.type='time'; c.value=on?(cur[day].close||''):''; c.disabled=!on;
      cb.onchange=function(){ if(cb.checked){cur[day]={open:o.value||'08:00',close:c.value||'17:00'}} else {delete cur[day]} setA(q.key, Object.keys(cur).length?cur:'') };
      o.onchange=c.onchange=function(){ if(cur[day]){cur[day]={open:o.value,close:c.value}; setA(q.key,cur)} };
      row.appendChild(cb); row.appendChild(nm); row.appendChild(o); row.appendChild(c); d.appendChild(row);
    });
    var hn=document.createElement('div'); hn.className='note';
    hn.textContent='Tick a day, then set when we can come. For any time, use 00:00 to 00:00. A close time earlier than the open time means overnight.';
    d.appendChild(hn);
  } else if(t==='gps_pin'){
    var b3=document.createElement('button'); b3.type='button'; b3.className='btn'; b3.textContent='Use my location';
    var out=document.createElement('div'); out.className='pin';
    out.textContent=(v&&v.lat!=null)?('Pinned at '+Number(v.lat).toFixed(6)+', '+Number(v.lng).toFixed(6)):'Stand next to it, then tap.';
    b3.onclick=function(){
      if(!navigator.geolocation){out.textContent='This phone will not share a location.';return}
      out.textContent='Getting location...';
      navigator.geolocation.getCurrentPosition(function(p){
        setA(q.key,{lat:p.coords.latitude,lng:p.coords.longitude,accuracy_m:Math.round(p.coords.accuracy||0)});
      },function(){out.textContent='Could not get a location. Check location permission.'},{enableHighAccuracy:true,timeout:15000});
    };
    d.appendChild(b3); d.appendChild(out);
  } else if(t==='photos'){
    var list=Array.isArray(v)?v:[];
    var f=document.createElement('input'); f.type='file'; f.accept='image/*'; f.setAttribute('capture','environment'); f.multiple=true; f.className='btn';
    f.onchange=function(){ var fs=[].slice.call(f.files||[]); f.value=''; fs.forEach(function(file){up(q.key,file)}) };
    d.appendChild(f);
    var g=document.createElement('div'); g.className='ph';
    list.forEach(function(p){ var im=document.createElement('img'); im.alt=''; if(p&&p.preview)im.src=p.preview; g.appendChild(im) });
    d.appendChild(g);
    var c2=document.createElement('div'); c2.className='note';
    c2.textContent=list.length?(list.length+' photo'+(list.length>1?'s':'')+' attached'):'No photos yet.';
    d.appendChild(c2);
  }
  return d;
}

// Upload is three hops: ask for a signed URL, PUT the bytes, then tell the server to
// link it. Only a path the server issued is ever stored in the answer.
function up(key,file){
  busy++; render();
  api({op:'upload',content_type:file.type||'image/jpeg'}).then(function(r){
    if(!r.ok) throw new Error(r.message||'Upload refused.');
    return fetch(r.signed_url,{method:'PUT',headers:{'Content-Type':file.type||'image/jpeg'},body:file}).then(function(p){
      if(!p.ok) throw new Error('The photo did not upload. Try again.');
      return api({op:'attach',path:r.path,role:key,content_type:file.type||'image/jpeg'}).then(function(a){
        if(!a.ok) throw new Error(a.message||'Could not attach the photo.');
        var cur=Array.isArray(A[key])?A[key]:[];
        cur.push({path:r.path,preview:URL.createObjectURL(file)});
        A[key]=cur; save();
      });
    });
  }).catch(function(e){ show(e.message||'The photo did not upload.') })
    .then(function(){ busy--; render() });
}

function submit(){
  var who=(document.getElementById('who').value||'').trim();
  if(!who){ show('Put your name so the office knows who collected this.'); return }
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
  var b=document.getElementById('send'); b.disabled=true; b.textContent='Submitting...';
  api({op:'submit',collector:who,answers:out}).then(function(r){
    if(!r.ok){ b.disabled=false; b.textContent='Submit'; show(r.message||'Could not submit.'); return }
    try{localStorage.removeItem(KEY)}catch(e){}
    document.getElementById('foot').className='hide';
    document.getElementById('main').innerHTML='<div class="big"><h2>Thank you</h2><p>'+
      (r.status==='Complete'?'Everything the office asked for is in.':'Sent. The office can see what is still missing.')+
      '</p><p class="note">You can close this page.</p></div>';
  }).catch(function(){ b.disabled=false; b.textContent='Submit'; show('No connection. Your answers are saved on this phone, try again in a moment.') });
}

load();
api({op:'load'}).then(function(r){
  if(!r.ok){ document.getElementById('sub').textContent=''; document.getElementById('main').innerHTML='<div class="big"><h2>'+esc(r.message)+'</h2></div>'; return }
  F=r;
  var p=r.property||{};
  document.getElementById('ttl').textContent=p.address||'Site survey';
  document.getElementById('sub').textContent=[p.name,p.city].filter(Boolean).join(' - ')||'Site survey';
  if(r.already_submitted){ document.getElementById('main').innerHTML='<div class="big"><h2>Already submitted</h2><p>This form was sent in. Ask the office if something needs changing.</p></div>'; return }
  document.getElementById('foot').className='';
  document.getElementById('send').onclick=submit;
  render();
}).catch(function(){ document.getElementById('main').innerHTML='<div class="big"><h2>No connection</h2><p>Check your signal and reload.</p></div>' });
</script></body></html>`
