// SPDX-License-Identifier: GPL-2.0-only
// EdgeTX Companion 2.12 Lua 5.3 (LUA_32BITS) opcode counter.
// Firmware hook: EdgeTX v2.12.0 radio/src/lua/widgets.cpp, luaHook().
#include <dlfcn.h>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <cstring>

struct lua_State;
struct lua_Debug { int event; };
using Hook = void (*)(lua_State*, lua_Debug*);

namespace {
int (*setHook)(lua_State*, Hook, int, int);
Hook (*getHook)(lua_State*);
int (*getHookCount)(lua_State*);
int (*getHookMask)(lua_State*);
void (*pushInteger)(lua_State*, std::int32_t);
void (*pushClosure)(lua_State*, int (*)(lua_State*), int);
void (*setGlobal)(lua_State*, const char*);
lua_State** widgets;
std::uint8_t* firmwarePercent;
Hook firmwareHook;
int period, elapsed, initialPercent;
std::int32_t instructions;
unsigned installations;

int counter(lua_State* state) {
    pushInteger(state, instructions);
    pushInteger(state, *firmwarePercent - initialPercent);
    pushInteger(state, period);
    return 3;
}

void countHook(lua_State* state, lua_Debug* event) {
    if (event->event != 3) {
        std::fprintf(stderr, "Unexpected native profiling hook event\n");
        std::abort();
    }
    ++instructions;
    if (++elapsed == period) {
        elapsed = 0;
        firmwareHook(state, event);
    }
}

FILE* instrumentOpen(const char* path, const char* mode) {
    if (widgets && *widgets && std::strstr(path, "/instruction-profile-enable")) {
        // The fixture opens this file on the Lua thread before each measured callback.
        // No Lua access is performed from the capture thread.
        auto state = *widgets;
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
    pushInteger = reinterpret_cast<decltype(pushInteger)>(dlsym(library, "lua_pushinteger"));
    pushClosure = reinterpret_cast<decltype(pushClosure)>(dlsym(library, "lua_pushcclosure"));
    setGlobal = reinterpret_cast<decltype(setGlobal)>(dlsym(library, "lua_setglobal"));
    widgets = static_cast<lua_State**>(dlsym(library, "lsWidgets"));
    firmwarePercent = static_cast<std::uint8_t*>(dlsym(library, "instructionsPercent"));
    if (!setHook || !getHook || !getHookCount || !getHookMask || !pushInteger
        || !pushClosure || !setGlobal || !widgets || !firmwarePercent) {
        std::fprintf(stderr, "Missing native instruction-profile symbols\n");
        std::exit(1);
    }
}

extern "C" bool captureInstructionProfileInstalled() {
    return installations > 0;
}
