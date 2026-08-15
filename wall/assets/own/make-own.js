#!/usr/bin/env node
'use strict';
// The city's own art: the noodle bar's cook, and the silhouettes that live
// behind the district's lit windows. There is no CC0 cook, so this one is
// authored here — and authored as TEXT, because a committed PNG nobody can read
// is a binary somebody has to trust. The pixel grids below ARE the art: one
// character per pixel, one letter per palette entry. Run this file and it writes
// `own.png` and `own.json` (a Phaser JSON-hash atlas) beside itself.
//
//   node wall/assets/own/make-own.js           write the atlas
//   node wall/assets/own/make-own.js --check   verify the committed files match
//
// The `--check` mode is what tests/wall.test.sh runs: the committed bytes have
// to be exactly what these grids produce, so editing the art without editing the
// picture is not possible. That is also why the PNG's deflate stream is STORED
// rather than compressed — a compressor's output drifts between zlib builds, and
// a byte-for-byte claim that only holds on one laptop is not a claim.
//
// Licence: CC0 1.0 (see LICENSE.txt beside this file). It is drawn to sit beside
// ansimuz's CC0 pixels without a seam, and it should be as free as they are.

const fs = require('fs');
const path = require('path');

// --- the palette ----------------------------------------------------------------
// Warm whites for the chef's linen, one accent at the throat, and the district's
// own STONE for the outline so the figure sits in the same night as the city.
const INK = {
  '.': null,
  k: '#101a24',   // outline / shadow
  h: '#2a1c22',   // hair
  s: '#e8b48a',   // skin
  t: '#c98f66',   // skin, turned away from the burner
  w: '#f4ead8',   // chef's whites
  g: '#cbb99e',   // the apron, and the seam down the jacket
  r: '#d9603f',   // the neckerchief — the one warm note that is not the flame
  m: '#8b9aa6',   // steel: the cleaver, the rim of the wok
  n: '#ffe9c6',   // noodles, mid-air
  b: '#2b3542',   // trousers
  // Behind a blind, a person is a shape and nothing else. Two values only: the
  // body, and a softer edge so a head does not read as a brick.
  o: '#050a10',
  d: '#0e1721',
};

// --- the cook ---------------------------------------------------------------------
// 30 x 36. The body is drawn once; each frame of the work loop is an ARM PASS
// over it, so the four poses can be read as four poses instead of as four
// near-identical copies of one man. Feet are at the bottom edge of the frame —
// the world stands him on the floor behind his counter with origin (0.5, 1) and
// the counter covers him from the hip down, exactly as a counter does.
const COOK_BODY = [
  '..........wwwwwwwwww..........',
  '.........wwwwwwwwwwww.........',
  '.........wwwwwwwwwwww.........',
  '.........wwwwwwwwwwww.........',
  '..........wwwwwwwwww..........',
  '..........hhhhhhhhhh..........',
  '..........hssssssssh..........',
  '..........hskssssksh..........',
  '..........hssssssssh..........',
  '..........tsssssssst..........',
  '...........ssssssss...........',
  '............ssssss............',
  '..........rrrrrrrrrr..........',
  '.........wwwwwwwwwwww.........',
  '........wwwwwwgwwwwwww........',
  '........wwwwwwgwwwwwww........',
  '........wwwwwwgwwwwwww........',
  '........wwwwwwgwwwwwww........',
  '........wwwwwwgwwwwwww........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '........wggggggggggggw........',
  '.........bbbbbbbbbbbb.........',
  '.........bbbbbbbbbbbb.........',
  '.........bbbbb..bbbbb.........',
  '.........bbbbb..bbbbb.........',
  '.........bbbbb..bbbbb.........',
  '.........kkkkk..kkkkk.........',
];

// The loop: cleaver up, cleaver down, a toss out of the wok, a bowl handed over
// the counter. Four beats is enough for the room to see WORK happening; a fifth
// would be a character study nobody is standing close enough to read.
const COOK_ARMS = [
  // 0 — the cleaver at the top of its swing. The board is on his left, which is
  //     the room's left: everything he works over stays on that side, so the
  //     four frames read as one continuous piece of work rather than as four
  //     unrelated poses.
  [
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..mmmmmm......................',
    '..mmmmmm......................',
    '..mmmmmm......................',
    '..mmmmmm......................',
    '..mmmmmm......................',
    '....kk........................',
    '....kk........................',
    '...sss........................',
    '...www........................',
    '....www.......................',
    '.....www......................',
    '......www............www......',
    '......................www.....',
    '.......................www....',
    '.......................www....',
    '.......................www....',
    '.......................sss....',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
  ],
  // 1 — down on the board, just above the counter. At 3 m this is the frame
  //     that says "chopping": the blade is level and both hands have dropped.
  [
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '......www............www......',
    '.....www..............www.....',
    '....www................www....',
    '....www................www....',
    '...www.................www....',
    '...sss.................sss....',
    '.mmmmmmm......................',
    '.mmmmmm.......................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
  ],
  // 2 — the toss. The wok is out over the burner and a handful of noodles is in
  //     the air above it, which is the whole trick of the frame.
  [
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '....nnn.......................',
    '..nn...nn.....................',
    '..n.....n.....................',
    '.....................www......',
    '......www.............www.....',
    '....www...............www.....',
    '..sss.................sss.....',
    'mmmmmmm.......................',
    '.mmmmm........................',
    '..mmm.........................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
  ],
  // 3 — a bowl handed over the counter, arm straight out to the room. Somebody
  //     is being fed, which is the point of the whole building.
  [
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '......www.....................',
    '.....www.............www......',
    '.....www...............www....',
    '.....sss.................sss..',
    '........................nnnnnn',
    '........................wwwwww',
    '.........................wwww.',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
    '..............................',
  ],
];

