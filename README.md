# EmbyFlow — iOS 14.5+ 的 Emby 播放器（含 iPhone 6s 专项优化）

一个可编译的 Emby 客户端：登录、首页推荐、媒体库、搜索、详情页、剧集列表，
以及一套自定义播放器（播放模式 / 音轨 / 字幕 / 倍速 / 小窗 / 进度回传）。

面向老设备做了专门处理：iPhone 6s（A9）不会收到 HEVC，全程 H.264 硬解，不烫手；
界面用 UICollectionView 复用单元格，滚动不掉帧。

## 一、最低要求

| 项目 | 版本 |
| --- | --- |
| iOS | 14.5+（iPhone 6s 最高 iOS 15.8，完全支持） |
| Xcode | 15.0+（Swift 5.9） |
| XcodeGen | 2.38+（只用来生成 .xcodeproj） |
| 服务器 | Emby Server 4.6+（标准 REST API） |

iPhone 6s 上必须允许「本地网络」权限，否则连不上家里的 Emby。

## 二、生成工程

```bash
brew install xcodegen
cd EmbyFlow
xcodegen generate
open EmbyFlow.xcodeproj
```

在 Xcode 里选 Team（Signing & Capabilities → Team），连真机或模拟器 Run。

## 三、打包 IPA（巨魔 / TrollStore 安装）

```bash
cd EmbyFlow
bash build-ipa.sh          # 若提示 permission denied：先 chmod +x build-ipa.sh
```

脚本会做三件事：生成工程 → Release 编译（关闭签名）→ 把 .app 打成 EmbyFlow.ipa。

产物在 `EmbyFlow/EmbyFlow.ipa`，传到 iPhone（隔空投送或「文件」App），
用巨魔打开安装即可。巨魔会自己完成签名，不需要证书，也不会 7 天掉签。

安装失败时依次检查：

1. IPA 内必须是 `Payload/EmbyFlow.app` 结构（脚本已保证；手动压缩时注意别多套一层文件夹）
2. 你的 iOS 版本在巨魔支持范围内，且巨魔本身已安装好
3. 手机存储空间足够（App 本体约 10–20MB）

## 四、iPhone 6s 专项优化

### 1. 自动识别硬件解码能力，绝不下发 HEVC

A9 芯片没有 HEVC 硬解，HEVC 只能软解 —— 这就是老机器看片发烫、掉帧的原因。
App 启动时读取机型标识（`hw.machine`），把设备分成三档：

| 档位 | 代表机型 | 视频策略 |
| --- | --- | --- |
| H.264 only | iPhone 6s / 6s Plus / SE(1) 及更早 | 白名单里只有 h264，HEVC 一律让服务器转成 H.264 |
| HEVC 8bit | iPhone 7 / 7 Plus（A10） | 允许 HEVC 8bit 直连，10bit 转码 |
| HEVC 10bit | iPhone 8 / X 及更新（A11+） | 允许 HEVC Main10 / HDR |

设置页会直接显示识别结果（例如 `iPhone8,1 · H.264 硬解（无 HEVC 硬解）`），方便确认生效。

另外 H.264 也加了 `VideoBitDepth ≤ 8` 限制：Hi10P（10bit H.264）这种动漫常见格式
AVFoundation 根本解不了，以前会黑屏或花屏，现在会让服务器转码。

### 2. 播放模式（设置 → 播放模式）

| 模式 | 行为 | 适合 |
| --- | --- | --- |
| 自动 | 能直连就直连；设备放不了的编码交给服务器 | 日常推荐 |
| 画质优先 | 尽量原画直连，不限制分辨率 | 网络好、要画质 |
| 省电（服务端转码） | 强制服务端出 HLS 流：H.264 / 8bit / ≤8Mbps / 1080p 以内 | 6s 最稳，手机不烫 |
| 极限省电（720p） | 在省电基础上降到 720p / 4Mbps | 电量紧张、外网观看 |

### 3. 内存与缓存按机型缩放

- 2GB 机型：解码位图缓存 36MB / 240 张（而不是 80MB / 600 张），磁盘缓存 384MB
- 监听系统内存警告，收到就立刻清空位图缓存，避免后台被杀

