# weread-yessi KOReader Plugin

> **免责声明**：本项目仅供个人学习和技术研究使用，不得用于商业用途。使用本项目所产生的一切后果（包括但不限于账号封禁、数据丢失等）由使用者自行承担，项目作者概不负责。请遵守微信读书的用户协议和相关法律法规。

在 KOReader 上阅读微信读书中的书籍、公众号文章的插件。支持同步进度同步，阅读时长同步和统计，查看书评、划线和想法。让Kindle、Kobo等封闭系统设备也能体验微信读书！


## 其它项目推荐

| 插件 | 简介                                                  |
|------|-----------------------------------------------------|
| [kindlebtcontroller.koplugin](https://github.com/finlater/kindlebtcontroller.koplugin) | 蓝牙手柄/遥控器控制 Kindle —— 翻页、调节亮度、章节跳转等 20+ 操作，按键完全可自定义。 |
| [one.koplugin](https://github.com/finlater/one.koplugin) | 在 KOReader 上离线阅读「ONE · 一个」每日更新：一图、一文、一问答。           |

## 功能

| 主菜单 | 书架 | 公众号 |
|:---:|:---:|:---:|
| ![主菜单](screenshots/main_manu.png) | ![微信读书书架](screenshots/bookshelf.png) | ![公众号](screenshots/bookshelf_wp.png) |

| 阅读时间上报 | 阅读统计 | 阅读进度同步 |
|:---:|:---:|:---:|
| ![阅读时间上报](screenshots/read_report.png) | ![阅读统计](screenshots/read_stats.png) | ![阅读进度同步](screenshots/read_progress.png) |

| 多选章节下载 | 章节预下载 | 下载全书 |
|:---:|:---:|:---:|
| ![多选章节下载](screenshots/download_multi_chapter.png) | ![章节预下载](screenshots/pre_download_next_chapter.png) | ![下载全书](screenshots/download.png) |

| 书籍详情 | 书评 | 划线和想法 |
|:---:|:---:|:---:|
| ![书籍详情](screenshots/book_detail.png) | ![书评](screenshots/book_review.png) | ![划线和想法](screenshots/thought.png) |

| 搜索书籍 | 快捷菜单 | 设置 |
|:---:|:---:|:---:|
| ![搜索书籍](screenshots/book_search.png) | ![快捷菜单](screenshots/quick_menu.png) | ![设置](screenshots/setting.png) |

## 安装

> ⚠️ 建议使用 **KOReader 2026.03 或更高版本**。旧版本可能无法正常加载或使用插件，例如「工具」菜单中找不到「微信读书」。详见 [#14](https://github.com/finlater/weread.koplugin/issues/14)。

1. 前往 [GitHub Releases](https://github.com/finlater/weread.koplugin/releases) 下载最新的 `weread.koplugin-vX.Y.Z.zip` 安装包，或运行 `bash scripts/package_release.sh` 打包当前源码。
2. 解压安装包，得到 `weread.koplugin` 文件夹。
3. 将该文件夹复制到 KOReader 的 `plugins` 目录：

```
koreader/plugins/weread.koplugin/
```

4. 重启 KOReader，在菜单中找到：

```
工具 → weread-yessi
```

这个私人版会关闭上游在线更新，避免公开版覆盖定制功能；后续更新请安装新的私人版 ZIP。插件显示名为“weread-yessi”，安装目录仍必须保持为 `weread.koplugin`。

## 登录与认证

插件只支持微信扫码登录，扫码前需要先为账号开通微信读书 Skill：

1. 手机打开**微信读书 App**。
2. 进入 **我 → 设置 → 微信读书 Skill**。
3. 点击 **获取 API Key**，确认已经生成个人官方 API Key。
4. 在 KOReader 打开 **工具 → weread-yessi → 微信扫码登录**。
5. 使用微信扫码并在手机端确认；若手机显示四位验证码，请在 KOReader 中输入。

## SimpleUI / Zen_UI 集成

插件提供统一的“微信读书书架”入口并支持集成到 SimpleUI和 ZenUI的快捷按钮中。(需要安装最新版 [SimpleUI](https://github.com/doctorhetfield-cmd/simpleui.koplugin) 和 [ZenUI](https://github.com/AnthonyGress/zen_ui.koplugin)插件)。

- **SimpleUI**：进入 `快捷操作` 新建操作，类型选择 `插件 → weread-yessi`，再把该操作加入底部栏即可。如需使用本项目图标，将 `icons/weread-w-book.svg` 或 `icons/weread-ink.png` 复制到 SimpleUI 的自定义图标目录`koreader/setting/simpleui/sui_icons`后，在快捷操作中选中它。
- **Zen_UI 底栏**：进入 `控件 → 按钮 → ➕ → 插件 → weread-yessi`，点击后直接打开微信读书书架。注册时会把 `weread-w-book.svg` 同步到 KOReader 用户图标目录，供 ZenUI 自动匹配或手动选择；不会自动修改、添加或启用 Tab。
- **Zen_UI 首页**：进入 `主页 → 小组件`，启用“weread-yessi”组件。组件默认关闭，可由用户自行排序。

原生 KOReader 的入口为“工具 → weread-yessi”。

|                     SimpleUI                     |                   Zen_UI                   |
|:------------------------------------------------:|:------------------------------------------:|
| ![simpleui](screenshots/simpleui_quick_menu.png) | ![ZenUI](screenshots/zenui_quick_menu.png) |

## 菜单结构

```
weread-yessi
├── 微信扫码登录 / 已经登录 · 账号名
├── 立即同步进度       （阅读微信读书缓存书籍时显示）
├── 书籍详情           （阅读微信读书缓存书籍时显示）
├── 显示划线和想法     （阅读书籍时显示，开关）
├── 本地书划线和想法   （阅读非微信读书的可重排文档时显示；不修改 EPUB/KOReader 笔记）
│   ├── 匹配微信读书书目 / 已匹配：书名
│   ├── 同步划线与想法（同步后显示已匹配条数）
│   └── 清除数据
├── 书架               书籍 / 公众号 Tab；书架内搜索、离线缓存、手动更新
├── weread收藏夹        已下载书籍（不包含单章）的本地入口
├── 搜索               搜索微信读书
├── 阅读时间上报        后台上报阅读时长（私人版默认开启）
│   ├── 启用阅读时间上报（默认开启，可关闭）
│   ├── 仅在阅读时上报（默认开启）
│   ├── 选择目标书籍
│   │   ├── 自动关联微信读书书籍（默认）
│   │   └── 手动设置上报书籍
│   └── 上报状态
├── 阅读统计            阅读时长/天数/排行/偏好可视化（页内 周/月/年/总 tab 切换，可翻阅历史周期）
├── 设置
│   ├── 书架视图
│   │   ├── 列表模式（默认；适合连续滚动）
│   │   └── 封面模式（按屏幕自适应行列；仅加载当前页封面）
│   ├── 分页书架（仅列表模式；默认开启，关闭后使用连续滚动）
│   ├── 界面语言（默认简体中文，可切换 English）
│   ├── 缓存管理
│   │   ├── 扫描并关联本地书籍
│   │   ├── 缓存清理
│   │   └── 缓存目录
│   ├── 进度管理
│   │   ├── 打开时拉取进度（默认开启；用于校验时长上报位置）
│   │   ├── 阅读时定时上传进度（默认每 1 分钟；可选关闭/1/2/5 分钟）
│   │   └── 关闭时上传进度（默认关闭）
│   ├── 下载设置
│   │   ├── 书籍排版（智能还原／尽量保持原版／纯净阅读；默认智能还原）
│   │   ├── 书籍图片（默认开启）
│   │   ├── 公众号文章图片（默认关闭）
│   │   └── 章节预下载
│   │       ├── 自动预下载下一章（默认关闭，开启时会确认网络卡顿风险）
│   │       ├── 预下载划线和想法（默认关闭，总开关关闭时不可操作）
│   │       └── 显示预下载提示（默认开启，总开关关闭时不可操作）
│   ├── 划线设置
│   │   ├── 划线边缘防误触（默认开启）
│   │   └── 边缘区域：20%（可调 10%–40%）
│   ├── 账号管理
│   │   ├── 账号状态
│   │   ├── 立即续期 Cookie
│   │   └── 清除账号数据
│   └── 关于
│       ├── 版本 x.y.z
│       ├── 作者：finlater
│       └── 私人版 · 仅支持手动更新
```

### 书籍排版模式

- **智能还原（默认）**：识别纯文字、普通图文和图片型章节；正文缺少目录标题时自动补全，并为章节开场、普通插图和图注加入自适应样式。
- **尽量保持原版**：保留下载到的正文与原始 CSS，不自动补充可见章节标题。
- **纯净阅读**：在智能补全的基础上统一正文行距、段落、引用、标题和插图间距。

排版模式只影响之后生成的 EPUB。更改设置后，需要重新下载已有书籍才能看到效果。常见 PNG、JPEG、GIF、WebP、SVG、响应式图片及资源包/CSS 中的图片引用会尽量写入本地 EPUB；固定版式、动态内容仍受 KOReader 排版引擎能力限制。

阅读进度与阅读时长是两条不同的微信读书记录：定时进度同步负责手机端位置，阅读时间上报负责“今日阅读”分钟数。私人版默认仅在打开 weread-yessi 缓存书籍时自动关联并上报时长，关闭书籍或设备休眠后会停止；可在“阅读时间上报”菜单中关闭。

## 贡献

欢迎提交 issue 和 PR。提交前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。

XPointer 外部标注层仍是实验性功能，测试步骤和限制见
[原型说明](docs/xpointer-overlay-prototype.md)。

## 许可证

本项目代码采用 [GNU Affero General Public License v3.0](LICENSE)，SPDX 标识为 `AGPL-3.0-only`，与 KOReader 使用的许可证保持一致。

修改、整合或再分发本项目时，必须遵守 AGPL-3.0，保留版权和许可证声明，并按许可证要求将本项目代码或其衍生作品开源。

`fonts/NotoEmoji-Regular.ttf` 是第三方字体，采用 [SIL Open Font License 1.1](fonts/LICENSE)，不适用本项目的 AGPL-3.0。

Copyright © 2026 finlater and contributors.
