# MVS 安装过程分析

本文分析的是 `MVS-5.0.0_x86_64_20260421/setup.sh` 的完整安装过程，以及它在安装时实际触发的调用链和系统副作用。

分析依据：

- 入口脚本：`MVS-5.0.0_x86_64_20260421/setup.sh`
- 安装载荷展开目录：`MVS-5.0.0_extracted`
- 说明：`setup.sh` 会先把 `MVS.tar.gz` 解到 `/opt/MVS`，后续真正执行的驱动、服务、桌面快捷方式脚本，大多来自解压后的 `/opt/MVS/...`，而不是包根目录里的同名副本。

## 1. 入口行为概览

`setup.sh` 不是一个“单纯解压 SDK”的脚本。它会同时做下面几类事情：

- 覆盖重装 `/opt/MVS`
- 尝试复制 Qt 字体到 `/usr/local/Qt-5.6.3/lib/fonts`
- 写 udev 规则，放开 USB3 Vision 设备和虚拟串口设备权限
- 修改当前 shell、所有用户 shell 启动文件、系统级 profile 中的 SDK 环境变量
- 刷新 SDK 库目录的 `ldconfig` 缓存
- 安装并立刻启动 GigE 驱动自启动服务
- 安装并立刻启动 ScriptServer，自行修改 USB 和网络内核参数
- 安装并立刻启动日志服务
- 安装并立刻启动 PCIe/MVFG 驱动自启动服务
- 向 `/usr/share/applications` 和所有 `/home/*` 用户桌面复制 `MVS.desktop`

## 2. 主调用链

完整主链如下：

```text
source ./setup.sh
└─ setup.sh
   ├─ source ./ExportAppName.sh
   ├─ source ~/.bashrc
   ├─ rm -rf /opt/MVS            (如果已存在)
   ├─ mkdir -p /opt/MVS
   ├─ tar -C /opt/MVS -xzf ./MVS.tar.gz
   ├─ cp /opt/MVS/bin/fonts/* -> /usr/local/Qt-5.6.3/lib/fonts   (尝试)
   ├─ bash ./set_usb_priority.sh
   ├─ bash ./set_virtualserial_priority.sh
   ├─ source ./set_env_path.sh /opt/MVS
   ├─ source ./set_sdk_version.sh
   ├─ /opt/MVS/driver/gige/unload.sh
   ├─ /opt/MVS/driver/gige/driver_self_starting.sh 1
   │  └─ 安装 /etc/init.d/DriverServer 并立刻 start
   │     └─ DriverServer
   │        ├─ 如无 gevfilter.ko 则 build.sh 编译
   │        └─ load.sh -> insmod gevfilter.ko
   ├─ /opt/MVS/bin/script_self_starting.sh 1
   │  └─ 安装 /etc/init.d/ScriptServer 并立刻 start
   │     └─ ScriptServer
   │        ├─ set_usbfs_memory_size.sh
   │        ├─ set_socket_buffer_size.sh
   │        └─ set_rp_filter.sh
   ├─ /opt/MVS/logserver/RemoveServer.sh
   ├─ /opt/MVS/logserver/InstallServer.sh
   │  └─ 安装 /etc/init.d/MvLogServer 并立刻 start
   ├─ /opt/MVS/driver/pcie/unload.sh
   ├─ /opt/MVS/driver/pcie/driver_self_starting.sh 1
   │  └─ 安装 /etc/init.d/FGDriverServer 并立刻 start
   │     └─ FGDriverServer
   │        ├─ build.sh 编译各类 PCIe/MVFG 驱动
   │        └─ load.sh -> insmod 多个 .ko，并恢复虚拟网卡配置
   ├─ /opt/MVS/bin/cpDesktop.sh
   └─ rm /opt/MVS/bin/cpDesktop.sh
```

## 3. 按执行顺序展开

### 3.1 入口准备

`setup.sh` 首先 `source ./ExportAppName.sh`，把安装名固定为 `MVS`。这也是为什么它要求用 `source ./setup.sh` 的形式执行，而不是 `./setup.sh`。脚本里用了 `return`，并且后面还要把环境变量写回当前 shell。

它随后：

- `source ~/.bashrc`
- 如果 `/opt/MVS` 不存在，则创建并解压
- 如果 `/opt/MVS` 已存在，则先整目录 `rm -rf /opt/MVS`，再重建并解压

所以这个安装器是“覆盖式重装”，不是增量安装。

### 3.2 复制字体

安装器接着检查 `/usr/local/Qt-5.6.3/lib/fonts` 是否存在：