// --- the people behind the blinds ---------------------------------------------------
// 8 x 12, drawn as shapes rather than as figures: this is what a person looks
// like through a lit blind from the far side of a street, and anything more
// detailed would be a lie about how much of them you can see. Five archetypes,
// two or three frames each, and the frame changes every several seconds — a
// window that flickers is a fault, a window whose occupant moved is a life.
const OCCUPANTS = {
  // Standing at the middle of the room, weight shifting.
  stand: [
    ['..dd....', '..oo....', '..oo....', '.oooo...', 'oooooo..', 'ooooooo.',
     '.oooooo.', '.ooooo..', '.oooo...', '.oo.oo..', '.oo.oo..', '.oo.oo..'],
    ['..dd....', '..oo....', '..oo....', '..oooo..', '.oooooo.', '.ooooooo',
     '..oooooo', '..ooooo.', '..oooo..', '..oo.oo.', '..oo.oo.', '..oo.oo.'],
    ['..dd....', '..oo....', '..oo....', '.oooo...', 'oooooo..', 'oooooo..',
     '.ooooo..', '.ooooo..', '.oooo...', '.oo.oo..', '.oo.oo..', '.oo.oo..'],
  ],
  // Sat down, leaning back and then forward.
  sit: [
    ['........', '........', '...dd...', '...oo...', '..oooo..', '..ooooo.',
     '..ooooo.', '.oooooo.', '.ooooooo', '..oo..oo', '..oo....', '..oo....'],
    ['........', '........', '..dd....', '..oo....', '.oooo...', '.ooooo..',
     '.oooooo.', '.ooooooo', '.ooooooo', '..oo..oo', '..oo....', '..oo....'],
  ],
  // At the glass, one arm up on the frame. The reason a lit window ever looks
  // occupied from a street: a shape that is nearer the pane than the room.
  lean: [
    ['oo..dd..', 'oo..oo..', 'oo..oo..', 'oo.oooo.', 'oo.ooooo', 'oo.ooooo',
     'oo.ooooo', '...oooo.', '...oooo.', '...oo.oo', '...oo.oo', '...oo.oo'],
    ['....dd..', 'oo..oo..', 'oo..oo..', 'ooooooo.', 'oo.ooooo', 'oo.ooooo',
     '...ooooo', '...oooo.', '...oooo.', '...oo.oo', '...oo.oo', '...oo.oo'],
  ],
  // Crossing the room. Three frames is a walk when the pane is only eight
  // pixels wide: left of the light, in it, out the far side.
  pace: [
    ['dd......', 'oo......', 'oo......', 'oooo....', 'ooooo...', 'ooooo...',
     'oooo....', 'oooo....', 'ooo.....', 'oo.oo...', 'oo..oo..', 'oo..oo..'],
    ['...dd...', '...oo...', '...oo...', '..oooo..', '..ooooo.', '..ooooo.',
     '..oooo..', '..oooo..', '..ooo...', '..oo.oo.', '..oo..oo', '..oo..oo'],
    ['......dd', '......oo', '......oo', '....oooo', '...ooooo', '...ooooo',
     '....oooo', '....oooo', '.....ooo', '...oo.oo', '..oo..oo', '..oo..oo'],
  ],
  // Sat at a table with something lit on it — the shift that is still working.
  desk: [
    ['........', '..dd....', '..oo....', '.oooo...', '.ooooo..', '.oooooo.',
     'oooooooo', '..oo..oo', '........', '........', '........', '........'],
    ['........', '........', '..dd....', '..oooo..', '.oooooo.', '.oooooo.',
     'oooooooo', '..oo..oo', '........', '........', '........', '........'],
  ],
};

// --- packing ------------------------------------------------------------------------
// One row of cooks over one row of occupants. Hand-placed rather than solved: an
// atlas with seven frames in it does not need a packer, and a fixed layout is a
// stable diff.

const COOK_W = 30;
const COOK_H = 36;
const OCC_W = 8;
const OCC_H = 12;

