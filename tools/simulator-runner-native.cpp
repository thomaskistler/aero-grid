// SPDX-License-Identifier: GPL-2.0-only
#include <dlfcn.h>
#include <array>
#include <chrono>
#include <csignal>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <iterator>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

namespace {
struct NativeHeap {
    std::uint32_t total_size, free_count, free_size, largest_free, used_count, peak_used;
    std::uint8_t used_percent, fragmented_percent;
};
static_assert(sizeof(NativeHeap) == 28, "Unexpected LVGL monitor ABI");

volatile std::sig_atomic_t stopRequested = 0;

void requestStop(int) {
    stopRequested = 1;
}

template<typename T> T symbol(void* library, const char* name) {
    auto value = reinterpret_cast<T>(dlsym(library, name));
    if (!value) std::fprintf(stderr, "Missing simulator symbol: %s\n", name);
    return value;
}

struct Action {
    int tick;
    int kind;
    int first;
    int second;
    int timeoutTicks;
    bool down;
    std::string condition;
};

struct Snapshot {
    int tick;
    std::string path;
};

bool readActions(const char* path, int ticks, std::vector<Action>& actions) {
    if (std::strcmp(path, "-") == 0) return true;
    std::ifstream input(path);
    if (!input) {
        std::fprintf(stderr, "Cannot open input script: %s\n", path);
        return false;
    }
    std::string line;
    int previous = -1;
    int lineNumber = 0;
    while (std::getline(input, line)) {
        ++lineNumber;
        const auto first = line.find_first_not_of(" \t\r");
        if (first == std::string::npos || line[first] == '#') continue;
        std::istringstream parser(line);
        int tick;
        std::string verb, state, extra;
        Action action{};
        if (!(parser >> tick >> verb) || tick < previous || tick < 0 || tick >= ticks) {
            std::fprintf(stderr, "Malformed or unordered action at line %d\n", lineNumber);
            return false;
        }
        if (verb == "touch") {
            if (!(parser >> action.first >> action.second >> state)
                || action.first < 0 || action.first >= 480
                || action.second < 0 || action.second >= 272
                || (state != "down" && state != "up")) {
                std::fprintf(stderr, "Invalid touch action at line %d\n", lineNumber);
                return false;
            }
            action.kind = 0;
        } else if (verb == "key") {
            if (!(parser >> action.first >> state) || action.first < 0 || action.first > 255
                || (state != "down" && state != "up")) {
                std::fprintf(stderr, "Invalid key action at line %d\n", lineNumber);
                return false;
            }
            action.kind = 1;
        } else if (verb == "wait") {
            if (!(parser >> action.condition >> action.timeoutTicks)
                || action.condition.empty() || action.timeoutTicks <= 0) {
                std::fprintf(stderr, "Invalid wait action at line %d\n", lineNumber);
                return false;
            }
            action.kind = 2;
        } else {
            std::fprintf(stderr, "Unknown input action at line %d\n", lineNumber);
            return false;
        }
        if (parser >> extra) {
            std::fprintf(stderr, "Extra fields in action at line %d\n", lineNumber);
            return false;
        }
        action.tick = tick;
        action.down = state == "down";
        actions.push_back(action);
        previous = tick;
    }
    if (input.bad()) {
        std::fprintf(stderr, "Failed reading input script\n");
        return false;
    }
    return true;
}

bool readSnapshots(const char* path, int ticks, std::vector<Snapshot>& snapshots) {
    if (std::strcmp(path, "-") == 0) return true;
    std::ifstream input(path);
    if (!input) {
        std::fprintf(stderr, "Cannot open snapshot plan: %s\n", path);
        return false;
    }
    std::string line;
    int previous = -1;
    while (std::getline(input, line)) {
        if (line.empty() || line[0] == '#') continue;
        std::istringstream parser(line);
        Snapshot snapshot{};
        if (!(parser >> snapshot.tick)) {
            std::fprintf(stderr, "Malformed or unordered snapshot plan\n");
            return false;
        }
        std::getline(parser >> std::ws, snapshot.path);
        if (snapshot.path.empty()
            || snapshot.tick < previous || snapshot.tick < 0 || snapshot.tick >= ticks
        ) {
            std::fprintf(stderr, "Malformed or unordered snapshot plan\n");
            return false;
        }
        snapshots.push_back(snapshot);
        previous = snapshot.tick;
    }
    return !input.bad();
}
}

