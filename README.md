# Visyn

Visyn（Vision + Synapse）是一个 iOS 15+ Swift Package，封装 ReplayKit 屏幕采集、自定义画中画，以及通过 MMWormhole 向主 App 传递屏幕帧的能力。

## 先运行 Demo

打开 [Examples/VisynDemo/VisynDemo.xcodeproj](Examples/VisynDemo/VisynDemo.xcodeproj)，选择共享 Scheme **VisynDemo**。

Demo 来自最初的录屏测试页，包含：

- 系统面板开始／停止录屏。
- 显示主程序收到的屏幕帧数量和尺寸。
- 开启／关闭白底、居中「测试中」的画中画。
- 展示录屏状态和错误。

模拟器可编译、查看页面和运行通信测试；录屏授权、跨 App 采集、后台与 PiP 效果需要真机验证。

Demo 默认不指定开发团队。Bundle ID 为示例 `com.example.VisynDemo`，App Group 按 `group.$(VISYN_DEMO_BUNDLE_ID)` 推导，避免在 entitlement 中生成空字符串。示例标识不能代替你账号下的有效签名配置；本地可以显式覆盖 App Group。

运行功能前，将 [Configuration.local.xcconfig.example](Examples/VisynDemo/Configuration.local.xcconfig.example) 复制为同目录的 `Configuration.local.xcconfig`，填入自己的 Team ID、唯一 Bundle ID 和已启用的 App Group。该文件已加入 `.gitignore`，不随 Demo 提供；模板里的值仅供示意，必须替换。两个 Target 都继承这里的 Team，避免只在主 App 的 Signing 页面选择团队。

```xcconfig
DEVELOPMENT_TEAM = YOUR_TEAM_ID
VISYN_DEMO_BUNDLE_ID = com.yourcompany.VisynDemo
VISYN_APP_GROUP = group.com.yourcompany.VisynDemo
```

在 Apple Developer / Xcode Signing & Capabilities 中，为 Demo 主 App 和广播扩展启用同一个 App Group。两端的 Bundle ID、plist 和 entitlements 都从 [Configuration.xcconfig](Examples/VisynDemo/Configuration.xcconfig) 继承配置，无需分别替换源码字符串。项目不包含个人签名信息。

已填写的 `Configuration.local.xcconfig` 应保留在本机；`.gitignore` 只阻止其进入 Git，不会阻止 Xcode 读取。不要为了清理公共模板而删除该文件。主 App 的 Team 设置不会自动传给扩展；本地配置通过项目级 Debug / Release 配置让两个 Target 共用同一组签名设置。

### 签名错误排查

- `Container identifier can not be an empty string`：检查 `VISYN_APP_GROUP` 是否为空；entitlement 数组不能包含空字符串。
- `profile doesn't support / match the App Group`：两个 App ID 必须启用同一个已注册的 App Group，再让 Xcode 自动签名更新描述文件；只在 plist 中填写名称不会创建或授权 App Group。
- `Signing ... requires a development team`：主 App 和扩展都需要同一个 Team；通过本地配置统一填写。
- 修改 Bundle ID 时使用 `VISYN_DEMO_BUNDLE_ID`，不要只覆盖主 App 的 `PRODUCT_BUNDLE_IDENTIFIER`，否则扩展 ID 和录屏选择器可能不一致。

## SPM 接入

在 Xcode 的 Add Package Dependencies 中选择 **Add Local**，添加包含 `Package.swift` 的 Visyn 根目录。Demo 使用相对路径 `../..` 引用同一份库，整个目录搬到其他电脑也可解析；无需 CocoaPods。

| 使用方 | 链接的 product | 入口 |
| --- | --- | --- |
| 主 App | `VisynCapture` | `VisynCaptureController` |
| Broadcast Upload Extension | `VisynBroadcast` | `VisynBroadcastSampleHandler` |
| 共享实现 | `VisynTransport`（内部 target） | `VisynConfiguration`、`VisynCapturedFrame`、`VisynBroadcastState` |

SPM 提供库代码；`.appex` 仍由 Xcode Target 构建、签名并嵌入主 App。主 App 需要 Background Modes / Audio，两端需要相同 App Group entitlement。

两端 Info.plist 都配置：

```xml
<key>VisynAppGroupIdentifier</key>
<string>group.com.yourcompany.YourApp</string>
<key>VisynExtensionIdentifier</key>
<string>com.yourcompany.YourApp.BroadcastExtension</string>
```

