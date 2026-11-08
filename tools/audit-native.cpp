// SPDX-License-Identifier: GPL-2.0-only
// Runs the EdgeTX 2.12 x86_64 macOS simulator with an exact Lua instruction counter.
//
// The firmware sets a count hook of 200 instructions before every widget
// callback, so `getUsage` only has 200-instruction resolution and Lua cannot read
// it mid-callback. This harness replaces `luaSetInstructionsLimit` with a version
// that installs a hook on every instruction and publishes two Lua globals:
// `__count()` returns the instructions executed so far and `__pause(flag)`
// excludes the caller's own bookkeeping from the count. The replacement does not
// enforce the 20000 limit, so oversized callbacks are measured rather than killed.
#include <dlfcn.h>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <unistd.h>
#include <mach/mach.h>
#include <mach/mach_vm.h>

typedef void lua_State;
typedef void (*Hook)(lua_State*, void*);
typedef void* (*Allocator)(void*, void*, size_t, size_t);

static volatile uint64_t counter = 0;
static volatile bool paused = false;
static void (*lua_sethook_)(lua_State*, Hook, int, int);
static void (*lua_pushcclosure_)(lua_State*, int (*)(lua_State*), int);
static void (*lua_setglobal_)(lua_State*, const char*);
static void (*lua_pushinteger_)(lua_State*, long long);
static int (*lua_toboolean_)(lua_State*, int);
static Allocator (*lua_getallocf_)(lua_State*, void**);
static void (*lua_setallocf_)(lua_State*, Allocator, void*);
static int (*lua_gc_)(lua_State*, int, int);
static bool memoryMode = false;
static Allocator previousAllocator = nullptr;
static void* previousAllocatorData = nullptr;
static int64_t heapBytes = 0, peakBytes = 0, initialBytes = 0;
static uint64_t allocationCalls = 0, heapChecks = 0;

static void* trackedAlloc(void*, void* ptr, size_t oldSize, size_t newSize) {
    void* result = previousAllocator(previousAllocatorData, ptr, oldSize, newSize);
    if (newSize == 0 || result != nullptr) {
        // For a new allocation Lua passes a type tag, not an old byte size.
        heapBytes += static_cast<int64_t>(newSize) - static_cast<int64_t>(ptr ? oldSize : 0);
        if (heapBytes > peakBytes) peakBytes = heapBytes;
    }
    ++allocationCalls;
    return result;
}

static void trackMemory(lua_State* L) {
    void* data = nullptr;
    Allocator current = lua_getallocf_(L, &data);
    const int LUA_GCCOUNT = 3, LUA_GCCOUNTB = 4;
    int64_t actual = static_cast<int64_t>(lua_gc_(L, LUA_GCCOUNT, 0)) * 1024
                     + lua_gc_(L, LUA_GCCOUNTB, 0);
    if (current == trackedAlloc) {
        if (actual != heapBytes) {
            std::fprintf(stderr, "Lua allocator mismatch: tracked=%lld actual=%lld\n",
                         static_cast<long long>(heapBytes), static_cast<long long>(actual));
            std::abort();
        }
        ++heapChecks;
        return;
    }
    if (previousAllocator != nullptr) {
        std::fprintf(stderr, "Multiple independent Lua allocators; memory measurement invalid\n");
        std::abort();
    }
    previousAllocator = current;
    previousAllocatorData = data;
    heapBytes = peakBytes = initialBytes = actual;
    lua_setallocf_(L, trackedAlloc, nullptr);
}

static void countHook(lua_State*, void*) {
    if (!paused) counter = counter + 1;
}

static int readCount(lua_State* L) {
    lua_pushinteger_(L, static_cast<long long>(counter));
    return 1;
}

static int setPause(lua_State* L) {
    paused = lua_toboolean_(L, 1) != 0;
    return 0;
}

static void instrumented(lua_State* L, int) {
    if (memoryMode) trackMemory(L);
    const int LUA_MASKCOUNT = 8;
    paused = false;
    lua_sethook_(L, countHook, LUA_MASKCOUNT, 1);
    lua_pushcclosure_(L, readCount, 0);
    lua_setglobal_(L, "__count");
    lua_pushcclosure_(L, setPause, 0);
    lua_setglobal_(L, "__pause");
}

template<typename T> static T symbol(void* library, const char* name) {
    auto value = reinterpret_cast<T>(dlsym(library, name));
    if (!value) std::fprintf(stderr, "Missing simulator symbol: %s\n", name);
    return value;
}

