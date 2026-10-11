#include "../core/Timeline.hpp"
#ifdef NDEBUG
#undef NDEBUG
#endif
#include <cassert>
#include <cstring>
#include <iostream>
#include <limits>
#include <thread>

static void near(float a, float b) { assert(std::abs(a - b) < .0002f); }
int main() {
    using namespace obs;
    Timeline timeline;
    float scratch[64]{};
    float mic[] = {.5f, -.5f};
    PCMBuffer buffer{mic, sizeof(mic), 1};
    assert(!mix(timeline, &buffer, 1, 2, 48000, PCMKind::Float32, 10, .65, .75, scratch, 64));
    near(mic[0], .5); // Full underflow must preserve the microphone.
    float source[] = {.2, .4, .6, .8}; timeline.write(source, 4, 10);
    assert(mix(timeline, &buffer, 1, 2, 48000, PCMKind::Float32, 10, .65, .75, scratch, 64));
    near(mic[0], .475); near(mic[1], -.025);
    float stereo[8]{}; PCMBuffer interleaved{stereo, sizeof(stereo), 2};
    assert(mix(timeline, &interleaved, 1, 4, 48000, PCMKind::Float32, 10, 1, 1, scratch, 64));
    for (size_t i = 0; i < 4; ++i) { near(stereo[2*i], source[i]); near(stereo[2*i+1], source[i]); }
    float left[4]{}, right[4]{}; PCMBuffer planar[] = {{left,sizeof(left),1},{right,sizeof(right),1}};
    assert(mix(timeline, planar, 2, 4, 48000, PCMKind::Float32, 10, 1, 1, scratch, 64));
    for (size_t i = 0; i < 4; ++i) { near(left[i], source[i]); near(right[i], source[i]); }
    float huge[] = {3, -3}; timeline.write(huge, 2, 20);
    int16_t integers[] = {30000, -30000}; PCMBuffer integer{integers, sizeof(integers), 1};
    assert(mix(timeline, &integer, 1, 2, 48000, PCMKind::Signed16, 20, 1, 1, scratch, 64));
    assert(integers[0] == 32767 && integers[1] == -32768);
    float invalid[] = {std::numeric_limits<float>::quiet_NaN(), 0}; timeline.write(invalid, 2, 30);
    float out[8]{}; assert(timeline.read(out, 2, 30, 48000)); near(out[0], 0);
    mic[0] = std::numeric_limits<float>::quiet_NaN(); mic[1] = 0;
    assert(mix(timeline, &buffer, 1, 2, 48000, PCMKind::Float32, 30, 1, 1, scratch, 64));
    near(mic[0], 0);
    // Interpolation at half a source sample and at a different output rate.
    timeline.write(source, 4, 40);
    assert(timeline.read(out, 1, 40 + .5/48000, 48000)); near(out[0], .3);
    assert(timeline.read(out, 2, 40, 44100)); near(out[1], .4 + .2f * (48000.f/44100 - 1));
    timeline.reset(); assert(!timeline.read(out, 2, 40, 48000));
    std::vector<float> longStream(Timeline::Capacity + 3, .25);
    timeline.write(longStream.data(), longStream.size(), 50);
    assert(!timeline.read(out, 1, 50, 48000));
    assert(timeline.read(out, 1, 50 + 3./48000, 48000)); near(out[0], .25);
    assert(!timeline.read(out, 1, 50, 0));
    assert(!timeline.read(out, 1, std::numeric_limits<double>::infinity(), 48000));
    assert(!mix(timeline, &buffer, 1, 65, 48000, PCMKind::Float32, 50, 1, 1, scratch, 64));
    PCMBuffer shortBuffer{mic, 1, 1};
    assert(!mix(timeline, &shortBuffer, 1, 2, 48000, PCMKind::Float32, 50, 1, 1, scratch, 64));
    // Concurrent producer/consumer; any missed try-lock read is intentional silence.
    std::thread producer([&] { for (int i = 0; i < 10000; ++i) timeline.write(source, 4, 100 + i/48000.); });
    for (int i = 0; i < 10000; ++i) timeline.read(out, 4, 100 + i/48000., 48000);
    producer.join();
    std::cout << "PASS: timeline, PCM float/int16, interleaved/planar, clipping, resampling, bounds, reset, concurrency\n";
}
