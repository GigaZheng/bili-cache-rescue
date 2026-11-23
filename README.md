# bili-cache-rescue

**B站旧缓存抢救工具** — 把 2019 年前后下载的 `.blv` FLV 缓存，转换成新版哔哩哔哩 App 能识别的 DASH 缓存目录，让老视频重新出现在「离线缓存」列表里。

*Rescue legacy Bilibili Android offline caches: re-mux `.blv` FLV files into fragmented MP4 and fabricate the modern DASH directory layout so old videos show up in the app again.*

---

## 问题

旧版 Android 客户端的缓存长这样：

```
download/9311255/1/lua.flv.bili2api.80/
├── 0.blv                  ← 完整 FLV 文件（H.264 + AAC），不是损坏文件
├── 0.blv.4m.sum           ← {"length": 53234309}
└── index.json
```

新版客户端只认这种：

```
download/117291530395476/c_42000976414/120/
├── video.m4s
├── audio.m4s
└── index.json
```

两边的目录名、`entry.json` schema、容器格式全都不同。把旧缓存直接拷进 `Android/data/tv.danmaku.bili/download/`，App 会当作不存在的目录跳过——**文件没坏，是格式不认**。

改后缀成 `.mp4` 能播的年代已经过去了：现在 Windows 播放器按扩展名判断，FLV 内容套 `.mp4` 外壳会直接被拒。改 `.flv` 才是对的。

## 原理

1. `.blv` 本身就是标准 FLV，**无损**转封装成 `ftyp → moov → sidx → moof → mdat` 的 fMP4
2. 关键参数 `+global_sidx` —— 没有它，视频能播但一拖进度条就从头开始
3. 按新 schema 重建 `entry.json` 和 `index.json`，`md5` 必须是文件真实 MD5
4. 通过 MTP 推进设备，**先清 App 数据、后放文件**，启动时才会全量重建索引

## 快速开始

```powershell
# 0. 装 ffmpeg
winget install --id Gyan.FFmpeg

# 1. 先体检：确认 .blv 到底有没有损坏
.\scripts\verify_blv.ps1 -Root "D:\bili_backup\download"

# 2. 转换（CacheVer 填目标 App 的 build 号，从设备上任意一条真实缓存的 entry.json 里读 cache_version_code）
.\scripts\batch.ps1 -Root "D:\bili_backup\download" -OutRoot ".\out_bili" -CacheVer 9180300

# 3. 推送（设备需已清数据且未启动 App）
.\scripts\push.ps1 -Package tv.danmaku.bili -LocalRoot ".\out_bili"
```

单条转换：

```powershell
.\scripts\convert.ps1 -SrcDir "D:\bili_backup\download\9311255\1" -OutRoot ".\out" -CacheVer 9180300
```

## 部署顺序（这一步错了就白干）

`清除数据` 会把整个 `/sdcard/Android/data/<包名>/` 删掉，包括 `download/`。所以：

1. 把 `download/` **移出**包目录（例如挪到 `/sdcard/dl_bak`），保住已有缓存
2. 设置 → 应用 → 哔哩哔哩 → 存储 → 清除数据
3. **不要打开 App**
4. 把转换产物拷进新建的 `download/`
5. 把 `dl_bak` 挪回来，再打开 App

如果第 3 步之前 App 已经启动过一次，它会建立空索引，后面再放文件就不认了，得再清一次。

## 脚本

| 脚本 | 作用 |
|---|---|
| `scripts/verify_blv.ps1` | 校验 `.blv`：FLV 签名 + 全量 tag 遍历 + 与 `.sum` 长度比对，输出问题清单 |
| `scripts/convert.ps1` | 单章转换：ffprobe 取宽高/帧率 → 拆音视频轨 → 算 MD5 → 生成两个 json |
| `scripts/batch.ps1` | 批量驱动，自动识别 `entry.json + lua.flv.*` 的章节目录 |
| `scripts/push.ps1` | MTP 推送，逐个目录轮询校验远端文件大小 |

所有脚本为纯 ASCII，路径从 `$PSScriptRoot` 推导——PowerShell 5.1 把无 BOM 的 UTF-8 当 ANSI 读，脚本里写中文会变乱码。

## 关键坑

| 坑 | 后果 |
|---|---|
| 漏了 `-f mp4` | `Unable to choose an output format for 'video.m4s'` |
| 漏了 `+global_sidx` | 能播，但拖进度条就重头开始 |
| `md5` 填错 | 条目可能被判为损坏 |
| `cache_version_code` 填错 | 条目看起来是旧版本遗留 |
| 手机 `m4s` 当成有 9 字节 `0x30` 头去切 | 那是 PC 端才有的混淆头，切了就废 |
| 先放文件后清数据 | 文件被一起删掉 |

## 实测数据

Windows 11 + PowerShell 5.1 + ffmpeg 9.1，两台真机：

- 76 个 `.blv`、2.36 GB：**全部完好**，FLV 签名、tag 链、`.sum` 长度三项全过
- 转换成功 75 条；5 条失败是因为 `0.blv` 本来就缺失（只剩 `entry.json` 和 `entry.json` 的元数据）
- 推送 69 个 avid / 75 个章节到平板，清数据后条目正常出现
- 手机端 `video.m4s` 开头直接是 `ftyp`，无混淆前缀；`index.json` 的 `md5` 与文件真实 MD5 完全一致

更多格式细节见 [`references/format-notes.md`](references/format-notes.md)。

## 适用范围与声明

- 仅适用于**你自己设备上已有的缓存**，用于恢复个人离线观看
- 不提供任何下载、抓流、绕过版权或解密功能
- 伪造缓存条目依赖客户端解析逻辑，**App 大版本升级后可能失效**
- 已知限制：没有 `danmaku.pb` 就没弹幕（只有 `danmaku.xml`）；旧 `entry.json` 里没有 UP 主信息，列表里 UP 主栏为空

## License

MIT
