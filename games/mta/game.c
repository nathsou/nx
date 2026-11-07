// Mario Tennis Aces's profile (runtime/game.h): no patches or hooks, one engine behaviour - the system font's stand-in
// is a Latin font (GAME_LATIN_SYSTEM_FONT).
#include "game.h"

static const GameVersion versions[] = {
#define GAME_ID(id, name)
#define GA_VERSION(key, label, build_id) {#key, label, build_id, NULL},
#include "profile.h"
#undef GAME_ID
#undef GA_VERSION
};

static const GameProfile mta = {
    .id = "mta",
    .name = "Mario Tennis Aces",
    .versions = versions,
    .nversions = sizeof versions / sizeof versions[0],
    .flags = GAME_LATIN_SYSTEM_FONT,
};
RT_GAME(mta);
