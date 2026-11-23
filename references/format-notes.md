# Bilibili Android Cache Format Notes

Observed and verified on Windows 11 + PowerShell 5.1, ffmpeg 9.1, and two real devices
(`tv.danmaku.bili` build 9180300, `tv.danmaku.bilibilihd` build 2051100), November 2026.

## Legacy layout (pre-2022, FLV)

```
download/
└── 9311255/                              ← avid
    └── 1/                                ← page number
        ├── entry.json
        ├── danmaku.xml
        └── lua.flv.bili2api.80/          ← quality: 80 = 1080P, 64 = 720P, 32 = 480P
            ├── 0.blv                     ← complete FLV file, H.264 + AAC
            ├── 0.blv.4m.sum              ← {"length": <bytes>}
            └── index.json                ← legacy FLV segment list
```

`0.blv` is a byte-exact FLV file. Renaming to `.flv` makes it playable in VLC/PotPlayer;
renaming to `.mp4` used to work on old players that sniff content, but modern Windows players
key off the extension and refuse.

There is also a variant `lua.flv720.bili2api.64` (same structure, different quality) and a
multi-segment variant where several `N.blv` files exist — only `0.blv` appears in the single-file
format described here.

## Modern layout (DASH)

```
download/
└── 117291530395476/                      ← avid
    └── c_42000976414/                    ← c_ + cid
        ├── entry.json
        ├── danmaku.pb                    ← protobuf danmaku (xml may also be present)
        ├── cover.jpg
        ├── subtitles/<id>.subtitle
        └── 120/                          ← quality id: 120 = 4K, 80 = 1080P, 64 = 720P
            ├── video.m4s
            ├── audio.m4s
            └── index.json
```

The app scans for `c_`-prefixed chapter directories. A legacy `1/` page directory is skipped
outright, which is why pasting an old tree into `download/` shows nothing.

## What the app's own files look like

Measured on a 4K cache written by build 9180300:

- `video.m4s` / `audio.m4s` begin directly with `00 00 00 20 66 74 79 70` (`ftyp`).
  **No 9-byte `0x30` prefix** — that prefix exists only on PC-client downloads.
- Box chain: `ftyp → moov → sidx → (moof + mdat)×N → mfra`, fragments roughly 2 MB each.
- `index.json`'s `md5` equals the real file MD5:
  `video.m4s` = `6bc05fa20cec7183551cb1e80518314a`, `audio.m4s` = `a1ab551a964494e0a65e2c8a7264ab96`.
- Video codec is H.264 (`codecid: 7`); `codecid` values: 7 = AVC, 12 = HEVC, 13 = AV1.

## entry.json fields (modern schema)

| Field | Notes |
|---|---|
| `media_type` | `2` for video |
| `has_dash_audio` | `true` |
| `is_completed` / `downloaded_bytes` / `total_bytes` | Completed caches have all three consistent |
| `type_tag` | Quality id as a **string**, e.g. `"80"` — must match the quality directory name |
| `video_quality`, `prefered_video_quality` | Same integer as `type_tag` (note the misspelling `prefered`) |
| `quality_pithy_description` | `4K` / `1080P` / `720P` / `480P` |
| `cache_version_code` | Build number that wrote the cache, e.g. `9180300` |
| `total_time_milli` | Duration in ms |
| `danmaku_count` | Should match the XML/`pb` danmaku count |
| `avid`, `bvid` | `bvid` may be `""` |
| `owner_id`, `owner_name` | May be `0` / `""`; UI then shows a blank uploader |
| `page_data.cid` | Must match the `c_<cid>` directory |
| `page_data.link` | `bilibili://video/<avid>?cid=<cid>` |
| `page_data.width` / `height` | Pixel size, from ffprobe |
| `ep` | `null` for ordinary videos |

Legacy `entry.json` uses a different schema (`"type_tag": "lua.flv.bili2api.80"`, has `seasion_id`
misspelled, no `media_type` / `owner_id` / `page_data.link`). Converting means rebuilding the
document, not patching it.

## index.json structure (modern)

```json
{
  "video": [{
    "id": 80, "base_url": "", "backup_url": [""], "bandwidth": 2962779,
    "codecid": 7, "md5": "<file md5>", "size": 3560890, "audio_id": 30232,
    "no_rexcode": false, "frame_rate": "30.000", "width": 1080, "height": 1920,
    "widevinePssh": "", "bilidrmUri": ""
  }],
  "audio": [{
    "id": 30232, "base_url": "", "backup_url": [""], "bandwidth": 321790,
    "codecid": 0, "md5": "<file md5>", "size": 386751, "audio_id": 0,
    "no_rexcode": false, "frame_rate": "", "width": 0, "height": 0,
    "widevinePssh": "", "bilidrmUri": ""
  }]
}
```

`base_url` may be left empty; offline playback reads local files. `bandwidth` is roughly
`size * 8 / duration_seconds`.

## ffmpeg invocations that work

```
ffmpeg -y -v error -i 0.blv -map 0:v:0 -c:v copy -an \
  -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx -f mp4 video.m4s

ffmpeg -y -v error -i 0.blv -map 0:a:0 -c:a copy -vn -bsf:a aac_adtstoasc \
  -movflags +frag_keyframe+empty_moov+default_base_moof+global_sidx -f mp4 audio.m4s
```

Both `-f mp4` and `+global_sidx` are required. Omitting `-f mp4` fails with
"Unable to choose an output format for '...video.m4s'". Omitting `+global_sidx` yields a file
that plays but cannot seek — dragging the progress bar restarts from zero.

A correct 10-second output looks like: `ftyp(28) → moov(826) → sidx(52) → moof(3524) → mdat → mfra`.

## Deployment order

`Clear data` deletes the whole `/sdcard/Android/data/<pkg>/` tree, including `download/`.
Correct sequence:

1. Move `download/` out of the package directory (e.g. to `/sdcard/dl_bak`) so real caches survive.
2. Clear app data.
3. Do **not** launch the app.
4. Copy the fabricated tree into a freshly created `download/` (via MTP or in-device move).
5. Restore `dl_bak` contents, then launch.

Launching the app before step 4 makes it build an empty index; later additions are then ignored
until the next clear.

## Relevant Bilibili API error codes

| Response | Meaning |
|---|---|
| `-404 啥都木有` | Video does not exist / deleted |
| `62002 稿件不可见` | Video exists but is not visible — owner set it private, or it is under review |
| `62012 仅UP主自己可见` | Owner-only visibility |
| `12002 当前页面评论功能已关闭` | Comment section closed, usually because the video is gone |

`62002` is worth distinguishing from `-404`: the entry still exists server-side, so only the
uploader can restore it. Nothing on the device can fetch it.

## Verified results

- 76 legacy `.blv` files, 2.36 GB: all passed FLV signature + tag-chain + `.sum` length checks.
- 75 chapters converted successfully; 5 failed because `0.blv` was genuinely missing (only
  `entry.json`, `index.json` and the `.sum` file remained).
- Pushed 69 avid directories / 75 chapters to a tablet over MTP; the fabricated entries appeared
  in the offline list after the clear-data-then-copy sequence.
