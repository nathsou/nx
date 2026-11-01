// In-game overlay menu (Dear ImGui). Open with F1 / Esc, or Minus+Plus (Back+Start) on a controller.
#pragma once
#include <stdbool.h>
#include <stdint.h>

#ifdef __OBJC__
#import <Metal/Metal.h>
#endif

#ifdef __cplusplus
extern "C" {
#endif

typedef union SDL_Event SDL_Event;

// Main (UI) thread: returns true if the event was consumed by the menu (the game must not see it).
bool menu_handle_event(const SDL_Event *e);
bool menu_is_open(void);
// Main thread: apply window requests (fullscreen) made from the menu.
void menu_apply_window_requests(void *sdl_window);
void touch_pad_update(bool menu_open);  // iOS: the on-screen controller shown or hidden (runtime/ui/touch_pad.mm)
bool touch_pad_shown(void);
// The game selection screen (main thread, before a game boots): the index of the game picked. covers: cache/<game>/
// cover.jpg (NULL / missing: a drawn card).
int menu_pick_game(int n, const char *const titles[], const char *const details[], const char *const covers[],
                   const bool playable[]);
// The loading screen, from a game's pick to its first frame (iOS): drawn by a thread of its own; status: what is
// being done (any thread, also without a loading screen); end: called before the renderer's first present.
void menu_loading_begin(const char *title, const char *cover);
void menu_loading_status(const char *status);
void menu_loading_end(void);
void renderer_request_cover(void);  // runtime/nvn/metal.m: the next game frame as the game's cover

#if defined(__APPLE__) && defined(__OBJC__)
// Render thread: draw the overlay into the drawable after the game image (no-op while closed).
void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target);
#elif !defined(__APPLE__)
// Render thread, inside the window image's rendering (Vulkan command buffer cmd).
void menu_render(void *cmd, uint32_t target_w, uint32_t target_h);
#endif

#ifdef __cplusplus
}
#endif
