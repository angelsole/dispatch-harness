'use strict';
// Ghost Shift's ROOM — one floor of one tower, from the inside.
//
// The wide city says a job is running. This says who is running it, on what,
// and how far it has got: a night office at pixel-art scale, authored on a
// 320x180 canvas and shown at an INTEGER scale (4x on a 1280x720 preview, 6x
// on a 1080p panel), so every pixel on the wall is a whole number of pixels
// from this file. Never a fractional scale — a half-pixel is what turns pixel
// art back into a blurry render.
//
// Everything in here is a fact about one run:
//
//   the worker      the actor that owns the stage, tinted with the actor neon
//                   the same way that run's car is tinted in the wide city
//   the monitor     the stage in one word, then the run's own feed line by
//                   line, in the page's own type — no lettering is ever drawn
//                   by a model, only by this file
//   the wall plate  the floor the run has climbed to, out of six
//   the lamp        the dispatcher, in their crew tint — the one place crew
//                   colour is allowed, exactly as in the wide city
//   the window      the same night, the same rain, from the other side
//
// Drawing rules, which are what keep it reading as a game and not as a render:
//
//   Rectangles on whole pixels. Every shape is fillRect at integer coordinates
//   and every sprite lands on a whole pixel with smoothing off, so the room has
//   one pixel grid and no shape has a soft edge. Light is BANDED — a stack of
//   flat rects, not a gradient — for the same reason.
//
//   Nothing keeps its own clock. Every moving thing is a pure function of one
//   frame clock that starts with the room hold, so the lens, hands, CRT and rain
//   all advance together. That clock is the FRAME clock — the timestamp rAF
//   hands in, which only ever goes forward — and never the wall clock plus the
//   server's skew, which steps sideways every time a snapshot lands and turns a
//   slow push into a jump cut. Reduced motion draws one frame at a pinned phase
//   and never starts a loop: a still room is a LIT room standing still.
//
//   The palette is the lock. Every colour below is one of the 32 in
//   .creative/palette.png, which is also what every sprite in wall/assets/room
//   is quantised to.

