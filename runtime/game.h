// Which game is running, and what the engine knows about it.
//
// Any game boots without a profile: its title ID comes from exefs/main.npdm and the recompiled code from its own
// exefs. A profile (games/<id>/: profile.h, game.c, patches.py) adds what one game needs on top of the engine: its
// versions' address tables, hook handlers for the instructions its patches.py marks, and fixes run at boot. Profiles
// register themselves with RT_GAME; the one whose version table has the main program's build ID is selected.
#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#include "cpu.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct GameVersion {
    const char *key;       // "v1_0_0": the suffix of its address tables (games/<id>/patches_<key>.h, runtime_<key>.h)
    const char *label;     // "1.0.0"
    const char *build_id;  // the main program's build ID, 40 upper-case hex digits
    const void *addrs;     // the profile's own address struct for this version (games/<id>/game.c)
} GameVersion;

typedef struct GameProfile {
    const char *id;    // the folder under games/ ("dread")
    const char *name;  // "Metroid Dread"
    const GameVersion *versions;
    int nversions;
    // The hook sites of patches.py HOOKS (generated code calls rt_hook there): 0 runs the site's own instruction,
    // 1: the hook did it all, 2..: jump to the site's targets in order. NULL: no hooks.
    int (*hook)(Cpu *c, uint64_t site);
    // After the modules are loaded and relocated, before the main thread starts (HLE overrides, memory patches).
    void (*booted)(void);
    uint32_t flags;  // GAME_* below: engine behaviours a game opts into
} GameProfile;

// Render targets the size of the screen (16:9, scaled) start each frame cleared, and every target at a level change:
// stale pixels where the game never draws (Link's Awakening's interiors, Dread's room transitions). Games that keep
// such targets' contents from frame to frame (ACNH's lazy clears decide themselves) don't want it.
#define GAME_CLEAR_SCREEN_TARGETS 1u
// Presents aren't held to the window's present interval: the game steps its world by elapsed time and runs at the
// display's refresh rate (Dread: 120 fps on a 120 Hz Mac). Without it, a frame is shown no sooner than its interval
// of 60 Hz vsyncs after the last, as on the Switch: games that step per frame (ACNH, 30 fps: interval 2) play at speed.
#define GAME_UNCAPPED_FPS 2u
// The shared system font's stand-in (runtime/hle/pl.c, without the console's own fonts) is a Latin one - Arial, DejaVu
// Sans - not a Japanese gothic: Mario Tennis Aces's font engine finds no glyph for its fallback character in BIZ
// UDPGothic (Linux's default) and crashes at its first text.
#define GAME_LATIN_SYSTEM_FONT 4u
static inline bool game_flag(uint32_t f);

typedef struct GameInfo {
    char key[64];                  // the profile's id, or "title-<title ID>" for a game without one
    char name[128];                // the profile's name, or the key
    uint64_t title_id;             // from exefs/main.npdm (0 when it has none)
    uint8_t build_id[20];          // exefs/main's
    const GameProfile *profile;    // NULL: no profile
    const GameVersion *version;    // NULL: no profile, or a version the profile doesn't list
} GameInfo;

extern GameInfo g_game;  // the running game (game_select)
static inline bool game_flag(uint32_t f) { return g_game.profile && (g_game.profile->flags & f); }

// Identifies the game files in game_dir (exefs/main, exefs/main.npdm). false: why says what's wrong.
bool game_identify(const char *game_dir, GameInfo *out, char *why, size_t why_size);
// Identifies them and makes them the running game (g_game), logging what was found.
bool game_select(const char *game_dir, char *why, size_t why_size);
// The selected version's address struct (the profile's own type), or NULL.
static inline const void *game_addrs(void) { return g_game.version ? g_game.version->addrs : NULL; }

// RT_GAME(profile): registers a GameProfile (games/<id>/game.c).
#define RT_GAME_CAT2(a, b) a##b
#define RT_GAME_CAT(a, b) RT_GAME_CAT2(a, b)
#ifdef __APPLE__
#define RT_GAME_SECTION "__DATA,__rt_games"
#elif defined(__linux__)
#define RT_GAME_SECTION "rt_games"
#else
#define RT_GAME_SECTION ".gam$m"  // between the .gam$a / .gam$z markers in runtime/game.c
#endif
#define RT_GAME(profile)                                                                    \
    __attribute__((used, section(RT_GAME_SECTION))) static const GameProfile *const         \
        RT_GAME_CAT(rt_game_entry_, __LINE__) = &(profile)

// For games/<id>/game.c, with its address tables (GA_ADDR(name, value) lines): GA_ADDR as GAME_ADDR_FIELD builds the
// profile's address struct, as GAME_ADDR_INIT one version's constant. Every version's tables list the same names.
#define GAME_ADDR_FIELD(name, value) uint64_t name;
#define GAME_ADDR_INIT(name, value) .name = UINT64_C(value),

#ifdef __cplusplus
}
#endif
