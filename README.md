# Yah

Yah 是 macOS 输入法和 iOS 键盘。两端内置雾凇拼音全拼方案，离线生成候选词。用 Xcode 打开 `Yah.xcodeproj`，选择 `YahMac` 或 `Yah` 构建。

## 在 iPhone 上使用

iPhone 可在“设置 → 通用 → 键盘 → 键盘 → 添加新键盘”启用 Yah。拼音选词支持离线使用。语音输入在 Yah 主应用中完成：首次使用默认调用随 App 安装的 Whisper base 多语言量化模型，在设备上转写普通话，无需密钥或另行下载模型。也可以选择 Apple 设备端中文识别，或保存 ElevenLabs 配置供自动模式优先使用。点击首页顶部「开始语音输入」，或用 Siri、快捷指令、操作按钮运行 Yah 的「开始语音输入」。录音时可点「取消录音」丢弃此次录音。可在录音前开启「转写完成后送到键盘」，或在完成后点「送到 Yah 键盘」，五分钟内回到目标输入框点「插入转写」。此流程只把你主动发送的一条文字交给键盘。也可编辑并复制转写文字，回到目标输入框，点键盘方案菜单中的「语音工具」，再点系统粘贴按钮。选择 ElevenLabs 时，录音和 API Key 将发送到保存的 HTTPS 地址。

日常连续听写可在系统「设置 → 通用 → 键盘 → 键盘 → Yah」中开启「允许完全访问」。打开 Yah，点「开启十分钟连续听写」，首次按系统提示允许麦克风，然后回到原输入框。点 Yah 键盘右上角的「语音」开始说话，点红色停止键，文字会填入发起听写的输入框。接下来可以直接点麦克风说下一段。会话默认关闭，开启后系统显示麦克风橙点。待命声音即时丢弃，每段从点击开始录音算起，最长五分钟。可在主应用或键盘方案菜单点「结束连续听写」，十分钟到时麦克风会自动释放。

也可以单次听写。点键盘麦克风后，支持该跳转的输入框会打开 Yah。回到原输入框即可从键盘停止并转写。Spotlight 等宿主可能拦截跳转；开启完全访问时，点麦克风后十五秒内打开 Yah 会接着开始本段录音。若已允许备用通知，也可点通知开始。系统暂停离线转写时，可在五分钟内点键盘「继续」或在 Yah 中继续识别该段。

键盘空闲时，点候选栏左侧的方案名切换全拼、九宫格、小鹤双拼或自然码双拼。九宫格依次点 6、4、4、2、6 可以输入「你好」。输入「很快」时，小鹤用 `hfkk`，自然码用 `hfky`。同一菜单的「输出字形」可选简体、通用繁体、台湾繁体和香港繁体。按「英」直接输入英文，按「123」输入数字和标点。iPad 宽屏九宫格将数字、运算符和拼音键排为三栏，可用 Tab 和左右箭头编辑。全拼和双拼也可以直接混输，例如全拼输入 `wojiadewifimima`，点选「我家的Wi-Fi密码」。

简体全拼可以在方案菜单开启「按上文选词」，默认关闭。开启后，键盘在本机参考光标前最多 12 个连续汉字，调整部分双字同音词的首屏顺序。前文只在当前组字期间留在内存。模型和验证方法见[上文选词说明](Tools/ContextVectors/README.md)。

组字时，点候选栏旁的向下箭头可展开候选，按字数筛选并点选。只选中一段时，组字栏会同时显示已选汉字和剩余拼音。按退格可撤回上一段，继续修改。靠近边界点键时，键盘会用相邻按键计算额外的纠错候选。上滑字母键可输入对应的数字或标点。

在主应用打开「社区输入方案」，选择包含 `.schema.yaml`、词典及所需依赖的文件夹。导入器在本机部署，成功后替换之前导入的一组方案。内置方案始终可选。回到键盘，点候选栏左侧方案名即可使用。已在模拟器验证 Rime 官方五笔画方案的导入、选字和切回全拼。

在「社区输入方案 → 个人词库」可为常用词设置编码和权重，也可导入 Rime 短语表或独立的 `.dict.yaml` 词典，导出 UTF-8 的 `custom_phrase.txt` 供迁移。返回另一应用的 Yah 键盘，输入自定义编码即可选词。

内置语音模型为 [ggml-base-q5_1.bin](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-base-q5_1.bin)，SHA-256 为 `422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898`。模型和推理代码的许可随主应用分发，见 [VoiceModel](Host/VoiceModel)。模型仅由主应用加载。

项目进度和设备验收步骤见 [设计与执行手册](DESIGN-AND-EXECUTION.md)。

## 雾凇拼音数据

[`Shared/RimeData`](Shared/RimeData) 内的雾凇拼音数据来自 [iDvel/rime-ice@927e1cf](https://github.com/iDvel/rime-ice/tree/927e1cf1d3eeb9bf4be85e3f684dba4dd485b6f6)，按 [GPL-3.0](Shared/RimeData/LICENSE) 分发。保留了全拼、英文混输、部件反查、Lua 和表情所需的文件。Yah 调整了 `default.yaml`，列出全拼、九宫格、小鹤双拼和自然码双拼方案，每页四个候选。简繁转换的配置和词典来自 [librime-xcframework 1.17.0-pack.10.0.0](https://github.com/ghostflyby/librime-xcframework/tree/1.17.0-pack.10.0.0/Sources/RimeOpenCCData)，许可见 [OpenCC copyright](Shared/RimeData/opencc/copyright)。

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
