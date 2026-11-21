# SyphonPub PN · 把 PowerPoint 和 Keynote 放映接入 QLab

在同一台 Mac 上做会议或演出时，上一位讲者可能用 PowerPoint（PPT），下一位用 Keynote。**SyphonPub PN 会跟随正在放映的观众页，通过 Syphon 把画面送进同一条 QLab Camera Cue。** 操作员可以留在 QLab 里播过渡、核对新首页、叠加实体摄像机。讲者即使一直停在标题页，稍后按 GO 也能接到当前画面。

SyphonPub PN routes PowerPoint and Keynote slides to QLab over Syphon on the same Mac. It follows deck changes and continuously publishes static slides, so a Camera Cue can join while the title slide is still on screen.

[下载 v1.4.4（Apple Silicon，macOS 14.6 或更高）](https://github.com/Unreal2Real/SyphonPub-PN/releases/download/v1.4.4/SyphonPub-PN-1.4.4-macOS-arm64.zip) · [最新发布与 SHA-256 校验文件](https://github.com/Unreal2Real/SyphonPub-PN/releases/latest) · [微信联系](#联系维护者) · [English setup guide](README.en.md)

[![SyphonPub PN 信号流程：PowerPoint 和 Keynote 的观众页合入同一个 QLab Camera Cue](docs/media/syphonpub-pn.png)](docs/media/syphonpub-pn.png)

## 第一次接入 QLab

1. 在 Apple Silicon Mac 上解压发布包，将 **SyphonPub PN.app** 拖入「应用程序」。最低系统版本为 macOS 14.6。
2. 打开本场要用的放映软件，先留在编辑界面。在 SyphonPub PN 的「放映软件授权…」中，允许读取对应软件的放映状态。选择「自动跟随放映」，保留默认 **30 FPS**，点 **Start**。macOS 若请求录屏权限，请在「系统设置 → 隐私与安全性」中为 SyphonPub PN 开启录屏。若系统提示重新打开，重开后再点 Start。
3. 在 QLab 选中用于幻灯片的 **Camera Cue**，打开 **I/O → Video Input → New patch with camera device**。在发布程序 **SyphonPub PN** 下选 `SyphonPub Show Follow — Audience`，点击 **Video Input** 旁的 **Monitor**。已有视频输入的工作区可以直接选用原来的输入，并在 **Workspace Settings → Video → Video Inputs** 核对来源。
4. PowerPoint 照常开始放映。Keynote 选「播放 → 在窗口中」，再开始播放。让只显示当前页的观众窗口保持展开。先在 QLab 输入监看核对首页，再切到观众屏。

发行包采用本地签名（ad hoc），尚未使用 Apple Developer ID 签名并公证。也可以按下方说明从源码构建。若现场 Mac 由组织管理，请按管理员的安装策略操作。

这条 Syphon 信号传送视频。文稿含有带声视频时，另行配置现场音频路由，并在彩排时试听。旧测试版用户可按迁移说明重新绑定发布程序。[QLab 官方 Camera Cue 指南](https://qlab.app/docs/v5/video/camera-cues/) · [1.4.4 更新与迁移](docs/RELEASE-1.4.4.md)

## 演出中换稿

在 QLab 播放过渡 → 结束上一份放映 → 开始新稿 → 在同一个输入监看认出新首页 → GO。

一次只播放一份稿。PowerPoint 和 Keynote 可以同时打开，也可以交替上场。SyphonPub PN 会在两场之间输出黑场，取得新稿的第一张有效画面后恢复输出。整个换稿过程沿用原来的输入和 Cue，SyphonPub PN 全场只需 Start 一次。

| 现场情况 | 处理方式 |
| --- | --- |
| 标题页静止 30 秒再按 GO，怎样收到当前页？ | 保持放映和自动跟随运行。应用在 GPU 上保留最新有效画面，按 15、24、30 或 60 FPS 持续发送。可在静止期间打开输入 Monitor 核对，再启动 Cue。 |
| Keynote 已经播放，自动跟随仍在等待 | 在正在放映的 Keynote 中显示一次「演讲者显示器」，帮助核实同一文稿的观众窗口。稳定的开场顺序是先启动跟随，再开始窗口放映。 |
| 切到 QLab 后，Keynote 全屏放映变黑 | 结束这次放映，改用「播放 → 在窗口中」。窗口放映让操作员能在同一台 Mac 上留在 QLab。 |
| 临时需要捕捉浏览器窗口或整块显示器 | 在过渡期间点 Stop，切到「手动选择」，Refresh 后选中所需来源并 Start。手动模式会显示自己的来源名，请在 QLab 核对输入。 |
| 怎样让摄像机叠在幻灯片上？ | 将幻灯片 Cue 和实体摄像机 Cue 送到同一个 QLab Stage，把摄像机放在更高图层。在输入 Monitor 确认首页后，再到 Stage Monitor 核对两层的合成。 |

## 验证范围

现场使用者已完成 PowerPoint 和 Keynote 跟随流程的验收。开发验证环境为 Apple M1、macOS 27.0.1、QLab 5.6.3、PowerPoint 16.114.4 和 Keynote 15.4。

**后台 Keynote 的静止页实测。** 在 1.4.3 开发验证中，Keynote 在窗口中放映有四个刻度标记的第 2 页，另一款应用保持前台。发布端设为 30 FPS，独立 Syphon 接收器收到 245 次帧通知，39 次像素抽样全部识别出同一张 3840 × 2160 页面。日志记录的是接收器读到的画面，最终观众屏可按下方步骤另行核对。[查看逐次采样日志](Tests/Integration/Results/keynote-windowed-1.4.3.txt)

彩排时用两份首页明显不同的稿件，检查「PowerPoint → Keynote → PowerPoint」、静止 30 秒后 GO、内嵌视频，以及实体摄像机叠加后的观众屏。每次换稿都能在同一个输入监看认出新页，再把这个配置用于正式演出。

独立彩排可以使用仓库里的两份文稿，先核对幻灯片内容，再确认舞台合成。[PowerPoint 测试稿](Tests/Fixtures/SyphonPub-QA.pptx) · [可用 Keynote 打开的测试稿](Tests/Fixtures/SyphonPub-Keynote-Audience-QA.pptx)

## 从源码构建

项目使用 Swift、ScreenCaptureKit、Metal 和 Syphon。在已安装 Apple Command Line Tools 的 Apple Silicon Mac 上，从本仓库根目录运行打包脚本。输出 ZIP 位于 `build/`。

```sh
./scripts/build-local.zsh
```

源码包含只读的放映识别测试，以及用两个独立进程验证静止页与换稿的 GPU 收发测试。[运行项目测试](Tests/README.md)

## 联系维护者

想交流 PowerPoint、Keynote 接入 QLab 的现场用法，可以用微信扫一扫添加维护者 **L**，备注「SyphonPub PN」。

<a href="docs/media/wechat-contact.jpg"><img src="docs/media/wechat-contact.jpg" width="320" alt="维护者 L 的微信二维码，点击查看原图"></a>

报告问题时，请附上 macOS、QLab 和放映软件版本，说明使用 PowerPoint 还是 Keynote 窗口放映，以及 **Video Input → Monitor** 里看到的画面。[提交 GitHub Issue](https://github.com/Unreal2Real/SyphonPub-PN/issues)

## 上游与许可

SyphonPub PN 基于 Xylopyrographer 的 SyphonPub 1.2 开发。项目保留上游 MIT 许可证与版权声明。Syphon Framework 和 Metal 接口的版权及再分发条款随源码和应用分发。[上游 SyphonPub](https://github.com/Xylopyrographer/SyphonPub) · [项目许可证](LICENSE) · [Syphon Framework 声明](Licenses/Syphon-Framework.txt)