- 不存在：创建目录并尝试从 `/opt/MVS/bin/fonts/*` 复制字体
- 已存在：直接输出 `path exist...`

这里有一个明显问题：

- 载荷里实际目录名是 `bin/Fonts/`
- `setup.sh` 用的是小写 `bin/fonts/`

在区分大小写的 Linux 文件系统上，这一步大概率会复制失败，但脚本不会中止整个安装流程。

### 3.3 写 USB 和虚拟串口 udev 规则

`setup.sh` 调用包根目录的两个脚本：

- `set_usb_priority.sh`
- `set_virtualserial_priority.sh`

它们直接写系统 udev 规则。

`set_usb_priority.sh` 的效果：

- 创建 `/etc/udev/rules.d/80-drivers-SDK-2bdf.rules`
- 给 `idVendor=="2bdf"` 的 USB 设备设置 `MODE="0666"`，新 udev 还会加 `GROUP="plugdev"`
- 执行 `udevadm trigger --action=add --subsystem-match=usb --attr-match idVendor="2bdf"`

`set_virtualserial_priority.sh` 的效果：

- 创建 `/etc/udev/rules.d/80-drivers-SDK-virtualserial.rules`
- 给 `ttyvirserial[0-9]*` 设置 `MODE="0666"`，新 udev 还会加 `GROUP="plugdev"`

这两步要求 root 权限。

### 3.4 写环境变量并刷新 SDK 动态库链接

`setup.sh` 接着：

- `source ./set_env_path.sh /opt/MVS`
- `source ./set_sdk_version.sh`

`set_env_path.sh` 的作用不只是改当前 shell，它会持久化修改多个 profile 文件：

- 当前 shell 中设置：
  - `MVCAM_SDK_PATH=/opt/MVS`
  - `MVCAM_COMMON_RUNENV=/opt/MVS/lib`
  - `MVCAM_SOFTWARE_LIBENV=/opt/MVS/lib`
  - `MVCAM_GENICAM_CLPROTOCOL=/opt/MVS/lib/CLProtocol`
  - `ALLUSERSPROFILE=/opt/MVS/MVFG`
  - `LD_LIBRARY_PATH` 追加 SDK 各架构 lib 目录
- 清理旧的 SDK 路径配置
- 追加新配置到：
  - `/home/*/.profile`
  - `/home/*/.bashrc`
  - `/home/*/.bash_profile`
  - `/etc/profile`
  - 当前用户 `~/.bashrc`
- 每改完一个文件还会 `source` 一次

这意味着安装时会直接执行这些 shell 启动文件里的已有内容。如果某个用户的 `.bashrc` 里有副作用命令，它会在安装过程中被执行。

`set_sdk_version.sh` 的作用是：

- `source /etc/profile`
- 进入 `$MVCAM_COMMON_RUNENV`
- 对 `64/`、`32/`、`armhf/`、`aarch64/`、`arm-none/` 这些子目录分别执行 `ldconfig -n`

它刷新的是 SDK 自带库目录的链接缓存，不是全局系统库扫描。

### 3.5 GigE 驱动链

安装器进入 `/opt/MVS/driver/gige` 后：

- 如果存在 `unload.sh`，先执行它
- 如果存在 `driver_self_starting.sh`，执行 `driver_self_starting.sh 1`

`unload.sh` 的作用：

- 如果内核中已加载 `gevfilter`，则 `/sbin/rmmod gevfilter`

`driver_self_starting.sh 1` 的作用：

- 把 `DriverServer` 里的 `SDK_HOME=...` 占位内容替换成真实路径 `/opt/MVS`
- 复制 `DriverServer` 到 `/etc/init.d/`
- 在 Debian 上用 `update-rc.d` 注册开机自启
- 记录当前内核版本到 `/opt/MVS/driver/kernel_version`
- 立刻启动 `/etc/init.d/DriverServer start`

`DriverServer` 在 start 时做的事：

- 读取 `/opt/MVS/driver/kernel_version`
- 如果当前 `uname -r` 与记录值不一致：
  - 更新 `kernel_version`
  - 删除 `/opt/MVS/driver/gige/*.ko`
- 如果 `gevfilter` 当前未加载：
  - 若 `/opt/MVS/driver/gige/gevfilter.ko` 不存在，则跑 `build.sh`
  - 对 `.ko` 执行 `chcon -t modules_object_t`
  - 跑 `load.sh`

`build.sh` 的效果：

