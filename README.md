# Yah

Yah 是 macOS 输入法和 iOS 键盘。两端内置雾凇拼音全拼方案，离线生成候选词。用 Xcode 打开 `Yah.xcodeproj`，选择 `YahMac` 或 `Yah` 构建。

## 雾凇拼音数据

[`Shared/RimeData`](Shared/RimeData) 内的雾凇拼音数据来自 [iDvel/rime-ice@927e1cf](https://github.com/iDvel/rime-ice/tree/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6)，按 [GPL-3.0](Shared/RimeData/LICENSE) 分发。保留了全拼、英文混输、部件反查、Lua 和表情所需的文件。Yah 调整了 `default.yaml`，只列出全拼方案，每页四个候选。简繁转换的配置和词典来自 [librime-xcframework 1.17.0-pack.10.0.0](https://github.com/ghostflyby/librime-xcframework/tree/1.17.0-pack.10.0.0/Sources/RimeOpenCCData)，许可见 [OpenCC copyright](Shared/RimeData/opencc/copyright)。

`Shared/RimeData/build` 是用 librime 1.17.0 预部署的配置和词库。更新上游数据后，用同版本的 `rime_deployer` 在空目录里重新部署，再替换 `build` 中的文件。预部署使 iOS 键盘不必在启动时编译词库。

```sh
data="$PWD/Shared/RimeData"
work="$(mktemp -d)"
# 使用临时副本，避免部署器复用仓库里的预编译数据。
mkdir "$work/source" "$work/user"
cp -R "$data/." "$work/source/"
mv "$work/source/build" "$work/previous-build"
rime_deployer --build "$work/user" "$work/source" "$work/build"
```
