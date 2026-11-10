// SPDX-License-Identifier: GPL-2.0-only
// EdgeTX Companion 2.12 Lua 5.3 (LUA_32BITS) opcode counter.
// Firmware hook: EdgeTX v2.12.0 radio/src/lua/widgets.cpp, luaHook().
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>
#include <algorithm>
#include <fstream>
#include <string>
#include <map>
#include <set>

struct lua_State;
// Lua 5.3 lua_Debug ABI (LUA_IDSIZE=60); integers here are C int even in LUA_32BITS.
struct lua_Debug {
    int event;
    const char *name, *namewhat, *what, *source;
    int currentline, linedefined, lastlinedefined;
    unsigned char nups, nparams;
    char isvararg, istailcall, short_src[60];
    void* i_ci;
};
using Hook = void (*)(lua_State*, lua_Debug*);

namespace {
int (*setHook)(lua_State*, Hook, int, int);
Hook (*getHook)(lua_State*);
int (*getHookCount)(lua_State*);
int (*getHookMask)(lua_State*);
int (*getInfo)(lua_State*, const char*, lua_Debug*);
int (*getStack)(lua_State*, int, lua_Debug*);
const char* (*getLocal)(lua_State*, const lua_Debug*, int);
int (*getTop)(lua_State*);
void (*setTop)(lua_State*, int);
int (*valueType)(lua_State*, int);
float (*toNumber)(lua_State*, int, int*);
void (*pushInteger)(lua_State*, std::int32_t);
void (*pushClosure)(lua_State*, int (*)(lua_State*), int);
void (*setGlobal)(lua_State*, const char*);
lua_State** widgets;
std::uint8_t* firmwarePercent;
Hook firmwareHook;
int period, elapsed, initialPercent;
std::int32_t instructions;
unsigned installations;
bool operationsEnabled;
bool functionsEnabled;
std::string operationsPath;
std::string functionsPath;
std::string limitStackPath;
std::map<std::pair<std::string, int>, int> functionCounts;
std::map<int, int> chartInclusive;
std::set<int> chartFunctions;
unsigned functionCallback;
int indexLine, populatedLine, placeLine, showLine, hideLine, probeLine, consumedLine;
int previousLine, columnInstructions, columnKind;
bool inColumn;
const char* operationNames[] = {
    "empty", "update", "position", "reveal", "hide", "activation_probe"
};
struct Distribution {
    std::uint64_t calls = 0, total = 0, squares = 0;
    int minimum = 0, maximum = 0;
    void add(int count) {
        minimum = calls ? std::min(minimum, count) : count;
        maximum = std::max(maximum, count);
        ++calls;
        total += count;
        squares += std::uint64_t(count) * count;
    }
} operations[6];

void finishColumn() {
    if (inColumn) operations[columnKind].add(columnInstructions);
    inColumn = false;
    columnInstructions = 0;
}

void writeFunctions() {
    if (!functionsEnabled || functionCounts.empty()) return;
    auto file = std::fopen(functionsPath.c_str(), functionCallback == 1 ? "w" : "a");
    if (!file) std::abort();
    for (const auto& entry : functionCounts) {
        std::fprintf(file, "FUNCTION callback=%u source=%s line=%d instructions=%d\n",
                     functionCallback, entry.first.first.c_str(), entry.first.second, entry.second);
    }
    for (const auto& entry : chartInclusive) {
        std::fprintf(file, "INCLUSIVE callback=%u source=panels/chart.lua line=%d instructions=%d\n",
                     functionCallback, entry.first, entry.second);
    }
    std::fclose(file);
    functionCounts.clear();
    chartInclusive.clear();
}

void locateOperationLines(const std::string& root) {
    std::ifstream source(root + "/WIDGETS/AeroGrid/lib/chart_mipmap_renderer.lua");
    const char* markers[] = {
        "local index = offset + slot", "local low, high = lows[slot], highs[slot]",
        "changes.x = left + bucket", "lvgl.show(objects[index])",
        "lvgl.hide(objects[index])", "job.activate, finish = true",
        "job.index = finish + 1"
    };
    int* lines[] = {&indexLine, &populatedLine, &placeLine, &showLine,
                    &hideLine, &probeLine, &consumedLine};
    std::string text;
    int number = 0;
    while (std::getline(source, text)) {
        ++number;
        for (int i = 0; i < 7; ++i) {
            if (text.find(markers[i]) == std::string::npos) continue;
            if (*lines[i]) {
                std::fprintf(stderr, "Duplicate renderer operation marker\n");
                std::abort();
            }
            *lines[i] = number;
        }
    }
    for (int i = 0; i < 7; ++i) {
        if (!*lines[i] && i != 5) {
            std::fprintf(stderr, "Missing renderer operation marker\n");
            std::abort();
        }
    }
}

void operationHook(lua_State* state, lua_Debug* event) {
    if (!getInfo(state, "Sl", event)) std::abort();
    const bool renderer = event->source &&
        std::strstr(event->source, "/lib/chart_mipmap_renderer.lua");
    const int line = renderer ? event->currentline : -1;
    if (!renderer || line < indexLine || line > consumedLine) {
        finishColumn();
    } else {
        if (line == consumedLine) finishColumn();
        if (line == indexLine && previousLine != line) {
            finishColumn();
            inColumn = true;
            columnKind = 0;
        }
        if (inColumn) {
            if (line == populatedLine) columnKind = 1;
            if (line == placeLine) columnKind = 2;
            if (line == showLine) columnKind = 3;
            if (line == hideLine) columnKind = 4;
            if (line == probeLine) columnKind = 5;
            ++columnInstructions;
        }
    }
    previousLine = line;
}

void writeOperations(const std::string& path) {
    finishColumn();
    auto file = std::fopen(path.c_str(), "w");
    if (!file) std::abort();
    for (int i = 0; i < 6; ++i) {
        const auto& d = operations[i];
        std::fprintf(file, "OPERATION kind=%s calls=%llu instructions=%llu squares=%llu minimum=%d maximum=%d\n",
                     operationNames[i], static_cast<unsigned long long>(d.calls),
                     static_cast<unsigned long long>(d.total),
                     static_cast<unsigned long long>(d.squares), d.minimum, d.maximum);
    }
    std::fclose(file);
}

int counter(lua_State* state) {
    pushInteger(state, instructions);
    pushInteger(state, *firmwarePercent - initialPercent);
    pushInteger(state, period);
    return 3;
}

void writeLimitStack(lua_State* state) {
    auto file = std::fopen(limitStackPath.c_str(), "w");
    if (!file) std::abort();
    std::fprintf(file, "LIMIT callback=%u instructions=%d firmware_percent=%u\n",
                 functionCallback, instructions, unsigned(*firmwarePercent));
    lua_Debug frame;
    for (int level = 0; getStack(state, level, &frame); ++level) {
        if (!getInfo(state, "Sl", &frame)) std::abort();
        std::fprintf(file, "FRAME level=%d source=%s function_line=%d current_line=%d\n",
                     level, frame.source ? frame.source : "<no-source>",
                     frame.linedefined, frame.currentline);
        const int top = getTop(state);
        for (int index = 1; ; ++index) {
            const char* name = getLocal(state, &frame, index);
            if (!name) break;
            if (valueType(state, -1) == 3 && name[0] != '(')
                std::fprintf(file, "LOCAL name=%s value=%.9g\n", name, double(toNumber(state, -1, nullptr)));
            setTop(state, top);
        }
    }
    std::fclose(file);
}

void countHook(lua_State* state, lua_Debug* event) {
    if (event->event != 3) {
        std::fprintf(stderr, "Unexpected native profiling hook event\n");
        std::abort();
    }
    ++instructions;
    if (functionsEnabled) {
        if (!getInfo(state, "S", event)) std::abort();
        const char* source = event->source ? std::strstr(event->source, "/WIDGETS/AeroGrid/") : nullptr;
        if (source) {
            ++functionCounts[{source + std::strlen("/WIDGETS/AeroGrid/"), event->linedefined}];
        } else {
            std::string label = event->source ? event->source : "<no-source>";
            if (label.size() > 160 || label.find_first_of(" \n\r\t") != std::string::npos)
                label = "<dynamic-chunk>";
            ++functionCounts[{label, event->linedefined}];
        }
        lua_Debug frame;
        for (int level = 0; getStack(state, level, &frame); ++level) {
            if (!getInfo(state, "S", &frame)) std::abort();
            if (!frame.source || !std::strstr(frame.source, "/panels/chart.lua")) continue;
            if (chartFunctions.count(frame.linedefined)) ++chartInclusive[frame.linedefined];
        }
    }
    if (operationsEnabled) operationHook(state, event);
    if (++elapsed == period) {
        elapsed = 0;
        if (functionsEnabled && *firmwarePercent == 100) writeLimitStack(state);
        firmwareHook(state, event);
    }
}

FILE* instrumentOpen(const char* path, const char* mode) {
    if (mode[0] == 'w' && std::strstr(path, "/capture-ready.txt")) {
        writeFunctions();
        if (operationsEnabled && !operationsPath.empty()) writeOperations(operationsPath);
    }
    if (functionsEnabled && std::strstr(path, "/instruction-profile.txt") &&
        mode[0] == 'w') writeFunctions();
    if (operationsEnabled && std::strstr(path, "/instruction-profile.txt") &&
        mode[0] == 'w') writeOperations(operationsPath);
    if (operationsEnabled && std::strstr(path, "/instruction-operations-reset")) {
        finishColumn();
        for (auto& operation : operations) operation = Distribution{};
    }
    if (operationsEnabled && std::strstr(path, "/instruction-operations-check-dump"))
        writeOperations(operationsPath + ".check");
    if (widgets && *widgets && std::strstr(path, "/instruction-profile-enable")) {
        // The fixture opens this file on the Lua thread before each measured callback.
        // No Lua access is performed from the capture thread.
        auto state = *widgets;
        if (functionsEnabled) {
            if (functionsPath.empty()) {
                const std::string root(path, std::strstr(path, "/instruction-profile-enable") - path);
                functionsPath = root + "/instruction-functions.txt";
                limitStackPath = root + "/instruction-limit-stack.txt";
                std::ifstream source(root + "/WIDGETS/AeroGrid/panels/chart.lua");
                std::string text;
                int line = 0;
                const char* names[] = {
                    "function chart.geometry(", "function chart.render(", "function chart.ranges(",
                    "local function updateHeader(", "local function updateGrid(",
                    "local function finishMipmap(", "local function prepareAxis("
                };
                while (std::getline(source, text)) {
                    ++line;
                    for (auto name : names)
                        if (text.find(name) != std::string::npos) chartFunctions.insert(line);
                }
                if (chartFunctions.size() != 7) {
                    std::fprintf(stderr, "Missing chart function markers\n");
                    std::abort();
                }
            }
            writeFunctions();
            ++functionCallback;
        }
        if (operationsEnabled && operationsPath.empty()) {
            const std::string root(path, std::strstr(path, "/instruction-profile-enable") - path);
            operationsPath = root + "/instruction-operations.txt";
            locateOperationLines(root);
        }
        finishColumn();
        previousLine = -1;
        firmwareHook = getHook(state);
        period = getHookCount(state);
        if (firmwareHook == countHook || getHookMask(state) != 8 || period <= 0) {
            std::fprintf(stderr, "Unexpected firmware hook at profiling activation\n");
            std::abort();
        }
        initialPercent = *firmwarePercent;
        elapsed = instructions = 0;
        ++installations;
        pushClosure(state, counter, 0);
        setGlobal(state, "__instructionCount");
        setHook(state, countHook, 8, 1);
    }
    return std::fopen(path, mode);
}

__attribute__((used)) static const struct {
    const void* replacement;
    const void* original;
} interpose __attribute__((section("__DATA,__interpose"))) = {
    reinterpret_cast<const void*>(instrumentOpen),
    reinterpret_cast<const void*>(fopen),
};
}

