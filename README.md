# OBSBridge：系统级 OBS 摄像头输入（实验源码）

**这是一份待真机适配的系统级插件源码，不是已验证兼容的成品 `.deb`。**

目标：越狱 rootless iOS 15.0–16.6，iPhone 8 Plus / SE 2。该范围是开发目标与安装包版本限制，不是测试结果。越狱本身是否支持某型号/系统组合，仍以你实际使用的越狱工具为准。

## 保留的功能

```text
OBS 场景画面 + 场景声音
        │ TCP / MPEG-TS（H.264 + AAC）
        ▼
手机 mediaserverd 内的接收与解码
        ├─ 修改系统摄像头源的 CVPixelBuffer / IOSurface
        │       └─ 经过该链路的应用收到 OBS 画面
        └─ 原始录音样本 + OBS 音频 → 系统音频转换节点
                └─ 视频声音与手机真实麦克风一起输出
```

- **不注入 TikTok 或其他目标应用，也不替换应用的 AVCapture 委托。** `OBSBridge.plist` 只过滤系统进程 `mediaserverd`。
- 这是系统采集链路上的软件替换，不会把物理传感器改造成新的硬件设备；原摄像头仍可能被系统用于产生帧和采集时序。
- 没有图片选择、本地视频播放、独立变声、镜像开关等附加功能。
- 设置页面只有电脑 IP、开始接收、复制 URL、状态、停止。
- 默认停止；收到新的设置命令才开启；旧的保存状态不会在下一次开机自动开启。
- TCP 只绑定手机 Wi-Fi IPv4，并只接受设置中指定的电脑 IPv4。未实现加密或密码认证，只适合可信局域网；不要做公网端口映射。

## 重要的适配限制

本工程使用苹果**未公开的系统类与方法**。从你提供的 VCam 包中，只参考了包结构、注入对象和接口名称；**没有复制其二进制或反编译实现**。

候选系统接入点：

- `BWFigVideoCaptureStream`：`sourceNodeWillEmitVideoSampleBuffer:drivesCameraControls:deliversStills:`，或旧的单参数变体。
- `BWAudioConverterNode`：`renderSampleBuffer:forInput:`。

运行时检查方法是否存在、返回值和参数类型。必须同时通过视频和音频检查才允许开始；签名不匹配时不强行调用、不扫描补丁、不修改未知内存偏移。**签名匹配只能证明可以挂接，不能证明每个应用都走这条链路。**

尚未完成或保证的事项：

1. 未在 iOS 15.0、15.1、16.5、16.6 等具体版本与两种机型上验证这些私有接口。
2. 不保证所有摄像头/录音路径均经过上述节点。电话、其他音频服务、部分第三方采集 SDK 可能走不同链路。
3. 实现的是实时视频链路，不替换拍照、深度图、AR、Face ID 等输出。
4. 支持摄像头输出格式为 BGRA、8-bit NV12（420v / 420f）。**HDR/10-bit 或其他格式不支持；状态中的“画面失败”会增加，真实画面可能仍输出。不要把这个实验版本当成隐私隔离工具。**
5. 混音只支持节点输入为 little-endian、packed float32 / signed int16 的线性 PCM，最多 8 通道、每次最多 8192 帧。不支持的原始音频保持不变；有音频解码计数但没有混音计数时，需要继续适配节点/格式。
6. 前后摄像头、方向、预览与推流结果需要分别验证。代码会在 OBS 画布方向与系统像素缓冲不一致时旋转 90°，然后居中裁切；部分相机时序/方向标记可能需要按版本调整。
7. 系统媒体进程可能禁止监听网络或访问配置/状态文件。若遇到沙盒拒绝，应记录具体日志进行适配；本工程没有实现系统沙盒绕过。
8. 不包含 TikTok 检测规避、账号风控绕过、直播资格绕过；平台是否允许该内容/输入方式由平台规则决定。

## 在 GitHub 生成 `.deb`

无需 Apple 开发者证书。工作流使用 macOS、Xcode、Theos、rootless 打包与 ldid 签名。

