// Loads the recompiled game code library (runtime/gamelib.h).
#include "gamelib.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <dlfcn.h>
#endif

#include "paths.h"
#include "rt.h"

static const GameLibTables *g_tables;
static char g_error[256];
static char g_tables_dir[1100];  // (the game_dir g_tables is for)

// The library's id file (<library>.id, written next to it by the build): its id (gamelib_full_id), read without
// loading it.
static bool id_matches(const char *lib, const char *want) {
    char path[1100], id[128] = {0};
    snprintf(path, sizeof path, "%s.id", lib);
    FILE *f = fopen(path, "rb");
    if (!f) return false;
    size_t n = fread(id, 1, sizeof id - 1, f);
    fclose(f);
    while (n && (id[n - 1] == '\n' || id[n - 1] == '\r')) id[--n] = 0;
    return !strcmp(id, want);
}

static bool exists(const char *p) {
    FILE *f = fopen(p, "rb");
    if (f) fclose(f);
    return f != NULL;
}

// The places to look, in order (gamelib.h). Returns how many were filled.
#define MAX_CANDIDATES 32
static int candidates(const char *game_dir, char out[MAX_CANDIDATES][1100]) {
    int n = 0;
    const char *env = getenv("LARECOMP_GAME_LIB");
    if (env && *env) snprintf(out[n++], 1100, "%s", env);
    char exe[1024];
    if (plat_exe_path(exe, sizeof exe)) {
        char *slash = strrchr(exe, '/');
#ifdef _WIN32
        char *bs = strrchr(exe, '\\');
        if (bs > slash) slash = bs;
#endif
        if (slash) *slash = 0;
        snprintf(out[n++], 1100, "%s/%s", exe, GAMELIB_NAME);
#ifndef _WIN32
        DIR *d = opendir(exe);  // build/<game>/game.<ext>: every game built in this checkout
        for (struct dirent *e; d && (e = readdir(d)) && n < MAX_CANDIDATES - 1;) {
            if (e->d_name[0] == '.') continue;
            snprintf(out[n], 1100, "%s/%s/%s", exe, e->d_name, GAMELIB_NAME);
            if (exists(out[n])) n++;
        }
        if (d) closedir(d);
#ifdef __APPLE__  // (the iOS app: Frameworks/<game>/game.dylib, one per game it holds)
        char fw[1100];
        snprintf(fw, sizeof fw, "%s/Frameworks", exe);
        d = opendir(fw);
        for (struct dirent *e; d && (e = readdir(d)) && n < MAX_CANDIDATES - 1;) {
            if (e->d_name[0] == '.') continue;
            snprintf(out[n], 1100, "%s/%s/%s", fw, e->d_name, GAMELIB_NAME);
            if (exists(out[n])) n++;
        }
        if (d) closedir(d);
#endif
#endif
    }
    if (game_dir && n < MAX_CANDIDATES) snprintf(out[n++], 1100, "%s/%s", game_dir, GAMELIB_NAME);
    return n;
}

bool gamelib_present(const char *game_dir) {
    if (g_tables && game_dir && !strcmp(game_dir, g_tables_dir)) return true;
    char want[GAMELIB_FULL_ID_SIZE];
    if (!game_dir || !gamelib_full_id(game_dir, want, sizeof want)) return false;
    char c[MAX_CANDIDATES][1100];
    int n = candidates(game_dir, c);
    for (int i = 0; i < n; i++)
        if (exists(c[i]) && id_matches(c[i], want)) return true;
    return false;
}

static const GameLibTables *open_lib(const char *path, const char *want) {
#ifdef _WIN32
    HMODULE h = LoadLibraryA(path);
    if (!h) { snprintf(g_error, sizeof g_error, "can't load %s (error %lu)", path, GetLastError()); return NULL; }
    GameLibEntry entry = (GameLibEntry)(void *)GetProcAddress(h, GAMELIB_ENTRY);
#else
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) { snprintf(g_error, sizeof g_error, "%s", dlerror()); return NULL; }
    GameLibEntry entry = (GameLibEntry)dlsym(h, GAMELIB_ENTRY);
#endif
    if (!entry) { snprintf(g_error, sizeof g_error, "%s: not game code", path); return NULL; }
    const GameLibTables *t = entry();
    if (!t || t->abi != GAMELIB_ABI || !t->id || strcmp(t->id, want)) {
        snprintf(g_error, sizeof g_error, "%s was built for another version", path);
        return NULL;  // (left loaded: nothing of it runs)
    }
    return t;
}

bool gamelib_load(const char *game_dir, char *why, size_t why_size) {
    static bool tried;
    if (tried && game_dir && strcmp(game_dir, g_tables_dir)) tried = false, g_tables = NULL;  // (another game: its own
                                                                                               //  library; the old stays loaded)
    if (!tried) {
        tried = true;
        snprintf(g_tables_dir, sizeof g_tables_dir, "%s", game_dir ? game_dir : "");
        snprintf(g_error, sizeof g_error, "the game code for these game files hasn't been built (make gen GAME=<name> && make GAME=<name>)");
        char want[GAMELIB_FULL_ID_SIZE] = "";
        if (!game_dir || !gamelib_full_id(game_dir, want, sizeof want)) {
            snprintf(g_error, sizeof g_error, "the game files' exefs/main is missing or unreadable");
            if (why) snprintf(why, why_size, "%s", g_error);
            return false;
        }
        char c[MAX_CANDIDATES][1100];
        int n = candidates(game_dir, c);
        const char *env = getenv("LARECOMP_GAME_LIB");
        for (int i = 0; i < n && !g_tables; i++) {
            if (!exists(c[i])) continue;
            bool given = i == 0 && env && *env;  // LARECOMP_GAME_LIB: loaded as given, the library's own id decides
            if (!given && !id_matches(c[i], want)) {
                snprintf(g_error, sizeof g_error, "%s was built for another version", c[i]);
                continue;
            }
            g_tables = open_lib(c[i], want);
            if (g_tables) {
                uint64_t fns = 0;
                for (uint32_t k = 0; k < g_tables->nmodules; k++) fns += *g_tables->modules[k].count;
                LOG("[gamelib] %s (%u modules, %llu functions)\n", c[i], g_tables->nmodules, (unsigned long long)fns);
            }
        }
    }
    if (!g_tables && why) snprintf(why, why_size, "%s", g_error);
    return g_tables != NULL;
}

const GameLibTables *gamelib_tables(void) { return g_tables; }
