# SyphonPub PN 1.4.4

**PowerPoint 换成 Keynote，QLab 继续用同一条 Camera Cue。** 这是首次以 **SyphonPub PN** 为名发布的版本（Build 31），延续先前验证过的自动跟随与静止画面连续输出功能。

## 下载与系统要求

发布文件为 `SyphonPub-PN-1.4.4-macOS-arm64.zip`，适用于 Apple Silicon Mac，最低 macOS 14.6。解压后将 **SyphonPub PN.app** 移至「应用程序」。[v1.4.4 发布页](https://github.com/Unreal2Real/SyphonPub-PN/releases/tag/v1.4.4)

## 演出时的三个操作

1. 开场前在 SyphonPub PN 点一次 **Start**。PowerPoint 照常放映，Keynote 选择「播放 → 在窗口中」。
2. 把 QLab Camera Cue 接到 **SyphonPub PN / SyphonPub Show Follow — Audience**。留在同一页时，程序会按设定帧率持续发布。默认 30 FPS。
3. 换稿前先播放 QLab 过渡，结束上一份放映，再开始新稿。两个放映之间应用输出黑场。在输入 **Monitor** 看到新首页后，再切回同一条 Cue。

## 从测试版迁移

在彩排空档退出 **SyphonPub Show Follow Test**，打开新版。如果 macOS 请求录屏或自动化权限，请核对名称为 **SyphonPub PN** 并按提示允许及重新打开。自动跟随的来源名仍为 **SyphonPub Show Follow — Audience**。由于发布程序改名，已有工作区可在彩排时给原 Camera Cue 的输入重新绑定一次。用两份首页明显不同的稿件验证切换后，再沿用此次绑定。

初次安装、窗口放映晚加入以及手动捕捉的操作见[项目使用说明](https://github.com/Unreal2Real/SyphonPub-PN/blob/v1.4.4/README.md)。
