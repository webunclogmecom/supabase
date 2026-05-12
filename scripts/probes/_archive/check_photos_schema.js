require('dotenv').config({ path: require('path').resolve(__dirname, '../../.env') });
const https = require('https');
const PAT = process.env.SUPABASE_PAT;
const PROJECT_ID = process.env.SUPABASE_PROJECT_ID;

function q(sql) {
  return new Promise((res, rej) => {
    const body = JSON.stringify({ query: sql });
    const req = https.request({
      hostname: 'api.supabase.com', path: `/v1/projects/${PROJECT_ID}/database/query`,
      method: 'POST',
      headers: { Authorization: `Bearer ${PAT}`, 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, r => { let d=''; r.on('data',c=>d+=c); r.on('end',()=>r.statusCode<300?res(JSON.parse(d)):rej(new Error(`${r.statusCode}: ${d.slice(0,400)}`))); });
    req.on('error', rej); req.write(body); req.end();
  });
}

(async () => {
  console.log('photos columns:');
  console.table(await q(`SELECT column_name, data_type FROM information_schema.columns WHERE table_schema='public' AND table_name='photos' ORDER BY ordinal_position;`));
})().catch(e=>{console.error(e.message);process.exit(1);});