extern "C" void captureInstructionProfileInit(void* library) {
    setHook = reinterpret_cast<decltype(setHook)>(dlsym(library, "lua_sethook"));
    getHook = reinterpret_cast<decltype(getHook)>(dlsym(library, "lua_gethook"));
    getHookCount = reinterpret_cast<decltype(getHookCount)>(dlsym(library, "lua_gethookcount"));
    getHookMask = reinterpret_cast<decltype(getHookMask)>(dlsym(library, "lua_gethookmask"));
    getInfo = reinterpret_cast<decltype(getInfo)>(dlsym(library, "lua_getinfo"));
    getStack = reinterpret_cast<decltype(getStack)>(dlsym(library, "lua_getstack"));
    getLocal = reinterpret_cast<decltype(getLocal)>(dlsym(library, "lua_getlocal"));
    getTop = reinterpret_cast<decltype(getTop)>(dlsym(library, "lua_gettop"));
    setTop = reinterpret_cast<decltype(setTop)>(dlsym(library, "lua_settop"));
    valueType = reinterpret_cast<decltype(valueType)>(dlsym(library, "lua_type"));
    toNumber = reinterpret_cast<decltype(toNumber)>(dlsym(library, "lua_tonumberx"));
    operationsEnabled = std::getenv("AEROGRID_PROFILE_OPERATIONS") != nullptr;
    functionsEnabled = std::getenv("AEROGRID_PROFILE_FUNCTIONS") != nullptr;
    pushInteger = reinterpret_cast<decltype(pushInteger)>(dlsym(library, "lua_pushinteger"));
    pushClosure = reinterpret_cast<decltype(pushClosure)>(dlsym(library, "lua_pushcclosure"));
    setGlobal = reinterpret_cast<decltype(setGlobal)>(dlsym(library, "lua_setglobal"));
    widgets = static_cast<lua_State**>(dlsym(library, "lsWidgets"));
    firmwarePercent = static_cast<std::uint8_t*>(dlsym(library, "instructionsPercent"));
    if (!setHook || !getHook || !getHookCount || !getHookMask || !pushInteger
        || !pushClosure || !setGlobal || !widgets || !firmwarePercent || !getInfo || !getStack
        || !getLocal || !getTop || !setTop || !valueType || !toNumber) {
        std::fprintf(stderr, "Missing native instruction-profile symbols\n");
        std::exit(1);
    }
}

extern "C" bool captureInstructionProfileInstalled() {
    return installations > 0;
}
