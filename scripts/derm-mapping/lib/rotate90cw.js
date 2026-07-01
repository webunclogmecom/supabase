// Rotate a JPEG/PNG 90 degrees clockwise, saving as JPEG (no EXIF tag emitted, so the output
// pixel buffer IS the display orientation -- used for images whose raw pixel data (as read by
// decode(), which ignores EXIF orientation tags) is stored rotated relative to how browsers /
// the Read tool display them (EXIF Orientation=8 case).
const fs = require('fs');
const jpeg = require('jpeg-js');
const { decode } = require('./crop');

function rotate90cw(imgPath, outPath) {
  const d = decode(imgPath);
  const { width: w, height: h, data } = d;
  const outW = h, outH = w;
  const out = Buffer.alloc(outW * outH * 4);
  // display(dx,dy) = raw(w-1-dy, dx)
  for (let dy = 0; dy < outH; dy++) for (let dx = 0; dx < outW; dx++) {
    const rx = w - 1 - dy, ry = dx;
    const si = (ry * w + rx) * 4, di = (dy * outW + dx) * 4;
    out[di] = data[si]; out[di + 1] = data[si + 1]; out[di + 2] = data[si + 2]; out[di + 3] = 255;
  }
  fs.writeFileSync(outPath, jpeg.encode({ data: out, width: outW, height: outH }, 95).data);
  return outPath;
}
module.exports = { rotate90cw };