- 要求 `/lib/modules/$(uname -r)/build` 存在
- 在 `/opt/MVS/driver/gige/TransportLayer` 里执行 `make clean` 和 `make`
- 成功后把 `gevfilter.ko` 挪到 `/opt/MVS/driver/gige/`

`load.sh` 的效果：

- `/sbin/insmod /opt/MVS/driver/gige/gevfilter.ko`
- 成功后把 `/dev/NeuGEVFilter` 改成 `chmod 777`

因此，GigE 驱动链的安装时副作用是：

- 安装 init 脚本 `/etc/init.d/DriverServer`
- 注册开机自启
- 可能现场编译内核模块
- 立即加载 `gevfilter`
- 修改 `/dev/NeuGEVFilter` 权限

### 3.6 ScriptServer 链

安装器随后进入 `/opt/MVS/bin`，执行：

- `script_self_starting.sh 1`

这里注意一个细节：

- `script_self_starting.sh` 会把 `ScriptServer` 内的 `SCRIPT_PATH=...` 占位值替换成真实路径 `/opt/MVS/bin`
- 然后复制到 `/etc/init.d/ScriptServer`

所以真正运行时，`ScriptServer` 执行的是 `/opt/MVS/bin/` 下的脚本，而不是包根目录里的副本。

`script_self_starting.sh 1` 的效果：

- 复制 `/opt/MVS/bin/ScriptServer` 到 `/etc/init.d/ScriptServer`
- `chmod 777 /etc/init.d/ScriptServer`
- 在 Debian 上用 `update-rc.d` 注册开机自启
- 立刻启动 `/etc/init.d/ScriptServer start`

`ScriptServer` start 顺序调用：

- `/opt/MVS/bin/set_usbfs_memory_size.sh`
- `/opt/MVS/bin/set_socket_buffer_size.sh`
- `/opt/MVS/bin/set_rp_filter.sh`

这三个脚本的副作用如下。

`set_usbfs_memory_size.sh`：

- 把 `/sys/module/usbcore/parameters/usbfs_memory_mb` 写成 `2000`
- 这是立即生效的运行时改动
- 脚本只对 “Ubuntu” 特判友好，但即使输出 `Unsupported distribution.`，只要 root 且文件可写，仍会继续写入

`set_socket_buffer_size.sh`：

- 把 `/proc/sys/net/core/wmem_max` 写成 `10485760`
- 把 `/proc/sys/net/core/rmem_max` 写成 `10485760`
- 如果 `/etc/sysctl.conf` 已有 `net.core.rmem_max`/`net.core.wmem_max`，则覆盖
- 否则追加：
  - `net.core.rmem_max = 10485760`
  - `net.core.wmem_max = 10485760`

`set_rp_filter.sh`：

- 默认把 `MODE` 设成 `0`
- 即把所有 `/proc/sys/net/ipv4/conf/*/rp_filter` 写成 `0`
- 持久化到 `/etc/sysctl.conf`：
  - `net.ipv4.conf.default.rp_filter = 0`
- 默认会重启网络栈：
  - 若有 `/etc/init.d/network`，则 `service network restart`
  - 否则优先 `systemctl restart NetworkManager.service`
  - 否则 `service network-manager restart`

这一步是安装时最激进的系统参数修改之一，因为它会立刻改网络参数并重启网络管理组件。

### 3.7 日志服务链

安装器进入 `/opt/MVS/logserver` 后，固定执行：

- `./RemoveServer.sh`
- `./InstallServer.sh`

`RemoveServer.sh` 的效果：

- `service MvLogServer stop`
- 移除旧自启动配置
- 删除 `/etc/init.d/MvLogServer`
- 删除 `/var/run/MvLogServer.pid`

`InstallServer.sh` 的效果：

- 读取 `Path.ini`，得到日志根目录 `/var/log/MVS`
- 根据系统类型选择 `Debian/MvLogServerd`、`Redhat/MvLogServerd`、`Kylin/MvLogServerd` 或 `OpenEuler/MvLogServerd`
- 把脚本里的 `SDK_HOME=...` 占位路径替换成真实 `/opt/MVS`
- 拷贝到 `/etc/init.d/MvLogServer`
- 注册开机自启
- 立刻 `service MvLogServer start`
- 把 `LogServer.ini` 复制到 `/var/log/MVS/MvSdkLog/`

Debian 版 `MvLogServerd` 的实际动作：

- 使用 `start-stop-daemon`
- 启动 `/opt/MVS/logserver/MvLogServer`
- 维护 pid 文件 `/var/run/MvLogServer.pid`

因此，日志服务链的副作用是：

