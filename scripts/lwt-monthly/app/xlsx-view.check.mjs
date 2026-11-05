// Standing check of xlsx-view.ts, the Monthly Report page's View button. Made-up data only, in a real browser, no network.
//   node scripts/lwt-monthly/app/xlsx-view.check.mjs            run it; non-zero exit on any failure
//   node scripts/lwt-monthly/app/xlsx-view.check.mjs out.xlsx   also write the made-up file, for the local test bench
// It ends by breaking the module one rule at a time, and each break must make the suite fail: a check that cannot fail proves nothing.
import { createRequire, stripTypeScriptTypes } from 'node:module'
import { readFileSync, writeFileSync } from 'node:fs'
import { crc32, deflateRawSync } from 'node:zlib'
const require = createRequire(import.meta.url)
const { chromium } = require(process.env.PLAYWRIGHT_CORE || 'C:/Users/FRED/AppData/Local/npm-cache/_npx/9833c18b2d85bc59/node_modules/playwright-core')

// ---- A small .xlsx, in the shape the bot's template has -----------------------------------------------------------------
function zip(files) {
  const locals = [], centrals = []
  let at = 0
  for (const [name, text, deflate] of files) {
    const raw = Buffer.isBuffer(text) ? text : Buffer.from(text)
    const body = deflate ? deflateRawSync(raw) : raw
    const nameB = Buffer.from(name)
    const head = Buffer.alloc(30)
    head.writeUInt32LE(0x04034b50, 0); head.writeUInt16LE(20, 4); head.writeUInt16LE(deflate ? 8 : 0, 8); head.writeUInt32LE(crc32(raw), 14)
    head.writeUInt32LE(body.length, 18); head.writeUInt32LE(raw.length, 22); head.writeUInt16LE(nameB.length, 26)
    const dir = Buffer.alloc(46)
    dir.writeUInt32LE(0x02014b50, 0); dir.writeUInt16LE(20, 4); dir.writeUInt16LE(20, 6); dir.writeUInt16LE(deflate ? 8 : 0, 10); dir.writeUInt32LE(crc32(raw), 16)
    dir.writeUInt32LE(body.length, 20); dir.writeUInt32LE(raw.length, 24); dir.writeUInt16LE(nameB.length, 28); dir.writeUInt32LE(at, 42)
    locals.push(head, nameB, body); centrals.push(dir, nameB)
    at += head.length + nameB.length + body.length
  }
  const central = Buffer.concat(centrals)
  const end = Buffer.alloc(22)
  end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(files.length, 8); end.writeUInt16LE(files.length, 10); end.writeUInt32LE(central.length, 12); end.writeUInt32LE(at, 16)
  return Buffer.concat([...locals, central, end])
}
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNkYAAAAAYAAjCB0C8AAAAASUVORK5CYII=', 'base64')
const NS = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"'
const istr = (r, s, t) => `<c r="${r}" s="${s}" t="inlineStr"><is><t>${t}</t></is></c>`
const sheet = (rows, extra = '') => `<?xml version="1.0"?><worksheet ${NS}><sheetFormatPr defaultRowHeight="15"/><cols><col min="1" max="1" width="20" customWidth="1"/><col min="2" max="2" width="10" customWidth="1"/><col min="3" max="3" width="9" hidden="1"/></cols><sheetData>${rows}</sheetData>${extra}<drawing r:id="rId1"/></worksheet>`
const emptyRows = Array.from({ length: 900 }, (_, i) => `<row r="${i + 80}"><c r="A${i + 80}" s="0"/></row>`).join('')
const page1 = sheet(
  `<row r="1" ht="30">${istr('A1', 1, 'MONTHLY REPORT FORM')}<c r="B1" s="0"/></row>`
  + `<row r="2">${istr('A2', 0, '&lt;script&gt;window.__x=1&lt;/script&gt; Grease &amp; Co')}</row>`
  + `<row r="3"><c r="A3" s="3"><v>87.9899999999999</v></c><c r="B3" s="4"><v>21000</v></c><c r="D3" s="0"><v>7</v></c></row>`
  + `<row r="4"><c r="A4" s="0"><v>2000.0000000001</v></c><c r="B4" s="5"><v>1.5</v></c></row>`
  + `<row r="5"><c r="A5" s="2" t="s"><v>0</v></c></row>`
  + emptyRows,
  '<mergeCells count="1"><mergeCell ref="A1:B1"/></mergeCells>',
)
export const sampleXlsx = () => zip([
  ['[Content_Types].xml', '<Types/>'],
  ['xl/workbook.xml', `<?xml version="1.0"?><workbook ${NS}><sheets><sheet name="Page 1" sheetId="1" r:id="rId1"/><sheet name="Hidden" sheetId="2" state="hidden" r:id="rId2"/><sheet name="Page 2" sheetId="3" r:id="rId3"/></sheets></workbook>`],
  ['xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Target="/xl/worksheets/sheet1.xml"/><Relationship Id="rId2" Target="worksheets/sheet2.xml"/><Relationship Id="rId3" Target="worksheets/sheet3.xml"/></Relationships>'],
  ['xl/sharedStrings.xml', `<sst ${NS}><si><t>Shared string</t></si></sst>`],
  ['xl/styles.xml', `<?xml version="1.0"?><styleSheet ${NS}><numFmts count="1"><numFmt numFmtId="165" formatCode="0.000"/></numFmts><fonts count="2"><font><sz val="10"/><name val="Arial"/></font><font><b/><sz val="12"/><color rgb="FFFF0000"/></font></fonts><fills count="3"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="solid"><fgColor rgb="FF00FF00"/></patternFill></fill><fill><patternFill patternType="solid"><fgColor rgb="red;background:url(http://x/)"/></patternFill></fill></fills><borders count="2"><border><left/><right/><top/><bottom/></border><border><left style="thin"/><right/><top/><bottom style="medium"/></border></borders><cellXfs count="6"><xf fontId="0" fillId="0" borderId="0" numFmtId="0"/><xf fontId="1" fillId="1" borderId="1" numFmtId="0"><alignment horizontal="center" vertical="center" wrapText="1"/></xf><xf fontId="0" fillId="2" borderId="0" numFmtId="0"/><xf fontId="0" fillId="0" borderId="0" numFmtId="2"/><xf fontId="0" fillId="0" borderId="0" numFmtId="3"/><xf fontId="0" fillId="0" borderId="0" numFmtId="165"/></cellXfs></styleSheet>`, true],
  ['xl/worksheets/sheet1.xml', page1, true],
  ['xl/worksheets/_rels/sheet1.xml.rels', '<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/drawing" Target="/xl/drawings/drawing1.xml"/></Relationships>'],
  ['xl/drawings/drawing1.xml', '<xdr:wsDr xmlns:xdr="urn:x" xmlns:a="urn:a" xmlns:r="urn:r"><xdr:oneCellAnchor><xdr:from><xdr:col>1</xdr:col><xdr:colOff>9525</xdr:colOff><xdr:row>0</xdr:row><xdr:rowOff>19050</xdr:rowOff></xdr:from><xdr:ext cx="952500" cy="476250"/><xdr:pic><a:blip r:embed="rId1"/></xdr:pic></xdr:oneCellAnchor></xdr:wsDr>', true],
  ['xl/drawings/_rels/drawing1.xml.rels', '<Relationships><Relationship Id="rId1" Target="/xl/media/image1.png"/></Relationships>'],
  ['xl/media/image1.png', PNG],
  ['xl/worksheets/sheet2.xml', sheet(`<row r="1">${istr('A1', 0, 'NEVER SHOWN')}</row>`)],
  ['xl/worksheets/sheet3.xml', `<?xml version="1.0"?><worksheet ${NS}><sheetData><row r="1">${istr('A1', 0, 'SECOND PAGE')}</row></sheetData></worksheet>`],
])