### 4. 界面：用 UICollectionView 代替 SwiftUI 懒加载

海报网格和首页横滑行都换成 `UICollectionView`（含 `prefetchItemsAt` 预取）：
固定数量的单元格被复用，滚动期间没有 SwiftUI 视图树的创建与 diff，
这是 A9 设备上「跟手」的关键。

## 五、已实现功能

登录：地址支持 `192.168.1.10:8096`、`https://emby.example.com/emby` 这类写法，
自动补协议与去尾斜杠；`/System/Info/Public` 探活取服务器名与版本；Token 存 Keychain，
重开自动恢复；最近服务器列表。

首页：继续观看（大图 Banner，含「已看 xx% · 剩 xx:xx」）、接下来（NextUp）、
每个媒体库的最新添加。

媒体库：库平铺、库内网格、分页加载（滚到接近底部自动取下一页）、
文件夹与合集可继续深入、排序（名称 / 最近添加 / 评分 / 年份）与筛选（全部 / 未观看 / 已观看）。

详情页：背景大图 + Logo、年份/时长/评分/分级胶囊标签、继续播放、下一集、标记已看、收藏、
季切换、剧集列表（缩略图 / S01E02 / 进度 / 已看勾 / 简介）、简介展开收起。

播放器：单击显示隐藏控件、双击左右 ±15 秒、中间双击暂停、全屏横向拖动进度（松手才 seek）、
进度条带缓冲区间、倍速 0.5–2x、音轨切换、字幕切换、画中画、后台音频、锁屏不熄屏、
每 10 秒回传进度、退出回传 Stopped、看完自动标记已看并自动下一集，
顶部实时显示当前是「原画直连 / 直接串流 / 服务端转码」。

字幕：文本字幕（SRT/VTT）由 App 抓取并渲染，切换秒开、不触发转码，
中文字幕带 GB18030 兜底；图形字幕（PGS/VobSub）提示需要服务端烧入。

## 六、为什么它不卡

图片管线（`Core/Images/ImagePipeline.swift`）

- 下载后用 ImageIO 按目标尺寸降采样解码，不把 2000px 原图交给 UI 每次缩放
- NSCache（已解码位图）+ 磁盘 LRU 两级缓存，同图请求去重，并发下载限流 6
- 单元格 configure 时先查内存缓存，命中直接贴图，滚动返回不闪占位图
- 列表滚动时通过 `prefetchItemsAt` 提前预热下一屏
- 卡片不用 shadow（离屏渲染），改用 0.5pt 描边

播放器

- `AVPlayerLayer` 放在 UIKit 宿主里，手势用原生识别器，不走 SwiftUI 手势仲裁
- `layoutSubviews` 用 `CATransaction` 关掉隐式动画，旋转或分屏不产生中间帧模糊
- 进度 4Hz 更新，字幕二分查找，内容不变就不刷 UI
- 拖动只更新预览时间，松手才 seek；seek 用 0.15s 容差，转码源上快一个数量级

工程层面

- `CADisableMinimumFrameDurationOnPhone = true`（新机型的 120Hz 才跑得满）
- JSON 解析在后台线程；所有 UI 状态都是 `@MainActor` + `ObservableObject`

## 七、iOS 14.5 兼容：刻意避开的 API

| 不能用（15/16/17+） | 本工程替代 |
| --- | --- |
| `@Observable`（17+） | `ObservableObject` + `@Published` |
| `NavigationStack`、`NavigationLink(value:)`（16+） | `NavigationView` + `NavigationLink(destination:)`，网格跳转用隐藏链接 |
| `.task {}`（15+） | `.onAppear { Task { ... } }` + 手动取消 |
| `.searchable`（15+） | 自定义搜索框 + 300ms 防抖 |
| `.refreshable`（15+） | 导航栏刷新按钮 |
| `AsyncImage`（15+） | 自制 `RemoteImage` + `ImagePipeline` |
| `URLSession.data(for:)`（15+） | `withCheckedThrowingContinuation` 包 `dataTask` |
| `MainActor.assumeIsolated`（17+） | `Task { @MainActor in ... }` |
| `.foregroundStyle`、`.overlay(alignment:)`、`.background(alignment:)` | `.foregroundColor`、`ZStack`、`.overlay(View)` |
| `Color(uiColor:)`（15+） | `Theme` 里的显式 RGB 调色板 |
| `.scrollTargetBehavior`、`.contentMargins`（17+） | 手动 padding |
| `SpatialTapGesture`（16+） | UIKit 手势识别器 |
| `@Environment(\.dismiss)`（15+） | `@Environment(\.presentationMode)` |