(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.WallRoom = factory();
}(typeof globalThis === 'object' ? globalThis : this, function () {
  // --- the room's grid ----------------------------------------------------
  // 320x180 divides both wall sizes this harness is ever shown at exactly:
  // 1280x720 is 4x and 1920x1080 is 6x. The room is authored here and nowhere
  // else; the page only picks the multiplier.
  const W = 320;
  const H = 180;

  const SOFFIT = 14;      // the ceiling band, in shadow
  const FLOOR_Y = 118;    // where the back wall meets the floor
  const DESK_Y = 132;     // the desk's top surface
  const DESK_END = 160;   // and the bottom of its front panel
  const PILLAR = 24;      // the near-plane column down the left edge

  // --- the palette --------------------------------------------------------
  // .creative/palette.png, by name. Nothing in this file may use a colour that
  // is not on this list.
  const NIGHT = '#010306';
  const STONE = '#0a1220';
  const MID = '#101e2a';
  const LIT = '#15202e';
  const WARM = '#1d2930';
  const STEEL = '#253038';
  const MOSS = '#2c4341';
  const GREY = '#525852';
  const SAGE = '#79907e';
  const ICE = '#96c3c8';
  const MINT = '#a9d9c6';
  const RUST = '#531820';
  const GLOW = '#ffc27d';
  const WORK = '#ffc680';
  const EMBER = '#ff9a5e';
  const CYAN = '#7ad6ec';
  const PALE = '#deeaee';
  const BONE = '#e6dfc8';
  const ALARM = '#ff2f45';

  // The 32 as numbers, for snapping a colour the rest of the wall owns — a
  // crew tint is chosen in scene.js from a five-hue set that predates this
  // palette, and a room that draws it verbatim is a room with a 33rd colour in
  // it.
  const LOCK = [
    '#010306', '#0a1220', '#101e2a', '#15202e', '#1d2930', '#253038', '#2c4341',
    '#14342d', '#525852', '#79907e', '#96c3c8', '#a9d9c6', '#531820', '#5e3437',
    '#4f4441', '#e0a23c', '#e8cfa6', '#ffc27d', '#ffc680', '#ff9a5e', '#7ad6ec',
    '#7fd4ec', '#deeaee', '#e6dfc8', '#e4fff3', '#4e7168', '#4c9dff', '#3fd984',
    '#4ff08f', '#2c9a61', '#9fe8b8', '#ff2f45',
  ];
  const rgbOf = (hex) => [
    parseInt(hex.slice(1, 3), 16),
    parseInt(hex.slice(3, 5), 16),
    parseInt(hex.slice(5, 7), 16),
  ];
  const LOCK_RGB = LOCK.map(rgbOf);

  function snap(hex) {
    if (typeof hex !== 'string' || !/^#[0-9a-fA-F]{6}$/.test(hex)) return SAGE;
    const [r, g, b] = rgbOf(hex);
    let best = 0;
    let near = Infinity;
    for (let i = 0; i < LOCK_RGB.length; i++) {
      const [pr, pg, pb] = LOCK_RGB[i];
      const d = (r - pr) * (r - pr) + (g - pg) * (g - pg) + (b - pb) * (b - pb);
      if (d < near) { near = d; best = i; }
    }
    return LOCK[best];
  }

  // Which model owns the stage, in the room's own 32. The wide city's actor
  // neons are wall.css :root tokens; the four that are not already on the lock
  // (setup, sync, skipped, unknown) sit on their nearest neighbour rather than
  // opening a colour the room is not allowed to have.
  const ACTOR = {
    opus: '#4c9dff', codex: '#3fd984', gate: '#e0a23c', pr: '#e6dfc8',
    demo: '#7fd4ec', setup: '#4e7168', sync: '#4e7168', skipped: '#79907e',
    deferred: '#e0a23c', alarm: '#ff2f45', done: '#3fd984', failed: '#ff2f45',
    unreviewed: '#ff2f45', unknown: '#79907e',
  };

  // --- the type -----------------------------------------------------------
  // Two hand-set bitmap faces, drawn a pixel at a time by this file. No web
  // font, no canvas fillText: type that is rasterised by the browser lands off
  // the room's grid and reads as a smear at 4x, and type generated by a model
  // is the invented lettering the art direction bans outright. Written as the
  // shapes themselves so a letter can be read and fixed in the source.
  //
  // The big face carries the two strings the room is for — the stage and the
  // ticket. One pixel of it is four on a 1280x720 wall, which clears the
  // three-pixel stroke floor the bible sets for anything that has to read from
  // three metres.
  const BIG = glyphs(5, 7, {
    A: '.###./#...#/#...#/#####/#...#/#...#/#...#',
    B: '####./#...#/#...#/####./#...#/#...#/####.',
    C: '.###./#...#/#..../#..../#..../#...#/.###.',
    D: '####./#...#/#...#/#...#/#...#/#...#/####.',
    E: '#####/#..../#..../####./#..../#..../#####',
    F: '#####/#..../#..../####./#..../#..../#....',
    G: '.###./#...#/#..../#.###/#...#/#...#/.####',
    H: '#...#/#...#/#...#/#####/#...#/#...#/#...#',
    I: '#####/..#../..#../..#../..#../..#../#####',
    J: '..###/...#./...#./...#./...#./#..#./.##..',
    K: '#...#/#..#./#.#../##.../#.#../#..#./#...#',
    L: '#..../#..../#..../#..../#..../#..../#####',
    M: '#...#/##.##/#.#.#/#.#.#/#...#/#...#/#...#',
    N: '#...#/##..#/##..#/#.#.#/#..##/#..##/#...#',
    O: '.###./#...#/#...#/#...#/#...#/#...#/.###.',
    P: '####./#...#/#...#/####./#..../#..../#....',
    Q: '.###./#...#/#...#/#...#/#.#.#/#..#./.##.#',
    R: '####./#...#/#...#/####./#.#../#..#./#...#',
    S: '.####/#..../#..../.###./....#/....#/####.',
    T: '#####/..#../..#../..#../..#../..#../..#..',
    U: '#...#/#...#/#...#/#...#/#...#/#...#/.###.',
    V: '#...#/#...#/#...#/#...#/#...#/.#.#./..#..',
    W: '#...#/#...#/#...#/#.#.#/#.#.#/##.##/#...#',
    X: '#...#/#...#/.#.#./..#../.#.#./#...#/#...#',
    Y: '#...#/#...#/.#.#./..#../..#../..#../..#..',
    Z: '#####/....#/...#./..#../.#.../#..../#####',
    0: '.###./#...#/#..##/#.#.#/##..#/#...#/.###.',
    1: '..#../.##../..#../..#../..#../..#../.###.',
    2: '.###./#...#/....#/...#./..#../.#.../#####',
    3: '#####/...#./..#../...#./....#/#...#/.###.',
    4: '...#./..##./.#.#./#..#./#####/...#./...#.',
    5: '#####/#..../####./....#/....#/#...#/.###.',
    6: '..##./.#.../#..../####./#...#/#...#/.###.',
    7: '#####/....#/...#./..#../.#.../.#.../.#...',
    8: '.###./#...#/#...#/.###./#...#/#...#/.###.',
    9: '.###./#...#/#...#/.####/....#/...#./.##..',
    '-': '...../...../...../#####/...../...../.....',
    '.': '...../...../...../...../...../...../..#..',
    ' ': '...../...../...../...../...../...../.....',
  });

  // And the small face, for the strings that are context rather than headline:
  // the repo, the dispatcher's name, the floor's label — and, since the tube
  // started showing the run's own feed, code. Code is punctuation as much as it
  // is letters: a line that draws `EDIT SRC/EXPORT.TS` with the slash missing is
  // a line that reads as two words nobody wrote. So the face carries the whole
  // set a feed line can contain, set in the same 3x5 grid a pixel at a time —
  // there is no second face and no larger one, because the tube is 68 px wide
  // and the composition is not moving.
  const SMALL = glyphs(3, 5, {
    A: '.#./#.#/###/#.#/#.#',
    B: '##./#.#/##./#.#/##.',
    C: '.##/#../#../#../.##',
    D: '##./#.#/#.#/#.#/##.',
    E: '###/#../##./#../###',
    F: '###/#../##./#../#..',
    G: '.##/#../#.#/#.#/.##',
    H: '#.#/#.#/###/#.#/#.#',
    I: '###/.#./.#./.#./###',
    J: '..#/..#/..#/#.#/.#.',
    K: '#.#/#.#/##./#.#/#.#',
    L: '#../#../#../#../###',
    M: '#.#/###/###/#.#/#.#',
    N: '##./#.#/#.#/#.#/#.#',
    O: '.#./#.#/#.#/#.#/.#.',
    P: '##./#.#/##./#../#..',
    Q: '.#./#.#/#.#/###/.##',
    R: '##./#.#/##./#.#/#.#',
    S: '.##/#../.#./..#/##.',
    T: '###/.#./.#./.#./.#.',
    U: '#.#/#.#/#.#/#.#/###',
    V: '#.#/#.#/#.#/#.#/.#.',
    W: '#.#/#.#/###/###/#.#',
    X: '#.#/#.#/.#./#.#/#.#',
    Y: '#.#/#.#/.#./.#./.#.',
    Z: '###/..#/.#./#../###',
    0: '###/#.#/#.#/#.#/###',
    1: '.#./##./.#./.#./###',
    2: '##./..#/.#./#../###',
    3: '##./..#/.#./..#/##.',
    4: '#.#/#.#/###/..#/..#',
    5: '###/#../##./..#/##.',
    6: '.##/#../##./#.#/.#.',
    7: '###/..#/.#./.#./.#.',
    8: '.#./#.#/.#./#.#/.#.',
    9: '.#./#.#/.##/..#/##.',
    '-': '.../.../###/.../...',
    '.': '.../.../.../.../.#.',
    '/': '..#/..#/.#./#../#..',
    ',': '.../.../.../.#./#..',
    ':': '.../.#./.../.#./...',
    ';': '.../.#./.../.#./#..',
    '!': '.#./.#./.#./.../.#.',
    '?': '##./..#/.#./.../.#.',
    '(': '.#./#../#../#../.#.',
    ')': '.#./..#/..#/..#/.#.',
    '[': '##./#../#../#../##.',
    ']': '.##/..#/..#/..#/.##',
    '{': '.##/.#./##./.#./.##',
    '}': '##./.#./.##/.#./##.',
    '<': '..#/.#./#../.#./..#',
    '>': '#../.#./..#/.#./#..',
    '=': '.../###/.../###/...',
    '+': '.../.#./###/.#./...',
    '_': '.../.../.../.../###',
    '|': '.#./.#./.#./.#./.#.',
    '*': '.../#.#/.#./#.#/...',
    '#': '#.#/###/#.#/###/#.#',
    '@': '.#./#.#/###/#../.##',
    '\'': '.#./.#./.../.../...',
    '"': '#.#/#.#/.../.../...',
    ' ': '.../.../.../.../...',
  });

  // Not letters: the two marks that say WHERE a feed line came from. The harness
  // writes its log with a glyph per source — a filled dot for the implementer's
  // own tool calls and thoughts, a diamond for the reviewer's — and neither is
  // in any face, so each is a shape in the same 3x5 cell, drawn in the crew
  // tint. Two, and no more: a third mark that meant "something" would be
  // texture, and this wall does not do texture.
  // Filled and hollow, and five rows against three. The reviewer's mark started
  // as a small solid diamond, which in this grid is `.#./###/.#.` — the same
  // three rows as the plus sign. A reviewer's line that opens with `+` would have
  // drawn the mark twice and meant it once.
  const MARKS = {
    dot: ['...', '###', '###', '###', '...'],
    diamond: ['.#.', '###', '#.#', '###', '.#.'],
  };
  const markOf = (src) => (src === 'codex' ? 'diamond' : 'dot');

  // The four rows' ink, oldest first. A cold ramp and nothing else: red is an
  // alarm in this palette and green is a run that shipped, so a `-` and a `+` in
  // a diff hunk are text. The eye is walked to the newest row by VALUE — measured
  // off the committed render, 252, 391, 545 and 694 of summed channel against the
  // tube's own 60 — rather than by thinning the old ones with alpha, which is how
  // the oldest row first came out at 204 and stopped reading at all.
  const FEED_INK = [GREY, SAGE, ICE, PALE];

  // A face is its shapes plus the two numbers every caller needs: how wide one
  // glyph is, and how far the next one starts.
  function glyphs(w, h, art) {
    const rows = {};
    for (const key of Object.keys(art)) rows[key] = art[key].split('/');
    return { w, h, pitch: w + 1, rows };
  }

  const widthOf = (face, text) => (text.length ? text.length * face.pitch - 1 : 0);

  // A string too long for the space it has, cut where it stops fitting. The
  // room would rather say VALORYX-GRAPHQL. than draw four unreadable pixels
  // per letter. Trailing space goes before the stop does: `CHECKPOINT 3 - .`
  // is a cut that looks like a mistake, and `CHECKPOINT 3 -.` is one that looks
  // like a cut.
  function fit(face, str, room) {
    if (widthOf(face, str) <= room) return str;
    const max = Math.max(1, Math.floor((room + 1) / face.pitch));
    return str.slice(0, Math.max(1, max - 1)).replace(/\s+$/, '') + '.';
  }

  // How many whole glyphs of a face a span of the tube holds.
  const cells = (face, room) => Math.max(0, Math.floor((room + 1) / face.pitch));

  // --- the assets ---------------------------------------------------------
  // Every file here is committed under wall/assets, listed in
  // wall/assets/MANIFEST.md with the hash it was committed at, and quantised to
  // the same 32 colours this file draws with. Nothing is fetched from anywhere
  // else; the room simply does not draw until they are all in.
  //
  // The furniture is one set and every run needs all of it.
  const PROPS = {
    wall: 'wall.png',
    floor: 'floor.png',
    windowFrame: 'window.png',
    desk: 'desk.png',
    lamp: 'lamp.png',
    plant: 'plant.png',
    shelf: 'shelf.png',
  };

  // The person at the desk is not a sprite but a SET of seventeen frames, and
  // which set that is depends on whose run this is — the one fact in this room
  // that is about a human rather than about the work. Every set under
  // wall/assets/crew/ names its frames the same way; the room's own worker
  // predates that directory and keeps the `worker-` prefix its files were
  // committed with, and its base still is worker-type-0.png rather than a
  // base.png, which is what ALIAS is for.
  //
  // One base and two eight-frame cycles. Eight because four at 300 ms is 3.3
  // poses a second, and at 4x on a preview — 12 device pixels per authored one
  // on the office panel — 3.3 poses a second is a slideshow with a jump in it
  // where the loop wraps. Eight at 120 ms is a hand.
  //
  // The BASE is a drawn frame now, not merely the still the generator was
  // handed: every drawn worker is the base above the split and the cycle's own
  // frame below it, so the head that was regenerated in every pose holds.
  const CYCLE = 8;
  const cycleFrames = (name) => Array.from({ length: CYCLE }, (_, i) => name + '-' + i);
  const TYPE_SET = cycleFrames('type8');
  const WAIT_SET = cycleFrames('wait8');
  const FRAMES = ['base'].concat(TYPE_SET, WAIT_SET);
  const PREFIX = { room: 'worker-' };
  const ALIAS = { room: { base: 'type-0' } };
  const FALLBACK = 'room';
  const fileOf = (set, frame) => 'assets/' + set + '/' + (PREFIX[set] || '')
    + ((ALIAS[set] || {})[frame] || frame) + '.png';

  // Where one figure is cut in two. Above this row the drawn worker is the
  // base and nothing else; below it the cycle's frame. Measured per set off the
  // committed PNGs rather than guessed: the row is chosen where the base's
  // silhouette and every frame's agree, because a seam is only invisible where
  // the jacket outline does not step. The heroes' jackets sit at different
  // heights in their 64x64 box, so one number does not seat all four.
  // Measured over the sixteen committed frames of each set: the row whose worst
  // single-frame left/right edge mismatch against the base's row above it is
  // smallest, out of the rows that still leave the forearms and hands below the
  // cut. Room 41 and Angel 41 step by at most one pixel in one frame, Emre 43 by
  // one in seven of sixteen, Ran 40 by two — Ran's sleeve is the widest thing in
  // any of these boxes and two pixels of it is the price of keeping every one of
  // her moving rows in the animated band.
  const SPLIT = { room: 41, 'crew/angel': 41, 'crew/emre': 43, 'crew/ran': 40 };
  const SPLIT_DEFAULT = 41;
  const splitOf = (set) => (SPLIT[set] === undefined ? SPLIT_DEFAULT : SPLIT[set]);

  // What one drawn worker is made of, as two bands and the row between them.
  // Returned by a pure function rather than decided inside the draw call so the
  // suite can ask the room which file each band came from — a head drawn from
  // frame N is the whole defect this cycle exists to remove, and it must not be
  // possible to reintroduce it without failing a test.
  //
  // `typing` is the reveal's override: while a line is appearing on the tube the
  // hands are working, whatever the burst schedule was about to do. The person
  // is typing what the screen is showing.
  function bandsOf(set, beat, alarm, typing) {
    const body = alarm ? WAIT_SET[beat.waiting]
      : ((beat.burst || typing) ? TYPE_SET[beat.typing] : 'base');
    return { split: splitOf(set), head: 'base', body };
  }

  // Whose character sits at the desk. The server already lower-cases an owner
  // into a lane key; this lower-cases again because crew.json is written by
  // hand and ANGEL and angel are one crew member — the same rule the wide
  // city's crewTint has always used. An owner nobody drew a character for gets
  // the room's own worker, which is who this room drew for everybody until now.
  //
  // The set name is checked against the shape the server's asset route will
  // actually serve. That is a shape check and nothing more — `crew/angl` looks
  // exactly like `crew/angel` — so it is the SERVER that decides a set exists,
  // by putting every frame of it through the asset guard before the roster goes
  // over the wire. This is the near half of the same fence: a roster from
  // anywhere else cannot talk the room into requesting a path the route would
  // refuse.
  const SET = /^[A-Za-z0-9][A-Za-z0-9_-]*(\/[A-Za-z0-9][A-Za-z0-9_-]*)?$/;
  function setOf(crew, owner) {
    const key = String(owner || '').trim().toLowerCase();
    const entry = crew && typeof crew === 'object' ? crew[key] : null;
    const set = entry && typeof entry.set === 'string' ? entry.set : '';
    return SET.test(set) ? set : FALLBACK;
  }

  // And the name that goes on the plate with them. crew.json is where a crew
  // member's own spelling lives, so it wins over the lane key the server
  // derived; an owner with no entry keeps the name their run dir was pinned
  // with, and an unowned run still has nothing to say.
  function labelOf(crew, view) {
    const entry = crew && typeof crew === 'object' ? crew[view.ownerKey] : null;
    const label = entry && typeof entry.label === 'string' ? entry.label : '';
    return label || view.owner;
  }

  // Where each sprite's own drawing sits inside its file, measured once off the
  // committed PNGs, so the room places the DESK rather than the desk's padding.
  const BOX = {
    windowFrame: { x: 23, y: 6, w: 66, h: 60, hole: { x: 30, y: 24, w: 52, h: 35 } },
    desk: { x: 27, y: 10, w: 72, h: 28 },
    lamp: { x: 2, y: 5, w: 28, h: 25 },
    plant: { x: 5, y: 4, w: 22, h: 39 },
    shelf: { x: 5, y: 7, w: 55, h: 70 },
    worker: { x: 4, y: 4, w: 56, h: 56 },
  };

  // --- what the room is made of, in room coordinates ----------------------
  const WINDOW = { x: 26, y: 16 };                       // the frame sprite's origin
  const HOLE = {
    x: WINDOW.x + BOX.windowFrame.hole.x,
    y: WINDOW.y + BOX.windowFrame.hole.y,
    w: BOX.windowFrame.hole.w,
    h: BOX.windowFrame.hole.h,
  };
  const PLATE = { x: 228, y: 26, w: 72, h: 32 };         // the floor sign on the wall
  const SCREEN = { x: 176, y: 78, w: 68, h: 38 };        // what the monitor shows
  const BEZEL = { x: 172, y: 74, w: 76, h: 52 };
  const WORKER = { x: 96, y: 74 };                       // the sprite's origin
  const LAMP = { x: 60, y: DESK_Y - BOX.lamp.y - BOX.lamp.h };
  const RAIN_SPEED = 6;                                  // room px / second

  // The typing loop: eight poses, 120 ms each, so the cycle is 960 ms and the
  // hands run at 8.3 poses a second. That is the floor for reading as typing —
  // a hand that travels three or four pixels between frames at 8-10 fps is a
  // hand, and one that travels one pixel at 3 fps is noise. The visual gate
  // samples every 750 ms, and 750 and 120 land on a different pose every time —
  // 0, 6, 4, 2, 1, 7 across a six-frame contact sheet, which is what stops a
  // contact sheet showing six copies of one pose. A loop, never a ping-pong:
  // the hands come round rather than reversing.
  const TYPE_MS = 120;
  const TYPE_FRAMES = CYCLE;

  // And waiting: eight poses at 220 ms, a 1.76 s breath. A LOOP here too, even
  // though a breath goes in and out — the eight frames are generated as one
  // closed cycle that already breathes both ways, so ping-ponging them would
  // play the exhale twice and double the period past what a breath takes. 220
  // against the gate's 750 also lands on six distinct poses (0, 3, 6, 2, 5, 1),
  // which matters more here than anywhere else: the alarm room IS the shot the
  // gate takes of this room.
  const WAIT_MS = 220;
  const WAIT_FRAMES = CYCLE;

  // The cursor on the tube. 530 ms is a terminal's own blink interval, and this
  // one is on the room's clock like everything else.
  const BLINK_MS = 530;

  // Typing comes in BURSTS, because a person does: a few seconds of work, then
  // half a second of hands-on-the-keys stillness while they read what they
  // wrote. Four (working, resting) pairs, in seconds, and nothing else in this
  // file is allowed to add a second source of motion to the hands — a one-pixel
  // band drop on top of frames that already travel reads as a twitch, which is
  // why the one that used to be here is gone.
  //
  // The four always sum to the same 13.9 s whatever order they are in, which is
  // the property that makes "which segment is this second in" a modulo and a
  // walk of at most four steps instead of a walk from the start of the shot: a
  // room that has been up for an hour costs exactly what one that just opened
  // costs. The ORDER rotates with a hashed step of the super-cycle index, so the
  // pattern does not read as a metronome — and it is a hash of the CLOCK, never
  // a random draw and never the page's seed, because a schedule dealt once at
  // create() would not repeat from startedAt and a recording of the same second
  // has to be the same picture.
  const BURSTS = [[2.4, 0.6], [3.6, 0.9], [2.0, 0.4], [3.0, 1.0]];
  const BURST_CYCLE = BURSTS.reduce((total, pair) => total + pair[0] + pair[1], 0);

  // Murmur3's finaliser, which is the cheapest thing that actually mixes into the
  // LOW bits — the two obvious shortcuts do not. A plain multiply by an odd
  // constant is the identity under mod 4, and one shift-xor after it lands on 0,
  // 3, 3, 3, 3...: both would have been "rotate by a constant" wearing the word
  // hash. This one gives 0 3 2 3 1 1 0 0 3 3 0 0 3 2 ... over the first
  // super-cycles, which is what an irregular working rhythm is made of.
  function step(turn) {
    let h = turn >>> 0;
    h ^= h >>> 16;
    h = Math.imul(h, 0x85ebca6b);
    h ^= h >>> 13;
    h = Math.imul(h, 0xc2b2ae35);
    h ^= h >>> 16;
    return (h >>> 0) % BURSTS.length;
  }

  function burstAt(elapsed) {
    const turn = Math.floor(elapsed / BURST_CYCLE);
    let at = elapsed - turn * BURST_CYCLE;
    const from = step(turn);
    for (let i = 0; i < BURSTS.length; i++) {
      const pair = BURSTS[(i + from) % BURSTS.length];
      if (at < pair[0]) return true;
      at -= pair[0];
      if (at < pair[1]) return false;
      at -= pair[1];
    }
    // A float that lands on the last seam works rather than freezes.
    return true;
  }

  // --- the beat -----------------------------------------------------------
  // Every cycle in the room, from one reading of the frame clock: which sprite
  // frame the worker is on, how hard the tube is glowing, how the strip light
  // is failing. No channel keeps an independent phase: every one receives the
  // same elapsed beat. Asking for it with `reduced` returns the SAME answer at
  // every second of the clock, which is what "reduced motion is a still frame,
  // not a slower one" has to mean once the room is a canvas and there is no
  // stylesheet left to inspect. It is a lit still, never a dark one: both
  // lights come back at full.
  function beatAt(t, reduced, startedAt) {
    const at = reduced ? 0 : t;
    const origin = Number.isFinite(startedAt) ? startedAt : 0;
    const elapsed = reduced ? 0 : Math.max(0, at - origin);
    return {
      t: elapsed,
      elapsed,
      // Which pose the hands are on. Milliseconds rather than seconds so the
      // arithmetic is exact at the cadence the gate samples at. It advances on
      // the shot clock and never on a clock of its own, so a rest does not
      // freeze the phase — the hands simply are not drawn from it while the
      // person is reading, and pick the loop up where the clock got to.
      typing: Math.floor((elapsed * 1000) / TYPE_MS) % TYPE_FRAMES,
      // Whether this second is one of the working ones.
      burst: reduced ? true : burstAt(elapsed),
      // And which breath a waiting worker is on.
      waiting: Math.floor((elapsed * 1000) / WAIT_MS) % WAIT_FRAMES,
      // The cursor, lit half the time. Lit in a still room rather than dark:
      // reduced motion is a room standing still, not a room switched off.
      blink: reduced ? true : (Math.floor((elapsed * 1000) / BLINK_MS) & 1) === 0,
      // One deliberate move per room hold. An epoch-anchored triangle can hit
      // its turning point anywhere in a six-frame contact sheet, which makes a
      // continuous push read as a jump. Starting with the shot makes every
      // capture travel in the same direction, then the lens simply holds.
      push: Math.min(1, elapsed / 12),
      // The CRT sweep shares that shot clock. It crosses several authored
      // pixels between gate samples, slowly enough to be followed tile to tile.
      scan: Math.floor(elapsed * 4) % (SCREEN.h + 8) - 4,
      glow: reduced ? 1 : 0.5 + 0.5 * Math.sin(elapsed * 1.7),
      tube: reduced ? 1 : 0.5 + 0.5 * Math.sin(elapsed * 0.9 + 1),
    };
  }

  // --- the feed -----------------------------------------------------------
  // What the tube says NOW: the tail of the run's own feed.log, which the
  // snapshot has been carrying all along — tool calls, thoughts, the reviewer's
  // diff hunks, `{t, text, src}` a line. The room does not interpret a line and
  // does not colour it by meaning; it draws it, the way a terminal would.
  //
  // Four rows of sixteen characters is what a 68 px tube holds at a four-pixel
  // advance, so a line has to earn its width. Three steps, in this order:
  //
  //   the leading marker comes off — the log's own source glyphs are not
  //     letters, and the 3x5 mark drawn beside the row in the crew tint says the
  //     same thing in three pixels
  //   look-alikes normalise — an em dash IS a hyphen at this size, a backslash
  //     is a slash, a curly quote is a quote; the face carries one of each
  //   a path collapses to its basename, but only if the line does not otherwise
  //     fit — EDIT SRC/INVOICES/EXPORT.TS becomes EDIT EXPORT.TS, because the
  //     file name is the part somebody three metres away needs and a
  //     head-truncated path is the one part it would lose
  //
  // and only then is what is left cut. Uppercase throughout: the face has no
  // lowercase, and that IS the terminal look rather than a compromise with it.
  const FEED_TAIL = 8;              // carried in the view
  const FEED_ROWS = 4;              // and drawn on the tube
  const FEED_MARK = 3;              // the source mark's cell, at the left edge
  const FEED_W = SCREEN.w - FEED_MARK - 1;
  const FEED_CELLS = cells(SMALL, FEED_W);
  const FEED_TOP = 12;              // under the stage word and its rule
  const FEED_PITCH = 6;             // five rows of glyph, one of air
  // And the progress ticks, on the last two rows of the tube with one row of air
  // above them. Butted straight against the log they read as an underline to the
  // newest line rather than as the bar they are.
  const FEED_TICKS = 36;
  // A row a step, not a pixel a step: this is a terminal, and a terminal
  // scrolls by lines. 120 ms is fast enough that a burst of four lines is one
  // movement rather than four events.
  const SCROLL_MS = 120;
  // And the newest line arrives a character at a time, at about the rate the
  // hands beside it are working. Pure arithmetic on how long ago the line
  // landed, so nothing can show a character before its second.
  const REVEAL_CPS = 28;
  const revealed = (chars, since) =>
    Math.max(0, Math.min(chars, Math.floor(Math.max(0, since) * REVEAL_CPS)));

  const MARKER = /^[^\x20-\x7e]+\s*/;
  const LOOKALIKE = {
    '—': '-', '–': '-', '−': '-', '·': '.', '•': '.',
    '…': '.', '\\': '/', '`': '\'', '‘': '\'', '’': '\'',
    '“': '"', '”': '"',
  };
  const LOOKALIKES = /[—–−·•…\\`‘’“”]/g;
  const basename = (str) => str.replace(/\S*\/\S*/g, (token) =>
    token.slice(token.lastIndexOf('/') + 1) || token);

  function lineOf(entry) {
    const raw = entry && typeof entry === 'object' ? entry : {};
    const original = String(raw.text || '');
    const source = String(raw.src || '');
    const time = String(raw.t || '');
    let text = original.replace(MARKER, '').toUpperCase()
      .replace(LOOKALIKES, (ch) => LOOKALIKE[ch]);
    if (widthOf(SMALL, text) > FEED_W) text = basename(text);
    return {
      // Identity is made from the full source line, before the tube shortens it.
      // Two patch lines can share a timestamp, source and sixteen-cell prefix;
      // treating their displayed forms as identity would silently drop the
      // second one when the next snapshot arrives.
      key: JSON.stringify([time, source, original]),
      t: time,
      src: source,
      mark: markOf(source),
      text: fit(SMALL, text, FEED_W),
    };
  }

  const keyOf = (row) => row.key;

  // --- the view -----------------------------------------------------------
  // Everything the room needs about a run, and nothing else: the page hands
  // this over, the room never reaches for a snapshot.
  function viewOf(run, floors) {
    const ladder = Array.isArray(floors) && floors.length ? floors : ['SETUP'];
    const alarm = run.state === 'alarm';
    return {
      id: (run.id || '').toUpperCase(),
      repo: (run.projectLabel || run.project || 'UNCHARTED').toUpperCase(),
      floorName: (run.floorName || ladder[0]).toUpperCase(),
      floor: Math.max(0, Math.min(ladder.length - 1, run.floor || 0)),
      floors: ladder.length,
      actorKey: run.actorKey || 'unknown',
      // The server owns stage/floor attribution. In an alarm actorKey is the
      // red status light, while workActorKey is the person behind the alert.
      workActorKey: run.workActorKey || (alarm ? 'unknown' : run.actorKey) || 'unknown',
      actor: (run.actor || '').toUpperCase(),
      owner: (run.owner || '').toUpperCase(),
      // The same name twice, because the room says it and looks it up: the
      // plate draws the loud one, crew.json is keyed by the quiet one.
      ownerKey: String(run.owner || '').trim().toLowerCase(),
      crew: snap(run.crew || '#e8cfa6'),
      alarm,
      // The monitor's headline. A run asking for a human says so instead of
      // naming a stage nobody is working on.
      word: alarm ? 'NEEDS INPUT' : (run.floorName || ladder[0]).toUpperCase(),
      // And the work itself, in the run's own words. A few more lines than the
      // tube shows, so the room can tell an appended line from a re-sent one
      // across two snapshots.
      feed: (Array.isArray(run.feed) ? run.feed : []).slice(-FEED_TAIL).map(lineOf),
    };
  }

  // What the person at the desk is tinted with: an actor neon, always — the same
  // colour that run's car is lit with out in the city. Never stone (which says
  // "this person is scenery" about the one person the shot is of) and never the
  // alarm red, which belongs to the things that raise the alarm.
  const tintOf = (v) => ACTOR[v.workActorKey] || SAGE;

  // --- the drawing --------------------------------------------------------

  // The room's clock when there is no rAF timestamp to hand: the same monotonic
  // origin those timestamps are measured in, so a paint from outside the loop
  // and a paint from inside it can be compared. Never Date.now(): the page's
  // wall clock carries the server's skew, which is re-measured on every
  // snapshot and moves in both directions.
  const nowOf = () => (typeof performance === 'object' && performance && performance.now
    ? performance.now() / 1000 : 0);

  function create(opts) {
    const canvas = opts.canvas;
    const still = opts.still;
    const random = opts.random;
    const out = canvas.getContext('2d');
    canvas.width = W;
    canvas.height = H;
    out.imageSmoothingEnabled = false;

    // A 320x180 buffer, made the same way five times over.
    const buffer = () => {
      const pad = document.createElement('canvas');
      pad.width = W;
      pad.height = H;
      pad.getContext('2d').imageSmoothingEnabled = false;
      return pad;
    };

    // Draw the authored 320x180 room unchanged, then let a second 320x180
    // buffer act as the lens. Cropping whole source pixels keeps every edge
    // hard while allowing the shot to push toward the monitor.
    const sceneCanvas = buffer();
    const sceneCtx = sceneCanvas.getContext('2d');

    // The three planes that are facts about the room and the run rather than
    // about the clock: the wall behind everything, the window/plate/floor/desk
    // over the city, and the nameplate and near plane over the people. They are
    // drawn ONCE per run and composited afterwards, because redrawing forty
    // rectangles of wall grain sixty times a second to show the same wall is
    // work with no picture in it. The beat-driven layers go between them.
    const plateBack = buffer();
    const plateMid = buffer();
    const plateFront = buffer();
    let baked = '';

    // Everything below draws through `ctx`, so baking a plane is a matter of
    // pointing it at that plane for the length of one call.
    let ctx = sceneCtx;
    function bake(pad, draw) {
      const was = ctx;
      ctx = pad.getContext('2d');
      ctx.clearRect(0, 0, W, H);
      draw();
      ctx = was;
    }

    // One offscreen buffer the size of a character sprite. The actor tint is
    // painted onto the worker there — source-atop on the room itself would
    // repaint the wall behind them.
    const tintPad = document.createElement('canvas');
    tintPad.width = 64;
    tintPad.height = 64;
    const tintCtx = tintPad.getContext('2d');
    tintCtx.imageSmoothingEnabled = false;

    const art = {};             // the furniture, by key
    const cast = {};            // and the people, by set name then frame name
    let crew = {};              // crew.json, once it has answered
    let roster = false;         // whether it has answered at all, either way
    let expected = 0;           // files asked for; the roster adds to this once
    let answered = 0;           // and how many have come back, either way
    let ready = false;
    let broken = false;
    let view = null;
    let running = false;
    let raf = 0;
    let scale = 1;
    let stamp = 0;            // the frame time this room last drew at, in seconds
    let startedAt = null;     // and the one the hold on screen began at

    // The tube's own state, and the only thing in this room that is not a pure
    // function of the clock: lines ARRIVE. `rows` is what is on the screen,
    // `queue` is what has landed and is still scrolling in a row at a time, and
    // `mostRecent` is how the next snapshot tells the one appended line from the
    // forty-seven it re-sent.
    //
    // Two anchors, both on the frame clock and neither on the shot's origin,
    // because a snapshot can append a line at any second of a hold and the
    // reveal has to start THERE. What they must never do is move the hands: the
    // burst schedule is arithmetic on `elapsed` from startedAt, and an arriving
    // line can force the hands to be working (they are typing what appears) but
    // cannot re-time a single pose of the cycle they are on.
    let rows = [];
    let queue = [];
    let mostRecent = '';
    let feedRun = null;
    let stepAt = 0;           // the frame time the next row may scroll in at
    let revealAt = 0;         // and the one the newest row began revealing at

    // Ready means every file this room decided to ask for is in AND the roster
    // has said who there is to ask for. Counting alone would light the room the
    // moment the furniture landed, which on a fast disk is before crew.json has
    // even come back: a lit room with nobody at the desk.
    function settle() {
      if (ready || broken || !roster || answered < expected) return;
      ready = true;
      canvas.dataset.ready = '1';
      paint();
    }

    // `set` names the character set this file belongs to, and is left off for
    // the furniture. Every file answers exactly once, whether it arrived or
    // not, so dropping a set never leaves the count waiting on it.
    function image(src, set) {
      const img = new Image();
      expected++;
      const answer = () => { answered++; settle(); };
      img.addEventListener('load', answer);
      img.addEventListener('error', () => {
        console.error('room: cannot load ' + img.src);
        // The furniture, and the set every unknown owner falls back to, ARE the
        // room: without them there is nothing to draw, so the loop stops rather
        // than spinning on a room that can never draw and the wide city
        // underneath is left untouched.
        if (set === undefined || set === FALLBACK) {
          broken = true;
          stop();
          return;
        }
        // A crew set is one person. Drop it and its owners sit down as the
        // worker this room drew for everybody before anyone had a face — an
        // empty chair for one dispatcher is not worth the whole room. The
        // server only ever puts a complete set on the roster, so reaching here
        // means the file went missing while the wall was up.
        delete cast[set];
        answer();
      });
      img.src = src;
      return img;
    }

    for (const key of Object.keys(PROPS)) art[key] = image('assets/room/' + PROPS[key]);

    // Who there is to draw. Every set the roster names is loaded up front
    // rather than when its owner's run arrives: a set is seventeen 64x64
    // sprites of a dozen colours each, the whole roster is still smaller than
    // one of the desks, and a room that fetched a face mid-dive would show an
    // empty chair for as long as that took. Loading only the cycle in play
    // would trade that for an empty chair the moment a run blocks. The
    // server has already dropped any set whose sprites are not on the disk, so
    // what arrives here is a list of people this room can definitely draw.
    //
    // A wall that cannot read crew.json is not a broken wall. It is a wall
    // where everybody is the worker this room drew before anyone had a face, so
    // the failure path registers the room's own set and nothing else.
    function register(table) {
      if (roster) return;
      crew = table && typeof table === 'object' ? table : {};
      const sets = new Set([FALLBACK]);
      for (const owner of Object.keys(crew)) sets.add(setOf(crew, owner));
      for (const set of sets) {
        cast[set] = {};
        for (const frame of FRAMES) cast[set][frame] = image(fileOf(set, frame), set);
      }
      roster = true;
      settle();
    }

    fetch('crew.json', { cache: 'no-store' })
      .then((res) => (res.ok ? res.json() : null))
      .then(register, () => register(null));

    // The city outside, dealt once off a fixed seed: the same skyline every
    // time this wall opens, on every screen in the room, because a window that
    // reshuffles itself between two frames is not a window.
    const CITY = (() => {
      const draw = random(0x5109);
      const blocks = [];
      let x = -4;
      while (x < HOLE.w + 4) {
        const w = 5 + Math.floor(draw() * 9);
        const h = 11 + Math.floor(draw() * 21);
        const lights = [];
        for (let ly = 2; ly < h - 1; ly += 3) {
          for (let lx = 1; lx < w - 1; lx += 3) {
            if (draw() < 0.5) lights.push({ x: lx, y: ly, warm: draw() < 0.62, phase: draw() });
          }
        }
        blocks.push({ x, w, h, lights, depth: draw() < 0.4 ? 0 : 1 });
        x += w + 1 + Math.floor(draw() * 2);
      }
      const drops = [];
      for (let i = 0; i < 26; i++) {
        drops.push({ x: draw() * (HOLE.w + 12) - 8, off: draw(), len: 3 + Math.floor(draw() * 4) });
      }
      return { blocks, drops };
    })();

    // --- primitives -------------------------------------------------------
    // Whole pixels, always. Rounding here rather than at forty call sites is
    // what keeps every edge in this room hard.
    function box(x, y, w, h, colour, alpha) {
      if (w <= 0 || h <= 0) return;
      ctx.globalAlpha = alpha === undefined ? 1 : alpha;
      ctx.fillStyle = colour;
      ctx.fillRect(Math.round(x), Math.round(y), Math.round(w), Math.round(h));
      ctx.globalAlpha = 1;
    }

    function sprite(img, x, y, flip) {
      if (!img.complete || !img.naturalWidth) return;
      if (!flip) { ctx.drawImage(img, Math.round(x), Math.round(y)); return; }
      ctx.save();
      ctx.translate(Math.round(x) + img.naturalWidth, Math.round(y));
      ctx.scale(-1, 1);
      ctx.drawImage(img, 0, 0);
      ctx.restore();
    }

    // A sprite tiled across a band, clipped to it. The wall and the floor are
    // grain over a flat value — the flat value is what reads from three metres,
    // the grain is what stops it looking like a swatch.
    function tile(img, x, y, w, h, alpha) {
      if (!img.complete || !img.naturalWidth) return;
      ctx.save();
      ctx.beginPath();
      ctx.rect(x, y, w, h);
      ctx.clip();
      ctx.globalAlpha = alpha;
      for (let ty = y; ty < y + h; ty += img.naturalHeight) {
        for (let tx = x; tx < x + w; tx += img.naturalWidth) ctx.drawImage(img, tx, ty);
      }
      ctx.restore();
      ctx.globalAlpha = 1;
    }

    // Light, banded. A stack of flat rectangles widening away from the source:
    // three steps is a lamp, a gradient is a render.
    function spill(cx, top, bottom, half, colour, alpha) {
      const steps = 3;
      for (let i = 0; i < steps; i++) {
        const t0 = top + ((bottom - top) * i) / steps;
        const t1 = top + ((bottom - top) * (i + 1)) / steps;
        const w = half * (0.45 + (0.55 * (i + 1)) / steps);
        box(cx - w, t0, w * 2, t1 - t0, colour, alpha * (1 - i * 0.28));
      }
    }

    // One cell of a face, or one of the two source marks — the same pixel loop
    // either way, because a mark IS a glyph that no string can spell.
    function shape(rows, x, y) {
      for (let r = 0; r < rows.length; r++) {
        const line = rows[r];
        for (let c = 0; c < line.length; c++) {
          if (line[c] === '#') ctx.fillRect(x + c, y + r, 1, 1);
        }
      }
    }

    function text(face, str, x, y, colour, alpha) {
      const rows = face.rows;
      ctx.globalAlpha = alpha === undefined ? 1 : alpha;
      ctx.fillStyle = colour;
      let cursor = Math.round(x);
      for (const ch of str) {
        shape(rows[ch] || rows[' '], cursor, Math.round(y));
        cursor += face.pitch;
      }
      ctx.globalAlpha = 1;
    }

    function mark(name, x, y, colour, alpha) {
      if (!MARKS[name]) return;
      ctx.globalAlpha = alpha === undefined ? 1 : alpha;
      ctx.fillStyle = colour;
      shape(MARKS[name], Math.round(x), Math.round(y));
      ctx.globalAlpha = 1;
    }

    const centred = (face, str, cx, y, colour, alpha) =>
      text(face, str, cx - Math.floor(widthOf(face, str) / 2), y, colour, alpha);

    // --- the planes -------------------------------------------------------

    function backWall() {
      // The wall is part of the same blue-black night as the city. Keep its
      // authored tile as surface grain, not as a mid-value colour field: the
      // lamp and monitor are the only things allowed to lift this plane.
      box(0, 0, W, FLOOR_Y, STONE);
      // Grain, not pattern. The tile is what stops a flat value reading as a
      // swatch; anything past a whisper of it and the back plane starts
      // competing with the desk, which is the one thing on this wall that has
      // to be looked at.
      tile(art.wall, 0, SOFFIT, W, FLOOR_Y - SOFFIT, 0.05);
      box(0, SOFFIT, W, FLOOR_Y - SOFFIT, NIGHT, 0.28);
      // Panel joints. The wall is a built thing, and a seam every two modules
      // is what says so without adding a single object to the room.
      for (let x = 0; x <= W; x += 32) box(x, SOFFIT, 1, FLOOR_Y - SOFFIT, STONE, 0.8);
      box(0, 64, W, 1, STONE, 0.6);
      box(0, 65, W, 1, LIT, 0.3);
      // The conduit run, at ceiling height where nothing else is standing: one
      // horizontal that says this is a working building, clipped at intervals,
      // and then the wall is left alone. An empty wall over a desk is the room
      // breathing, not the room missing something.
      box(0, 18, W, 4, WARM);
      box(0, 18, W, 1, STEEL, 0.5);
      box(0, 21, W, 1, NIGHT, 0.55);
      for (let x = 10; x < W; x += 34) box(x, 16, 3, 8, STEEL, 0.5);
      // Nothing is lighting the far corners, so nothing pretends to be. Three
      // flat steps in from each edge — banded, like every other light in here.
      for (let i = 0; i < 3; i++) {
        box(0, 0, 26 - i * 8, FLOOR_Y, NIGHT, 0.16);
        box(W - (30 - i * 9), 0, 30 - i * 9, FLOOR_Y, NIGHT, 0.14);
      }
      // Skirting, and the shadow the floor throws back up the wall.
      box(0, FLOOR_Y - 6, W, 5, LIT, 0.75);
      box(0, FLOOR_Y - 6, W, 1, STEEL, 0.5);
      box(0, FLOOR_Y - 1, W, 1, NIGHT, 0.7);
      // The ceiling, and the strip light nobody has replaced. One dead tube is
      // why the room is lit by a lamp and a monitor at all.
      box(0, 0, W, SOFFIT, NIGHT);
      box(0, SOFFIT, W, 1, STONE);
      box(112, 5, 96, 3, WARM, 0.8);
    }

    // The one line of the ceiling that is on the clock: the failing tube's own
    // highlight, drawn over the baked wall. Nothing else reaches this band, so
    // it lands exactly where it did when it was the last line of backWall().
    function stripLight(beat) {
      box(112, 5, 96, 1, STEEL, 0.4 + 0.14 * beat.tube);
    }

    function floorPlane() {
      box(0, FLOOR_Y, W, H - FLOOR_Y, STONE);
      // Grain first, then back onto the ramp. The floor tile carries a warm step
      // (#4f4441), which is right for lino under a lamp and wrong for the plane
      // the whole lower third of the frame is made of: a warm value over a
      // blue-black one is what makes a 640x360 tile of this room read violet
      // rather than night. So the tile stays as texture at half the weight and
      // STONE puts the plane's own value back where the wall's is — one
      // night-and-stone ramp across both, which is what a room in this city is.
      tile(art.floor, 0, FLOOR_Y, W, H - FLOOR_Y, 0.09);
      box(0, FLOOR_Y, W, H - FLOOR_Y, STONE, 0.35);
      box(0, FLOOR_Y, W, H - FLOOR_Y, NIGHT, 0.3);
      // Two bands of depth rather than a perspective grid: the near floor is
      // darker because nothing is lighting it.
      box(0, FLOOR_Y, W, 7, LIT, 0.4);
      box(0, 154, W, H - 154, NIGHT, 0.45);
    }

    // The frame is metal in an unlit room and the sprite was authored at full
    // value, so it is sunk here — around the glass, never over it, because the
    // city behind it is the light this corner of the room has.
    function shadeFrame(alpha) {
      const right = HOLE.x + HOLE.w;
      const under = HOLE.y + HOLE.h;
      box(WINDOW.x, WINDOW.y, 112, HOLE.y - WINDOW.y, NIGHT, alpha);
      box(WINDOW.x, under, 112, WINDOW.y + 72 - under, NIGHT, alpha);
      box(WINDOW.x, HOLE.y, HOLE.x - WINDOW.x, HOLE.h, NIGHT, alpha);
      box(right, HOLE.y, WINDOW.x + 112 - right, HOLE.h, NIGHT, alpha);
    }

    // What the window puts in the room. A cold slab on the wall beside it and a
    // second one on the floor under it: the city outside is a light source, and
    // a window that lit nothing would be a picture hung on a wall.
    function windowLight() {
      const b = { x: HOLE.x - 4, w: HOLE.w + 8 };
      box(b.x, HOLE.y + HOLE.h, b.w, 14, CYAN, 0.05);
      box(b.x + 4, HOLE.y + HOLE.h + 14, b.w - 8, 12, CYAN, 0.035);
      box(b.x - 6, FLOOR_Y, b.w + 12, 8, CYAN, 0.07);
      box(b.x - 2, FLOOR_Y + 8, b.w + 4, 8, CYAN, 0.045);
    }

    function nightCity(beat) {
      box(HOLE.x, HOLE.y, HOLE.w, HOLE.h, NIGHT);
      ctx.save();
      ctx.beginPath();
      ctx.rect(HOLE.x, HOLE.y, HOLE.w, HOLE.h);
      ctx.clip();
      // The cloud ceiling the city lights from underneath — the same glow the
      // wide shot paints over its own skyline, banded down in three steps.
      box(HOLE.x, HOLE.y + HOLE.h - 26, HOLE.w, 26, STONE, 0.6);
      box(HOLE.x, HOLE.y + HOLE.h - 17, HOLE.w, 17, MOSS, 0.16);
      box(HOLE.x, HOLE.y + HOLE.h - 9, HOLE.w, 9, MOSS, 0.16);
      for (const b of CITY.blocks) {
        const top = HOLE.y + HOLE.h - b.h;
        box(HOLE.x + b.x, top, b.w, b.h, b.depth ? MID : STONE);
        box(HOLE.x + b.x, top, b.w, 1, b.depth ? LIT : MID);
        for (const l of b.lights) {
          // The same window colours the city is lit with, breathing on the wall
          // clock so the view is never a photograph.
          const on = 0.55 + 0.45 * Math.sin((beat.t / 9 + l.phase) * Math.PI * 2);
          box(HOLE.x + b.x + l.x, top + l.y, 1, 2, l.warm ? WORK : CYAN, 0.42 + 0.5 * on);
        }
      }
      // Rain, from the dry side of the glass.
      for (const d of CITY.drops) {
        const travel = HOLE.h + d.len;
        const distance = ((d.off * travel + beat.t * RAIN_SPEED) % travel + travel) % travel;
        const y = distance - d.len;
        // Every streak shares one velocity. Its seed chooses only where it is
        // on that vector, so consecutive frames show rain falling rather than
        // a new scatter of bright pixels.
        box(HOLE.x + d.x + distance * 0.18, HOLE.y + y, 1, d.len, ICE, 0.26);
      }
      ctx.restore();
      // The glass itself: what the room leaves on it, and the sill's wet edge.
      box(HOLE.x, HOLE.y, HOLE.w, HOLE.h, CYAN, 0.045);
      box(HOLE.x, HOLE.y + HOLE.h - 1, HOLE.w, 1, MINT, 0.3);
    }

    // The floor the run has climbed to, as the plate beside a lift. Six pips,
    // one lit — the same ladder the tower's cars climb outside.
    function floorPlate(v) {
      // This plate reports a floor, not an alert. A blocked run already owns
      // the monitor, so its plate stays neutral instead of making a second red
      // object on the wall.
      const tint = v.alarm ? BONE : ACTOR[v.actorKey] || SAGE;
      box(PLATE.x - 1, PLATE.y - 1, PLATE.w + 2, PLATE.h + 2, NIGHT, 0.55);
      box(PLATE.x, PLATE.y, PLATE.w, PLATE.h, LIT);
      box(PLATE.x, PLATE.y, PLATE.w, 1, STEEL);
      box(PLATE.x, PLATE.y + PLATE.h - 1, PLATE.w, 1, NIGHT, 0.6);
      box(PLATE.x, PLATE.y, 2, PLATE.h, tint, 0.85);
      const number = String(v.floor + 1).padStart(2, '0');
      text(BIG, number, PLATE.x + 7, PLATE.y + 6, BONE, 0.92);
      text(SMALL, fit(SMALL, v.floorName, PLATE.w - 26), PLATE.x + 24, PLATE.y + 7, MINT, 0.8);
      for (let i = 0; i < v.floors; i++) {
        const on = i === v.floor;
        box(PLATE.x + 24 + i * 6, PLATE.y + 18, 4, 3, on ? tint : STEEL, on ? 0.95 : 0.7);
      }
    }

    // What the snapshot brought. Called from paint, so it is cheap and
    // idempotent by construction: with nothing new the loop below finds the last
    // line it already has and queues nothing.
    function feedIn(v, at) {
      const lines = v.feed;
      if (feedRun !== v.id) {
        // A new run is a new screen. Whatever the last one was saying goes,
        // including a reveal that was half way through a sentence nobody on this
        // ticket wrote.
        feedRun = v.id;
        rows = lines.slice(-FEED_ROWS);
        queue = [];
        mostRecent = lines.length ? keyOf(lines[lines.length - 1]) : '';
        revealAt = at;
        stepAt = at;
        return;
      }
      if (!lines.length) return;
      let from = Math.max(0, lines.length - FEED_ROWS);
      if (mostRecent) {
        for (let i = lines.length - 1; i >= 0; i--) {
          if (keyOf(lines[i]) === mostRecent) { from = i + 1; break; }
        }
      }
      for (let i = from; i < lines.length; i++) queue.push(lines[i]);
      if (!queue.length) return;
      queue = queue.slice(-FEED_TAIL);
      mostRecent = keyOf(queue[queue.length - 1]);
      if (stepAt < at) stepAt = at;
    }

    // One row per step. The clock is the frame clock, so a tab that was hidden
    // for a minute catches up over the queue rather than over the minute.
    function feedStep(at) {
      while (queue.length && at >= stepAt) {
        rows.push(queue.shift());
        if (rows.length > FEED_ROWS) rows.shift();
        revealAt = stepAt;
        stepAt += SCROLL_MS / 1000;
      }
    }

    // How much of the newest line has arrived. A still room shows it whole: a
    // reveal frozen half way through a word is a broken screen, not a still one.
    function revealOf(row) {
      if (still.matches) return row.text.length;
      return revealed(row.text.length, stamp - revealAt);
    }

    // And whether one is still arriving, which is what tells the hands to work.
    function revealing() {
      if (!rows.length) return false;
      const row = rows[rows.length - 1];
      return revealOf(row) < row.text.length;
    }

    // The log on the tube: four rows of the run's own feed, newest at the
    // bottom, older rows stepping back down the cold ramp so the eye lands on
    // the newest without anything blinking to say so. Bottom-aligned, which is
    // what puts the newest line and the cursor in the same place whether there
    // are four lines or one.
    //
    // No colour means anything here. Red is an alarm in this palette and green
    // is a run that shipped, so a `-` and a `+` in a diff hunk are text and
    // nothing more; the only tinted thing in the block is the source mark, in
    // the crew colour the lamp already uses.
    function log(v, beat) {
      const top = SCREEN.y + FEED_TOP;
      const bottom = top + (FEED_ROWS - 1) * FEED_PITCH;
      for (let i = 0; i < rows.length; i++) {
        const row = rows[i];
        const slot = FEED_ROWS - rows.length + i;
        const y = top + slot * FEED_PITCH;
        const newest = i === rows.length - 1;
        const shown = newest ? revealOf(row) : row.text.length;
        // The mark is the only tinted thing in the block, and it steps back with
        // its row so four crew-coloured dots do not flatten the ramp the text
        // makes.
        mark(row.mark, SCREEN.x, y, v.crew, 0.55 + 0.15 * slot);
        text(SMALL, row.text.slice(0, shown), SCREEN.x + FEED_MARK + 1, y,
          FEED_INK[slot], 1);
        if (newest) {
          caret(SCREEN.x + FEED_MARK + 1 + shown * SMALL.pitch, y, beat,
            shown < row.text.length);
        }
      }
      // A run that has said nothing yet — a fixture with no feed.log, a run three
      // seconds old — gets the stage word and a cursor waiting under it. Never a
      // black tube, and never the last line of whoever was here before.
      if (!rows.length) caret(SCREEN.x + FEED_MARK + 1, bottom, beat, false);
    }

    // Solid while a line is arriving, blinking once it has landed: that is what
    // a terminal does, and it is the one thing on this screen that says the run
    // is still going while nothing else changes.
    //
    // Held inside the tube. A line that fills all sixteen cells puts the cursor's
    // own cell one past the right edge, where it would be drawn on the bezel; the
    // last column of the tube is the one column no glyph reaches, so that is
    // where it goes instead.
    function caret(x, y, beat, arriving) {
      if (!arriving && !beat.blink) return;
      box(Math.min(x, SCREEN.x + SCREEN.w - 1), y, 1, SMALL.h, PALE, 0.9);
    }

    // The one screen in the room, drawn rather than photographed: a chunky
    // bezel this file owns to the pixel, because the type inside it is the
    // whole reason there is a room at all.
    function monitor(v, beat) {
      const tint = v.alarm ? ALARM : CYAN;
      // What it throws on the wall behind it, and on the desk in front.
      spill(BEZEL.x + BEZEL.w / 2, BEZEL.y - 10, BEZEL.y + BEZEL.h + 6, 60, tint, 0.06 * beat.glow);
      box(BEZEL.x - 3, BEZEL.y - 3, BEZEL.w + 6, BEZEL.h + 6, NIGHT, 0.5);
      box(BEZEL.x, BEZEL.y, BEZEL.w, BEZEL.h, STEEL);
      box(BEZEL.x, BEZEL.y, BEZEL.w, 1, GREY, 0.8);
      box(BEZEL.x, BEZEL.y + BEZEL.h - 1, BEZEL.w, 1, NIGHT, 0.8);
      box(BEZEL.x + BEZEL.w - 1, BEZEL.y, 1, BEZEL.h, NIGHT, 0.5);
      // The stand, and the desk under it.
      box(202, BEZEL.y + BEZEL.h, 16, 4, WARM);
      box(192, BEZEL.y + BEZEL.h + 4, 36, 2, STEEL);
      // The tube. Never black: a monitor with nothing on it is a room with
      // nobody in it, which is the one thing this shot may not say.
      box(SCREEN.x, SCREEN.y, SCREEN.w, SCREEN.h, v.alarm ? RUST : STONE);
      box(SCREEN.x, SCREEN.y, SCREEN.w, 1, tint, 0.25);
      const cx = SCREEN.x + SCREEN.w / 2;
      const bright = 0.86 + 0.14 * beat.glow;
      const room = SCREEN.w - 4;
      if (v.alarm) {
        // Untouched, on purpose. This is the one screen in the room that has to
        // be read from three metres by somebody who has just walked in, and its
        // four lines already use every row: NEEDS and INPUT are seven pixels
        // each, the id and the repo five, and what is left under the repo is two
        // rows — three short of one line of the small face. So the log does not
        // appear here. A blocked run's work is what it said before it stopped,
        // and the ticker along the bottom of the wall is still saying it.
        centred(BIG, 'NEEDS', cx, SCREEN.y + 4, ALARM, bright);
        centred(BIG, 'INPUT', cx, SCREEN.y + 13, ALARM, bright);
        centred(SMALL, fit(SMALL, v.id, room), cx, SCREEN.y + 24, GLOW, 0.95);
        centred(SMALL, fit(SMALL, v.repo, room), cx, SCREEN.y + 31, EMBER, 0.8);
      } else {
        // The stage, then the work. The id and the repo used to sit under the
        // headline and they are gone from here: the id is already on the wall
        // plate and on the tower's own sign out in the city, said twice, while
        // the four rows of feed under this line were said nowhere at all.
        centred(BIG, fit(BIG, v.word, room), cx, SCREEN.y + 4, PALE, bright);
        box(SCREEN.x + 2, SCREEN.y + 11, SCREEN.w - 4, 1, tint, 0.3);
        log(v, beat);
        // The last row is the progress the wall plate reports too — a row of
        // ticks that fills to the floor this run has reached. It stays because it
        // fits under four rows of log, in the rows the log does not use.
        const done = Math.round(((v.floor + 1) / v.floors) * 15);
        for (let i = 0; i < 15; i++) {
          box(SCREEN.x + 4 + i * 4, SCREEN.y + FEED_TICKS, 3, 2,
            i < done ? tint : STEEL, i < done ? 0.8 : 0.6);
        }
      }
      // Scanlines, at the room's own scale: one dark row in three.
      for (let y = SCREEN.y; y < SCREEN.y + SCREEN.h; y += 3) {
        box(SCREEN.x, y, SCREEN.w, 1, NIGHT, 0.16);
      }
      // One brighter retrace travels down the tube. Unlike a flicker it has a
      // position that can be followed across the contact sheet.
      const scanY = SCREEN.y + beat.scan;
      if (scanY >= SCREEN.y && scanY < SCREEN.y + SCREEN.h) {
        box(SCREEN.x + 1, scanY, SCREEN.w - 2, 1, PALE, 0.24);
      }
    }

    // The dispatcher, in the only two places the wide city lets crew colour
    // appear: the lamp under the work, and the name in type.
    function lamp(v, beat) {
      // Warm first. The lamp is the only light in this room somebody chose to
      // switch on, so it gets the biggest pool and the wall behind it keeps a
      // little of it.
      box(28, DESK_Y - 74, 92, 74, v.crew, 0.035);
      box(38, DESK_Y - 56, 72, 56, v.crew, 0.05);
      box(48, DESK_Y - 34, 50, 34, v.crew, 0.06);
      sprite(art.lamp, LAMP.x, LAMP.y);
      box(LAMP.x + 4, LAMP.y + 16, 10, 4, v.crew, 0.6);
      spill(LAMP.x + 12, LAMP.y + 20, DESK_Y + 4, 30, v.crew, 0.13 * (0.85 + 0.15 * beat.tube));
      // And the pool it lays across the desk top itself.
      box(46, DESK_Y, 62, 2, v.crew, 0.3);
      box(52, DESK_Y + 2, 50, 2, v.crew, 0.14);
    }

    // The two colour systems the wide city keeps apart, side by side on the desk
    // front where a nameplate goes: WHO is running this stage, in the actor
    // neon the worker behind it is tinted with, and WHO DISPATCHED it, in their
    // crew tint — the same pairing the brief plate makes outside.
    function nameplate(v) {
      let x = 96;
      const chip = (label, colour) => {
        if (!label) return;
        const w = widthOf(SMALL, fit(SMALL, label, 76)) + 8;
        box(x, 137, w, 11, NIGHT, 0.6);
        box(x, 137, w, 1, STEEL, 0.55);
        box(x, 137, 1, 11, colour, 0.7);
        text(SMALL, fit(SMALL, label, 76), x + 4, 140, colour, 0.95);
        x += w + 4;
      };
      chip(v.actor, v.alarm ? BONE : ACTOR[v.actorKey] || SAGE);
      chip(labelOf(crew, v), v.crew);
    }

    // The silhouette of one sprite, row by row: the leftmost and rightmost
    // opaque pixel of each row, or [-1, -1] for an empty one. Read once per
    // image and kept, because a sprite's outline never changes — a getImageData
    // every frame is a readback the room has no reason to pay for.
    const outlines = new WeakMap();
    const edgePad = document.createElement('canvas');
    edgePad.width = 64;
    edgePad.height = 64;
    const edgeCtx = edgePad.getContext('2d', { willReadFrequently: true });
    edgeCtx.imageSmoothingEnabled = false;

    function outlineOf(img) {
      let rows = outlines.get(img);
      if (rows) return rows;
      edgeCtx.clearRect(0, 0, 64, 64);
      edgeCtx.drawImage(img, 0, 0);
      const px = edgeCtx.getImageData(0, 0, 64, 64).data;
      rows = [];
      for (let y = 0; y < 64; y++) {
        let left = -1;
        let right = -1;
        for (let x = 0; x < 64; x++) {
          if (px[(y * 64 + x) * 4 + 3] < 128) continue;
          if (left < 0) left = x;
          right = x;
        }
        rows.push([left, right]);
      }
      outlines.set(img, rows);
      return rows;
    }

    // A rim of light down that silhouette, on the tint pad, after the wash.
    //
    // The head this room pins is the base's own band, which is the darkest thing
    // in the set, and against a back wall of nearly the same value it merges: a
    // critic reading the close frames preferred the champion for exactly that,
    // and it is the one thing about the pin that measuring could not have caught.
    // So the edge pixels catch the two lights this room actually has — the
    // monitor down the right side, the lamp down the left.
    //
    // ON the edge pixel, never outside it. A pixel painted outside the
    // silhouette is an outline, and nothing in this room is outlined; a pixel
    // painted on it is light. And the rim runs the WHOLE figure rather than
    // stopping at the split, because an edge that is lit above a row and unlit
    // below it is the seam this run exists to remove, drawn in light.
    //
    // Warm is the palette's own lamp colour rather than the crew tint: the wide
    // city allows crew colour in two places, the lamp and the name in type, and
    // a third would make it decoration.
    const RIM_COLD = 0.34;
    const RIM_WARM = 0.24;

    function rim(head, body, split) {
      const above = outlineOf(head);
      const below = outlineOf(body);
      for (let y = 0; y < 64; y++) {
        const row = y < split ? above[y] : below[y];
        if (row[0] < 0) continue;
        tintCtx.globalAlpha = RIM_COLD;
        tintCtx.fillStyle = CYAN;
        tintCtx.fillRect(row[1], y, 1, 1);
        tintCtx.globalAlpha = RIM_WARM;
        tintCtx.fillStyle = GLOW;
        tintCtx.fillRect(row[0], y, 1, 1);
      }
      tintCtx.globalAlpha = 1;
    }

    // Who is working, and which model they are. The tint is the run's actor
    // neon — the same colour that run's car is lit with out in the city, so a
    // dive from the wide shot lands on a figure the room already recognises.
    // ONE rule, for every state: waiting is a pose, not a second colour system.
    // A blocked run's operator kept getting painted stone, which said "this
    // person is scenery" about the one person the shot is of, and it is not
    // what the wide city does either — out there the blocked car keeps its
    // light. The alarm is loud on the alert sources (the monitor, the wash it
    // throws) and nowhere else; the jacket stays the actor's own.
    function worker(v, beat, typing) {
      // Whose desk this is. A set the roster named but that is not in hand —
      // which only happens before the roster answers — falls back rather than
      // leaving the chair empty.
      let set = setOf(crew, v.ownerKey);
      if (!cast[set]) set = FALLBACK;
      const who = cast[set];
      if (!who) return;
      const bands = bandsOf(set, beat, v.alarm, typing);
      const head = who[bands.head];
      const body = who[bands.body];
      if (!head || !body) return;
      if (!head.complete || !head.naturalWidth || !body.complete || !body.naturalWidth) return;
      const tint = tintOf(v);
      // The figure, in two bands. Everything above the split is the base at
      // every frame of every cycle; only the band below it is the cycle's own.
      //
      // This is the whole answer to "the movement feels wrong". Ask a generator
      // to move two hands and it regenerates the whole picture: between two
      // consecutive poses of the four-frame loop this replaced, 10-21 % of the
      // sprite's pixels changed — the hood, the headphones, the shoulders and
      // the jacket outline all reflowing — while the hands themselves barely
      // travelled. A person who jitters in place three times a second while
      // their hands hold still is not typing, and no cadence fixes that. So the
      // still parts are made still HERE, where it costs nothing, and the frames
      // are spent entirely on the band that is supposed to move.
      //
      // The band is CLEARED before it is drawn rather than drawn over: the base
      // is wider than some frames in places, and a base pixel left showing
      // through a frame's transparent one is a double outline.
      tintCtx.clearRect(0, 0, 64, 64);
      tintCtx.drawImage(head, 0, 0);
      tintCtx.clearRect(0, bands.split, 64, 64 - bands.split);
      tintCtx.drawImage(body, 0, bands.split, 64, 64 - bands.split,
        0, bands.split, 64, 64 - bands.split);
      tintCtx.globalCompositeOperation = 'source-atop';
      // A wash light enough that the figure keeps its own shading — the tint
      // says which model this is, it does not repaint the person.
      tintCtx.globalAlpha = 0.11;
      tintCtx.fillStyle = tint;
      tintCtx.fillRect(0, 0, 64, 64);
      // And a rim down the side the monitor is on, which is where the light
      // actually is.
      tintCtx.globalAlpha = 0.2;
      tintCtx.fillRect(48, 0, 16, 64);
      tintCtx.globalAlpha = 1;
      tintCtx.globalCompositeOperation = 'source-over';
      rim(head, body, bands.split);
      // The shadow they sit in, then the figure, in one piece and on one origin.
      // The band used to be drawn a pixel lower on alternate beats to fake some
      // travel the four frames did not have; the eight carry their own, and two
      // sources of motion on the same hands read as a twitch.
      box(WORKER.x + 2, DESK_Y - 3, 60, 4, NIGHT, 0.45);
      ctx.drawImage(tintPad, WORKER.x, WORKER.y);
    }

    // The near plane. Nothing here is a fact — it is the room's own depth, and
    // it is drawn dark on purpose: an asset is authored at full value and the
    // renderer is what veils it.
    function nearPlane() {
      sprite(art.shelf, 267, 99);
      box(262, 96, W - 262, H - 96, NIGHT, 0.76);
      box(0, 0, PILLAR, H, NIGHT, 0.9);
      box(PILLAR - 1, 0, 1, H, STEEL, 0.45);
      box(PILLAR, 0, 3, H, NIGHT, 0.35);
      // The frame's own falloff, top and bottom, so the eye lands on the desk.
      box(0, 0, W, 6, NIGHT, 0.35);
      box(0, H - 5, W, 5, NIGHT, 0.4);
    }

    // The floor in front of the desk, catching what the two lights spill past
    // it. Without this the bottom fifth of the frame is a black band and the
    // room stops being a room at the kerb.
    function floorLight(v, beat) {
      // The screen's light on the floor. It used to be two wide slabs of the
      // tube's own colour at a tenth of an alpha, which for an alarm is the
      // reddest colour on the lock thinned over blue-black — and thinned, red
      // does not read as red light on night, it MIXES with it. The two slabs
      // measured hue 318 and 277: a violet field across a sixth of the frame,
      // and the reason a 640x360 tile of this room did not read blue-black.
      //
      // So it is a POOL now, banded the way every other light in here is —
      // three flat steps widening away from the source, narrow enough to sit
      // under the screen that casts it — and for an alarm it is the palette's
      // own deep red rather than a diluted klaxon. The bright red stays where
      // the alarm is: the tube.
      const cast = v.alarm ? RUST : CYAN;
      spill(BEZEL.x + BEZEL.w / 2, DESK_END + 2, DESK_END + 20, 42,
        cast, v.alarm ? 0.7 + 0.1 * beat.glow : 0.16 + 0.06 * beat.glow);
      box(40, DESK_END + 3, 92, 9, v.crew, 0.1);
      box(56, DESK_END + 12, 64, 8, v.crew, 0.06);
    }

    // The three still planes, drawn once for a run and kept. The key is the view
    // itself: the hero can hand over and the stage under it can climb a floor
    // while the room is up, and both change what the plate and the nameplate
    // say — nothing else in here does.
    function bakePlanes(v) {
      // The feed is left out of the key. It lives on the tube, which is
      // repainted every frame anyway, and a snapshot that only appended one line
      // must not redraw forty rectangles of wall grain to show it.
      const key = JSON.stringify({ ...v, feed: null });
      if (key === baked) return;
      baked = key;
      bake(plateBack, backWall);
      bake(plateMid, () => {
        sprite(art.windowFrame, WINDOW.x, WINDOW.y);
        shadeFrame(0.32);
        windowLight();
        floorPlate(v);
        floorPlane();
        sprite(art.desk, 29, DESK_Y - BOX.desk.y);
        sprite(art.desk, 99, DESK_Y - BOX.desk.y, true);
        sprite(art.desk, 173, DESK_Y - BOX.desk.y);
        // The desk is furniture in an unlit room, not a light source: authored
        // at full value, sunk here, and then lit back up by the lamp and the
        // tube.
        box(56, DESK_Y, 216, DESK_END - DESK_Y, NIGHT, 0.46);
        box(56, DESK_END, 216, 3, NIGHT, 0.5);
      });
      bake(plateFront, () => {
        nameplate(v);
        nearPlane();
      });
    }

    // One frame: three baked planes, and between them everything the beat
    // touches. `at` is the frame clock in seconds — the loop hands its own rAF
    // timestamp in, and a paint from outside the loop reads the same origin.
    function paint(at) {
      if (!ready || !view) return;
      stamp = at === undefined ? nowOf() : at;
      if (startedAt === null) startedAt = stamp;
      const beat = beatAt(stamp, still.matches, startedAt);
      // What the snapshot brought, then what the clock has done with it. Both
      // read the frame clock and neither touches the beat: the hands are the
      // beat's business and an arriving line may tell them to be working, never
      // to be somewhere else in their cycle.
      feedIn(view, stamp);
      feedStep(stamp);
      bakePlanes(view);
      ctx.clearRect(0, 0, W, H);
      ctx.drawImage(plateBack, 0, 0);
      stripLight(beat);
      nightCity(beat);
      ctx.drawImage(plateMid, 0, 0);
      floorLight(view, beat);
      lamp(view, beat);
      monitor(view, beat);
      worker(view, beat, revealing());
      ctx.drawImage(plateFront, 0, 0);
      present(beat);
    }

    function present(beat) {
      out.clearRect(0, 0, W, H);
      out.imageSmoothingEnabled = false;
      const push = beat.push;
      if (push <= 0) {
        out.drawImage(sceneCanvas, 0, 0);
        return;
      }

      // At the end of the push the monitor and the worker share the middle of
      // the shot. The outer pillar and shelf move out first, making the three
      // room planes do visible camera work without adding another object.
      const zoom = 1 + push * 0.14;
      const sw = Math.round(W / zoom);
      const sh = Math.round(H / zoom);
      const cx = W / 2 + (BEZEL.x + BEZEL.w / 2 - W / 2) * push * 0.48;
      const cy = H / 2 + (BEZEL.y + BEZEL.h / 2 - H / 2) * push * 0.4;
      const sx = Math.max(0, Math.min(W - sw, Math.round(cx - sw / 2)));
      const sy = Math.max(0, Math.min(H - sh, Math.round(cy - sh / 2)));
      out.drawImage(sceneCanvas, sx, sy, sw, sh, 0, 0, W, H);
    }

    // The timestamp rAF hands in is the room's clock, in the same origin
    // performance.now() reports, so the two are interchangeable and both only
    // ever go forward.
    function frame(ts) {
      raf = 0;
      if (!running) return;
      paint(ts / 1000);
      raf = requestAnimationFrame(frame);
    }

    // The one place the room's scale is decided: the largest whole multiple of
    // 320x180 that fits, never a fraction of one.
    function measure() {
      const next = Math.max(1, Math.floor(Math.min(window.innerWidth / W, window.innerHeight / H)));
      if (next === scale) return;
      scale = next;
      canvas.style.width = W * scale + 'px';
      canvas.style.height = H * scale + 'px';
    }

    function start() {
      if (running || broken || still.matches) { paint(); return; }
      running = true;
      raf = requestAnimationFrame(frame);
    }

    // Stopping means the frame that was already queued is cancelled too, not
    // merely ignored when it arrives: a room nobody is looking at should cost
    // this page nothing.
    function stop() {
      running = false;
      if (raf) cancelAnimationFrame(raf);
      raf = 0;
    }

    measure();
    window.addEventListener('resize', measure);
    still.addEventListener('change', () => {
      if (still.matches) { stop(); paint(); } else if (view) start();
    });

    return {
      // Which run the room is showing. Called with a run and the ladder; the
      // room turns that into its own view and nothing else.
      show(run, floors) {
        view = viewOf(run, floors);
        canvas.dataset.on = '1';
        measure();
        paint();
        start();
      },
      hide() {
        stop();
        // The next dive is a new shot and starts its own push from the top.
        startedAt = null;
        delete canvas.dataset.on;
      },
      get holding() { return canvas.dataset.on === '1'; },
    };
  }

  return {
    create, viewOf, tintOf, beatAt, snap, widthOf, fit, cells, setOf, labelOf,
    fileOf, splitOf, bandsOf, lineOf, keyOf, markOf, burstAt, revealed,
    BIG, SMALL, MARKS, W, H, SCREEN, LOCK, ACTOR, PROPS, FRAMES,
    TYPE_SET, WAIT_SET, FALLBACK, TYPE_MS, TYPE_FRAMES, WAIT_MS, WAIT_FRAMES,
    BLINK_MS, BURSTS, BURST_CYCLE, FEED_INK, FEED_ROWS, FEED_CELLS, FEED_W,
    FEED_MARK, FEED_TOP, FEED_PITCH, FEED_TICKS, SCROLL_MS, REVEAL_CPS,
  };
}));
