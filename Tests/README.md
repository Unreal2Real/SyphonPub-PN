# 验证 SyphonPub PN

在 Apple Silicon Mac 上，从仓库根目录运行以下命令。需要 Apple Command Line Tools。GPU 收发测试需要已登录的图形桌面及 Python 3。默认编译、发送与接收都使用仓库附带的 Syphon SDK。

## 识别放映与权限状态

```sh
Tests/Integration/test-powerpoint-locator.sh --self-events
Tests/Integration/test-keynote-locator.sh --self-events
Tests/Integration/test-automation-consent.sh
```

这些检查使用模拟窗口和本进程的 Apple 事件响应器。覆盖观众窗口识别、演讲者窗口排除、同名或已经关闭的文稿，以及授权结果的处理。

## 用真实 GPU 发送及接收合成画面

```sh
Tests/Integration/test-capture-status.sh
Tests/Integration/build-probes.sh
python3 Tests/Integration/test-follow-publisher.py
python3 Tests/Integration/run.py continuous --switches-only
```

第一项向应用的捕捉回调注入不同状态，检查静止、暂停、恢复以及关闭旧窗口后迟到的回调。其余测试用独立进程建立临时 Syphon 来源，向发布器提交已知色块，再从接收纹理读取像素。它们按顺序检查空档黑场、A 稿、切换黑场、尺寸不同的 B 稿，确认迟加入的接收端读取 B，以及停止后旧帧失效。还会检查持续发送开关和 30、60 FPS 的帧通知。上述命令只使用测试图像。真实舞台链路仍需在 QLab 的输入监看和最终观众屏分别核对。

要做静止 30 秒后加入、重复连接 10 次和至少 10 分钟的稳定性测试，可以运行以下命令。它将首个正确画面的时间、接收通知、发送进程的 CPU 时间和常驻内存写到标准输出。

```sh
python3 Tests/Integration/run.py continuous --soak 600
```

## 可选对照

- 已在 `/Applications/QLab.app` 安装 QLab 时，用 `Tests/Integration/build-probes.sh --qlab-receiver` 重新编译，再运行收发测试。独立接收进程会加载 QLab 随附的 Syphon 框架。QLab 工作区无需打开。
- 需要比较上游 SyphonPub 1.2 时，在持有上游 `v1.2` 标签的 checkout 中运行 `Tests/Integration/build-probes.sh --with-baseline`，然后执行 `python3 Tests/Integration/run.py original --soak 30`。这项对照使用标签中的原始捕捉回调，平常验证 PN 无需准备该标签。