## 八、播放策略：为什么大部分片子不吃服务器 CPU

`Core/Networking/DeviceProfile.swift` 会告诉服务器这台设备到底能放什么：

1. 原画直连：容器 `mp4/m4v/mov`、编码在白名单内，直接把文件地址交给 AVPlayer，服务器零负载
2. 直接串流（remux）：MKV 里的 H.264 这类情况只换封装不转码，手机硬解、服务器几乎不费
3. 转码：设备放不了的（HEVC、10bit、AV1、DTS 音轨、超出分辨率上限）才真转码

音轨同理：AAC / MP3 / AC-3 / E-AC-3 可直连，DTS / TrueHD 会让服务器只转音频
（音频转码开销极小，视频仍可 copy）。

建议在 Emby 服务端开启硬件加速（Intel QSV / NVIDIA NVENC / VAAPI）。
1080p H.264 转码大概只占一个核的 5–15%，6s 这一侧则完全硬解。

## 九、工程结构

```
EmbyFlow/
├── project.yml                     # XcodeGen 描述（Info.plist / 图标 / ATS 等）
├── build-ipa.sh                    # 一键出未签名 IPA（巨魔用）
└── EmbyFlow/
    ├── App/                        # 入口与 Tab
    ├── Core/
    │   ├── Auth/                   # Keychain、SessionStore
    │   ├── Images/                 # ImagePipeline / DiskImageCache / RemoteImage
    │   ├── Models/                 # Emby DTO 与播放模型
    │   ├── Networking/             # HTTPClient / EmbyClient / DeviceProfile
    │   ├── Playback/               # PlaybackController / PlaybackPlan / SubtitleService
    │   ├── Settings/               # AppSettings（含播放模式）
    │   └── Utils/                  # Theme / Formatting / AsyncSemaphore / DeviceCapabilities
    ├── Features/
    │   ├── Login/ Home/ Library/ Search/ Settings/ Detail/
    │   ├── Components/             # PosterGrid（UICollectionView 网格）、卡片、徽标
    │   └── Player/                 # 播放器 UI + AVPlayerLayer 宿主
    └── Resources/Assets.xcassets   # App 图标
```

## 十、已知限制与后续

1. MKV 的零转码原画直连：AVFoundation 打不开 Matroska，现在走服务器 remux
   （画质无损、服务器开销极小，6s 仍硬解 H.264）。若要连 remux 都不要，
   需要接入 VLCKit / MPV 内核，`PlaybackPlan` 已预留按容器选择引擎的位置
2. ASS/SSA 特效字幕：靠服务端烧入，App 内渲染不还原特效定位
3. 局域网服务器自动发现（UDP 7359）未接入，目前是手填地址 + 历史记录
4. 投屏 / DLNA、离线下载、多用户切换、演员列表与相关推荐尚未实现

## 十一、排错

| 现象 | 处理 |
| --- | --- |
| 连接超时 | 地址要带端口；手机与服务器同网段；首次连接允许「本地网络」权限 |
| 401 / 登录失效 | 服务器重启或用户被改，退出登录重新登录 |
| 有声音没画面 | 源是 AV1 / 10bit 等；切到「省电」模式强制转码 |
| 播放很烫 | 切到「省电（服务端转码）」或「极限省电」；确认设置页显示的机型档位正确 |
| 拖动进度后卡住 | 服务端转码性能不足：开硬件加速、降低码率、减小拖动幅度 |
| 字幕不显示 | 图形字幕需服务端烧入；文本字幕检查「首选字幕」设置 |
| 海报一直是占位图 | 服务器拒绝图片请求，或本地网络权限未开 |
