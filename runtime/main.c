// Entry: identify the game, load its modules and recompiled code, set up the kernel, run nn::init::Start on the main
// thread.
#include <SDL3/SDL.h>
#ifdef __APPLE__
#include <TargetConditionals.h>
#endif
#if TARGET_OS_IPHONE  // (UIKit: SDL runs main inside the app's UIApplicationMain)
#include <SDL3/SDL_main.h>
#include <dirent.h>
#include <sys/stat.h>
#endif
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include "game.h"
#include "gamelib.h"
#include "paths.h"
#include "settings.h"
#include "hle.h"
#include "kernel.h"
#include "ui/menu.h"
#include "ui/cloud.h"

const char *g_romfs_dir;

const char *rt_window_title(void) {
    static char t[160];
    snprintf(t, sizeof t, g_game.name[0] ? "nx - %s" : "nx", g_game.name);
    return t;
}

// rtld normally passes these to nn::init::Start: run every module's init/fini arrays.
static void run_array(Cpu *c, uint64_t arr, uint64_t size) {
    for (uint64_t i = 0; i < size / 8; i++) {
        uint64_t fn = ((uint64_t *)arr)[i];
        if (fn) guest_call(c, fn);
    }
}

// nn::init::Start takes the callbacks rtld would pass. SDK 11 (three): x2 right after nnosInitialize, x3 after
// nninitStartup just before nnMain, and x4 after nnMain returns - SDK constructors run early, the game's once
// nninitStartup has set up its heap, and the modules' fini arrays at the end. Older SDKs (9: two): x2 right after
// nnosInitialize runs every module's constructors, x3 the fini arrays after nnMain.
// rtld runs a module's DT_INIT, which registers it (and its TLS template) with musl via
// __nnmusl_init_dso and then runs its init_array; fall back to the array if there is no DT_INIT.
static void module_init(Cpu *c, Module *m) {
    LOG("init %s (DT_INIT %llx, %llu init_array entries)\n", m->name, m->init, m->init_array_sz / 8);
    if (m->init) guest_call(c, m->init);
    else run_array(c, m->init_array, m->init_array_sz);
}

static void rtld_init_sdk(Cpu *c) {  // the SDK, then the subsdks (built on it), in load order
    Module *sdk = loader_module("sdk");
    if (sdk) module_init(c, sdk);
    for (int i = 1; i < g_nmodules; i++)
        if (&g_modules[i] != sdk) module_init(c, &g_modules[i]);
}
static void rtld_init_main(Cpu *c) { module_init(c, &g_modules[0]); }
static void rtld_init_all(Cpu *c) { rtld_init_sdk(c); rtld_init_main(c); }
static void rtld_fini(Cpu *c) {
    for (int i = 0; i < g_nmodules; i++) {
        Module *m = &g_modules[i];
        if (m->fini) guest_call(c, m->fini);
        else if (m->fini_array_sz)  // (in reverse, as rtld runs them)
            for (uint64_t k = m->fini_array_sz / 8; k-- > 0;) {
                uint64_t fn = ((uint64_t *)m->fini_array)[k];
                if (fn) guest_call(c, fn);
            }
    }
}

// Claim the guest address range before anything else can map there. The host allocator places
// regions at random addresses in the same window; on a collision, re-exec for a fresh layout.
// LARECOMP_REEXEC_FORCE=1 (test): the first process skips the reservation once and starts again, as when the range is
// taken (the new process has LARECOMP_REEXEC set and reserves normally).
#define REEXEC_FORCED "forced by LARECOMP_REEXEC_FORCE"
__attribute__((constructor(101))) static void reserve_guest_space(void) {
    const char *force = getenv("LARECOMP_REEXEC_FORCE");
    bool forced = force && *force && strcmp(force, "0") && !getenv("LARECOMP_REEXEC");
    if (forced) setenv("LARECOMP_REEXEC_WHY", REEXEC_FORCED, 1);
    else if (plat_reserve_guest(GUEST_LO, GUEST_HI)) return;
    else setenv("LARECOMP_REEXEC_WHY", "", 0);  // (the platform may have said what holds the range; else nothing more)
    const char *tries = getenv("LARECOMP_REEXEC");
    int n = tries ? atoi(tries) : 0;
    if (n >= 20) {
        fprintf(stderr, "FATAL: guest address range %llx-%llx is not free\n", GUEST_LO, GUEST_HI);
        exit(1);
    }
    char buf[16];
    snprintf(buf, sizeof buf, "%d", n + 1);
    setenv("LARECOMP_REEXEC", buf, 1);
    plat_exec(NULL);
    perror("re-exec");
    exit(1);
}