const out = process.argv[2]
if (out) writeFileSync(out, sampleXlsx())

// ---- The suite ------------------------------------------------------------------------------------------------------------
const source = stripTypeScriptTypes(readFileSync(new URL('./xlsx-view.ts', import.meta.url), 'utf8')).replace(/^export /gm, '')
const browser = await chromium.launch({ executablePath: 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
const b64 = sampleXlsx().toString('base64')

async function suite(code) {
  const failed = []
  const ok = (cond, name) => { if (!cond) failed.push(name) }
  const ctx = await browser.newContext()
  await ctx.route('**/*', r => r.abort())
  const page = await ctx.newPage()
  try {
    const result = await page.evaluate(async ({ code, b64 }) => {
      const api = new Function(`${code}\nreturn { reportHtml, fitted, formatNumber };`)()
      const bytes = Uint8Array.from(atob(b64), c => c.charCodeAt(0))
      const report = await api.reportHtml(bytes.buffer)
      let refused = ''
      try { await api.reportHtml(new TextEncoder().encode('{"detail":"nope"}').buffer) } catch (e) { refused = e.message }
      return {
        report, refused,
        fit: { wide: api.fitted({ html: '/*zoom*/', width: 1000 }, 2020), mid: api.fitted({ html: '/*zoom*/', width: 1000 }, 820), phone: api.fitted({ html: '/*zoom*/', width: 1000 }, 300) },
        nums: [api.formatNumber('87.9899999999999', '0.00'), api.formatNumber('21000', '#,##0'), api.formatNumber('2000.0000000001', undefined), api.formatNumber('1.5', '0.000'), api.formatNumber('', '0.00')],
      }
    }, { code, b64 })
    await page.setContent(result.report.html)
    const seen = await page.evaluate(() => {
      const cells = [...document.querySelectorAll('td')]
      const td = t => cells.find(c => c.textContent === t)
      const style = t => td(t)?.getAttribute('style') || ''
      return {
        text: document.body.textContent, pages: document.querySelectorAll('section').length, rows: document.querySelector('section').querySelectorAll('tr').length,
        colspan: td('MONTHLY REPORT FORM')?.getAttribute('colspan'), scripts: document.querySelectorAll('script').length, ran: window.__x === 1,
        escaped: cells.some(c => c.textContent.includes('<script>')), styleTitle: style('MONTHLY REPORT FORM'), styleBad: style('Shared string'),
        img: document.querySelector('img')?.getAttribute('src')?.slice(0, 22), imgStyle: document.querySelector('img')?.getAttribute('style'), hiddenCol: document.querySelectorAll('section:first-child col')[2]?.getAttribute('style'),
      }
    })
    ok(seen.pages === 2, 'draws each visible page')
    ok(!seen.text.includes('NEVER SHOWN'), 'a hidden sheet stays hidden')
    ok(seen.text.includes('SECOND PAGE'), 'the second page is there')
    ok(seen.rows === 5, 'the page ends at its last mark, not at row 984')
    ok(seen.colspan === '2', 'a merge spans its cells')
    ok(seen.scripts === 0 && !seen.ran && seen.escaped, 'a cell is text, never markup')
    ok(seen.text.includes('Grease & Co'), 'an ampersand reads as an ampersand')
    ok(seen.text.includes('87.99'), 'a number prints in its format (87.99)')
    ok(!seen.text.includes('87.9899'), 'the float noise is gone')
    ok(seen.text.includes('21,000'), 'thousands from the format')
    ok(seen.text.includes('1.500'), 'a custom format')
    ok(seen.text.includes('Shared string'), 'a shared string')
    ok(/font-weight:700/.test(seen.styleTitle) && /color:#FF0000/i.test(seen.styleTitle) && /background:#00FF00/i.test(seen.styleTitle), 'font and fill')
    ok(/border-left:1px solid/.test(seen.styleTitle) && /border-bottom:2px solid/.test(seen.styleTitle), 'borders')
    ok(/text-align:center/.test(seen.styleTitle) && /white-space:normal/.test(seen.styleTitle), 'alignment and wrap')
    ok(!/url\(/.test(seen.styleBad), 'a colour that is not a colour never reaches a style')
    ok(seen.img === 'data:image/png;base64,', 'a picture is a data URL')
    ok(/left:\d+px/.test(seen.imgStyle || '') && /width:100px/.test(seen.imgStyle || '') && /height:50px/.test(seen.imgStyle || ''), 'a picture keeps its place and size')
    ok(/width:0px/.test(seen.hiddenCol || ''), 'a hidden column takes no room')
    ok(result.report.width > 100 && result.report.width < 400, 'the width is the used columns, not column AA')
    ok(/could not be read/.test(result.refused), 'a reply that is not a file says so')
    ok(/zoom:1\.250/.test(result.fit.wide), 'zoom stops at 1.25')
    ok(/zoom:0\.800/.test(result.fit.mid), 'zoom fits the width')
    ok(/zoom:0\.550/.test(result.fit.phone), 'a phone keeps a readable size')
    ok(result.nums.join('|') === '87.99|21,000|2000|1.500|', `formatNumber: ${result.nums.join('|')}`)
  } catch (e) {
    failed.push(`threw: ${e.message.split('\n')[0]}`)
  }
  await ctx.close()
  return failed
}

const first = await suite(source)
for (const f of first) console.log('FAIL', f)
if (first.length) { await browser.close(); console.log(`${first.length} failed`); process.exit(1) }
console.log('ok   all 25 checks')

const MUTANTS = [
  ['esc stops escaping', "s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/\"/g, '&quot;')", 's'],
  ['any colour passes', '(v && /^[0-9a-f]{8}$/i.test(v) ? `#${v.slice(2)}` : null)', '(v ? `#${v.slice(2)}` : null)'],
  ['every cell counts as used', "if (text !== '' || styles[style]?.marks)", 'if (true)'],
  ['formats ignored', "if (!m) return String(+n.toPrecision(12));", 'return raw;'],
  ['float noise kept', 'String(+n.toPrecision(12))', 'raw'],
  ['merges ignored', 'spans.set(`${r1}:${c1}`,', 'void (`${r1}:${c1}`,'],
  ['hidden sheets drawn', "if (s.getAttribute('state') && s.getAttribute('state') !== 'visible') continue;", ''],
  ['hidden columns kept', 'widths.set(i, hidden ? 0 : Number', 'widths.set(i, false ? 0 : Number'],
  ['pictures dropped', 'await pictures(zip, path, t.colPx, t.rowPx)', "''"],
  ['no zoom floor', 'Math.max(0.55, (boxWidth - 20) / page.width)', '(boxWidth - 20) / page.width'],
]
let bad = 0
for (const [name, from, to] of MUTANTS) {
  if (!source.includes(from)) { console.log('FAIL mutant cannot apply:', name); bad++; continue }
  const failed = await suite(source.replace(from, to))
  if (!failed.length) { console.log('FAIL mutant survived:', name); bad++ }
}
await browser.close()
if (bad) { console.log(`${bad} of ${MUTANTS.length} mutants were not caught`); process.exit(1) }
console.log(`ok   ${MUTANTS.length} of ${MUTANTS.length} mutants caught`)
console.log('\nall good')
