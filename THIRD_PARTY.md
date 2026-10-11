# 第三方依赖与源码

- 本工程不包含用户提供的 VCam 二进制，也不提取或复制它的实现。
- FFmpeg 7.1.5 官方源码：https://ffmpeg.org/releases/ffmpeg-7.1.5.tar.xz
- 实际下载文件 SHA-256：`de668509caf9e35e3cd162473441fdb29538c6d96ed080292b3cf9e6fc5d558f`。
- `scripts/build_ffmpeg.sh` 不启用 GPL、nonfree 或 libx264；仅构建 H.264/AAC 解码、MPEG-TS 解复用、缩放和重采样，以及苹果 VideoToolbox 硬件解码接口。
- FFmpeg 的许可证和配置说明来自其源码中的 `COPYING.LGPLv2.1`、`LICENSE.md`。工作流将它们与原始源码包、静态库、插件对象文件一并附在构建产物中。分发编译结果时请保留这些材料，并提供本工程完整对应源码及构建方法，方便替换 LGPL 组件和重新链接。
- Theos、SDK 和注入框架的许可证分别以各自项目为准。本压缩包不附带苹果 SDK。
- OBS / FFmpeg 电脑端的编码器与本插件中的解码库是两套独立依赖。

参考：
- https://ffmpeg.org/legal.html
- https://theos.dev/docs/rootless
- https://theos.dev/docs/arm64e-deployment
