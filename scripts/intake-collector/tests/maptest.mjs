// Does the Page Builder's Google Maps key draw a satellite map on a given origin? Headless (visible) Chrome, so
// requestAnimationFrame runs, unlike the automated background tab. Each origin gets a stub page served by
// page.route (nothing is fetched from the app), which loads the SAME script URL the live bundle uses.
// node maptest.mjs <bundle-chunk.js> origin...
import fs from 'node:fs'
import { createRequire } from 'node:module'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')
const [chunk, ...origins] = process.argv.slice(2)
const src = fs.readFileSync(chunk, 'utf8').match(/https:\/\/maps\.googleapis\.com\/maps\/api\/js\?key=[^`"']+/)[0]
  .replace('callback=__initAccessMap', 'callback=__t')
const html = `<!doctype html><html><body style="margin:0"><div id="m" style="width:800px;height:480px"></div><script>
window.__r={auth:false,err:null};window.gm_authFailure=()=>{window.__r.auth=true};
window.__t=()=>{try{window.__map=new google.maps.Map(document.getElementById('m'),{center:{lat:25.7654,lng:-80.2102},zoom:19,mapTypeId:'satellite',tilt:0})}catch(e){window.__r.err=String(e)}};
</script><script async src="${src}"></script></body></html>`
const browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
for (const origin of origins) {
  const page = await browser.newPage()
  const msgs = []
  page.on('console', (m) => { if (/Google Maps|RefererNotAllowed|ApiNotActivated|InvalidKey|BillingNotEnabled|error/i.test(m.text())) msgs.push(m.text().slice(0, 160)) })
  await page.route(origin + '/__maptest', (r) => r.fulfill({ status: 200, contentType: 'text/html', body: html }))
  await page.goto(origin + '/__maptest')
  await page.waitForTimeout(9000)
  const out = await page.evaluate(() => ({
    ...window.__r,
    gmStyle: !!document.querySelector('.gm-style'),
    errBox: !!document.querySelector('.gm-err-container, .dismissButton'),
    tiles: [...document.querySelectorAll('#m img')].filter((i) => i.complete && i.naturalWidth > 0).length,
  }))
  console.log(origin.padEnd(48), JSON.stringify(out), msgs.length ? '| ' + msgs.join(' || ') : '')
  await page.close()
}
await browser.close()
