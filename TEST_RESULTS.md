# 检查记录（2026-10-11）

执行环境：Windows，Python 3.12.1，Zig 0.13.0 的 C++ 编译器（仅测试可移植核心），电脑端 FFmpeg/ffprobe 9.0.1。

| 检查 | 实际结果 |
|---|---|
| `core/Timeline.cpp` + `tests/timeline_tests.cpp`，C++17、`-Wall -Wextra -Werror -O2` | 编译成功，测试程序通过；测试断言明确保持开启 |
| float32 / int16、交错/分离通道、增益、限幅、44.1k 输出重采样、空缓冲、重置、边界、NaN、并发 | 通过可移植核心测试 |
| `tests/check_project.py` | 4 个静态结构测试通过；包括 plist 解析和系统进程过滤规则 |
| `tests/test_transport.py` | 1 个本机回环 TCP 测试通过；每次读取 137 字节，重新收到完整 MPEG-TS，ffprobe 确认 H.264 + AAC 48kHz |
| FFmpeg 7.1.5 源码下载与 SHA-256 | 实际下载核对：`de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f` |
| Theos / SDK 固定提交与 iPhoneOS16.5 SDK 目录 | 已核对官方仓库存在 |
| GitHub 工作流 YAML、FFmpeg 构建脚本与内嵌 Shell 步骤 | 通过 YAML 解析与 bashlex 静态语法解析；未实际执行 macOS 构建 |
| 更新后的源码目录定位 | 已在临时目录验证：源码位于仓库根目录、位于 OBSBridge 子目录、缺少 core/Timeline.cpp 三种情况；前两种正确定位，第三种明确报错 |
| `.github/workflows/build-deb.yml` / iOS 编译 | 未在 GitHub 或 macOS 上执行，不代表编译成功 |
| arm64/arm64e 注入、系统沙盒、iOS 15.0–16.6 真机、TikTok 远端画面与声音 | 未测试 |

这些结果不证明完整插件可运行。不要将核心测试、协议测试或打包配置称为完成了全版本系统级摄像头替换。