1. 解压源码包，建立 GitHub 仓库。
2. **把 `OBSBridge` 文件夹里面的内容放到仓库根目录**，不是把 ZIP 上传，也不是再套一层文件夹。根目录应直接有 `Makefile`、`control`、`Receiver.mm`、`.github/workflows/build-deb.yml` 等。
3. 确认隐藏的 `.github` 文件夹也已上传。
   如果隐藏文件夹无法网页上传，在仓库根目录使用 Add file → Create new file，输入 `.github/workflows/build-deb.yml`，粘贴工作流内容保存。必须保留 `core/`、`tests/`、`prefs/`、`scripts/`、`layout/` 目录结构，不能只上传根目录的几个文件。
4. 打开仓库 **Actions → Build rootless OBS camera deb → Run workflow**。
5. 构建成功后，在运行详情下方 **Artifacts** 下载 `OBSBridge-rootless-deb`。
6. 解压该构建产物，安装里面的 `local.xiaoguai.obsbridge_0.1.0_iphoneos-arm64.deb`（文件名可能带 Theos 版本后缀）。

工作流固定了 Theos 和 SDK 提交，下载经过 SHA-256 校验的 FFmpeg 7.1.5，构建 arm64 与 arm64e。rootless 安装位置由 Theos 自动加 `/var/jb`，不要手工再加一遍。

更新后的工作流也能自动定位仓库子目录中的源码，但工作流自身仍必须位于仓库根目录的 `.github/workflows/`。如果出现 `no such file or directory: core/Timeline.cpp`，是源码上传缺失或目录不匹配，不是需要删除测试；补齐目录后再重新运行。

**目前没有实际运行你的 GitHub Actions，也没有在本机完成 iOS 编译。** 工作流是提供给你运行的编译配置，不是“构建成功证明”。首次构建如失败，请提供失败步骤和完整报错；依赖下载、SDK 与新版本编译器可能需要调整。

编译产物包含 FFmpeg 对应源码、许可证、插件对象与静态库，以便重新链接。保留这些材料；详见 `THIRD_PARTY.md`。GitHub 私有仓库的 macOS 构建会消耗 Actions 配额，请按账号情况使用。

## 安装与 OBS 设置

先在备用越狱手机上测试，不要在通话、录制重要内容或正式直播中首次安装。卸载/恢复方式应提前确认。

1. 先禁用或卸载原 VCam，以及其他摄像头/麦克风替换插件，避免两套系统 Hook 冲突。
2. 用支持本机 rootless 环境的包管理器安装编译出来的 `.deb`。需要 ElleKit 与 PreferenceLoader。
3. 使用越狱工具的**重启用户空间**功能，让 `mediaserverd` 重新加载。单独刷新桌面可能不足。
4. 打开 **设置 → OBS 摄像头**，填写 OBS 电脑的局域网 IPv4。
5. 点击 **查看状态**。确认媒体服务有新状态，视频/音频接口均为“已挂接（待实测）”。
6. 点击 **开始接收 OBS**，再复制手机 TCP 地址。
7. 电脑与手机连接同一个可信局域网；路由器不能开启阻止互通的客户端隔离。

OBS 建议先用：

| 项目 | 设置 |
|---|---|
| 输出模式 | 高级 |
| 录制类型 | 自定义输出（FFmpeg） |
| 输出位置 | 输出到 URL，不是保存到文件 |
| 文件路径或 URL | `tcp://手机的Wi-Fi-IP:5000` |
| 容器 | `mpegts` |
| 视频编码器 | `libx264` / H.264 |
| 视频编码器设置 | `preset=veryfast tune=zerolatency bf=0 g=30` |
| 视频尺寸 | 先用 360×640 / 30fps；通过后再试 720×1280 / 30fps |
| 视频码率 | 先用约 1500–3000 Kbps |
| 音频编码器 | `aac` |
| 音频采样率 | 48000 Hz |
| 音频码率 | 128 Kbps，单声道或双声道 |

OBS 不同版本的字段名称可能略有区别。“开始录制”在这里表示开始往 TCP 输出；该输出不同时保存本地录制文件。OBS 音量表必须显示视频的声音；先关闭电脑麦克风源，避免和手机麦克风重复录音。不要将手机扬声器播放的声音作为混音方案，本插件在数字音频链路混合，不需要外放。

手机先开始接收，然后 OBS 开始录制。TCP 断开后，在 OBS 停止录制再重新开始；手机保持监听，无有效视频超过 0.5 秒时，支持的摄像头格式会输出黑屏。停止插件会恢复真实摄像头/麦克风；服务崩溃、插件未注入或不支持的路径仍可能输出真实画面。

## 音频与同步