- 安装 init 脚本 `/etc/init.d/MvLogServer`
- 注册自启动
- 立刻启动常驻日志服务进程
- 把日志配置放到 `/var/log/MVS/MvSdkLog/LogServer.ini`

### 3.8 PCIe / MVFG 驱动链

安装器进入 `/opt/MVS/driver/pcie` 后：

- 先执行 `unload.sh`
- 再执行 `driver_self_starting.sh 1`

`pcie/unload.sh` 的效果：

- 在非 rk3588 平台上先清空 `./static_virnic_config.ini`
- 执行二进制 `./save_virnic_settings`
- 逐个尝试卸载这些模块：
  - `gevframegrabber`
  - `cxpframegrabber`
  - `xofframegrabber`
  - `cmlframegrabber`
  - `mvfgvirtualserial`
  - `lightcontroller`

`save_virnic_settings` 是二进制。结合其字符串可以判断：

- 它会通过 `nmcli` 读取和删除 `mvfg*` 虚拟网卡相关连接
- 可能会把静态 IP / gateway / managed 状态保存到 `static_virnic_config.ini`

`driver_self_starting.sh 1` 的效果：

- 把 `FGDriverServer` 里的 `SDK_HOME=...` 占位值替换成 `/opt/MVS`
- 复制到 `/etc/init.d/FGDriverServer`
- 注册开机自启
- 写 `/opt/MVS/driver/kernel_version`
- 立刻启动 `/etc/init.d/FGDriverServer start`

`FGDriverServer` start 的动作：

- 读取 `/opt/MVS/driver/kernel_version`
- 若内核版本变化，则更新记录并删除 `/opt/MVS/driver/pcie/*.ko`
- 无条件调用 `build.sh`
- 对生成的 `.ko` 执行 `chcon -t modules_object_t`
- 调用 `load.sh`

`pcie/build.sh` 在 x86_64 非 rk3588 平台上的逻辑：

- 要求 `/lib/modules/$(uname -r)/build` 存在
- 逐个处理下面这些驱动目录：
  - `gev`
  - `cxp`
  - `xof`
  - `cml`
  - `virtualserial`
  - `lightcontroller`
- 默认执行 `make clean`、`make`
- `xof` 会额外带 `XOF_SUPPORTED=Yes`
- 成功后把生成的 `.ko` 移到 `/opt/MVS/driver/pcie/`

目标模块名分别是：

- `gevframegrabber.ko`
- `cxpframegrabber.ko`
- `xofframegrabber.ko`
- `cmlframegrabber.ko`
- `mvfgvirtualserial.ko`
- `lightcontroller.ko`

`pcie/load.sh` 的效果：

- 对上面存在的 `.ko` 逐个 `insmod`
- 跳过不存在或已加载的模块
- 最后：
  - `chmod 777 /dev/mvfg*`
  - `chmod 777 /dev/ttyvirserial*`
  - 在非 rk3588 上执行 `./load_virnic_settings`

`load_virnic_settings` 也是二进制。结合字符串可以判断：

- 它会通过 `nmcli` 恢复 `mvfg*` 虚拟网卡的静态连接
- 可能会创建 `static-%s` 形式的连接名
- 会执行 `nmcli connection add ... ipv4.addresses ... ipv4.gateway ... ipv4.method manual`
- 会执行 `nmcli device set %s managed yes`
- 会执行 `nmcli device connect %s`

因此，PCIe / MVFG 驱动链的安装时副作用是：

- 安装 `/etc/init.d/FGDriverServer`
- 注册开机自启
- 可能现场编译 6 类内核模块
- 立刻加载这些模块
- 修改 `/dev/mvfg*` 和 `/dev/ttyvirserial*` 权限
- 修改或恢复由 `nmcli` 管理的虚拟网卡连接配置

### 3.9 桌面快捷方式分发

最后，安装器在 `/opt/MVS/bin` 执行 `cpDesktop.sh`，随后删除它自己：

- `./cpDesktop.sh`
- `rm cpDesktop.sh`

`cpDesktop.sh` 的效果：

- 把 `/opt/MVS/bin/MVS.desktop` 复制到 `/usr/share/applications/`
- 枚举 `ls /home/` 得到所有用户
- 对每个用户：
  - 优先找桌面目录：
    - `~/桌面`
    - `~/Desktop`
    - `~/Escritorio`
    - `~/Bureau`
    - `~/Schreibtisch`
  - 如果都没有，则退回用户 home 根目录
  - 复制 `MVS.desktop`
  - `chmod +x`
  - `chown user:user`
  - 用 `gio set metadata::trusted true` 尝试标记为可信启动器
