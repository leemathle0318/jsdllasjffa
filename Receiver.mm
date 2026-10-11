#import "Receiver.h"
#import "Shared.h"
#import <CoreImage/CoreImage.h>
#include "core/Timeline.hpp"
#include <atomic>
#include <array>
#include <deque>
#include <memory>
#include <mutex>
#include <string>
#include <vector>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <sys/socket.h>
#include <poll.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
extern "C" {
#include <libavformat/avformat.h>
#include <libavcodec/avcodec.h>
#include <libavutil/hwcontext.h>
#include <libavutil/pixdesc.h>
#include <libswresample/swresample.h>
#include <libswscale/swscale.h>
}

namespace {
struct Image {
    CVPixelBufferRef pixel;
    double due;
    Image(CVPixelBufferRef p, double d) : pixel(CVPixelBufferRetain(p)), due(d) {}
    ~Image() { CVPixelBufferRelease(pixel); }
};
struct Engine {
    std::atomic<bool> enabled{false}, videoHook{false}, audioHook{false};
    std::atomic<uint64_t> generation{0}, videos{0}, audios{0}, replaced{0}, mixed{0}, failed{0};
    std::mutex mutex;
    std::string message = "尚未启用", hookDetail = "正在检查系统接口";
    std::deque<std::shared_ptr<Image>> images;
    std::shared_ptr<Image> current;
    bool clockValid = false;
    double originPTS = 0, originLocal = 0;
    obs::Timeline audio;
    dispatch_queue_t queue = dispatch_queue_create("local.xiaoguai.obsbridge.receive", DISPATCH_QUEUE_SERIAL);
    bool active(uint64_t g) { return enabled.load() && generation.load() == g; }
    void note(const char *s) { std::lock_guard<std::mutex> l(mutex); message = s; }
    void clearLocked() { images.clear(); current.reset(); clockValid = false; audio.reset(); }
    // The same sender clock schedules both tracks, independent of network arrival jitter.
    double scheduleLocked(double pts) {
        double now = OBNow();
        if (!clockValid) { originPTS = pts; originLocal = now + .180; clockValid = true; }
        double due = originLocal + pts - originPTS;
        if (due < now - 1.0 || due > now + 1.0) {
            clearLocked(); originPTS = pts; originLocal = now + .180; clockValid = true;
            due = originLocal;
        }
        return due;
    }
};
Engine &engine() { static Engine e; return e; }

struct Reader {
    int fd = -1;
    uint64_t generation;
    double lastData = OBNow();
    explicit Reader(uint64_t g) : generation(g) {}
    ~Reader() { if (fd >= 0) close(fd); }
    static int read(void *opaque, uint8_t *data, int size) {
        auto &r = *static_cast<Reader *>(opaque);
        while (engine().active(r.generation)) {
            pollfd p{r.fd, POLLIN, 0};
            int rc = poll(&p, 1, 100);
            if (rc < 0 && errno == EINTR) continue;
            if (rc < 0) return AVERROR(errno);
            if (!rc) { if (OBNow() - r.lastData > 8) return AVERROR(ETIMEDOUT); continue; }
            ssize_t n = recv(r.fd, data, size, 0);
            if (n > 0) { r.lastData = OBNow(); return int(n); }
            if (!n) return AVERROR_EOF;
            if (errno != EINTR && errno != EAGAIN) return AVERROR(errno);
        }
        return AVERROR_EXIT;
    }
    static int interrupt(void *opaque) {
        auto &r = *static_cast<Reader *>(opaque);
        return !engine().active(r.generation);
    }
};

struct Decoder {
    AVCodecContext *ctx = nullptr;
    AVStream *stream = nullptr;
    AVFrame *frame = av_frame_alloc();
    SwrContext *swr = nullptr;
    SwsContext *sws = nullptr;
    int inputRate = 0;
    AVSampleFormat inputFormat = AV_SAMPLE_FMT_NONE;
    AVChannelLayout inputLayout{};
    ~Decoder() {
        avcodec_free_context(&ctx); av_frame_free(&frame);
        swr_free(&swr); sws_freeContext(sws); av_channel_layout_uninit(&inputLayout);
    }
    static AVPixelFormat pixelFormat(AVCodecContext *, const AVPixelFormat *formats) {
        for (auto p = formats; *p != AV_PIX_FMT_NONE; ++p)
            if (*p == AV_PIX_FMT_VIDEOTOOLBOX) return *p;
        for (auto p = formats; *p != AV_PIX_FMT_NONE; ++p) {
            auto d = av_pix_fmt_desc_get(*p);
            if (d && !(d->flags & AV_PIX_FMT_FLAG_HWACCEL)) return *p;
        }
        return AV_PIX_FMT_NONE;
    }
    bool open(AVFormatContext *fmt, AVMediaType type) {
        int i = av_find_best_stream(fmt, type, -1, -1, nullptr, 0);
        if (i < 0) return false;
        stream = fmt->streams[i];
        AVCodecID expected = type == AVMEDIA_TYPE_VIDEO ? AV_CODEC_ID_H264 : AV_CODEC_ID_AAC;
        if (stream->codecpar->codec_id != expected) return false;
        const AVCodec *codec = avcodec_find_decoder(expected);
        if (!codec || !frame || !(ctx = avcodec_alloc_context3(codec))) return false;
        if (avcodec_parameters_to_context(ctx, stream->codecpar) < 0) return false;
        ctx->pkt_timebase = stream->time_base;
        ctx->thread_count = 2;
        ctx->max_pixels = 1920 * 1080;
        if (type == AVMEDIA_TYPE_VIDEO) {
            if (av_hwdevice_ctx_create(&ctx->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX,
                                      nullptr, nullptr, 0) >= 0) ctx->get_format = pixelFormat;
        }
        return avcodec_open2(ctx, codec, nullptr) >= 0;
    }
    double pts() {
        int64_t p = frame->best_effort_timestamp;
        if (p == AV_NOPTS_VALUE) p = frame->pts;
        return p == AV_NOPTS_VALUE ? NAN : p * av_q2d(stream->time_base);
    }
    void video(uint64_t g) {
        if (frame->width <= 0 || frame->height <= 0 || frame->width > 2048 ||
            frame->height > 2048 || int64_t(frame->width) * frame->height > 1920 * 1080) return;
        double p = pts(); if (!std::isfinite(p)) return;
        CVPixelBufferRef pixel = nullptr;
        bool owned = false;
        if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) pixel = (CVPixelBufferRef)frame->data[3];
        else {
            NSDictionary *attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey: @{}};
            if (CVPixelBufferCreate(kCFAllocatorDefault, frame->width, frame->height,
                    kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)attrs, &pixel) != kCVReturnSuccess) return;
            owned = true;
            sws = sws_getCachedContext(sws, frame->width, frame->height, (AVPixelFormat)frame->format,
                    frame->width, frame->height, AV_PIX_FMT_BGRA, SWS_FAST_BILINEAR, nullptr, nullptr, nullptr);
            if (!sws || CVPixelBufferLockBaseAddress(pixel, 0) != kCVReturnSuccess) {
                CVPixelBufferRelease(pixel); return;
            }
            uint8_t *out[] = {(uint8_t *)CVPixelBufferGetBaseAddress(pixel), nullptr, nullptr, nullptr};
            int stride[] = {(int)CVPixelBufferGetBytesPerRow(pixel), 0, 0, 0};
            int rows = sws_scale(sws, frame->data, frame->linesize, 0, frame->height, out, stride);
            CVPixelBufferUnlockBaseAddress(pixel, 0);
            if (rows != frame->height) { CVPixelBufferRelease(pixel); return; }
        }
        if (pixel) {
            auto &e = engine(); std::lock_guard<std::mutex> l(e.mutex);
            if (e.active(g)) {
                double due = e.scheduleLocked(p);
                if (due >= OBNow() - .25 && due < OBNow() + .75) {
                    e.images.push_back(std::make_shared<Image>(pixel, due));
                    while (e.images.size() > 12) e.images.pop_front();
                    ++e.videos;
                }
            }
        }
        if (owned) CVPixelBufferRelease(pixel);
    }
    void audio(uint64_t g) {
        double p = pts();
        if (!std::isfinite(p) || frame->nb_samples <= 0 || frame->nb_samples > 8192 ||
            frame->sample_rate < 8000 || frame->sample_rate > 96000 ||
            frame->ch_layout.nb_channels < 1 || frame->ch_layout.nb_channels > 2) return;
        if (!swr || frame->sample_rate != inputRate || frame->format != inputFormat ||
            av_channel_layout_compare(&frame->ch_layout, &inputLayout)) {
            swr_free(&swr); av_channel_layout_uninit(&inputLayout);
            AVChannelLayout mono = AV_CHANNEL_LAYOUT_MONO;
            if (swr_alloc_set_opts2(&swr, &mono, AV_SAMPLE_FMT_FLT, obs::Timeline::Rate,
                    &frame->ch_layout, (AVSampleFormat)frame->format, frame->sample_rate, 0, nullptr) < 0 ||
                swr_init(swr) < 0) { swr_free(&swr); return; }
            av_channel_layout_copy(&inputLayout, &frame->ch_layout);
            inputRate = frame->sample_rate; inputFormat = (AVSampleFormat)frame->format;
        }
        int64_t delay = swr_get_delay(swr, inputRate);
        int count = (int)av_rescale_rnd(delay + frame->nb_samples, obs::Timeline::Rate, inputRate, AV_ROUND_UP);
        if (count <= 0 || count > 65536) return;
        std::vector<float> mono(count);
        uint8_t *out[] = {(uint8_t *)mono.data()};
        int n = swr_convert(swr, out, count, (const uint8_t **)frame->extended_data, frame->nb_samples);
        if (n <= 0) return;
        auto &e = engine(); std::lock_guard<std::mutex> l(e.mutex);
        if (e.active(g)) {
            double due = e.scheduleLocked(p) - double(delay) / inputRate;
            if (due > OBNow() - .25 && due < OBNow() + .75) {
                e.audio.write(mono.data(), n, due); ++e.audios;
            }
        }
    }
    void push(AVPacket *packet, uint64_t g, bool isVideo) {
        if (!ctx || packet->stream_index != stream->index) return;
        int rc = avcodec_send_packet(ctx, packet);
        if (rc < 0) return;
        while (avcodec_receive_frame(ctx, frame) >= 0) {
            @autoreleasepool { if (isVideo) video(g); else audio(g); }
            av_frame_unref(frame);
        }
    }
};

