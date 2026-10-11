#include "Timeline.hpp"
#include <cstring>
#include <limits>

namespace obs {
static constexpr int64_t Empty = std::numeric_limits<int64_t>::min();
static size_t slot(int64_t index) {
    int64_t r = index % int64_t(Timeline::Capacity);
    return size_t(r < 0 ? r + Timeline::Capacity : r);
}
Timeline::Timeline() : data_(Capacity, 0), tags_(Capacity, Empty) {}
void Timeline::reset() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::fill(tags_.begin(), tags_.end(), Empty);
}
void Timeline::write(const float *samples, size_t count, double time) {
    if (!samples || !std::isfinite(time) || std::abs(time) > 1e10) return;
    int64_t start = int64_t(std::llround(time * Rate));
    std::lock_guard<std::mutex> lock(mutex_);
    size_t first = count > Capacity ? count - Capacity : 0;
    for (size_t i = first; i < count; ++i) {
        int64_t index = start + int64_t(i);
        size_t p = slot(index);
        data_[p] = std::isfinite(samples[i]) ? samples[i] : 0;
        tags_[p] = index;
    }
}
bool Timeline::read(float *out, size_t count, double time, double rate) {
    if (!out || rate < 8000 || rate > 192000 || !std::isfinite(rate) ||
        !std::isfinite(time) || std::abs(time) > 1e10) return false;
    std::fill(out, out + count, 0);
    std::unique_lock<std::mutex> lock(mutex_, std::try_to_lock);
    if (!lock.owns_lock()) return false;
    bool found = false;
    for (size_t i = 0; i < count; ++i) {
        double t = (time + double(i) / rate) * Rate;
        int64_t a = int64_t(std::floor(t));
        float f = float(t - double(a));
        size_t p = slot(a), q = slot(a + 1);
        if (tags_[p] == a) {
            float v = data_[p];
            out[i] = tags_[q] == a + 1 ? v + f * (data_[q] - v) : v;
            found = true;
        }
    }
    return found;
}
bool mix(Timeline &timeline, PCMBuffer *buffers, size_t n, size_t frames,
         double rate, PCMKind kind, double time, float micGain, float obsGain,
         float *scratch, size_t scratchCount) {
    if (!buffers || !n || !frames || frames > scratchCount || n > 8) return false;
    size_t bytes = kind == PCMKind::Float32 ? 4 : 2;
    for (size_t b = 0; b < n; ++b) {
        if (!buffers[b].data || !buffers[b].channels || buffers[b].channels > 8 ||
            frames > buffers[b].bytes / bytes / buffers[b].channels) return false;
    }
    // Underflow/contention leaves the original microphone entirely untouched.
    if (!timeline.read(scratch, frames, time, rate)) return false;
    for (size_t b = 0; b < n; ++b) {
        auto *base = static_cast<uint8_t *>(buffers[b].data);
        for (size_t i = 0; i < frames; ++i) {
            for (unsigned c = 0; c < buffers[b].channels; ++c) {
                size_t offset = (i * buffers[b].channels + c) * bytes;
                float mic;
                if (kind == PCMKind::Float32) std::memcpy(&mic, base + offset, 4);
                else { int16_t v; std::memcpy(&v, base + offset, 2); mic = v / 32768.f; }
                if (!std::isfinite(mic)) mic = 0;
                float v = std::clamp(micGain * mic + obsGain * scratch[i], -1.f, 1.f);
                if (kind == PCMKind::Float32) std::memcpy(base + offset, &v, 4);
                else {
                    int16_t s = int16_t(std::clamp(std::lround(v * 32768.f), -32768L, 32767L));
                    std::memcpy(base + offset, &s, 2);
                }
            }
        }
    }
    return true;
}
}
