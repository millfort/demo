# hls.js 1.6.16 — audio is never requested again after `EXT-X-DISCONTINUITY`

A self-contained reproduction. Open `index.html` — from the filesystem or over HTTP — and press
**Start**.

## Symptom

On a stream with separate audio and video renditions, `audio-stream-controller` can stop
requesting fragments at an `EXT-X-DISCONTINUITY` and never resume. Video keeps buffering and
playing; audio is silent for the rest of the session. No error is raised, no recovery happens.

## The race

At the discontinuity the audio controller loads the first fragment of the new continuity counter
and needs `initPTS[cc]` from the main (video) track before it can append. It parks the fragment
and logs `Syncing with main frag`. That path is guarded by `mainFragLoading.cc`:

```js
if (mainFragLoading?.cc === waitingToAppend.cc) return;   // main is on it, keep waiting
```

but `mainFragLoading` is only set for media fragments:

```js
if (!this.audioOnly && data.frag.type === MAIN && isMediaFragment(data.frag)) {
  this.mainFragLoading = data;      // not executed for sn === 'initSegment'
}
```

So while video is fetching its **init segment** for `cc > 0`, the guard does not hold, the
controller takes the other branch and leaves `startFragRequested === false` with a frozen
`nextLoadPosition`.

From then on `doTickIdle()` returns on its first line forever:

```js
if (bufferLen >= maxBufLen ...) return;
```

`bufferLen` is measured from `getLoadPosition()`, which keeps returning that frozen
`nextLoadPosition`. The position never advances, so the buffer always looks full, so nothing is
ever requested, so the position never advances.

The window is exactly as long as the video init segment request. In production it was ~3 ms;
the page widens it with a configurable delay so you do not have to win a lottery. Uncheck
**hold back the video init segment** to see it happen at its natural odds.

## What the page shows

- verdict: **AUDIO IS DEAD** / **OK, audio is alive**
- the gate arithmetic (`bufferLen` vs `maxBufLen`) with the frozen position
- audio and video buffer ranges, playhead and discontinuity on a timeline
- the two request columns — the right one grows, the left one stops
- the filtered hls.js log, with a jump-to-the-race button
- **Revive audio** — a workaround that clears the fragment tracker and calls
  `startLoad(currentTime)`; a plain `stopLoad()/startLoad()` is not enough

## Setup

hls.js is stock `1.6.16` from jsDelivr — nothing is patched. The page adds a logger, a start
position, the init segment delay, and a loader that serves the embedded stream; all four are
marked `// [PATCH N]` in the source and explained on the page itself.

Config: `maxMaxBufferLength: 30`. The value only decides how much content has to sit in front of
the discontinuity — the bug does not depend on it, as long as the buffer is saturated on the way
in.

## The test stream

88 seconds, two renditions, one discontinuity at 48 s:

| | before | after |
|---|---|---|
| video | `testsrc2` 320x180@15 | `smptebars` |
| audio | 440 Hz, 1 Hz pulse | 660 Hz |
| `cc` | 0 | 1 |
| init | `init0.mp4` | `init1.mp4` |

Part B carrying its own `EXT-X-MAP` is the essential bit: that is what makes hls.js fetch a video
init segment at `cc > 0`.

The stream lives in `stream-data.js` as base64 rather than as files on disk, because browsers
block XHR to `file://` URLs but not `<script src>` — that is what lets the page run off the
filesystem. Regenerate it with:

```sh
./make-stream.sh      # needs ffmpeg, nothing else
```

Intermediate output stays in `build/` (git-ignored) if you want the plain `.m4s` files and
playlists to inspect or to serve as a normal stream.

## Pointing it at a real stream

Type any CORS-enabled HLS URL into the **Source** field. The loader falls through to the stock
XHR loader for anything it does not have in memory, and the init segment delay still applies. Use
the **target discontinuity** field to pick which discontinuity to aim at when a playlist has more
than one.