void decodeConnection(Reader &reader) {
    auto &e = engine();
    AVFormatContext *fmt = avformat_alloc_context();
    uint8_t *data = (uint8_t *)av_malloc(32768);
    AVIOContext *io = data ? avio_alloc_context(data, 32768, 0, &reader, Reader::read, nullptr, nullptr) : nullptr;
    if (!fmt || !io) {
        if (io) { av_freep(&io->buffer); avio_context_free(&io); } else av_free(data);
        avformat_free_context(fmt); e.note("内存不足"); return;
    }
    fmt->pb = io; fmt->flags |= AVFMT_FLAG_CUSTOM_IO;
    fmt->max_streams = 8;
    fmt->interrupt_callback = {Reader::interrupt, &reader};
    AVDictionary *opts = nullptr;
    av_dict_set(&opts, "probesize", "262144", 0);
    av_dict_set(&opts, "analyzeduration", "500000", 0);
    av_dict_set(&opts, "max_delay", "0", 0);
    av_dict_set(&opts, "format_whitelist", "mpegts", 0);
    av_dict_set(&opts, "codec_whitelist", "h264,aac", 0);
    int rc = avformat_open_input(&fmt, nullptr, av_find_input_format("mpegts"), &opts);
    av_dict_free(&opts);
    if (rc >= 0) rc = avformat_find_stream_info(fmt, nullptr);
    if (rc >= 0) {
        Decoder video, audio;
        bool v = video.open(fmt, AVMEDIA_TYPE_VIDEO), a = audio.open(fmt, AVMEDIA_TYPE_AUDIO);
        if (!v || !a) e.note("格式不匹配：必须同时发送 H.264 视频和 AAC 音频");
        else {
            e.note("已连接；等待系统摄像头和录音链路消费");
            AVPacket *packet = av_packet_alloc();
            if (packet) {
                while (e.active(reader.generation) && av_read_frame(fmt, packet) >= 0) {
                    video.push(packet, reader.generation, true);
                    audio.push(packet, reader.generation, false);
                    av_packet_unref(packet);
                }
                av_packet_free(&packet);
            }
        }
    } else e.note("无法读取 MPEG-TS，或连接超时");
    avformat_close_input(&fmt);
    // Custom AVIO remains owned by us; FFmpeg may have replaced its buffer.
    av_freep(&io->buffer); avio_context_free(&io);
}

