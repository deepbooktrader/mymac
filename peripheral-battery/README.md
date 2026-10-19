# 外设电量 · Peripheral Battery

一个为 Mac mini 和苹果无线键盘、触控板做的本地菜单栏电量工具。

这个项目起于一个很具体的小烦恼：键盘和触控板经常快没电了才被发现，而系统里的电量信息又不够直观。最初考虑购买现成软件，后来决定自己动手，把这个日常问题做成一个属于自己的小工具。

## 下载使用（无需编译）

**[下载外设电量 v1.2.1 · M 系列 Mac](https://github.com/moonwmh/mymac/releases/download/peripheral-battery-v1.2.1/PeripheralBattery-v1.2.1-macOS-arm64.zip)** · [发布说明](https://github.com/moonwmh/mymac/releases/tag/peripheral-battery-v1.2.1)

1. 下载 ZIP 并解压，把“外设电量.app”拖入“应用程序”。
2. 双击打开，按需开启通知和登录启动。
3. 退出后，可在“访达 → 应用程序”找到它，或按 **Command + 空格**搜索“外设电量”。

下载包适用于 **Apple Silicon（M 系列）、macOS 14+**，已实测 macOS 26.3.1；其他版本尚未实测，不支持 Intel Mac。

**首次打开说明：** 此版本使用本地临时签名，尚无 Apple 开发者 ID 签名和公证。如果系统阻止打开，确认下载来源后，按照 [Apple 官方说明](https://support.apple.com/zh-cn/102445)，在“系统设置 → 隐私与安全性”选择“仍要打开”。不需要关闭系统整体安全保护。

升级时先关闭旧副本的登录启动并退出；新副本安装到“应用程序”后重新开启。详见 [安装说明](docs/INSTALL.txt)。

## 界面预览

<p align="center">
  <img src="docs/images/app-window.png" alt="外设电量 v1.2 实际运行截图：设备电量卡片、外观切换与通知设置" width="470">
</p>

实际运行截图，拍摄于 2026 年 10 月 19 日。截图中的电量与提醒阈值为拍摄时的状态，可在设置中调整。

## 当前设计

- 菜单栏显示设备图标与电量百分比，也可切换名称、电池图标样式。
- 设置窗口展示设备电量卡片，支持自定义名称。
- 每 5 秒读取系统电量，Mac 唤醒后刷新，也可手动刷新。
- 默认电量 ≤30% 时提醒，可选择 10%、20%、30%。
- 低电量数字显示橙色，≤10% 显示红色。
- 显示通知授权状态，提供开启通知、测试通知与系统设置入口。
- 同一设备持续低电量时，最多每 6 小时提醒一次。
- 可设置登录自动启动。
- 无服务器、无账号、无第三方依赖，设备信息在本机处理。

## 构建与运行

需要 Mac 和 Apple Command Line Tools（提供 Swift 编译器及 macOS SDK）。使用较新的 SDK 编译；应用和构建目标最低 macOS 14，当前实际验证环境为 Apple Silicon、macOS 26.3.1，较旧系统尚未验证。

```bash
# 尚未安装开发工具时运行
xcode-select --install

# 在工程目录执行
bash build.sh

# 打开生成的应用
open build/PeripheralBattery.app
```

构建脚本从源码生成完整 `.app`，执行本地临时签名与电量读取检查。不需要 Xcode 工程文件，也不需要付费开发者账号。

启动后会显示设置窗口，关闭窗口后仍在菜单栏运行。再次双击应用可重新打开设置。首次使用，请点击“开启通知”，再通过“测试通知”检查提醒效果。

检查系统电量而不启动界面：

```bash
build/PeripheralBattery.app/Contents/MacOS/PeripheralBattery --check
```

若要更新正在运行的应用，请先从菜单栏退出旧版，再打开新版。启用登录启动后应保持应用路径稳定；移动前先关闭自动启动，移动后重新开启。

## 工程结构

```text
Sources/PeripheralBattery.swift  主程序与设置界面
Resources/Info.plist             macOS 应用元数据
build.sh                        编译、打包、本地签名与读取检查
package.sh                      制作包含应用与安装说明的 ZIP
CHANGELOG.md                    版本记录
docs/PROJECT_STORY.md            从问题到实现的项目记录
docs/使用说明.txt                中文使用说明
```

运行 `bash package.sh` 可在 `build/` 生成发布 ZIP，并输出 SHA-256。

## 充电状态与刷新

系统报告正在充电时，菜单栏显示闪电，设备卡片显示绿色充电状态。电量上涨本身不会被当成充电证据；已接电但未充电、已充满与状态未知分别显示。界面显示最近读取系统的时间，这不是外设最后一次采样的时间。

当前版本动态加载 Apple 的 `IOPSCopyPowerSourcesByType` 外设接口。该接口属于公开不受支持的系统接口，可能随系统升级变化；无法访问时降级为电量读取，不猜测充电状态。实现依据：[Apple IOKitUser 源码](https://github.com/apple-oss-distributions/IOKitUser/blob/main/ps.subproj/IOPowerSourcesPrivate.h)。

可运行 `build/PeripheralBattery.app/Contents/MacOS/PeripheralBattery --self-test` 检查充电状态解析规则；真实插拔仍需要实机验证。

## 实现与限制

使用 AppKit 创建菜单栏项目，SwiftUI 构建设置界面，IOKit 外设电源服务读取设备电量和明确的充电状态；接口不可用时回退到 `AppleDeviceManagementHIDEventService` 电量记录并显示充电状态未知，UserNotifications 发送提醒，ServiceManagement 管理登录启动。

- 电量更新取决于外设向 macOS 上报的频率，不是秒级测量。
- 主要面向苹果键盘、触控板与鼠标，不承诺支持所有蓝牙设备。
- 系统尚未移除的休眠设备记录可能保留最近一次电量。
- 通知提交成功不等于横幅一定可见；系统通知设置和专注模式会影响显示。
- 同名设备目前共用名称设置与通知抑制记录。
- 构建产物只做本地临时签名，没有 Apple 公证；已提供无需编译的 ZIP 下载包；首次打开可能需要系统授权。

## 验证记录

- Swift 编译、本地代码签名验证通过。
- 在实际 Mac 上成功读取苹果无线键盘与触控板电量，并与系统设置对照一致。
- 已实测完整插拔：未接线 23% / 电池供电 → 接线 23% / 正在充电 → 拔线 24% / 电池供电；窗口状态同步变化。
- 状态解析自检通过；数字上涨不会被误判为充电。
- 使用者已确认菜单栏可见，并认可当前设计。
- 通知横幅与登录启动的完整行为仍待实际确认，不把代码存在等同于验证完成。

项目于 2026 年 10 月 19 日由使用者与 AI 编程助手协作完成第一轮实现与个性化调整。保留这个工程，是为了记录一次从生活里的不便，到亲手拥有解决工具的过程。