// ------------------------------------------------------------------ boot / in-place reboot
// Switching seeds (or vanilla) and going back to the start screen reboot the game inside this process: the window,
// GPU device, settings and shader caches stay. rt_request_reboot (menu, any thread) makes ui_run return on the
// main thread, which then: stops every guest thread (kernel_stop_threads: each unwinds at its next svc / HLE call /
// wait), resets the renderer (textures, address-keyed caches) and all per-boot host state (RT_ON_RESET hooks:
// services, HLE features, seed data, audio), empties the kernel, wipes guest memory, and boots again.
static _Atomic int g_reboot;
void rt_request_reboot(int kind) {
    LOG("[reboot] requested (%s)\n", kind == RT_REBOOT_TITLE ? "start screen" : "boot");
    g_reboot = kind;
}
int rt_reboot_requested(void) { return g_reboot; }

// LARECOMP_REBOOT_AT=<frame>:<seed | vanilla | title>[,...] (test): at that presented frame, switch to the seed /
// vanilla in place, or go back to the start screen (with LARECOMP_LAUNCHER_AUTOPLAY it plays the saved choice).
// Frames count on across reboots. Called by the presenter every frame.
void reboot_test_frame(uint64_t frame) {
    static const char *next;
    static int init;
    if (!init) { init = 1; next = getenv("LARECOMP_REBOOT_AT"); }
    long at;
    char what[128];
    if (!next || !*next || sscanf(next, "%ld:%127[^,]", &at, what) != 2 || (long)frame < at) return;
    next = strchr(next, ',');
    if (next) next++;
    if (!strcmp(what, "title")) { rt_request_reboot(RT_REBOOT_TITLE); return; }
    rt_request_reboot(RT_REBOOT_GAME);
}

#ifdef __APPLE__
extern const ResetFn __start_resets[] __asm__("section$start$__DATA$__rt_reset");
extern const ResetFn __stop_resets[] __asm__("section$end$__DATA$__rt_reset");
#elif defined(__linux__)
extern const ResetFn __start_resets[], __stop_resets[];  // (ELF: defined by the linker)
#else
// PE/COFF: .rst$a < .rst$m (entries, hle.h) < .rst$z (the linker sorts by the text after '$')
__attribute__((section(".rst$a"), used)) static const ResetFn __start_resets[1];
__attribute__((section(".rst$z"), used)) static const ResetFn __stop_resets[1];
#endif

void backend_reset(void);             // renderer: GPU idle, game textures and address-keyed caches dropped
void backend_guest_memory_reset(void);  // renderer: guest memory was replaced (re-wrap the heap)
void backend_clear_window(void);      // a black frame while the game is down
void backend_quit(void);              // quitting: the render thread stopped, the GPU idle, caches kept (before exit())

static void reboot_idle(void) {  // (main thread, while guest threads stop) keep the window alive
    SDL_Event e;
    while (SDL_PollEvent(&e))
        if (e.type == SDL_EVENT_QUIT) { LOG("window closed\n"); backend_quit(); cloud_quit(); exit(0); }
}

static void teardown(void) {
    uint64_t t0 = plat_now_ns();
    kernel_stop_threads(reboot_idle);
    backend_clear_window();
    backend_reset();
    const ResetFn *start = __start_resets, *stop = __stop_resets;
    __asm__("" : "+r"(start), "+r"(stop));  // separate objects: keep the compiler from reasoning about them
    int n = 0;
    for (const ResetFn *p = start; p < stop; p++)
        if (*p) { (*p)(); n++; }
    kernel_reset();
    if (!plat_reset_guest(GUEST_LO, GUEST_HI)) FATAL("cannot reset guest memory\n");
    backend_guest_memory_reset();
    g_nmodules = 0;
    g_reboot = RT_REBOOT_NONE;
    LOG("[reboot] game torn down in %llums (%d reset hooks)\n", (unsigned long long)((plat_now_ns() - t0) / 1000000), n);
}

