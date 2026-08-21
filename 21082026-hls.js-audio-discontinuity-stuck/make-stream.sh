#!/usr/bin/env bash
#
# Builds the minimal HLS stream that reproduces the hls.js audio-stuck bug and
# packs it into stream-data.js, so that index.html works from file:// as well.
#
# Requires: ffmpeg. No python, no web server.
#
#   ./make-stream.sh
#
# Layout produced in build/:
#
#   playlist.m3u8          multivariant
#   v1/playlist.m3u8       video rendition, init0.mp4 + init1.mp4 + media/N.m4s
#   a1/playlist.m3u8       audio rendition, same shape
#
# Each rendition is two independently encoded parts glued together with an
# EXT-X-DISCONTINUITY. Part B carries its own EXT-X-MAP (init1.mp4), and that is
# what makes hls.js fetch a video init segment at cc > 0 -- the race window the
# bug lives in.

set -euo pipefail
cd "$(dirname "$0")"

OUT=build
DUR_A=48          # seconds before the discontinuity; must exceed maxMaxBufferLength
DUR_B=40          # seconds after it
SEG=4             # segment duration
FPS=15
SIZE=320x180
VBITRATE=80k
ABITRATE=48k

command -v ffmpeg >/dev/null || { echo "ffmpeg not found" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT/v1/media" "$OUT/a1/media"

# ---------------------------------------------------------------------------
# Encode one part of one rendition.
#   $1 track (v1|a1)   $2 part (0|1)   $3 duration   $4 start_number
# ---------------------------------------------------------------------------
encode() {
  local track=$1 part=$2 dur=$3 start=$4
  local hls_opts=(-f hls -hls_time "$SEG" -hls_playlist_type vod -hls_list_size 0
                  -hls_segment_type fmp4
                  -hls_fmp4_init_filename "init$part.mp4"
                  -hls_segment_filename "$OUT/$track/media/%d.m4s"
                  -start_number "$start")

  if [ "$track" = v1 ]; then
    # part B looks different, so the discontinuity is obvious on screen
    local pattern=testsrc2
    [ "$part" = 1 ] && pattern=smptebars
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "$pattern=size=$SIZE:rate=$FPS:duration=$dur" \
      -c:v libx264 -profile:v main -preset veryfast -pix_fmt yuv420p \
      -b:v "$VBITRATE" -g $((SEG * FPS)) -keyint_min $((SEG * FPS)) -sc_threshold 0 \
      "${hls_opts[@]}" "$OUT/$track/part$part.m3u8"
  else
    # 1 Hz amplitude pulse, so stuck audio is audible at once; the tone also
    # changes across the discontinuity (440 Hz -> 660 Hz)
    local freq=440
    [ "$part" = 1 ] && freq=660
    ffmpeg -hide_banner -loglevel error -y \
      -f lavfi -i "aevalsrc=0.35*sin(2*PI*$freq*t)*(0.5+0.5*cos(2*PI*t)):s=48000:d=$dur" \
      -c:a aac -b:a "$ABITRATE" -ac 1 -ar 48000 \
      "${hls_opts[@]}" "$OUT/$track/part$part.m3u8"
  fi
}

# ---------------------------------------------------------------------------
# AAC segments never land exactly on $SEG, so a part can end with a sub-frame
# stub (a 21 ms EXTINF). Drop it -- a stub right before the discontinuity is
# just a distraction in a bug report.
#   $1 track   $2 part playlist
# ---------------------------------------------------------------------------
trim_stub() {
  local track=$1 pl=$2 dur seg n
  dur=$(grep '^#EXTINF' "$pl" | tail -1 | sed 's/#EXTINF:\([0-9.]*\),.*/\1/')
  awk -v d="$dur" 'BEGIN { exit !(d < 0.5) }' || return 0
  seg=$(grep '\.m4s$' "$pl" | tail -1)
  rm -f "$OUT/$track/media/$(basename "$seg")"
  n=$(wc -l < "$pl")
  # the last three lines are: #EXTINF, the uri, #EXT-X-ENDLIST
  { head -n $((n - 3)) "$pl"; echo '#EXT-X-ENDLIST'; } > "$pl.tmp"
  mv "$pl.tmp" "$pl"
}

# highest segment number present in a rendition, plus one
next_sn() {
  ls "$OUT/$1/media" | sed 's/\.m4s$//' | sort -n | tail -1 | awk '{print $1 + 1}'
}

for track in v1 a1; do
  encode "$track" 0 "$DUR_A" 0
  trim_stub "$track" "$OUT/$track/part0.m3u8"
  encode "$track" 1 "$DUR_B" "$(next_sn "$track")"
  trim_stub "$track" "$OUT/$track/part1.m3u8"
done

# ---------------------------------------------------------------------------
# Glue part0 + EXT-X-DISCONTINUITY + part1 into one VOD playlist, rewriting
# bare "N.m4s" into "media/N.m4s".
# ---------------------------------------------------------------------------
body() {
  grep -v '^#EXT\(M3U\|-X-VERSION\|-X-TARGETDURATION\|-X-MEDIA-SEQUENCE\|-X-PLAYLIST-TYPE\|-X-ENDLIST\|-X-INDEPENDENT-SEGMENTS\)' "$1" \
    | sed 's|^\([0-9][0-9]*\.m4s\)$|media/\1|'
}

for track in v1 a1; do
  { echo '#EXTM3U'
    echo '#EXT-X-VERSION:7'
    echo "#EXT-X-TARGETDURATION:$((SEG + 1))"
    echo '#EXT-X-MEDIA-SEQUENCE:0'
    echo '#EXT-X-PLAYLIST-TYPE:VOD'
    echo '#EXT-X-INDEPENDENT-SEGMENTS'
    body "$OUT/$track/part0.m3u8"
    echo '#EXT-X-DISCONTINUITY'
    body "$OUT/$track/part1.m3u8"
    echo '#EXT-X-ENDLIST'
  } > "$OUT/$track/playlist.m3u8"
  rm -f "$OUT/$track/part0.m3u8" "$OUT/$track/part1.m3u8"
done

cat > "$OUT/playlist.m3u8" <<'M3U8'
#EXTM3U
#EXT-X-VERSION:7
#EXT-X-INDEPENDENT-SEGMENTS
#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="a1/playlist.m3u8"
#EXT-X-STREAM-INF:BANDWIDTH=180000,AVERAGE-BANDWIDTH=140000,RESOLUTION=320x180,FRAME-RATE=15.000,CODECS="avc1.4d401e,mp4a.40.2",AUDIO="aud"
v1/playlist.m3u8
M3U8

# ---------------------------------------------------------------------------
# Pack everything into one JS file: playlists as readable text, media as base64.
# ---------------------------------------------------------------------------
DATA=stream-data.js
{
  echo '// Generated by make-stream.sh -- do not edit by hand.'
  echo '//'
  echo '// The whole test stream lives here so that index.html can be opened straight'
  echo '// from the filesystem: browsers block XHR to file:// URLs, but not <script src>.'
  echo '// index.html hands these bytes to hls.js through a loader that does nothing but'
  echo '// pass them through.'
  echo 'window.HLS_DEMO_STREAM = {'
  find . -path "./$OUT/*" -name '*.m3u8' | sed "s|^\./$OUT/||" | sort | while read -r f; do
    printf "  '%s': { text:\n" "$f"
    sed "s/'/\\\\'/g" "$OUT/$f" | awk '{printf "    %s\n", "\x27" $0 "\\n\x27 +"}'
    echo "    ''},"
  done
  find . -path "./$OUT/*" \( -name '*.mp4' -o -name '*.m4s' \) | sed "s|^\./$OUT/||" \
    | sort -t/ -k1,1 -k2,2 -V | while read -r f; do
    printf "  '%s': { b64: '%s' },\n" "$f" "$(base64 < "$OUT/$f" | tr -d '\n')"
  done
  echo '};'
} > "$DATA"

echo "built $DATA ($(du -h "$DATA" | cut -f1))"
for track in v1 a1; do
  printf '  %s: %s segments, discontinuity at %ss\n' "$track" \
    "$(grep -c '\.m4s$' "$OUT/$track/playlist.m3u8")" \
    "$(awk -F: '/^#EXTINF/ { s += $2 } /^#EXT-X-DISCONTINUITY/ { print s; exit }' "$OUT/$track/playlist.m3u8")"
done