function build() {
  const frames = {};
  const placed = [];
  let x = 0;
  COOK_ARMS.forEach((arms, i) => {
    placed.push({ x, y: 0, w: COOK_W, h: COOK_H, rows: over(COOK_BODY, arms) });
    frames['cook/' + i] = box(x, 0, COOK_W, COOK_H);
    x += COOK_W;
  });
  const width = x;
  x = 0;
  for (const [kind, poses] of Object.entries(OCCUPANTS)) {
    poses.forEach((rows, i) => {
      placed.push({ x, y: COOK_H, w: OCC_W, h: OCC_H, rows });
      frames['occupant/' + kind + '/' + i] = box(x, COOK_H, OCC_W, OCC_H);
      x += OCC_W;
    });
  }
  const w = Math.max(width, x);
  const h = COOK_H + OCC_H;
  const px = Buffer.alloc(w * h * 4);
  for (const cell of placed) {
    for (let row = 0; row < cell.h; row++) {
      const line = cell.rows[row];
      if (line.length !== cell.w) {
        throw new Error(`row ${row} is ${line.length} wide, expected ${cell.w}: ${line}`);
      }
      for (let col = 0; col < cell.w; col++) {
        const colour = INK[line[col]];
        if (colour === undefined) throw new Error('unknown ink [' + line[col] + ']');
        if (!colour) continue;
        const at = ((cell.y + row) * w + cell.x + col) * 4;
        px[at] = parseInt(colour.slice(1, 3), 16);
        px[at + 1] = parseInt(colour.slice(3, 5), 16);
        px[at + 2] = parseInt(colour.slice(5, 7), 16);
        px[at + 3] = 255;
      }
    }
  }
  return { png: encodePNG(w, h, px), atlas: atlasOf(frames, w, h) };
}

// An arm pass over the body: a dot keeps whatever is underneath.
function over(body, arms) {
  return body.map((line, y) => {
    const arm = arms[y] || '';
    return line.split('').map((ch, x) => (arm[x] && arm[x] !== '.' ? arm[x] : ch)).join('');
  });
}

const box = (x, y, w, h) => ({
  frame: { x, y, w, h },
  rotated: false,
  trimmed: false,
  spriteSourceSize: { x: 0, y: 0, w, h },
  sourceSize: { w, h },
});

const atlasOf = (frames, w, h) => JSON.stringify({
  frames,
  meta: {
    app: 'wall/assets/own/make-own.js',
    version: '1.0',
    image: 'own.png',
    format: 'RGBA8888',
    size: { w, h },
    scale: '1',
    source: 'authored in this repository — CC0 1.0, see LICENSE.txt',
  },
}, null, 2) + '\n';

// --- PNG ------------------------------------------------------------------------------
// A minimal RGBA8888 encoder. Stored deflate blocks on purpose: see the header.

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return (~c) >>> 0;
}

function chunk(type, data) {
  const head = Buffer.alloc(8);
  head.writeUInt32BE(data.length, 0);
  head.write(type, 4, 'ascii');
  const tail = Buffer.alloc(4);
  tail.writeUInt32BE(crc32(Buffer.concat([head.subarray(4), data])), 0);
  return Buffer.concat([head, data, tail]);
}

function adler32(buf) {
  let a = 1;
  let b = 0;
  for (let i = 0; i < buf.length; i++) {
    a = (a + buf[i]) % 65521;
    b = (b + a) % 65521;
  }
  return ((b << 16) | a) >>> 0;
}

function deflateStored(raw) {
  const parts = [Buffer.from([0x78, 0x01])];
  for (let at = 0; at < raw.length || at === 0; at += 65535) {
    const slice = raw.subarray(at, at + 65535);
    const head = Buffer.alloc(5);
    head[0] = at + 65535 >= raw.length ? 1 : 0;
    head.writeUInt16LE(slice.length, 1);
    head.writeUInt16LE(~slice.length & 0xffff, 3);
    parts.push(head, slice);
  }
  const sum = Buffer.alloc(4);
  sum.writeUInt32BE(adler32(raw), 0);
  parts.push(sum);
  return Buffer.concat(parts);
}

function encodePNG(w, h, px) {
  const stride = w * 4;
  const raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) {
    raw[y * (stride + 1)] = 0;                       // filter: none
    px.copy(raw, y * (stride + 1) + 1, y * stride, (y + 1) * stride);
  }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0);
  ihdr.writeUInt32BE(h, 4);
  ihdr[8] = 8;      // bit depth
  ihdr[9] = 6;      // colour type: RGBA
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk('IHDR', ihdr),
    chunk('IDAT', deflateStored(raw)),
    chunk('IEND', Buffer.alloc(0)),
  ]);
}

// --- run ------------------------------------------------------------------------------

const HERE = __dirname;
const built = build();
const pngAt = path.join(HERE, 'own.png');
const jsonAt = path.join(HERE, 'own.json');

if (process.argv.includes('--check')) {
  const same = (file, want) => {
    let got;
    try { got = fs.readFileSync(file); } catch { return file + ': missing'; }
    return Buffer.compare(got, Buffer.isBuffer(want) ? want : Buffer.from(want)) === 0
      ? '' : path.basename(file) + ': the committed file is not what the grids draw';
  };
  const bad = [same(pngAt, built.png), same(jsonAt, built.atlas)].filter(Boolean);
  if (bad.length) { console.error(bad.join('; ')); process.exit(1); }
  console.log('own: the committed atlas is exactly what make-own.js draws');
} else {
  fs.writeFileSync(pngAt, built.png);
  fs.writeFileSync(jsonAt, built.atlas);
  console.log('own: wrote own.png and own.json');
}
