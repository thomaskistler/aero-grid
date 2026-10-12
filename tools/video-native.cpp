// SPDX-License-Identifier: GPL-2.0-only
// TX16S Companion ABI, shared by all video recipes. Tick = 10 ms.
#include <dlfcn.h>
#include <array>
#include <chrono>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <thread>
#include <vector>

template<typename T> T load(void* library, const char* name) {
    auto value = reinterpret_cast<T>(dlsym(library, name));
    if (!value) std::fprintf(stderr, "Missing simulator symbol: %s\n", name);
    return value;
}

int main(int argc, char** argv) {
    if (argc != 7) {
        std::fprintf(stderr, "Usage: video-native LIB SD ACTIONS OUTPUT TICKS WARMUP\n");
        return 2;
    }
    int ticks, warmup;
    try { ticks = std::stoi(argv[5]); warmup = std::stoi(argv[6]); }
    catch (...) { return 2; }
    if (warmup < 0 || ticks <= warmup || warmup % 5 || ticks % 5) return 2;
    std::ifstream script(argv[3]);
    std::vector<std::array<int, 4>> actions;
    std::array<int, 4> action;
    int previous = -1;
    while (script >> action[0] >> action[1] >> action[2] >> action[3]) {
        if (action[0] < previous || action[0] < 0 || action[0] >= ticks
            || action[1] < -32 || action[1] >= 480 || action[2] < 0
            || action[2] >= 272 || (action[3] != 0 && action[3] != 1)) return 2;
        previous = action[0];
        actions.push_back(action);
    }
    if (!script.eof() || actions.empty()) return 2;
    void* library = dlopen(argv[1], RTLD_NOW);
    if (!library) { std::fprintf(stderr, "%s\n", dlerror()); return 1; }
    auto init = load<void(*)()>(library, "_Z8simuInitv");
    auto start = load<void(*)(bool, const char*, const char*)>(library, "_Z9simuStartbPKcS0_");
    auto stop = load<void(*)()>(library, "_Z8simuStopv");
    auto flush = load<void(*)()>(library, "lcdFlushed");
    auto buffer = load<unsigned char**>(library, "simuLcdBuf");
    auto changed = load<bool*>(library, "simuLcdRefresh");
    auto down = load<void(*)(short, short)>(library, "_Z14touchPanelDownss");
    auto up = load<void(*)()>(library, "_Z12touchPanelUpv");
    auto key = load<void(*)(unsigned char, bool)>(library, "_Z10simuSetKeyhb");
    if (!init || !start || !stop || !flush || !buffer || !changed || !down || !up || !key)
        return 1;
    FILE* output = std::fopen(argv[4], "wb");
    if (!output) { std::perror(argv[4]); return 1; }
    std::vector<unsigned char> image(480 * 272 * 2);
    init();
    start(false, argv[2], argv[2]);
    const auto beginning = std::chrono::steady_clock::now();
    bool ok = true;
    bool sawFrame = false;
    size_t next = 0;
    for (int tick = 0; tick < ticks && ok; ++tick) {
        while (next < actions.size() && tick == actions[next][0]) {
            const auto& a = actions[next++];
            if (a[1] < 0) key(static_cast<unsigned char>(-a[1] - 1), a[3] != 0);
            else if (a[3]) down(a[1], a[2]);
            else up();
        }
        if (*buffer) {
            sawFrame = true;
            std::memcpy(image.data(), *buffer, image.size());
            if (*changed) { *changed = false; flush(); }
        }
        if (tick >= warmup && tick % 5 == 0)
            ok = std::fwrite(image.data(), 1, image.size(), output) == image.size();
        std::this_thread::sleep_until(beginning + std::chrono::milliseconds((tick + 1) * 10));
    }
    stop();
    ok = std::fclose(output) == 0 && ok && sawFrame;
    dlclose(library);
    if (!ok) std::fprintf(stderr, "Failed writing simulator frames (or no LCD buffer)\n");
    return ok ? 0 : 1;
}