void serve(NSString *ip, NSString *peer, uint64_t g) {
    auto &e = engine();
    sockaddr_in addr{}; addr.sin_len = sizeof(addr); addr.sin_family = AF_INET;
    addr.sin_port = htons(OB_PORT);
    in_addr allowed{};
    if (inet_pton(AF_INET, ip.UTF8String, &addr.sin_addr) != 1 ||
        inet_pton(AF_INET, peer.UTF8String, &allowed) != 1) { e.note("IP 地址无效"); return; }
    int listener = socket(AF_INET, SOCK_STREAM, 0);
    if (listener < 0) { e.note("系统拒绝创建 TCP socket"); return; }
    int yes = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    if (bind(listener, (sockaddr *)&addr, sizeof(addr)) || listen(listener, 2)) {
        e.note("无法监听：检查 Wi-Fi、端口占用和媒体服务沙盒权限"); close(listener); return;
    }
    while (e.active(g)) {
        e.note("等待 OBS 连接；摄像头输出黑屏，麦克风保持原样");
        pollfd p{listener, POLLIN, 0};
        int rc = poll(&p, 1, 100);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0) break;
        if (!rc) continue;
        sockaddr_in remote{}; socklen_t len = sizeof(remote);
        Reader reader(g); reader.fd = accept(listener, (sockaddr *)&remote, &len);
        if (reader.fd < 0) continue;
        if (remote.sin_addr.s_addr != allowed.s_addr) continue;
        { std::lock_guard<std::mutex> lock(e.mutex); if (e.active(g)) e.clearLocked(); }
        @autoreleasepool { decodeConnection(reader); }
        { std::lock_guard<std::mutex> lock(e.mutex); if (e.active(g)) e.clearLocked(); }
        // OBS must restart Recording after a lost TCP connection.
    }
    close(listener);
}