static void boot(const char *root) {
    char exefs[1024], romfs[1024], npdm_path[1024];
    snprintf(exefs, sizeof exefs, "%s/exefs", root);
    snprintf(romfs, sizeof romfs, "%s/romfs", root);
    snprintf(npdm_path, sizeof npdm_path, "%s/main.npdm", exefs);
    free((void *)g_romfs_dir);  // (the game may be another one: the selection screen)
    g_romfs_dir = strdup(romfs);

#ifdef __linux__
    {   // the window and graphics device first (normally made by the start screen or ui_run), so the guest heap can be
        // the driver's memory before any game thread runs (runtime/nvn/vulkan/exec.c backend_guest_heap_prepare)
        extern void ui_window_init(void);
        extern void backend_guest_heap_prepare(void);
        ui_window_init();
        backend_guest_heap_prepare();
    }
#endif
    char why[512];
    uint64_t t0 = plat_now_ns();
    if (!game_select(root, why, sizeof why)) FATAL("%s\n", why);  // (its profile, if any: game.h)
    menu_loading_status("Loading the game's code");
    if (!gamelib_load(root, why, sizeof why)) FATAL("%s\n", why);
    uint64_t t1 = plat_now_ns();
    menu_loading_status("Loading the game");
    loader_load(exefs);
    { extern void settings_load(void); settings_load(); }
    cloud_boot();  // (a newer save from another device: runtime/ui/cloud.mm)
    kernel_init();
    dispatch_init();

    uint32_t stack_size = 0x100000;
    int prio = 44, core = 0;
    FILE *f = fopen(npdm_path, "rb");
    if (f) {
        uint8_t meta[0x80];
        if (fread(meta, 1, sizeof meta, f) == sizeof meta && !memcmp(meta, "META", 4)) {
            prio = meta[0xE];
            core = meta[0xF];
            stack_size = *(uint32_t *)(meta + 0x1C);
        }
        fclose(f);
    }
    LOG("main thread: prio %d, core %d, stack 0x%x\n", prio, core, stack_size);
    LOG("[boot] game code loaded in %llu ms, the game in %llu ms\n", (unsigned long long)((t1 - t0) / 1000000),
        (unsigned long long)((plat_now_ns() - t1) / 1000000));
    menu_loading_status("Starting");

    if (g_game.profile && g_game.profile->booted) g_game.profile->booted();
    if (getenv("LARECOMP_WATCH_EARLY")) { extern void watch_arm(void); watch_arm(); }  // (debug: the watch from boot)
    uint64_t fini = hle_register("<rtld_fini>", rtld_fini);
    uint64_t start = loader_find_symbol("_ZN2nn4init5StartEmmPFvvES2_S2_");  // (SDK 11)
    KThread *t;
    if (start) {
        uint64_t init_sdk = hle_register("<rtld_init_sdk>", rtld_init_sdk);
        uint64_t init_main = hle_register("<rtld_init_main>", rtld_init_main);
        t = kernel_create_main_thread(start, stack_size, prio, core);
        // nn::init::Start(thread_handle, args_region, init_sdk, init_main, fini)
        kernel_run_main(t, t->handle, 0, init_sdk, init_main, fini);
    } else if ((start = loader_find_symbol("_ZN2nn4init5StartEmmPFvvES2_"))) {  // (older SDKs: two callbacks)
        uint64_t init_all = hle_register("<rtld_init_all>", rtld_init_all);
        t = kernel_create_main_thread(start, stack_size, prio, core);
        kernel_run_main(t, t->handle, 0, init_all, fini, 0);
    } else FATAL("nn::init::Start not found\n");
}

// The log's first line after the log's own: this build and the machine, for bug reports. Nothing that identifies the
// player (platform.h plat_system_info). Once per session: a restart of this process (the start screen re-executing
// itself for the game) appends to the same log and inherits LASRECOMP_INFO_LOGGED.
static void log_startup_info(void) {
    if (getenv("LASRECOMP_INFO_LOGGED")) return;
    setenv("LASRECOMP_INFO_LOGGED", "1", 1);
    extern const char *larecomp_version(void);  // runtime/ui/launcher.mm
    PlatSysInfo si = {0};
    plat_system_info(&si);
    char cores[96] = "";
    if (si.cores > 0) {
        int n = snprintf(cores, sizeof cores, " %d cores", si.cores);
        if (si.cores_detail[0]) n += snprintf(cores + n, sizeof cores - n, " (%s)", si.cores_detail);
        if (si.threads > si.cores) snprintf(cores + n, sizeof cores - n, " / %d threads", si.threads);
    } else if (si.threads > 0) snprintf(cores, sizeof cores, " %d threads", si.threads);
    unsigned long long tenths = (si.ram * 10 + (1ull << 29)) >> 30;  // (GB to a tenth; whole when it is: 64 GB, 14.5 GB)
    char ram[32] = "RAM unknown";
    if (si.ram && tenths % 10) snprintf(ram, sizeof ram, "%llu.%llu GB RAM", tenths / 10, tenths % 10);
    else if (si.ram) snprintf(ram, sizeof ram, "%llu GB RAM", tenths / 10);
    fprintf(stderr, "[info] nx %s, %s, %s%s, %s%s%s\n", larecomp_version(), si.os[0] ? si.os : "unknown OS",
            si.cpu[0] ? si.cpu : "unknown CPU", cores, ram, si.package ? ", " : "", si.package ? si.package : "");
}

