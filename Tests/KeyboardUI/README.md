# iOS 键盘回归测试

该套件在独立 UIKit 应用的文本框中操作系统安装的 Yah 键盘，检查候选选择后的实际文本。需要 Xcode、可用的 iPhone 模拟器和 PATH 中的 XcodeGen。请使用专用模拟器，脚本会为语音跳转用例撤销该模拟器上 Yah 的麦克风权限。

## 首次配置

1. 启动一台 iPhone 模拟器，关闭 Simulator 菜单 **I/O → Keyboard → Connect Hardware Keyboard**。测试中的系统键盘切换器使用英文标签，建议选用英语系统。
2. 在仓库根目录运行 `Tests/KeyboardUI/run.sh --install` 安装 Yah。在模拟器的 **Settings → General → Keyboard → Keyboards → Add New Keyboard** 中添加 **Yah**，打开 Yah 主应用一次。
3. 在普通文本框里用地球键选中 Yah。使用内置全拼和简体开始测试。

## 运行

```sh
Tests/KeyboardUI/run.sh
```

有多台模拟器时，用 `xcrun simctl list devices` 找到目标 UDID，再运行 `Tests/KeyboardUI/run.sh "$DEVICE_UDID"`。首次安装同样支持 `--install "$DEVICE_UDID"`。脚本串行运行测试。控制台会打印临时目录，可在 Xcode 打开其中的 `KeyboardUI.xcresult` 查看每一步和失败现场。

只跑一个测试类可执行 `Tests/KeyboardUI/run.sh "$DEVICE_UDID" -only-testing:KeyboardUITests/SegmentEditing`。反复开发时可将 `YAH_BUILD_DIR` 和 `YAH_PACKAGE_CACHE` 分别指向自己的 Yah DerivedData 和 SwiftPM 缓存。设置 `YAH_APP_BUNDLE` 可以测试已经构建的 iOS Simulator 版 Yah.app。

## 断言

- 展开候选，按字数过滤，收起后再次打开并选词，选择超出首个 Rime 页的候选。
- 全拼上下行边界纠错、双误触与退格撤回，小鹤和九宫格边缘纠错，自然码上屏，以及上划输入数字。
- 跨字母与数字布局输入 Unicode，撤销部分选中的分段继续编辑，输入包含 Wi-Fi 和 ChatGPT 的混合句。
- 全拼和双拼回车上屏英文字母（忽略手动分词符），空格仍选首个候选；九宫格、编码输入与部分选词时回车确认候选。没有可确认的候选时保留输入以供编辑。
- 简体、通用繁体、台湾繁体与香港繁体的实际词形。重开接收应用后保留上次选择。
- 未开启完全访问时，确认键盘只有一个语音入口，点击后在当前应用显示提示，仍可打字。

Host 待机接力录音和第三方转写需要在真机开启完全访问并配置 API Key 后验证。