bool black(CVPixelBufferRef p) {
    OSType type = CVPixelBufferGetPixelFormatType(p);
    if (type != kCVPixelFormatType_32BGRA && type != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        type != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) return false;
    if (CVPixelBufferLockBaseAddress(p, 0) != kCVReturnSuccess) return false;
    if (CVPixelBufferIsPlanar(p)) {
        for (size_t i = 0; i < CVPixelBufferGetPlaneCount(p); ++i) {
            void *base = CVPixelBufferGetBaseAddressOfPlane(p, i);
            size_t bytes = CVPixelBufferGetBytesPerRowOfPlane(p, i) * CVPixelBufferGetHeightOfPlane(p, i);
            if (base) memset(base, i ? 128 : (type == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ? 16 : 0), bytes);
        }
    } else {
        uint8_t *base = (uint8_t *)CVPixelBufferGetBaseAddress(p);
        size_t stride = CVPixelBufferGetBytesPerRow(p), h = CVPixelBufferGetHeight(p), w = CVPixelBufferGetWidth(p);
        if (base) for (size_t y = 0; y < h; ++y) {
            memset(base + y * stride, 0, stride);
            for (size_t x = 0; x < w; ++x) base[y * stride + x * 4 + 3] = 255;
        }
    }
    CVPixelBufferUnlockBaseAddress(p, 0);
    return true;
}
}

