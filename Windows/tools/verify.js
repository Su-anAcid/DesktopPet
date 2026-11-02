// 校验 pet.dat：解析后把几帧用调色板渲染成 PPM，人工比对是否与 macOS 版一致
const fs = require('fs');

const buf = fs.readFileSync(process.argv[2] || 'assets/pet.dat');
const magic = buf.toString('utf8', 0, 4);
if (magic !== 'PXP1') throw new Error('magic 不对: ' + magic);
let p = 4;
const W = buf[p++], H = buf[p++];
const alphaN = buf[p++];
const alphabet = buf.toString('utf8', p, p + alphaN);
p += alphaN;
const frameCount = buf.readUInt16LE(p); p += 2;
const frames = {};
for (let i = 0; i < frameCount; i++) {
  const n = buf[p++];
  const name = buf.toString('utf8', p, p + n); p += n;
  frames[name] = buf.subarray(p, p + W * H);
  p += W * H;
}
const palCount = buf[p++];
const pals = [];
for (let i = 0; i < palCount; i++) {
  const n = buf[p++];
  const name = buf.toString('utf8', p, p + n); p += n;
  const cols = [];
  for (let c = 0; c < alphaN; c++) {
    cols.push([buf[p], buf[p + 1], buf[p + 2], buf[p + 3]]);
    p += 4;
  }
  pals.push({ name, cols });
}

console.log('网格', W + 'x' + H, '帧数', frameCount, '调色板', pals.length,
  '字符表', JSON.stringify(alphabet));
console.log('毛色:', pals.map(x => x.name).join(' / '));
console.log('帧名:', Object.keys(frames).sort().join(' '));
console.log('剩余字节', buf.length - p);

// 渲染若干帧成一排 PPM
const names = ['walk0', 'walk1', 'walk2', 'walk3', 'sitA', 'lickA', 'stretchA', 'quarterCrouch'];
const scale = 8, gap = 8;
const outW = names.length * (W * scale + gap) + gap;
const outH = H * scale + 2 * gap;
const px = Buffer.alloc(outW * outH * 3);
// 棋盘格背景
for (let y = 0; y < outH; y++) {
  for (let x = 0; x < outW; x++) {
    const c = ((x >> 4) + (y >> 4)) % 2 === 0 ? 230 : 205;
    const o = (y * outW + x) * 3;
    px[o] = c; px[o + 1] = c; px[o + 2] = c;
  }
}
names.forEach((nm, fi) => {
  const f = frames[nm];
  if (!f) { console.log('缺帧', nm); return; }
  for (let y = 0; y < H; y++) {
    for (let x = 0; x < W; x++) {
      const ci = f[y * W + x];
      if (ci === 0) continue;
      const [r, g, b, a] = pals[0].cols[ci];
      if (a === 0) continue;
      for (let sy = 0; sy < scale; sy++) {
        for (let sx = 0; sx < scale; sx++) {
          const ox = gap + fi * (W * scale + gap) + x * scale + sx;
          const oy = gap + y * scale + sy;
          const o = (oy * outW + ox) * 3;
          px[o] = r; px[o + 1] = g; px[o + 2] = b;
        }
      }
    }
  }
});
const header = Buffer.from(`P6\n${outW} ${outH}\n255\n`, 'ascii');
fs.writeFileSync('/tmp/verify.ppm', Buffer.concat([header, px]));
console.log('已写出 /tmp/verify.ppm');
