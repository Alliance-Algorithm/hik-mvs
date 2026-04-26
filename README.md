# hik-mvs

海康威视 MVS（Machine Vision Software）客户端的非官方镜像仓库。

## 为什么需要这个仓库

海康威视官方下载页面（[hikrobotics.com](https://www.hikrobotics.com/cn/machinevision/service/download)）禁止了非浏览器直接下载，导致 CI 流水线和自动化工具无法从官方源拉取。

本仓库在 GitHub Release 中镜像了 MVS SDK，同时提供裁剪后的 AppImage 打包，替代官方安装方式。

## 仓库内容

### Release 文件

每个 Release 包含 4 个文件，按字母序自然分组：

| 文件 | 用途 |
|------|------|
| `mvs-app-{tag}-x86_64.AppImage` | 面向 x86_64 的便携式 MVS 客户端 |
| `mvs-app-{tag}-aarch64.AppImage` | 面向 aarch64 的便携式 MVS 客户端 |
| `mvs-sdk-x86_64.tar.gz` | 原始 x86_64 SDK（从官方 zip 提取，供下游 Dockerfile 使用） |
| `mvs-sdk-aarch64.tar.gz` | 原始 aarch64 SDK（从官方 zip 提取，供下游 Dockerfile 使用） |

### 脚本

| 文件 | 说明 |
|------|------|
| `package-appimage.sh` | 从 Release 下载 SDK，打包为 AppImage。详见 [打包与验证](#打包与验证) |

## 为什么用 AppImage 代替官方安装

海康官方的 `setup.sh` 安装脚本不是简单的文件解压——它会做大量系统级修改（详见 [`docs/what-did-mvs-installation-do.md`](docs/what-did-mvs-installation-do.md)）：

- **写 udev 规则**：修改 USB 设备和虚拟串口的权限
- **修改全局环境变量**：向 `/etc/profile`、所有用户的 `.bashrc`/`.profile` 写入 SDK 路径
- **安装系统服务**：注册 `DriverServer`、`ScriptServer`、`MvLogServer`、`FGDriverServer` 四个开机自启服务
- **编译并加载内核模块**：GigE、PCIe、MVFG 等驱动模块
- **修改网络参数**：改写 `rp_filter`、socket buffer 大小，**可能重启网络栈**
- **向所有用户桌面复制快捷方式**

AppImage 完全绕过这套安装流程：
- **零系统修改**：不写 udev 规则、不改 profile、不装 init 脚本、不编译内核模块
- **自包含**：Qt 运行时、SDK 库、配置文件全部打包在单个文件中
- **即删即用**：删除 AppImage 文件即完成卸载，无残留

> **⚠️ 已知限制**：当前 AppImage 仅保留 **USB3 Vision** 相机的支持。SDK 中移除了以下内容：
> - GigE Vision 驱动库（`libMVGigEVisionSDK.so`）
> - CameraLink / CXP / XoF 采集卡驱动
> - MVFG 帧抓取器驱动及 PCIe 内核模块
> - 虚拟相机（`VirtualCamera`）、帧抓取器配置工具
>
> **其它类型相机（网口相机、CameraLink 相机等）未经测试，不具备对应的驱动支持。** 如需支持，需自行保留相关库并安装对应的内核模块。
>
> AppImage 依赖宿主机的 `libusb-1.0.so.0`。厂商自带的 libusb 版本老旧，打包时被移除——运行时由系统提供。除了 `libusb`，AppImage 还依赖宿主机的 X11、OpenGL、libudev 等标准系统库，这些在所有主流桌面发行版上均已预装。如需手动安装：`apt install libusb-1.0-0 libgl1 libxcb-icccm4`。

## 更新指南

### 1. 下载官方安装包

访问 [海康机器人 Machine Vision 下载中心](https://www.hikrobotics.com/cn/machinevision/service/download)，下载最新 MVS 客户端压缩包。

下载文件名格式：`MVS_Linux_STD_V{version}_{date}.zip`

### 2. 提取所需架构的 SDK

```bash
unzip MVS_Linux_STD_V{version}_{date}.zip
```

解压后，在目录内找到以下文件：

| 架构 | 所需文件 |
|------|---------|
| x86_64 | `MVS-{version}_x86_64_{date}.tar.gz` |
| aarch64 | `MVS-{version}_aarch64_{date}.tar.gz` |

> 注：只需这两个 tar.gz。`.deb` 包和 `i386`/`arm-none` 架构文件不需要。

接着解压这两个 tar.gz：

```bash
# x86_64
tar -xzf MVS-{version}_x86_64_{date}.tar.gz

# aarch64
tar -xzf MVS-{version}_aarch64_{date}.tar.gz
```

解压后得到两个目录（如 `MVS-5.0.0_x86_64_20260421/`），每个目录内包含 `MVS.tar.gz`（实际的 SDK 载荷）及安装脚本等。我们只需要其中的 `MVS.tar.gz`。

### 3. 创建 Release

将两个 `MVS.tar.gz` 重命名并上传到本仓库的 GitHub Release：

```bash
# x86_64
mv MVS-{version}_x86_64_{date}/MVS.tar.gz mvs-sdk-x86_64.tar.gz

# aarch64
mv MVS-{version}_aarch64_{date}/MVS.tar.gz mvs-sdk-aarch64.tar.gz
```

创建 Release 并上传这两个文件。

### 4. 自动构建 AppImage

Release 创建（`published` 事件）会自动触发 GitHub Actions workflow，在 x86_64 runner 上：

1. 下载两个架构的 `mvs-sdk-*.tar.gz`
2. 打包 `mvs-app-{tag}-x86_64.AppImage`
3. 打包 `mvs-app-{tag}-aarch64.AppImage`
4. 将两个 AppImage 上传回同一 Release

完成后 Release 中会包含 4 个文件（2 SDK + 2 AppImage）。

## 打包与验证

### 本地打包

```bash
# 自动从最新 Release 下载并打包
./package-appimage.sh                    # amd64（自动检测）
./package-appimage.sh --arch arm64      # arm64

# 使用本地 SDK tarball
./package-appimage.sh --arch amd64 --source ./mvs-sdk-x86_64.tar.gz
```

### 验证依赖

```bash
output/mvs-app-test-x86_64.AppImage --appimage-extract
LD_LIBRARY_PATH=squashfs-root/mvs-gui/bin:squashfs-root/mvs-usb3-core/lib/64:squashfs-root/mvs-usb3-core/lib/64/ThirdParty \
  ldd squashfs-root/mvs-gui/bin/MVS | grep 'not found'
# 期望输出：空（无缺失依赖）
```

### CI 手动触发

GitHub Actions → Build AppImage → Run workflow → 可选指定 release tag（默认 latest）。

## AppImage 技术细节

- AppDir 布局分为 `/opt/mvs-usb3-core` 和 `/opt/mvs-gui` 双目录
- 运行时通过符号链接将可写目录（Temp、Cfg）映射到 `/tmp/mvs-runtime/`
- 使用 `AppImage/appimagetool` 在 x86_64 主机上交叉打包 aarch64 AppImage（无需 QEMU）
- SDK 保留 USB3 Vision 核心库，移除非必需驱动（GigE、CameraLink、MVFG 等）
