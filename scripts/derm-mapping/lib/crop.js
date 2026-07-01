// Crop a %-region of a JPEG/PNG to a JPEG at native resolution (no downscale).
const jpeg = require('jpeg-js');
const { PNG } = require('pngjs');
const fs = require('fs');

function decode(imgPath) {
  const buf = fs.readFileSync(imgPath);
  if (buf[0] === 0x89 && buf[1] === 0x50) { const p = PNG.sync.read(buf); return { width: p.width, height: p.height, data: p.data }; }
  return jpeg.decode(buf, { useTArray: true });
}

// box = {x0Pct,y0Pct,x1Pct,y1Pct} (0-100). Clamped + padded. Writes outPath, returns the clamped box used.
function cropPct(imgPath, box, outPath, padPct = 1.5) {
  const d = decode(imgPath);
  const x0Pct = Math.max(0, box.x0Pct - padPct), x1Pct = Math.min(100, box.x1Pct + padPct);
  const y0Pct = Math.max(0, box.y0Pct - padPct), y1Pct = Math.min(100, box.y1Pct + padPct);
  const x0 = Math.round(d.width * x0Pct / 100), x1 = Math.round(d.width * x1Pct / 100);
  const y0 = Math.round(d.height * y0Pct / 100), y1 = Math.round(d.height * y1Pct / 100);
  const cw = Math.max(1, x1 - x0), ch = Math.max(1, y1 - y0);
  const cdata = Buffer.alloc(cw * ch * 4);
  for (let y = 0; y < ch; y++) for (let x = 0; x < cw; x++) {
    const si = ((y0 + y) * d.width + (x0 + x)) * 4, di = (y * cw + x) * 4;
    cdata[di] = d.data[si]; cdata[di + 1] = d.data[si + 1]; cdata[di + 2] = d.data[si + 2]; cdata[di + 3] = 255;
  }
  fs.writeFileSync(outPath, jpeg.encode({ data: cdata, width: cw, height: ch }, 95).data);
  return { x0Pct, y0Pct, x1Pct, y1Pct };
}
module.exports = { decode, cropPct };
