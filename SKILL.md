---
name: bili-cache-rescue
description: Rescues legacy Bilibili Android offline caches. This skill should be used when old .blv files inside lua.flv.bili2api quality directories no longer appear in the Bilibili app, when checking whether cached .blv videos are corrupted, or when converting those FLV caches into the modern DASH layout (avid folder, c_cid chapter folder, quality folder holding video.m4s, audio.m4s, entry.json and index.json) and pushing them to an Android device over MTP so the entries show up in the offline list again.
---

# Bilibili Legacy Cache Rescue

## Purpose

Old Bilibili Android clients cached video as a single FLV file named `0.blv` inside a directory called `lua.flv[720|480].bili2api.<qid>`. Modern clients ignore that layout entirely: they scan for `<avid>/c_<cid>/<quality>/video.m4s` + `audio.m4s` and read a DASH-style `entry.json`/`index.json`. This skill bridges the two by re-muxing FLV to fragmented MP4 (no re-encode) and fabricating the modern directory layout.

The `.blv` files themselves are almost never corrupt — they are plain, complete FLV files that were simply misnamed. Verify before assuming data loss.

## When to Use

- User has a folder tree like `.../tv.danmaku.bili/download/9311255/1/lua.flv.bili2api.80/0.blv` and the app shows nothing.
- User asks whether old cached `.blv` videos are damaged.
- User wants old caches visible in the modern app, or at least playable locally.
- User copied an old `download/` tree into `Android/data/<pkg>/download/` and it did not appear in the offline list.

## Prerequisites

- Windows with PowerShell 5.1+.
- FFmpeg (`ffmpeg.exe` + `ffprobe.exe`). Install with `winget install --id Gyan.FFmpeg`.
- The Android device connected over MTP (visible under "This PC"). MTP write access to `Android/data/<pkg>/` is enough — no adb or root required.
- Free space roughly equal to the source cache size.

## Workflow

### Step 1 — Verify integrity first

Run `scripts/verify_blv.ps1 -Root <download dir>`. It walks every `.blv`, checks the `FLV` signature, walks the full tag chain, and cross-checks file length against the sibling `*.sum` file.

Expected healthy output: `leftover=0`, non-zero video and audio tag counts, `maxTs` matching `entry.json`'s `total_time_milli`. If verification passes, the files are intact and the problem is purely format/layout.

### Step 2 — Determine the target app's cache version

Read `cache_version_code` from any `entry.json` that the device produced itself (a cache the app downloaded normally). This value must be copied into the fabricated `entry.json`; a wrong value makes the entry look stale. Do not guess it.

Also record the app package name: `tv.danmaku.bili` (phone/portrait) or `tv.danmaku.bilibilihd` (tablet/landscape). The two have different version schemes.

### Step 3 — Convert

Single chapter: `scripts/convert.ps1 -SrcDir <.../9311255/1> -OutRoot <out> -CacheVer <code>`

Batch: `scripts/batch.ps1 -From 0 -To 999 -OutRoot <out> -CacheVer <code>`

Each source chapter directory (the one containing `entry.json` plus a `lua.flv.*` subdirectory) becomes `<out>/<avid>/c_<cid>/<qid>/{video.m4s, audio.m4s, index.json}`, with `entry.json` and `danmaku.xml` one level up.

### Step 4 — Push to device (order matters)

The app only rescans the filesystem when it starts with a clean offline database. Clearing app data deletes the entire `download/` directory, so anything already on the device must be moved out of the package directory first (`/sdcard/dl_bak`), then moved back after clearing.

1. Back up any real caches the user wants to keep: move `Android/data/<pkg>/download` to `/sdcard/dl_bak`.
2. Clear app data (Settings → Apps → Bilibili → Storage → Clear data).
3. Confirm the app has not been started.
4. Run `scripts/push.ps1 -From 0 -To 999 -LocalRoot <out>` to copy the fabricated tree back into `download/`.
5. Move `dl_bak` back in, then open the app.

Launching the app before step 4 is what causes "files are there but the list is empty".

### Step 5 — Confirm in the app

Expect the entry to appear with its original title. Known limitations: no `danmaku.pb` means no danmaku (only `danmaku.xml`); missing `cover.jpg` means a blank cover; `owner_name`/`bvid` are usually unavailable from legacy `entry.json` and can be left empty.

## Critical Pitfalls

- **`-f mp4` is mandatory.** FFmpeg cannot infer the container from a `.m4s` extension and fails with "Unable to choose an output format".
- **`+global_sidx` is mandatory** in `-movflags`. Without a `sidx` box the app plays the file but seeking is broken (dragging the progress bar restarts playback). Verified working chain: `ftyp → moov → sidx → moof → mdat → mfra`.
- **`md5` in `index.json` must be the real file MD5.** The app's own caches satisfy this; a wrong hash can invalidate the entry.
- **`cache_version_code` must match the running app build.**
- **Mobile `.m4s` files carry no `0x30` prefix.** A 9-byte prefix exists only on PC-client downloads; do not strip anything from phone caches.
- **PowerShell 5.1 reads UTF-8 without BOM as ANSI.** Chinese literals in `.ps1` files become mojibake and paths break. Either keep scripts ASCII-only and derive paths from `$PSScriptRoot`, or re-save the script as UTF-8 with BOM.
- **Avoid `$var?param` inside double-quoted strings.** PowerShell swallows the variable; build URLs with explicit concatenation.
- **MTP copies are asynchronous.** After `CopyHere`, poll until the remote file size matches the source before proceeding.

## Bundled Resources

- `scripts/verify_blv.ps1` — integrity check for legacy `.blv` caches.
- `scripts/convert.ps1` — single-chapter FLV → fMP4 + metadata generation.
- `scripts/batch.ps1` — batch driver over a whole `download/` tree.
- `scripts/push.ps1` — MTP push with size verification.
- `references/format-notes.md` — directory layouts, `entry.json` / `index.json` field tables, error codes, and the exact ffmpeg invocations.
