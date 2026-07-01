// Rotate a JPEG/PNG 180 degrees, saving as JPEG. Used for occasional upside-down scans.
const fs = require('fs');
const jpeg = require('jpeg-js');
const { decode } = require('./crop');

function rotate180(imgPath, outPath) {
  const d = decode(imgPath);
  const { width: w, height: h, data } = d;
  const out = Buffer.alloc(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const si = (y * w + x) * 4, di = ((h - 1 - y) * w + (w - 1 - x)) * 4;
    out[di] = data[si]; out[di + 1] = data[si + 1]; out[di + 2] = data[si + 2]; out[di + 3] = 255;
  }
  fs.writeFileSync(outPath, jpeg.encode({ data: out, width: w, height: h }, 95).data);
  return outPath;
}
module.exports = { rotate180 };