double OBNow(void) { return CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())); }
BOOL OBEnabled(void) { return engine().enabled.load(); }
void OBSetHookStatus(BOOL v, BOOL a, NSString *detail) {
    auto &e = engine(); e.videoHook = v; e.audioHook = a;
    std::lock_guard<std::mutex> l(e.mutex); e.hookDetail = detail.UTF8String ?: "";
}
void OBStart(NSString *ip, NSString *peer) {
    OBStop(); auto &e = engine();
    if (!e.videoHook || !e.audioHook) { e.note("未启用：当前系统的摄像头/录音接口未通过检查"); return; }
    uint64_t g = ++e.generation;
    e.videos = 0; e.audios = 0; e.replaced = 0; e.mixed = 0; e.failed = 0;
    e.enabled = true;
    dispatch_async(e.queue, ^{ @autoreleasepool { serve(ip, peer, g); } });
}
void OBStop(void) {
    auto &e = engine(); e.enabled = false; ++e.generation;
    std::lock_guard<std::mutex> l(e.mutex); e.clearLocked(); e.message = "已停止，恢复真实摄像头和麦克风";
}
NSString *OBStatus(void) {
    auto &e = engine(); std::lock_guard<std::mutex> l(e.mutex);
    return [NSString stringWithFormat:@"%s\n%s\n解码：视频 %llu / 音频 %llu\n系统输出：画面替换 %llu / 混音 %llu / 画面失败 %llu",
        e.message.c_str(), e.hookDetail.c_str(), (unsigned long long)e.videos.load(),
        (unsigned long long)e.audios.load(), (unsigned long long)e.replaced.load(),
        (unsigned long long)e.mixed.load(), (unsigned long long)e.failed.load()];
}
NSString *OBWiFiIP(void) {
    ifaddrs *list = nullptr; NSString *ip = nil;
    if (!getifaddrs(&list)) {
        for (auto p = list; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strcmp(p->ifa_name, "en0")) continue;
            char value[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &((sockaddr_in *)p->ifa_addr)->sin_addr, value, sizeof(value)))
                ip = [NSString stringWithUTF8String:value];
        }
        freeifaddrs(list);
    }
    return ip;
}

BOOL OBReplaceVideo(CMSampleBufferRef sample) {
    auto &e = engine(); if (!e.enabled || !sample) return NO;
    CVPixelBufferRef dest = CMSampleBufferGetImageBuffer(sample);
    if (!dest) { ++e.failed; return NO; }
    // Work on the existing IOSurface: this callback is a source notification,
    // so merely passing a different CMSampleBuffer to its original IMP is insufficient.
    OSType type = CVPixelBufferGetPixelFormatType(dest);
    if (type != kCVPixelFormatType_32BGRA && type != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
        type != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) { ++e.failed; return NO; }
    std::shared_ptr<Image> chosen;
    { std::unique_lock<std::mutex> l(e.mutex, std::try_to_lock);
      if (l.owns_lock()) {
          double now = OBNow();
          while (!e.images.empty() && e.images.front()->due <= now) {
              e.current = e.images.front(); e.images.pop_front();
          }
          if (e.current && now - e.current->due <= .5) chosen = e.current;
      }
    }
    if (!chosen) { BOOL ok = black(dest); if (ok) ++e.replaced; else ++e.failed; return ok; }
    static CIContext *context; static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}]; });
    @try {
        CIImage *image = [CIImage imageWithCVPixelBuffer:chosen->pixel];
        CGRect from = image.extent;
        CGFloat width = CVPixelBufferGetWidth(dest), height = CVPixelBufferGetHeight(dest);
        // A portrait OBS canvas enters the usual landscape sensor buffer. Camera
        // orientation metadata still belongs to the original capture session.
        if ((from.size.width < from.size.height) != (width < height)) {
            image = [image imageByApplyingOrientation:6]; from = image.extent;
        }
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(-from.origin.x, -from.origin.y)];
        CGFloat scale = MAX(width / from.size.width, height / from.size.height);
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(
            (width - from.size.width * scale) / 2, (height - from.size.height * scale) / 2)];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        [context render:image toCVPixelBuffer:dest bounds:CGRectMake(0, 0, width, height) colorSpace:space];
        CGColorSpaceRelease(space); ++e.replaced; return YES;
    } @catch (NSException *exception) { (void)exception; BOOL ok = black(dest); ++e.failed; return ok; }
}

