// SPDX-License-Identifier: GPL-2.0-only
#include <dlfcn.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include <array>
#include <fstream>
#include <sstream>
#include <unistd.h>

template<typename T> T symbol(void* library, const char* name) {
    auto value = reinterpret_cast<T>(dlsym(library, name));
    if (!value) {
        std::fprintf(stderr, "Missing simulator symbol: %s\n", name);
    }
    return value;
}

int main(int argc, char** argv) {
    if (argc != 5 && argc != 6) {
        std::fprintf(stderr, "Usage: capture-native LIBRARY ISOLATED_SD OUTPUT_RGB565 REGIONS [fullscreen|actions=FILE]\n");
        return 2;
    }
    bool fullscreen = argc == 6 && std::strcmp(argv[5], "fullscreen") == 0;
    bool scripted = argc == 6 && std::strncmp(argv[5], "actions=", 8) == 0;
    std::vector<std::array<int, 4>> actions;
    if (scripted) {
        std::ifstream script(argv[5] + 8);
        std::array<int, 4> action;
        while (script >> action[0] >> action[1] >> action[2] >> action[3]) actions.push_back(action);
        if (actions.empty() || !script.eof()) return 2;
    }
    if (argc == 6 && !fullscreen && !scripted) {
        std::fprintf(stderr, "Unknown capture mode\n");
        return 2;
    }
    std::ifstream input(argv[4]);
    std::vector<std::array<int, 4>> regions;
    std::array<int, 4> region;
    std::string line;
    while (std::getline(input, line)) {
        std::istringstream fields(line);
        std::string extra;
        if (!(fields >> region[0] >> region[1] >> region[2] >> region[3]) || fields >> extra) {
            std::fprintf(stderr, "Malformed capture region\n");
            return 2;
        }
        if (region[0] < 0 || region[1] < 0 || region[2] <= 0 || region[3] <= 0
            || region[0] > 480 || region[1] > 272
            || region[2] > 480 - region[0] || region[3] > 272 - region[1]) {
            std::fprintf(stderr, "Invalid capture region\n");
            return 2;
        }
        regions.push_back(region);
    }
    if (regions.empty() || input.bad()) {
        std::fprintf(stderr, "Missing or malformed capture regions\n");
        return 2;
    }
    void* library = dlopen(argv[1], RTLD_NOW);
    if (!library) {
        std::fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    // EdgeTX 2.12 native simulator entry points; see targets/simu/simpgmspace.cpp.
    auto init = symbol<void(*)()>(library, "_Z8simuInitv");
    auto start = symbol<void(*)(bool, const char*, const char*)>(library, "_Z9simuStartbPKcS0_");
    auto stop = symbol<void(*)()>(library, "_Z8simuStopv");
    auto flush = symbol<void(*)()>(library, "lcdFlushed");
    auto buffer = symbol<unsigned char**>(library, "simuLcdBuf");
    auto changed = symbol<bool*>(library, "simuLcdRefresh");
    auto touchDown = fullscreen || scripted ? symbol<void(*)(short, short)>(library, "_Z14touchPanelDownss") : nullptr;
    auto touchUp = fullscreen || scripted ? symbol<void(*)()>(library, "_Z12touchPanelUpv") : nullptr;
    if (!init || !start || !stop || !flush || !buffer || !changed) {
        return 1;
    }
    if ((fullscreen || scripted) && (!touchDown || !touchUp)) return 1;
    const size_t bytes = 480 * 272 * 2;
    std::vector<unsigned char> previous(bytes), image(bytes);
    std::string ready = std::string(argv[2]) + "/capture-ready.txt";
    int stable = 0;
    bool captured = false;
    init();
    start(false, argv[2], argv[2]);
    for (int tick = 0; tick < 3000; ++tick) {
        if (fullscreen && tick == 500) touchDown(200, 140);
        if (fullscreen && tick == 600) touchUp();
        for (const auto& action : actions) {
            if (tick == action[0]) {
                if (action[3]) touchDown(action[1], action[2]);
                else touchUp();
            }
        }
        if (*buffer) {
            std::memcpy(image.data(), *buffer, bytes);
            if (*changed) {
                *changed = false;
                flush();
            }
            if (access(ready.c_str(), F_OK) == 0
                && (!scripted || tick > actions.back()[0] + 100)) {
                bool same = true;
                for (const auto& region : regions) {
                    for (int y = region[1]; y < region[1] + region[3]; ++y) {
                        size_t offset = (y * 480 + region[0]) * 2;
                        same = same && std::memcmp(image.data() + offset,
                            previous.data() + offset, region[2] * 2) == 0;
                    }
                }
                stable = same ? stable + 1 : 0;
                if (stable >= 20) {
                    captured = true;
                    break;
                }
            }
            previous = image;
        }
        usleep(10000);
    }
    stop();
    if (!captured) {
        std::fprintf(stderr, "Timed out waiting for verified content and stable frames\n");
        return 1;
    }
    FILE* output = std::fopen(argv[3], "wb");
    if (!output) {
        std::perror(argv[3]);
        return 1;
    }
    bool written = std::fwrite(image.data(), 1, bytes, output) == bytes;
    written = std::fclose(output) == 0 && written;
    return written ? 0 : 1;
}