#if TARGET_OS_IPHONE
// The games in the data folder (the app's Documents): its folders with exefs/main in them, by name
int g_game_count;  // (runtime/ui/menu.mm: "Switch game" with more than one)
static char g_games[16][1024];
static int cmp_str(const void *a, const void *b) { return strcmp(a, b); }
static void find_games(void) {
    g_game_count = 0;
    DIR *d = opendir(".");
    struct stat st;
    char p[1100];
    for (struct dirent *e; d && (e = readdir(d)) && g_game_count < 16;) {
        snprintf(p, sizeof p, "%s/exefs/main", e->d_name);
        if (e->d_name[0] != '.' && stat(p, &st) == 0 && realpath(e->d_name, g_games[g_game_count])) g_game_count++;
    }
    if (d) closedir(d);
    qsort(g_games, g_game_count, sizeof g_games[0], cmp_str);
}
// The game to play: the only one, or the player's pick on the selection screen (runtime/ui/menu.mm)
static const char *pick_game(void) {
    if (!g_game_count)
        FATAL("No game files found. Put the game's folder (with exefs/ and romfs/ in it) in nx's folder in the "
              "Files app (On My iPhone / iPad > nx), then start nx again.\n");
    if (g_game_count == 1) return g_games[0];
    static char titles[16][160], details[16][200], covers[16][600];
    const char *t[16], *dt[16], *cv[16];
    bool playable[16];
    for (int i = 0; i < g_game_count; i++) {
        GameInfo g;
        char why[256];
        const char *folder = strrchr(g_games[i], '/') ? strrchr(g_games[i], '/') + 1 : g_games[i];
        playable[i] = game_identify(g_games[i], &g, why, sizeof why) && gamelib_present(g_games[i]);
        snprintf(titles[i], sizeof titles[i], "%s", g.name[0] ? g.name : folder);
        if (!playable[i]) snprintf(details[i], sizeof details[i], "%s - this app doesn't have its game code", folder);
        else snprintf(details[i], sizeof details[i], "%s%s%s", g.version ? "Version " : "", g.version ? g.version->label : "",
                      g.version ? "" : folder);
        snprintf(covers[i], sizeof covers[i], "cache/%s/cover.jpg", g.key);
        t[i] = titles[i], dt[i] = details[i], cv[i] = covers[i];
    }
    extern void ui_window_init(void);
    ui_window_init();
    int k = menu_pick_game(g_game_count, t, dt, cv, playable);
    LOG("[boot] game picked: %s\n", g_games[k]);
    return g_games[k];
}
// The loading screen until the game's first frame (runtime/ui/menu.mm): its name over its cover
static void loading_screen(const char *root) {
    GameInfo g;
    char why[256], cover[600];
    if (!game_identify(root, &g, why, sizeof why)) return;
    extern void ui_window_init(void);
    ui_window_init();
    snprintf(cover, sizeof cover, "cache/%s/cover.jpg", g.key);
    menu_loading_begin(g.name, cover);
}
#endif

int main(int argc, char **argv) {
    plat_init();
    log_startup_info();
    if (getenv("LARECOMP_REEXEC")) {  // (reserve_guest_space started this process again)
        const char *why = getenv("LARECOMP_REEXEC_WHY"), *n = getenv("LARECOMP_REEXEC");
        if (!why) LOG("[boot] started again (try %s) (LARECOMP_REEXEC set by the caller)\n", n);
        else if (!strcmp(why, REEXEC_FORCED)) LOG("[boot] started again (try %s): %s\n", n, why);
        else LOG("[boot] started again (try %s): the guest address range was in use%s%s\n", n, *why ? ": " : "", why);
    }
#ifdef _WIN32
    setvbuf(stderr, NULL, _IONBF, 0);  // the Windows CRT treats _IOLBF as full buffering
#else
    setvbuf(stderr, NULL, _IOLBF, 0);
#endif
    const char *root = ".";  // (the folder with exefs/ and romfs/; default: the data root)
    static char arg_root[1024];
    for (int i = 1; i < argc; i++) {
        if (argv[i][0] == '-') continue;  // (--play: accepted for LASRecomp's scripts; there is no start screen yet)
        root = realpath(argv[i], arg_root) ? arg_root : argv[i];  // (relative to where we started)
    }
    rt_paths_init();  // the data root becomes the working directory (runtime/paths.h)
#if TARGET_OS_IPHONE
    // the game files: a folder in the data folder (the app's Documents) with exefs/main in it, unless given
    bool given = strcmp(root, ".") != 0;
    find_games();
    if (!given) root = pick_game();
#endif
    for (;;) {  // (an in-place reboot boots again; "back to the start screen": the game selection screen on iOS)
#if TARGET_OS_IPHONE
        loading_screen(root);
#endif
        boot(root);
        int kind = ui_run();  // window and input on the main thread; returns when a reboot is requested
        teardown();
#if TARGET_OS_IPHONE
        if (kind == RT_REBOOT_TITLE && !given) { find_games(); root = pick_game(); }
#else
        (void)kind;
#endif
    }
}
