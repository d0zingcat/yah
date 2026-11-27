# Yah iOS TestFlight 打包操作报告

2026 年 11 月 27 日，从 `fe6937e` 对应的工作区重新归档 Yah iOS。主应用和键盘扩展的构建号均为 `6`。Xcode 27.2 成功导出约 109 MiB 的 IPA，签名验证通过，Apple 处理后将 `0.1 (6)` 分发到 **Yah Internal**。最终状态为 `VALID` 和 `IN_BETA_TESTING`。[App Store Connect 构建记录](https://appstoreconnect.apple.com/apps/6839642767/testflight/ios/1de3c409-1abc-4f91-893c-b649004d5776)

## 1. 确认源码、应用和构建号

在仓库根目录运行。Mac 上需要 Xcode、可用的项目依赖、团队签名配置和已登录的 `asc`。命令速查见 [ASC.md](ASC.md)。

```sh
git status --short
git rev-parse --short HEAD
xcodebuild -version
asc auth status
asc apps list --bundle-id local.yah.ios --output table
```

确认应用记录为 Yah，App Store Connect ID 为 `6839642767`，Apple Developer Team ID 为 `8ZT5SZDD42`。

```sh
app_id=6839642767
version=0.1
asc builds next-build-number --app "$app_id" --version "$version" --platform IOS
```

把 `nextBuildNumber` 填入下面的 `build_number`，并同步更新主应用和键盘扩展的 `CFBundleVersion`。若调整营销版本，也要同步两个 plist 中的 `CFBundleShortVersionString`。

```sh
build_number=6
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" Host/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build_number" Keyboard/Info.plist
plutil -lint Host/Info.plist Keyboard/Info.plist

artifact_dir=".asc/artifacts/Yah-build-$build_number"
mkdir -p "$artifact_dir"
```

## 2. 归档并导出 IPA

用 `Yah` scheme 归档 iOS 真机 Release 产物。两个 Bundle ID 分别为 `local.yah.ios` 和 `local.yah.ios.keyboard`，都需要签入 `group.local.yah.voice`。

```sh
asc xcode archive --project Yah.xcodeproj --scheme Yah \
  --configuration Release --destination generic/platform=iOS \
  --archive-path "$artifact_dir/Yah.xcarchive" \
  --xcodebuild-flag=DEVELOPMENT_TEAM=8ZT5SZDD42 \
  --xcodebuild-flag=CODE_SIGN_STYLE=Automatic \
  > "$artifact_dir/archive.json" 2> "$artifact_dir/archive.log"
```

Build 6 的自动分发签名通过现有 App Store Connect API 密钥完成。以下三个变量对应本机私有目录中的 `.p8` 路径及 Apple 提供的 Key ID、Issuer ID。凭据保存在仓库之外。

```sh
asc xcode export --archive-path "$artifact_dir/Yah.xcarchive" \
  --ipa-path "$artifact_dir/Yah.ipa" \
  --xcodebuild-flag=-allowProvisioningUpdates \
  --xcodebuild-flag=-authenticationKeyPath \
  --xcodebuild-flag="$YAH_ASC_KEY_PATH" \
  --xcodebuild-flag=-authenticationKeyID \
  --xcodebuild-flag="$YAH_ASC_KEY_ID" \
  --xcodebuild-flag=-authenticationKeyIssuerID \
  --xcodebuild-flag="$YAH_ASC_ISSUER_ID" \
  > "$artifact_dir/export.json" 2> "$artifact_dir/export.log"
```

若导出日志出现 `No Accounts` 或 `No signing certificate "iOS Distribution" found`，检查 Xcode 登录或上述 API 密钥能否访问该团队的签名服务。若报 App Groups entitlement 不匹配，在 Apple Developer 中将 `group.local.yah.voice` 关联到两个 Bundle ID，刷新描述文件后重新归档。

验证 IPA 的版本、构建号、签名及内嵌资源。Build 6 还解包运行了 `codesign --verify --deep --strict`，确认主应用和扩展通过签名校验，并检查扩展签名中包含语音共享组。

```sh
asc ipa-info --path "$artifact_dir/Yah.ipa" --include-entitlements \
  --verify-signature --output json > "$artifact_dir/ipa-info.json"
unzip -Z1 "$artifact_dir/Yah.ipa" | rg 'Keyboard.appex/Keyboard$'
```

## 3. 上传并验证内部测试分发

```sh
asc publish testflight --app "$app_id" --ipa "$artifact_dir/Yah.ipa" \
  --upload-only --wait --timeout 25m --output json \
  > "$artifact_dir/upload.json" 2> "$artifact_dir/upload.log"
```

等 Apple 返回 `VALID`，从 `upload.json` 取出 `buildId`。如果命令在 Apple 已接收后超时，先按版本和构建号查询，确认处理状态再决定是否重传。

```sh
build_id=$(jq -er '.buildId' "$artifact_dir/upload.json")
asc builds info --build-id "$build_id" --include buildBetaDetail --output json
asc testflight groups list --app "$app_id" --paginate --output table
```

Build 6 初次处理完成后显示 `MISSING_EXPORT_COMPLIANCE`。本次经授权为该构建提交了仅使用豁免加密的声明。后续构建遇到此状态时，应按该版本及其依赖实际使用的加密确认分类。只有确认适用且已获授权时，才执行 `asc builds update --build-id "$build_id" --uses-non-exempt-encryption=false`。[Apple 加密合规说明](https://developer.apple.com/documentation/Security/complying-with-encryption-export-regulations)

确认目标组是 **Yah Internal** 后添加构建，并检查返回的 `betaGroups` 和 `internalBuildState`。

```sh
asc builds add-groups --build-id "$build_id" \
  --group 8d9dc09f-6423-4765-9270-de54308f405f
asc builds info --build-id "$build_id" --include buildBetaDetail,betaGroups --output json
```

当 `internalBuildState` 为 `IN_BETA_TESTING` 且包含 Yah Internal 时，组内成员可在 TestFlight 安装或更新。保留本地 IPA、归档及操作回执供排查。真机安装和输入验收单独记录，步骤见 [设计与执行手册](DESIGN-AND-EXECUTION.md)。