- 脚本结束前删除源文件 `/opt/MVS/bin/MVS.desktop`

`MVS.desktop` 本身指向：

- `Exec=/opt/MVS/bin/MVS.sh`
- `Icon=/opt/MVS/bin/MVS.ico`

这一步会直接改所有 `/home/*` 用户目录，不做用户筛选。

## 4. 最终副作用总表

### 4.1 文件系统持久化修改

- 覆盖安装目录 `/opt/MVS`
- 可能创建 `/usr/local/Qt-5.6.3/lib/fonts`
- 写入 `/etc/udev/rules.d/80-drivers-SDK-2bdf.rules`
- 写入 `/etc/udev/rules.d/80-drivers-SDK-virtualserial.rules`
- 修改 `/home/*/.profile`
- 修改 `/home/*/.bashrc`
- 修改 `/home/*/.bash_profile`
- 修改 `/etc/profile`
- 修改 `/etc/sysctl.conf`
- 写入 `/etc/init.d/DriverServer`
- 写入 `/etc/init.d/ScriptServer`
- 写入 `/etc/init.d/MvLogServer`
- 写入 `/etc/init.d/FGDriverServer`
- 写入 `/var/log/MVS/MvSdkLog/LogServer.ini`
- 写入 `/usr/share/applications/MVS.desktop`
- 向所有 `/home/*` 用户桌面或 home 目录复制 `MVS.desktop`

### 4.2 运行时系统改动

- 可能重启网络栈或 `NetworkManager`
- 可能现场编译内核模块
- 加载内核模块：
  - `gevfilter`
  - `gevframegrabber`
  - `cxpframegrabber`
  - `xofframegrabber`
  - `cmlframegrabber`
  - `mvfgvirtualserial`
  - `lightcontroller`
- 启动常驻服务：
  - `MvLogServer`
- 写运行时 sysfs / procfs：
  - `/sys/module/usbcore/parameters/usbfs_memory_mb = 2000`
  - `/proc/sys/net/core/wmem_max = 10485760`
  - `/proc/sys/net/core/rmem_max = 10485760`
  - `/proc/sys/net/ipv4/conf/*/rp_filter = 0`

### 4.3 设备节点权限修改

- `chmod 777 /dev/NeuGEVFilter`
- `chmod 777 /dev/mvfg*`
- `chmod 777 /dev/ttyvirserial*`

### 4.4 自启动注册

在 Debian 系系统上，安装器会通过 `update-rc.d` 注册以下服务开机自启：

- `DriverServer`
- `ScriptServer`
- `MvLogServer`
- `FGDriverServer`

## 5. 重要注意事项

### 5.1 这是覆盖式安装

只要 `/opt/MVS` 已存在，`setup.sh` 就会先整目录删除再重装。用户在 `/opt/MVS` 下做的本地改动都会丢失。

### 5.2 它会执行用户 shell 启动文件

`setup.sh` 自己先 `source ~/.bashrc`，`set_env_path.sh` 又会在修改后 `source` 多个 profile 文件。这意味着安装过程会执行这些文件里已有的 shell 逻辑。

### 5.3 它会改全局网络参数并重启网络

`ScriptServer` 链会：

- 改 socket buffer
- 改 `rp_filter`
- 重启网络服务

这不是单纯的 SDK 本地配置，而是全局系统网络行为变更。

### 5.4 驱动编译依赖内核头文件

在 x86_64 版本中，安装载荷目录里没有现成的 `.ko`。因此首次安装通常依赖：

- `/lib/modules/$(uname -r)/build`

如果缺内核头文件或构建环境，驱动编译会失败。

### 5.5 脚本容错差，但默认继续跑

整个 `setup.sh` 没有 `set -e`。很多下游脚本即使失败，安装主链也不会立即停下。常见结果是：

- 某些驱动没编译出来
- 某些模块没加载成功
- 字体没复制成功
- 桌面信任属性没设置成功

但安装主脚本仍然会打印 `Install MVS complete!`

### 5.6 字体复制路径大小写可能写错

安装器尝试复制 `bin/fonts/*`，但载荷中实际是 `bin/Fonts/`。在普通 Linux 文件系统上，这一步很可能无效。

## 6. 一句话总结

`MVS-5.0.0_x86_64_20260421/setup.sh` 的本质是一个“重装 SDK + 改系统环境 + 编译并加载驱动 + 改网络参数 + 装系统服务 + 发桌面快捷方式”的综合安装器，而不是一个只在 `/opt/MVS` 内部落文件的无副作用解压脚本。