- AAC 解码后统一转为 mono float32 / 48 kHz。
- 视频和音频使用同一发送端 PTS 映射到手机单调时钟，并增加约 180ms 播放缓冲；队列长度有限，不积累无限延迟。
- 视频解码优先 VideoToolbox，失败时使用软件解码。8 Plus 软件解码高分辨率可能发热/掉帧。
- 麦克风默认增益 0.65，OBS 音频增益 0.75；相加后硬限幅到 [-1,1]，防止整数溢出，但过大仍会产生削波失真。调整 OBS 源音量。
- 完全没有对应 OBS 音频或实时队列争用时，保持原始麦克风不变。
- 所有录音消费者可按相同时间读取样本，不会因一个消费者读过就让另一个消费者失去声音。
- 当前系统音频节点的消费时间按回调到达的主机时间估算；**没有测得真实设备端到端同步误差**。它不是已校准的专业级唇音同步实现。

## 验收清单

按每台手机、每个准确 iOS 版本单独记录，不能用“一台成功”推断整个 15.0–16.6：

1. OBS 放明显的计时画面；手机系统相机**视频预览**中出现该画面，验证是系统链路替换，而不是 TikTok 界面上的叠加图。
2. 状态的“解码：视频/音频”与“系统输出：画面替换/混音”计数都增长。**解码增长但输出不增长，不算成功。**
3. OBS 播放说话或 997Hz 测试音；手机对麦克风说话。用第二台设备/第二个账号听直播或录音，分别确认两种声音。手机自身监听不能代表观众收到的声音。
4. 盖住物理摄像头，远端仍显示 OBS 画面；遮挡麦克风，环境音下降但 OBS 音频不受影响。
5. 切换前后摄像头，检查方向、裁切、镜像；不要只看主播预览，需检查远端实际画面。
6. 停止 OBS / 断开 Wi-Fi，确认支持的画面格式黑屏，不展示真实环境；重新连接不长期累积延迟。
7. 设置里停止插件，确认真实摄像头与麦克风恢复。
8. 测试连续 30 分钟、相机开关、屏幕锁定与解锁、应用切换、软件解码/硬件解码差异，记录发热、崩溃及音画偏移。

需要适配时提供：准确设备/iOS/TikTok 版本、越狱版本、状态页文字、媒体服务崩溃日志或沙盒拒绝日志、最小复现。日志请先脱敏。

## 本机检查

```sh
clang++ -std=c++17 -Wall -Wextra -Werror -O2 core/Timeline.cpp tests/timeline_tests.cpp -o work/timeline_tests
work/timeline_tests
python3 tests/check_project.py
# 另外需要电脑端 ffmpeg 和 ffprobe；仅本机回环 TCP，不连接手机。
python3 tests/test_transport.py
```

这些测试覆盖音频时间线、PCM 混音、缓冲边界、静态包结构，以及 MPEG-TS 的 TCP 分段传输；**不覆盖 iOS 私有接口、系统沙盒、插件注入或 TikTok 实际推流**。

## 工程结构

- `SystemHooks.mm`：仅系统媒体进程挂接、类型检查、设置命令和状态输出。
- `Receiver.mm`：局域网 TCP、MPEG-TS 解复用、H.264/AAC 解码、系统像素缓冲修改和音频样本构建。
- `core/Timeline.*`：可独立测试的带时间戳音频环形缓冲与 PCM 混音。
- `prefs/`：PreferenceLoader 设置页面。
- `scripts/build_ffmpeg.sh`：在 macOS 构建两个架构的解码静态库。
- `.github/workflows/build-deb.yml`：GitHub 编译与打包。
- `tests/`：独立于 iOS 的测试。

参考资料：

- [Theos rootless 约定](https://theos.dev/docs/rootless)
- [Theos arm64e / iOS 14+ ABI](https://theos.dev/docs/arm64e-deployment)
- [FFmpeg 解复用 API](https://ffmpeg.org/doxygen/trunk/group__lavf__decoding.html)
- [FFmpeg 重采样 API](https://ffmpeg.org/doxygen/trunk/group__lswr.html)
- [FFmpeg 官方版本与源码](https://ffmpeg.org/download.html)
- [OBS 自定义 FFmpeg 输出说明](https://obsproject.com/forum/threads/obs-studio-send-an-udp-stream-to-a-second-pc-using-obs-deleted.55379/)
