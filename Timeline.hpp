#pragma once
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <mutex>
#include <vector>

namespace obs {
// Decoded mono float audio, indexed by absolute monotonic time at 48 kHz.
// A two-second bound prevents runaway memory/latency. Real-time readers never wait.
class Timeline {
public:
    static constexpr int Rate = 48000;
    static constexpr size_t Capacity = Rate * 2;
    Timeline();
    void reset();
    void write(const float *samples, size_t count, double startTime);
    bool read(float *out, size_t count, double startTime, double rate);
private:
    std::mutex mutex_;
    std::vector<float> data_;
    std::vector<int64_t> tags_;
};

enum class PCMKind { Float32, Signed16 };
struct PCMBuffer { void *data; size_t bytes; unsigned channels; };
// Caller supplies fixed-size scratch, avoiding allocation in AudioUnitRender.
bool mix(Timeline &timeline, PCMBuffer *buffers, size_t bufferCount,
         size_t frames, double sampleRate, PCMKind kind, double time,
         float micGain, float obsGain, float *scratch, size_t scratchCount);
}
