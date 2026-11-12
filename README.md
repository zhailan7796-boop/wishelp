<h1 align="center">随屏</h1>
<p align="center"><strong>副屏点开的应用，在副屏接着用。</strong></p>
<p align="center">
  <a href="https://github.com/zhailan7796-boop/wishelp/releases/download/v0.3.3/TaskbarFollow-0.3.3-portable.zip"><strong>下载 Windows 便携版 ↓</strong></a>
  ·
  <a href="https://github.com/zhailan7796-boop/wishelp/releases">查看版本</a>
</p>
<p align="center">Windows 11 x64 · v0.3.3 · 解压即用</p>

## 少一次把窗口拖回来的动作

主屏上开着文档，你在副屏的任务栏点开浏览器，窗口却盖到了文档上。随屏会尝试让打开或恢复的应用窗口出现在你点击任务栏的那块屏幕，少一次来回拖拽。

- **先看一眼再打开。** 悬停在任务栏的窗口缩略图上，可以在当前屏幕预览，原窗口留在原位。
- **想暂停就暂停。** 按 `Ctrl+Alt+F12` 切换跟随状态，也可以从托盘打开状态窗口操作。
- **接上副屏再启动。** 可在托盘菜单开启「连接第二块屏幕时自动启动」。

## 三步开始

1. 下载便携 ZIP，完整解压到任意文件夹。
2. 双击 `Start.exe`，等状态显示「运行中」。运行时随包附带。
3. 把一个应用最小化，再从另一块屏幕的任务栏点它，看看窗口出现在哪块屏幕。

遇到问题可以从状态窗口打开「兼容性诊断」，再到 [Issues](https://github.com/zhailan7796-boop/wishelp/issues) 反馈系统版本、应用名称和复现步骤。

## 桌面图标开关

共享屏幕前，点一下奶牛猫就能收起桌面图标。再点一次即可恢复。适用于 Windows 10 22H2 和 Windows 11。 [查看用法与下载](desktop-icon-toggle/README.md)

## 源码与构建

程序入口为 [TaskbarFollow.ahk](TaskbarFollow.ahk)。[lib/](lib) 包含状态窗口和应用识别代码，[native/](native) 包含 Windows 窗口定位组件，[tests/](tests) 包含回归检查。

在 Windows 上安装 Visual C++ x64 工具和 Windows SDK 后，运行 `build.ps1` 构建便携包。详见[原生定位设计](docs/NATIVE-ENGINE.md)、[项目许可证](LICENSE)和[第三方组件说明](THIRD-PARTY-NOTICES.md)。