int main(int argc, char** argv) {
    if (argc < 3 || argc > 7) {
        std::fprintf(stderr, "Usage: audit-native LIBRARY ISOLATED_SD [TIMEOUT_SECONDS] "
                             "[passthrough] [fullscreen] [memory]\n");
        return 2;
    }
    int timeout = argc >= 4 ? std::atoi(argv[3]) : 120;
    bool passthrough = false, fullscreen = false;
    for (int index = 4; index < argc; ++index) {
        if (std::strcmp(argv[index], "passthrough") == 0) passthrough = true;
        else if (std::strcmp(argv[index], "fullscreen") == 0) fullscreen = true;
        else if (std::strcmp(argv[index], "memory") == 0) memoryMode = true;
        else {
            std::fprintf(stderr, "Unknown audit mode: %s\n", argv[index]);
            return 2;
        }
    }
    void* library = dlopen(argv[1], RTLD_NOW);
    if (!library) {
        std::fprintf(stderr, "%s\n", dlerror());
        return 1;
    }
    auto init = symbol<void (*)()>(library, "_Z8simuInitv");
    auto start = symbol<void (*)(bool, const char*, const char*)>(library, "_Z9simuStartbPKcS0_");
    auto stop = symbol<void (*)()>(library, "_Z8simuStopv");
    lua_sethook_ = symbol<decltype(lua_sethook_)>(library, "lua_sethook");
    lua_pushcclosure_ = symbol<decltype(lua_pushcclosure_)>(library, "lua_pushcclosure");
    lua_setglobal_ = symbol<decltype(lua_setglobal_)>(library, "lua_setglobal");
    lua_pushinteger_ = symbol<decltype(lua_pushinteger_)>(library, "lua_pushinteger");
    lua_toboolean_ = symbol<decltype(lua_toboolean_)>(library, "lua_toboolean");
    if (memoryMode) {
        lua_getallocf_ = symbol<decltype(lua_getallocf_)>(library, "lua_getallocf");
        lua_setallocf_ = symbol<decltype(lua_setallocf_)>(library, "lua_setallocf");
        lua_gc_ = symbol<decltype(lua_gc_)>(library, "lua_gc");
        if (passthrough || !lua_getallocf_ || !lua_setallocf_ || !lua_gc_) return 1;
    }
    auto target = symbol<uint8_t*>(library, "_Z23luaSetInstructionsLimitP9lua_Statei");
    // LVGL waits for the host to acknowledge each display flush.
    auto flush = symbol<void (*)()>(library, "lcdFlushed");
    auto buffer = symbol<unsigned char**>(library, "simuLcdBuf");
    auto changed = symbol<bool*>(library, "simuLcdRefresh");
    auto touchDown = fullscreen ? symbol<void (*)(short, short)>(library, "_Z14touchPanelDownss") : nullptr;
    auto touchUp = fullscreen ? symbol<void (*)()>(library, "_Z12touchPanelUpv") : nullptr;
    if (fullscreen && (!touchDown || !touchUp)) return 1;
    if (!flush || !buffer || !changed) return 1;
    if (!init || !start || !stop || !lua_sethook_ || !lua_pushcclosure_ || !lua_setglobal_ || !lua_pushinteger_
        || !lua_toboolean_ || !target) {
        return 1;
    }
    if (!passthrough) {
        // movabs rax, imm64; jmp rax
        uint8_t jump[12] = {0x48, 0xB8};
        uint64_t destination = reinterpret_cast<uint64_t>(&instrumented);
        std::memcpy(jump + 2, &destination, 8);
        jump[10] = 0xFF;
        jump[11] = 0xE0;
        mach_vm_address_t page = reinterpret_cast<mach_vm_address_t>(target) & ~0xfffULL;
        if (mach_vm_protect(mach_task_self(), page, 0x2000, 0,
                            VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY | VM_PROT_EXECUTE) != KERN_SUCCESS) {
            std::fprintf(stderr, "Cannot make the simulator hook patchable\n");
            return 1;
        }
        std::memcpy(target, jump, sizeof(jump));
    }
    std::string ready = std::string(argv[2]) + "/audit-ready.txt";
    init();
    start(false, argv[2], argv[2]);
    bool finished = false;
    for (int tick = 0; tick < timeout * 100; ++tick) {
        usleep(10000);
        if (fullscreen && tick == 500) touchDown(200, 140);
        if (fullscreen && tick == 600) touchUp();
        if (*buffer && *changed) {
            *changed = false;
            flush();
        }
        if (access(ready.c_str(), F_OK) == 0) {
            finished = true;
            break;
        }
    }
    stop();
    if (memoryMode) {
        if (previousAllocator == nullptr || allocationCalls == 0 || heapChecks == 0
            || peakBytes < initialBytes || heapBytes < 0) {
            std::fprintf(stderr, "Lua memory measurement invalid\n");
            return 1;
        }
        std::fprintf(stderr, "AEROGRID_LUA_HEAP initial=%lld peak=%lld final=%lld calls=%llu checks=%llu\n",
                     static_cast<long long>(initialBytes), static_cast<long long>(peakBytes),
                     static_cast<long long>(heapBytes), static_cast<unsigned long long>(allocationCalls),
                     static_cast<unsigned long long>(heapChecks));
    }
    if (!finished) {
        std::fprintf(stderr, "Timed out waiting for the audit to finish\n");
        return 1;
    }
    return 0;
}
