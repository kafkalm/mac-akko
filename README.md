<p align="center"><img src="assets/icon.png" width="128" alt="Mac-Akko"></p>

# mac-akko

**Mac-Akko** 是一个 macOS 菜单栏工具，用来看 Akko 键盘电量、调灯光。

- 电量百分比，一眼可见。
- 灯光开关、四档亮度、八种灯效，支持动画预览。
- 适配浅色和深色模式，数据仅保存在本机。

<img src="assets/preview.png" width="344" alt="Mac-Akko 界面示例，电量为演示数据">

## 使用条件

- Apple Silicon Mac，macOS 14+。
- 当前适配 Akko Armor Alice 蛇年限定版（ID 2655，固件 109）。USB 灯光开关和亮度已实测。
- 电量显示为估算值，需要带 ABT1 遥测扩展的固件和本机满电标定；原厂固件暂不支持这套估算。固件不包含在下载包中。

## 安装

1. 从 [Releases](https://github.com/kafkalm/mac-akko/releases) 下载并解压，将 `Mac-Akko.app` 放进“应用程序”。
2. 打开应用，在“系统设置 → 隐私与安全 → 输入监控”中允许 Mac-Akko，然后重开。
3. 点击菜单栏键盘图标。蓝牙下查看电量，有线下调节灯光。

当前版本尚未经过 Apple 公证，首次打开可能被系统拦截。

## 构建

安装 Xcode Command Line Tools 后运行：

```sh
zsh scripts/build.sh
open build/Mac-Akko.app
```

打包：`zsh scripts/package.sh`。

## 许可

[MIT](LICENSE) · [第三方许可](THIRD-PARTY-NOTICES.txt)
