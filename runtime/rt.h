// Runtime-internal declarations.
#pragma once
#include <pthread.h>
#include <stdarg.h>
#include <stdbool.h>
#include <stdio.h>

#include "cpu.h"
#include "platform.h"

// One write per line: stderr is unbuffered (main.c / platform: crash logs aren't lost), and Windows' CRT then wrote a
// formatted line as dozens of separate WriteFile calls - the 2-second stats line cost ~40 ms, a hitch every 2 s.
static inline void __attribute__((format(printf, 1, 2))) rt_log(const char *fmt, ...) {
    char b[2048];
    va_list ap;
    va_start(ap, fmt);
    int n = vsnprintf(b, sizeof b, fmt, ap);
    va_end(ap);
    if (n < 0) return;
    if ((size_t)n < sizeof b) { fwrite(b, 1, (size_t)n, stderr); return; }
    va_start(ap, fmt);
    vfprintf(stderr, fmt, ap);  // (longer: as before)
    va_end(ap);
}
#define LOG(...) rt_log(__VA_ARGS__)
#define FATAL(...) (rt_fatal_msg(__VA_ARGS__), rt_fatal_trace())  // (runtime/crash_explain.c keeps the line)

// ---- address space layout (guest addresses == host addresses)
// macOS reserves 0x2_0000_0000-0x70_0000_0000, and guest addresses must fit in 39 bits, so the
// guest lives in a 13.5 GB window at 0x70_0000_0000 claimed at startup (see main.c).
#define GUEST_LO     0x7000000000ull
#define GUEST_HI     0x7360000000ull
#define MAIN_BASE    0x7000000000ull   // the first module; the others follow it (tools/gen_game.py), below HLE_BASE
#define HLE_BASE     0x7080000000ull   // fake addresses for host-implemented functions
#define HLE_SIZE     0x0000100000ull
#define TLS_BASE     0x7090000000ull
#define TLS_SIZE     0x0000100000ull
#define HLE_HEAP     0x7092000000ull   // guest-visible memory owned by host code
#define HLE_HEAP_SIZE 0x000E000000ull
#define ALIAS_BASE   0x7100000000ull   // alias region (svcMapMemory targets)
#define ALIAS_SIZE   0x0100000000ull
#define HEAP_BASE    0x7240000000ull
#define HEAP_MAX     0x00D0000000ull   // 3.25 GB
// NVN virtual memory pools (no storage of their own: the GPU sees them at addresses physical pools are mapped to)
// get theirs here, right after the heap, inside the range the renderer gives the GPU (GPU_SPAN from HEAP_BASE)
#define VPOOL_BASE   (HEAP_BASE + HEAP_MAX)
#define VPOOL_SIZE   0x0040000000ull   // 1 GB
#define GPU_SPAN     (HEAP_MAX + VPOOL_SIZE)

// ---- loader.c
typedef struct Module {
    const char *name;
    uint64_t base, size;
    uint64_t text_off, text_size, ro_off, ro_size, data_off, data_size;
    uint64_t dynamic, init, fini, init_array, init_array_sz, fini_array, fini_array_sz;
    uint64_t symtab, strtab, nsyms;
} Module;

#define MAX_MODULES 12
extern Module g_modules[MAX_MODULES];  // the game's modules in load order: main, subsdk0..9, sdk (tools/gen_game.py)
extern int g_nmodules;
Module *loader_module(const char *name);  // NULL: the game has no such module
void loader_load(const char *exefs_dir);  // (again after a reboot: modules are reloaded into wiped memory)
uint64_t loader_find_symbol(const char *name);
const char *loader_symbol_at(uint64_t addr, uint64_t *offset);

// ---- dispatch.c
typedef void (*HostFn)(Cpu *c);
void dispatch_init(void);
GuestFn dispatch_lookup(uint64_t addr);
uint64_t hle_register(const char *name, HostFn fn);  // returns fake guest address
HostFn hle_lookup_impl(const char *name);
void hle_override(uint64_t guest_addr, HostFn fn, const char *name);
void rt_fatal_trace(void) __attribute__((noreturn));
// runtime/crash_explain.c: the fatal line / crash spot, and the player's explanation of it (the crash dialog)
void rt_fatal_msg(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
void rt_crash_fault(const char *what, uint64_t fa, uint64_t pc);
void rt_crash_explain(char *out, size_t n, const char *log_path);
extern int rt_romfs_files;
void crash_handler_install(void);  // per thread (alternate signal stack)

// ---- kernel.c
typedef struct KThread KThread;
void kernel_init(void);
void kernel_stop_threads(void (*idle)(void));  // reboot: unwind every guest thread and join it (idle: called while waiting)
void kernel_reset(void);                       // reboot: empty handle table, memory map, thread list
KThread *kernel_create_main_thread(uint64_t entry, uint64_t stack_size, int prio, int core);  // core: main.npdm's default
void kernel_run_main(KThread *t, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4);
uint32_t kernel_current_thread_handle(void);
Cpu *kernel_current_cpu(void);
void kernel_block_begin(void);  // host code blocks a guest thread outside the kernel: its core goes to another meanwhile
void kernel_sched_point(void);  // a safe point: per-core scheduling (kernel.c)

// ---- ipc.c
typedef struct Service Service;
int ipc_handle_request(Cpu *c, uint32_t handle);
uint32_t ipc_connect_named_port(const char *name);

// ---- in-place reboot (main.c): switch seeds or go back to the start screen without leaving the process
enum { RT_REBOOT_NONE, RT_REBOOT_GAME, RT_REBOOT_TITLE };  // GAME: boot again at once (new seed); TITLE: start screen
void rt_request_reboot(int kind);  // any thread; the window loop (ui_run) returns it and main() carries it out
int rt_reboot_requested(void);
extern volatile int g_rt_unwind;   // set while guest threads are being stopped (kernel.c)
void rt_unwind_point(void);        // guest threads: unwind to thread_main if a reboot is stopping them

// ---- ui (runtime/nvn/metal.m)
int ui_run(void);
// The game's clock (runtime/kernel.c): the host's at the game speed (menu: Video > Game speed)
uint64_t rt_game_ns(void);
double rt_speed(void);
void rt_speed_set(double speed);
void rt_speed_frame(void);  // (each frame: the setting applied)  // window loop; returns the reboot kind requested (the window stays open)

// ---- helpers
void guest_call(Cpu *c, uint64_t addr);   // call guest function at addr (saves/restores x30)
uint64_t guest_sym(const char *name);     // cached loader_find_symbol, fatal if missing
void *hle_alloc(uint64_t size);           // zeroed guest-visible memory (never freed)
extern const char *g_romfs_dir;