主 App 的 UIViewController 持有 controller：

```swift
import VisynCapture

private var capture: VisynCaptureController?

func configureCapture() throws {
    let controller = try VisynCaptureController(
        configuration: .load(),
        pictureInPictureContent: makePiPContent() // 自定义 UIView
    )
    controller.onFrame = { frame in
        // frame.jpegData 是方向归一化后的 JPEG。
        // 在主程序中消费，不要把原图或聊天内容写入日志。
    }
    controller.onStateChange = { state in /* 更新 UI */ }
    controller.onError = { error in /* 展示错误 */ }
    controller.prepare(on: view)
    capture = controller
}

// 用户按钮触发，仍须系统面板确认。
func recordTapped() { capture?.showBroadcastPicker(on: view) }
func pipTapped() { capture?.togglePictureInPicture() }
```

广播扩展只需一个本地子类，并在扩展 plist 的 `NSExtensionPrincipalClass` 指向它：

```swift
import VisynBroadcast

final class SampleHandler: VisynBroadcastSampleHandler {}
```

扩展须保留 `com.apple.broadcast-services-upload`、`RPBroadcastProcessModeSampleBuffer` 配置及合法显示名、版本号和构建号；可直接参考 Demo。

## 目录

```text
Visyn/
├── Package.swift
├── Sources/
│   ├── VisynCapture/       # 主 App 入口、PiP、静音承载视频
│   ├── VisynBroadcast/     # ReplayKit 回调、帧节流和编码
│   └── VisynTransport/     # 消息类型和 Wormhole 封装
├── Tests/VisynTransportTests/
├── Vendor/MMWormhole/      # 上游 2.0.0 文件传输核心及 MIT 许可证
└── Examples/VisynDemo/     # 独立 App + Broadcast Extension 工程
```

## 数据与生命周期

`ReplayKit → VisynBroadcast → VisynTransport / MMWormhole → App Group → VisynCaptureController.onFrame`

- `VisynBroadcastStatus`：session ID、broadcasting/paused/stopped、更新时间。扩展每秒续期；6 秒无更新按停止处理。
- `VisynCapturedFrame`：frame ID、session ID、采集时间、尺寸和 JPEG。每 0.3 秒最多一帧、长边不超过 1280、质量 0.7、JPEG 最大 2 MB；不传音频，不做 OCR 或模型请求。
- `VisynWormholeChannel` 使用 App Group 内的 `Visyn` 临时目录。消息名称加 App Group 命名空间，按最新值传递，不保证每帧送达。
- 最多一个未消费帧；消费后删除，扩展定时清理超过 2 秒的未消费帧，开始／暂停／停止时清理。两端同时被系统终止时，最后一帧可能保留到下次启动清理；目录排除备份并启用设备文件保护。
- Darwin 通知不会唤醒被挂起的主 App；恢复后读取最新状态并丢弃过期帧。这里不生成录像或保存截图历史。

## 测试

在 Visyn 根目录运行：

```sh
xcodebuild -scheme Visyn-Package \
  -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' test

xcodebuild -project Examples/VisynDemo/VisynDemo.xcodeproj \
  -scheme VisynDemo -destination 'generic/platform=iOS Simulator' \
  build CODE_SIGNING_ALLOWED=NO
```

通信测试使用独立临时目录和真实 MMWormhole 实例，验证通知、二进制帧、清理、错误格式和过期／超限拒收。真机手动检查：系统授权／取消 → 收帧计数增长 → 白底「测试中」PiP → 切换其他 App → 返回 → 停止；另检查暂停／恢复和扩展终止后的状态复位。

## 兼容性与依赖

画中画使用 iOS 15+ 的 `AVSampleBufferDisplayLayer` 内容源，将调用方传入的 View 渲染为 828 × 160 视频帧，每秒更新两次。使用公开 PiP API，不再查找系统私有窗口、设置 `controlsStyle` 或播放静音承载视频，因此不会因找不到私有窗口而在启动后超时关闭。内容按 414 × 80 点布局；当前 CPU 渲染适用于 UILabel 等普通 UIKit 内容，不支持依赖独立视频或 Metal 渲染表面的视图，也不接收触摸。系统仍保留 PiP 的播放控件。

MMWormhole 2.0.0 上游没有 SPM manifest，本项目将其文件通信核心封装为 Objective-C target，保留原名称、来源及 [MIT 许可证](Vendor/MMWormhole/LICENSE)，不引入 WatchConnectivity。