int main(int argc, char** argv) {
    std::setvbuf(stdout, nullptr, _IONBF, 0);
    std::setvbuf(stderr, nullptr, _IONBF, 0);
    if (argc != 8) {
        std::fprintf(stderr, "Usage: simulator-runner-native LIBRARY SD INPUTS FRAME_RGB565 TICKS OBSERVE SNAPSHOTS\n");
        return 2;
    }
    char* end = nullptr;
    long ticksLong = std::strtol(argv[5], &end, 10);
    if (!end || *end || ticksLong <= 0 || ticksLong > 360000) {
        std::fprintf(stderr, "Ticks must be in the range 1..360000\n");
        return 2;
    }
    if (std::strcmp(argv[6], "0") != 0 && std::strcmp(argv[6], "1") != 0) {
        std::fprintf(stderr, "OBSERVE must be 0 or 1\n");
        return 2;
    }
    const bool observe = std::strcmp(argv[6], "1") == 0;
    int ticks = static_cast<int>(ticksLong);
    std::vector<Action> actions;
    if (!readActions(argv[3], ticks, actions)) return 2;
    std::vector<Snapshot> snapshots;
    if (!readSnapshots(argv[7], ticks, snapshots)) return 2;

    void* library = dlopen(argv[1], RTLD_NOW);
    if (!library) {
        std::fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    auto init = symbol<void(*)()>(library, "_Z8simuInitv");
    auto start = symbol<void(*)(bool, const char*, const char*)>(library, "_Z9simuStartbPKcS0_");
    auto stop = symbol<void(*)()>(library, "_Z8simuStopv");
    auto flush = symbol<void(*)()>(library, "lcdFlushed");
    auto buffer = symbol<unsigned char**>(library, "simuLcdBuf");
    auto changed = symbol<bool*>(library, "simuLcdRefresh");
    auto touchDown = symbol<void(*)(short, short)>(library, "_Z14touchPanelDownss");
    auto touchUp = symbol<void(*)()>(library, "_Z12touchPanelUpv");
    auto key = symbol<void(*)(unsigned char, bool)>(library, "_Z10simuSetKeyhb");
    auto monitor = reinterpret_cast<void(*)(NativeHeap*)>(dlsym(library, "lv_mem_monitor"));
    if (!init || !start || !stop || !flush || !buffer || !changed || !touchDown
        || !touchUp || !key) {
        dlclose(library);
        return 1;
    }

    std::signal(SIGTERM, requestStop);
    std::signal(SIGINT, requestStop);
    std::vector<unsigned char> image(480 * 272 * 2);
    bool hasFrame = false;
    bool touchHeld = false;
    std::size_t nextAction = 0;
    std::size_t nextSnapshot = 0;
    init();
    start(false, argv[2], argv[2]);
    const auto beginning = std::chrono::steady_clock::now();
    for (int tick = 0; tick < ticks && !stopRequested; ++tick) {
        while (nextAction < actions.size() && actions[nextAction].tick == tick) {
            const Action& action = actions[nextAction++];
            if (action.kind == 2) {
                bool satisfied = false;
                const std::string markerPath = std::string(argv[2]) + "/AEROGRID_RUNNER_UI.txt";
                for (int elapsed = 0; elapsed < action.timeoutTicks && !stopRequested; ++elapsed) {
                    std::ifstream marker(markerPath);
                    if (marker) {
                        const std::string state(
                            (std::istreambuf_iterator<char>(marker)),
                            std::istreambuf_iterator<char>()
                        );
                        if (state.find(action.condition) != std::string::npos) {
                            satisfied = true;
                            break;
                        }
                    }
                    std::this_thread::sleep_for(std::chrono::milliseconds(10));
                }
                if (!satisfied) {
                    std::fprintf(stderr, "Timed out waiting for UI state: %s\n",
                                 action.condition.c_str());
                    if (touchHeld) touchUp();
                    stop();
                    dlclose(library);
                    return 3;
                }
            } else if (action.kind == 0) {
                if (action.down) {
                    touchDown(static_cast<short>(action.first), static_cast<short>(action.second));
                    touchHeld = true;
                } else {
                    touchUp();
                    touchHeld = false;
                }
            } else {
                key(static_cast<unsigned char>(action.first), action.down);
            }
        }
        if (*buffer) {
            hasFrame = true;
            if (observe) std::memcpy(image.data(), *buffer, image.size());
            if (*changed) {
                *changed = false;
                flush();
            }
        }
        while (nextSnapshot < snapshots.size() && snapshots[nextSnapshot].tick == tick) {
            if (!observe || !*buffer) {
                std::fprintf(stderr, "Cannot capture requested snapshot at tick %d\n", tick);
                touchUp();
                stop();
                dlclose(library);
                return 1;
            }
            std::ofstream output(snapshots[nextSnapshot].path, std::ios::binary);
            output.write(reinterpret_cast<const char*>(image.data()), image.size());
            if (!output) {
                std::fprintf(stderr, "Cannot write requested snapshot at tick %d\n", tick);
                touchUp();
                stop();
                dlclose(library);
                return 1;
            }
            ++nextSnapshot;
        }
        std::this_thread::sleep_until(beginning + std::chrono::milliseconds((tick + 1) * 10));
    }
    if (touchHeld) touchUp();
    stop();
    if (hasFrame && observe) {
        std::ofstream output(argv[4], std::ios::binary);
        output.write(reinterpret_cast<const char*>(image.data()), image.size());
        if (!output) {
            std::fprintf(stderr, "Cannot write framebuffer capture\n");
            dlclose(library);
            return 1;
        }
    }
    if (monitor) {
        NativeHeap heap{};
        monitor(&heap);
        std::ofstream memory(std::string(argv[4]) + ".heap.json");
        memory << "{\"lvgl_total_bytes\":" << heap.total_size
               << ",\"lvgl_free_bytes_after_shutdown\":" << heap.free_size
               << ",\"lvgl_largest_free_after_shutdown\":" << heap.largest_free
               << ",\"lvgl_peak_used_bytes\":" << heap.peak_used
               << ",\"lvgl_used_percent_after_shutdown\":"
               << static_cast<unsigned int>(heap.used_percent)
               << ",\"lvgl_fragmented_percent_after_shutdown\":"
               << static_cast<unsigned int>(heap.fragmented_percent) << "}\n";
        if (!memory) {
            std::fprintf(stderr, "Cannot write LVGL allocator snapshot\n");
            dlclose(library);
            return 1;
        }
    }
    dlclose(library);
    if (!hasFrame) {
        std::fprintf(stderr, "Simulator did not expose a framebuffer\n");
        return 1;
    }
    return stopRequested ? 143 : 0;
}