BOOL OBMixABL(AudioBufferList *abl, UInt32 frames, const AudioStreamBasicDescription *f, double time) {
    if (!OBEnabled() || !abl || !f || f->mFormatID != kAudioFormatLinearPCM ||
        abl->mNumberBuffers > 8 || f->mChannelsPerFrame > 8 ||
        (f->mFormatFlags & kAudioFormatFlagIsBigEndian) || !(f->mFormatFlags & kAudioFormatFlagIsPacked)) return NO;
    obs::PCMKind kind;
    if ((f->mFormatFlags & kAudioFormatFlagIsFloat) && f->mBitsPerChannel == 32) kind = obs::PCMKind::Float32;
    else if ((f->mFormatFlags & kAudioFormatFlagIsSignedInteger) && f->mBitsPerChannel == 16) kind = obs::PCMKind::Signed16;
    else return NO;
    unsigned bytes = kind == obs::PCMKind::Float32 ? 4 : 2;
    unsigned channels = (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved) ? 1 : f->mChannelsPerFrame;
    if (f->mBytesPerFrame != bytes * channels) return NO;
    obs::PCMBuffer buffers[8];
    for (unsigned i = 0; i < abl->mNumberBuffers; ++i)
        buffers[i] = {abl->mBuffers[i].mData, abl->mBuffers[i].mDataByteSize, abl->mBuffers[i].mNumberChannels};
    thread_local std::array<float, 8192> scratch;
    BOOL result = obs::mix(engine().audio, buffers, abl->mNumberBuffers, frames, f->mSampleRate, kind,
                           time, .65f, .75f, scratch.data(), scratch.size());
    return result;
}

CMSampleBufferRef OBCopyAudio(CMSampleBufferRef mic) {
    if (!OBEnabled() || !mic) return nullptr;
    if (CMGetAttachment(mic, CFSTR("local.xiaoguai.obsbridge.mixed"), nullptr)) return nullptr;
    auto format = CMSampleBufferGetFormatDescription(mic);
    if (!format || CMFormatDescriptionGetMediaType(format) != kCMMediaType_Audio) return nullptr;
    const AudioStreamBasicDescription *f = CMAudioFormatDescriptionGetStreamBasicDescription(format);
    CMItemCount frames = CMSampleBufferGetNumSamples(mic);
    if (!f || frames <= 0 || frames > 8192) return nullptr;
    alignas(AudioBufferList) std::array<uint8_t, offsetof(AudioBufferList, mBuffers) + sizeof(AudioBuffer) * 8> storage{};
    auto *abl = reinterpret_cast<AudioBufferList *>(storage.data());
    CMBlockBufferRef retained = nullptr;
    OSStatus rc = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(mic, nullptr, abl, storage.size(),
        kCFAllocatorDefault, kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &retained);
    if (rc || !retained) return nullptr;
    std::vector<uint8_t> copies[8];
    if (abl->mNumberBuffers > 8) { CFRelease(retained); return nullptr; }
    for (unsigned i = 0; i < abl->mNumberBuffers; ++i) {
        const auto &b = abl->mBuffers[i];
        if (!b.mData || b.mDataByteSize > 8192 * 8 * 4) { CFRelease(retained); return nullptr; }
        copies[i].resize(b.mDataByteSize); memcpy(copies[i].data(), b.mData, b.mDataByteSize);
        abl->mBuffers[i].mData = copies[i].data();
    }
    // Host-clock scheduling is approximate at this private converter input.
    // True end-to-end audio latency must be measured on each device/build.
    if (!OBMixABL(abl, (UInt32)frames, f, OBNow())) { CFRelease(retained); return nullptr; }
    CMSampleTimingInfo timing{}; CMSampleBufferRef mixed = nullptr;
    rc = CMSampleBufferGetSampleTimingInfo(mic, 0, &timing);
    if (!rc) rc = CMSampleBufferCreate(kCFAllocatorDefault, nullptr, false, nullptr, nullptr,
                                      format, frames, 1, &timing, 0, nullptr, &mixed);
    if (!rc) rc = CMSampleBufferSetDataBufferFromAudioBufferList(mixed, kCFAllocatorDefault,
        kCFAllocatorDefault, kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, abl);
    if (!rc) rc = CMSampleBufferSetDataReady(mixed);
    CFRelease(retained);
    if (rc) { if (mixed) CFRelease(mixed); return nullptr; }
    CFDictionaryRef attachments = CMCopyDictionaryOfAttachments(kCFAllocatorDefault, mic, kCMAttachmentMode_ShouldPropagate);
    if (attachments) { CMSetAttachments(mixed, attachments, kCMAttachmentMode_ShouldPropagate); CFRelease(attachments); }
    CMSetAttachment(mixed, CFSTR("local.xiaoguai.obsbridge.mixed"), kCFBooleanTrue, kCMAttachmentMode_ShouldPropagate);
    ++engine().mixed;
    return mixed;
}
