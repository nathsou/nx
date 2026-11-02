// In-game menu (Dear ImGui over the game image): F1 or Esc, Home or Minus + Plus together on a controller. The game pauses
// under it (Game tab: its frame loop waits in nvnQueuePresentTexture, runtime/nvn/objects.c, the window showing its
// last frame) and its sound is muted. Tabs: the game (resume, restart, quit), saves (backups under save/<game>/backups,
// restored by restarting the game), the game's date and time, video, audio, controls. Settings go to nx.ini at once.
// The menu is built and drawn on the render thread (menu_render, after the game image), input reaches it from the
// window's event loop on the main thread (menu_handle_event): one lock between the two.
// iOS / iPadOS (MENU_TOUCH): the menu button at the top of the screen opens it; a tap presses, a drag up or down
// scrolls, a drag sideways moves a slider; sized in points for fingers, inside the screen's safe area. The button shows
// while the screen is touched (and a few seconds after). With several games in the app, a selection screen comes
// first (menu_pick_game) and the Game tab can go back to it.
#include "menu.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#define MENU_TOUCH 1
#else
#import <Cocoa/Cocoa.h>
#define MENU_TOUCH 0
#endif
#define HAVE_METALFX (!TARGET_OS_SIMULATOR)  // (the iOS Simulator has no MetalFX: renderer bilinear / optical flow)
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <ImageIO/ImageIO.h>
#include <pthread.h>
#include <SDL3/SDL.h>

#include <sys/stat.h>
#include <unistd.h>

#include <algorithm>
#include <cfloat>
#include <cmath>
#include <atomic>
#include <ctime>
#include <filesystem>
#include <mutex>
#include <string>
#include <system_error>
#include <vector>

#include "imgui.h"
#include "backends/imgui_impl_metal.h"

extern "C" {
#include "../settings.h"
}
#include "cloud.h"
#include "s3.h"

namespace fs = std::filesystem;

#define DREADRECOMP_VERSION "0.0.1-dev"

extern "C" {
extern const char *g_save_dir;  // runtime/services/fs.c: save/<game>
void rt_request_reboot(int kind);
int rt_reboot_requested(void);
void input_reset(void);
void input_touch_tap(bool plus);       // runtime/hle/input.c
int64_t time_game_now(void);           // runtime/services/time.c
void time_offset_changed(void);
void renderer_frame_counts(uint64_t *game, uint64_t *shown);  // runtime/nvn/metal.m
const char *menu_game_name(void);      // runtime/game.c
}
enum { REBOOT_GAME = 1, REBOOT_TITLE = 2 };  // (rt.h RT_REBOOT_*: TITLE - the game selection screen on iOS)

static std::atomic<bool> g_want_fullscreen_apply{true};
static std::atomic<bool> g_open{false};
static std::atomic<bool> g_text_input{false};  // SDL text events wanted (a text field has focus): the main thread starts them
static std::atomic<bool> g_popup{false};       // a confirmation is up: Esc closes it, not the menu
static std::recursive_mutex g_mx;              // ImGui's context: built on the render thread, fed on the main thread
static float g_density = 1;                    // window pixels per point (main thread: mouse positions are in points)
static bool g_pad_back, g_pad_start;           // (Minus + Plus held together: the menu)
#if MENU_TOUCH
// (main thread) the window in pixels, its safe area (clear of the notch / Dynamic Island / home bar), the finger the
// menu follows; (render thread -> main) where the menu button is and the font's size, in pixels
static int g_win_w = 1, g_win_h = 1;
static std::atomic<float> g_safe[4] = {0, 0, 0, 0};  // x, y, w, h (pixels; w = 0: the whole window)
static std::atomic<float> g_button[4] = {0, 0, 0, 0};  // (the menu's; Minus / Plus left / right of it, as wide, when
static std::atomic<float> g_button_gap{0};              //  the on-screen controller is up: g_button_gap apart)
static std::atomic<bool> g_pad_buttons{false};
static std::atomic<float> g_font_px{17};
static struct { SDL_FingerID id; bool down, pressed, scrolling; float x0, y0, x, y; } g_touch;
// (main -> render thread) the menu button: shown while a finger is on the screen and BUTTON_SHOW seconds after
#define BUTTON_SHOW 5.0
#define BUTTON_FADE 0.4
static std::atomic<int> g_fingers{0};
static std::atomic<double> g_last_touch{-100};
static double button_visibility(void) {  // 1 shown, 0 hidden, between: fading out
    if (g_fingers > 0) return 1;
    double t = CACurrentMediaTime() - g_last_touch;
    return t < BUTTON_SHOW ? 1 : t > BUTTON_SHOW + BUTTON_FADE ? 0 : 1 - (t - BUTTON_SHOW) / BUTTON_FADE;
}
extern "C" int g_game_count;  // runtime/main.c: games in the app's Documents
#endif
// The loading screen (menu_loading_begin, drawn by its own thread until the game's first frame)
static std::atomic<bool> g_loading{false}, g_loading_stop{false};
// The game selection screen (menu_pick_game, main thread): its games, and the one picked
static bool g_picking;
static int g_pick_n, g_picked = -1;
static const char *const *g_pick_titles, *const *g_pick_details;
static const bool *g_pick_playable;
extern "C" void *ui_metal_layer(void);
extern "C" void *ui_metal_device(void);
extern "C" SDL_Window *ui_window(void);
extern "C" void input_handle_event(const SDL_Event *e);

extern "C" {

const char *larecomp_version(void) { return DREADRECOMP_VERSION; }

bool menu_is_open(void) { return g_open; }
bool menu_input_captured(void) { return g_open; }
bool menu_pauses_game(void) { return g_open && g_settings.menu_pause && !rt_reboot_requested(); }

static void set_open(bool on) {
    if (g_open == on) return;
    g_open = on;
    if (on) renderer_request_cover();  // (the game's picture for the selection screen: its next frame, once resumed)
    if (on) cloud_flush();  // (a pause: the save uploaded now if it changed - runtime/ui/cloud.mm)
    input_reset();  // (keys held when it opened don't stay pressed for the game)
}
void menu_test_open(void) { set_open(true); }

// Name entry (runtime/hle/swkbd.c): no on-screen keyboard - the game gets its initial text back. (Animal Crossing has
// its own and reads the keyboard: runtime/hle/input.c)
int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    (void)max_len;
    snprintf(out, cap, "%s", initial ? initial : "");
    return 1;
}

}  // extern "C"

// ------------------------------------------------------------------ input (main thread)
static ImGuiKey imgui_key(SDL_Keycode k) {
    switch (k) {
    case SDLK_TAB: return ImGuiKey_Tab;
    case SDLK_LEFT: return ImGuiKey_LeftArrow;
    case SDLK_RIGHT: return ImGuiKey_RightArrow;
    case SDLK_UP: return ImGuiKey_UpArrow;
    case SDLK_DOWN: return ImGuiKey_DownArrow;
    case SDLK_PAGEUP: return ImGuiKey_PageUp;
    case SDLK_PAGEDOWN: return ImGuiKey_PageDown;
    case SDLK_HOME: return ImGuiKey_Home;
    case SDLK_END: return ImGuiKey_End;
    case SDLK_DELETE: return ImGuiKey_Delete;
    case SDLK_BACKSPACE: return ImGuiKey_Backspace;
    case SDLK_SPACE: return ImGuiKey_Space;
    case SDLK_RETURN: return ImGuiKey_Enter;
    case SDLK_KP_ENTER: return ImGuiKey_KeypadEnter;
    case SDLK_ESCAPE: return ImGuiKey_Escape;
    case SDLK_LCTRL: return ImGuiKey_LeftCtrl;
    case SDLK_RCTRL: return ImGuiKey_RightCtrl;
    case SDLK_LSHIFT: return ImGuiKey_LeftShift;
    case SDLK_RSHIFT: return ImGuiKey_RightShift;
    case SDLK_LALT: return ImGuiKey_LeftAlt;
    case SDLK_RALT: return ImGuiKey_RightAlt;
    case SDLK_LGUI: return ImGuiKey_LeftSuper;
    case SDLK_RGUI: return ImGuiKey_RightSuper;
    case SDLK_A: return ImGuiKey_A;
    case SDLK_C: return ImGuiKey_C;
    case SDLK_V: return ImGuiKey_V;
    case SDLK_X: return ImGuiKey_X;
    case SDLK_Z: return ImGuiKey_Z;
    default: return ImGuiKey_None;
    }
}

// The controller's buttons for ImGui's navigation: confirm on the right (A, as the game) or at the bottom (the
// controller's own convention: Settings > menu_confirm)
static ImGuiKey imgui_pad(int b) {
    bool nintendo = g_settings.menu_confirm == MENU_CONFIRM_GAME;
    switch (b) {
    case SDL_GAMEPAD_BUTTON_SOUTH: return nintendo ? ImGuiKey_GamepadFaceRight : ImGuiKey_GamepadFaceDown;
    case SDL_GAMEPAD_BUTTON_EAST: return nintendo ? ImGuiKey_GamepadFaceDown : ImGuiKey_GamepadFaceRight;
    case SDL_GAMEPAD_BUTTON_WEST: return ImGuiKey_GamepadFaceLeft;
    case SDL_GAMEPAD_BUTTON_NORTH: return ImGuiKey_GamepadFaceUp;
    case SDL_GAMEPAD_BUTTON_DPAD_UP: return ImGuiKey_GamepadDpadUp;
    case SDL_GAMEPAD_BUTTON_DPAD_DOWN: return ImGuiKey_GamepadDpadDown;
    case SDL_GAMEPAD_BUTTON_DPAD_LEFT: return ImGuiKey_GamepadDpadLeft;
    case SDL_GAMEPAD_BUTTON_DPAD_RIGHT: return ImGuiKey_GamepadDpadRight;
    case SDL_GAMEPAD_BUTTON_LEFT_SHOULDER: return ImGuiKey_GamepadL1;
    case SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER: return ImGuiKey_GamepadR1;
    default: return ImGuiKey_None;
    }
}

static void ensure_context(void) {
    if (ImGui::GetCurrentContext()) return;
    ImGui::CreateContext();
    ImGuiIO &io = ImGui::GetIO();
    io.IniFilename = NULL;
    io.ConfigFlags |= ImGuiConfigFlags_NavEnableKeyboard | ImGuiConfigFlags_NavEnableGamepad;
    io.BackendFlags |= ImGuiBackendFlags_HasGamepad;
}

extern "C" bool menu_handle_event(const SDL_Event *e) {
    if (e->type == SDL_EVENT_KEY_DOWN && e->key.key == SDLK_F11 && !e->key.repeat) {
        g_settings.fullscreen = !g_settings.fullscreen;
        settings_save();
        g_want_fullscreen_apply = true;
        return true;
    }
    bool open = g_open || g_picking;
    if (!g_picking && e->type == SDL_EVENT_KEY_DOWN && !e->key.repeat &&
        (e->key.key == SDLK_F1 || (e->key.key == SDLK_ESCAPE && !(open && (g_popup || g_text_input))))) {
        set_open(!open);
        return true;
    }
    if (!g_picking && (e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN || e->type == SDL_EVENT_GAMEPAD_BUTTON_UP)) {
        bool down = e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_GUIDE) {  // Home (a Switch Pro controller's, an Xbox / PlayStation logo)
            if (down && !g_popup) set_open(!open);
            return true;
        }
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_BACK) g_pad_back = down;
        if (e->gbutton.button == SDL_GAMEPAD_BUTTON_START) g_pad_start = down;
        if (down && g_pad_back && g_pad_start) { set_open(!open); return true; }
        if (open && down && e->gbutton.button == SDL_GAMEPAD_BUTTON_START && !g_popup) { set_open(false); return true; }
    }
#if MENU_TOUCH
    if (e->type == SDL_EVENT_FINGER_DOWN || e->type == SDL_EVENT_FINGER_MOTION || e->type == SDL_EVENT_FINGER_UP ||
        e->type == SDL_EVENT_FINGER_CANCELED) {
        float x = e->tfinger.x * g_win_w, y = e->tfinger.y * g_win_h;
        static int log_touch = -1;  // LARECOMP_LOG_TOUCH=1: every finger event
        if (log_touch < 0) log_touch = getenv("LARECOMP_LOG_TOUCH") != NULL;
        if (log_touch)
            fprintf(stderr, "[menu] finger %#x %llx at %.0f,%.0f (window %dx%d, button %.0f,%.0f-%.0f,%.0f)\n", e->type,
                    (unsigned long long)e->tfinger.fingerID, x, y, g_win_w, g_win_h, (float)g_button[0], (float)g_button[1],
                    (float)g_button[2], (float)g_button[3]);
        bool shown = button_visibility() > 0.5;  // (before this touch: a touch on a hidden button only shows it)
        if (e->type == SDL_EVENT_FINGER_DOWN) g_fingers++;
        if ((e->type == SDL_EVENT_FINGER_UP || e->type == SDL_EVENT_FINGER_CANCELED) && g_fingers > 0) g_fingers--;
        g_last_touch = CACurrentMediaTime();
        if (!open) {  // (the game takes no touches: only the menu button's, and Minus / Plus beside it)
            float pad = g_font_px * 0.5f, w = g_button[2] - g_button[0], step = w + g_button_gap;
            if (e->type != SDL_EVENT_FINGER_DOWN || y < g_button[1] - pad || y > g_button[3] + pad) return true;
            if (x >= g_button[0] - pad && x <= g_button[2] + pad) { if (shown) set_open(true); }
            else if (g_pad_buttons && x >= g_button[0] - step - pad && x < g_button[0] - pad) input_touch_tap(false);
            else if (g_pad_buttons && x > g_button[2] + pad && x <= g_button[2] + step + pad) input_touch_tap(true);
            return true;
        }
        std::lock_guard<std::recursive_mutex> lk(g_mx);
        ensure_context();
        ImGuiIO &io = ImGui::GetIO();
        float slop = g_font_px * 0.6f;
        if (e->type == SDL_EVENT_FINGER_DOWN) {  // (one finger at a time: the first)
            if (g_touch.down) return true;
            g_touch = {e->tfinger.fingerID, true, false, false, x, y, x, y};
            io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
            io.AddMousePosEvent(x, y);
            return true;
        }
        if (!g_touch.down || e->tfinger.fingerID != g_touch.id) return true;
        if (e->type == SDL_EVENT_FINGER_MOTION) {
            float dx = x - g_touch.x0, dy = y - g_touch.y0;
            if (!g_touch.pressed && !g_touch.scrolling) {
                if (fabsf(dy) > slop && fabsf(dy) >= fabsf(dx)) g_touch.scrolling = true;  // up / down: scrolls
                else if (fabsf(dx) > slop) {  // sideways: a press that follows the finger (sliders)
                    g_touch.pressed = true;
                    io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
                    io.AddMousePosEvent(g_touch.x0, g_touch.y0);
                    io.AddMouseButtonEvent(0, true);
                }
            }
            io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
            if (g_touch.scrolling) io.AddMouseWheelEvent(0, (y - g_touch.y) / (5 * g_font_px));  // (ImGui: 5 lines a notch)
            else if (g_touch.pressed) io.AddMousePosEvent(x, y);
            g_touch.x = x, g_touch.y = y;
            return true;
        }
        io.AddMouseSourceEvent(ImGuiMouseSource_TouchScreen);
        if (e->type == SDL_EVENT_FINGER_UP && !g_touch.pressed && !g_touch.scrolling) {  // a tap: a click where it began
            io.AddMousePosEvent(g_touch.x0, g_touch.y0);
            io.AddMouseButtonEvent(0, true);
            io.AddMouseButtonEvent(0, false);
        } else if (g_touch.pressed) io.AddMouseButtonEvent(0, false);
        io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);  // (no finger: nothing hovered)
        g_touch.down = false;
        return true;
    }
#endif
    if (!open) return false;
    std::lock_guard<std::recursive_mutex> lk(g_mx);
    ensure_context();
    ImGuiIO &io = ImGui::GetIO();
    switch (e->type) {
    case SDL_EVENT_MOUSE_MOTION:
        io.AddMousePosEvent(e->motion.x * g_density, e->motion.y * g_density);
        return true;
    case SDL_EVENT_MOUSE_BUTTON_DOWN: case SDL_EVENT_MOUSE_BUTTON_UP: {
        int b = e->button.button == SDL_BUTTON_LEFT ? 0 : e->button.button == SDL_BUTTON_RIGHT ? 1 : e->button.button == SDL_BUTTON_MIDDLE ? 2 : -1;
        if (b >= 0) io.AddMouseButtonEvent(b, e->type == SDL_EVENT_MOUSE_BUTTON_DOWN);
        return true;
    }
    case SDL_EVENT_MOUSE_WHEEL: io.AddMouseWheelEvent(e->wheel.x, e->wheel.y); return true;
    case SDL_EVENT_KEY_DOWN: case SDL_EVENT_KEY_UP: {
        bool down = e->type == SDL_EVENT_KEY_DOWN;
        io.AddKeyEvent(ImGuiMod_Ctrl, (e->key.mod & SDL_KMOD_CTRL) != 0);
        io.AddKeyEvent(ImGuiMod_Shift, (e->key.mod & SDL_KMOD_SHIFT) != 0);
        io.AddKeyEvent(ImGuiMod_Alt, (e->key.mod & SDL_KMOD_ALT) != 0);
        io.AddKeyEvent(ImGuiMod_Super, (e->key.mod & SDL_KMOD_GUI) != 0);
        ImGuiKey k = imgui_key(e->key.key);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, down);
        return true;
    }
    case SDL_EVENT_TEXT_INPUT: io.AddInputCharactersUTF8(e->text.text); return true;
    case SDL_EVENT_GAMEPAD_BUTTON_DOWN: case SDL_EVENT_GAMEPAD_BUTTON_UP: {
        ImGuiKey k = imgui_pad(e->gbutton.button);
        if (k != ImGuiKey_None) io.AddKeyEvent(k, e->type == SDL_EVENT_GAMEPAD_BUTTON_DOWN);
        return true;
    }
    case SDL_EVENT_GAMEPAD_AXIS_MOTION: {
        float v = e->gaxis.value / 32767.0f, dead = 0.35f;
        float on = v > dead ? (v - dead) / (1 - dead) : v < -dead ? (-v - dead) / (1 - dead) : 0;
        if (e->gaxis.axis == SDL_GAMEPAD_AXIS_LEFTX) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickLeft, v < -dead, v < -dead ? on : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickRight, v > dead, v > dead ? on : 0);
        } else if (e->gaxis.axis == SDL_GAMEPAD_AXIS_LEFTY) {
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickUp, v < -dead, v < -dead ? on : 0);
            io.AddKeyAnalogEvent(ImGuiKey_GamepadLStickDown, v > dead, v > dead ? on : 0);
        }
        return true;
    }
    default: return false;
    }
}

extern "C" uint32_t g_window_resize_request;  // (runtime/hle/input.c: test scripts' "resize")
extern "C" void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
    if (g_want_fullscreen_apply.exchange(false)) SDL_SetWindowFullscreen(w, g_settings.fullscreen);
    if (uint32_t r = __atomic_exchange_n(&g_window_resize_request, 0u, __ATOMIC_RELAXED))
        SDL_SetWindowSize(w, (int)(r >> 16), (int)(r & 0xffff));
    float d = SDL_GetWindowPixelDensity(w);
    if (d > 0) g_density = d;
#if MENU_TOUCH
    touch_pad_update(g_open || g_picking || g_loading);
    g_pad_buttons = touch_pad_shown();
    SDL_GetWindowSizeInPixels(w, &g_win_w, &g_win_h);
    SDL_Rect sa;
    if (SDL_GetWindowSafeArea(w, &sa)) {  // (points)
        float k = g_density;
        g_safe[0] = sa.x * k, g_safe[1] = sa.y * k, g_safe[2] = sa.w * k, g_safe[3] = sa.h * k;
    }
#endif
    bool text = g_open && g_text_input;  // (SDL sends typed text only between Start / StopTextInput)
    if (text != SDL_TextInputActive(w)) {
        if (text) SDL_StartTextInput(w);
        else SDL_StopTextInput(w);
    }
}

// ------------------------------------------------------------------ saves
// The game's saves are the folders of save/<game>/ (one per save data mount: Animal Crossing's save_0, ...), written
// when the game commits. A backup copies them to save/<game>/backups/<name>/; restoring one copies it back while the
// game is down: the restart's reset (menu_reset, below) does it, after the game's threads stopped, before it boots.
struct Backup { std::string name; fs::path path; time_t when; uintmax_t bytes; };
static std::vector<Backup> g_backups;
static double g_backups_listed = -1;
static std::string g_status;     // the last save action's outcome, shown under the buttons
static fs::path g_restore_from, g_restore_root;  // (render thread -> reset: the root as it was - the save service's own
                                                  // reset sets it back to "save" first)

static fs::path save_root(void) { return fs::path(g_save_dir ? g_save_dir : "save"); }
static bool is_mount(const fs::directory_entry &d) {
    std::string n = d.path().filename().string();
    return d.is_directory() && n != "backups" && n != "album" && n[0] != '.';
}
static uintmax_t dir_bytes(const fs::path &p, time_t *newest) {
    uintmax_t n = 0;
    std::error_code ec;
    for (auto it = fs::recursive_directory_iterator(p, ec); !ec && it != fs::recursive_directory_iterator(); it.increment(ec)) {
        if (!it->is_regular_file(ec)) continue;
        n += it->file_size(ec);
        if (newest) {
            struct stat st;
            if (!stat(it->path().c_str(), &st) && st.st_mtime > *newest) *newest = st.st_mtime;
        }
    }
    return n;
}
static std::string human_bytes(uintmax_t b) {
    char s[32];
    if (b >= 1u << 20) snprintf(s, sizeof s, "%.1f MB", b / 1048576.0);
    else snprintf(s, sizeof s, "%.0f KB", b / 1024.0);
    return s;
}
static std::string format_time(time_t t, const char *fmt = "%a %d %b %Y, %H:%M") {
    char s[64];
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(s, sizeof s, fmt, &tm);
    return s;
}
static void list_backups(void) {
    g_backups.clear();
    std::error_code ec;
    for (auto &d : fs::directory_iterator(save_root() / "backups", ec)) {
        if (!d.is_directory()) continue;
        Backup b{d.path().filename().string(), d.path(), 0, 0};
        b.bytes = dir_bytes(d.path(), &b.when);
        struct stat st;
        if (!stat(d.path().c_str(), &st)) b.when = st.st_mtime;
        g_backups.push_back(b);
    }
    std::sort(g_backups.begin(), g_backups.end(), [](const Backup &a, const Backup &b) { return a.when > b.when; });
}
// Copies the save's folders to backups/<date>[ - label]: the empty string when it worked, else what went wrong
static std::string back_up(const std::string &label, fs::path *made = nullptr, fs::path root = save_root()) {
    std::string name = format_time(time(NULL), "%Y-%m-%d %H-%M-%S");
    std::string l;
    for (char ch : label) if (ch != '/' && ch != ':' && ch != '\\' && (unsigned char)ch >= 32) l += ch;
    if (!l.empty()) name += " - " + l;
    fs::path dst = root / "backups" / name;
    std::error_code ec;
    fs::create_directories(dst, ec);
    if (ec) return "could not create " + dst.string() + ": " + ec.message();
    int n = 0;
    for (auto &d : fs::directory_iterator(root, ec)) {
        if (!is_mount(d)) continue;
        fs::copy(d.path(), dst / d.path().filename(), fs::copy_options::recursive, ec);
        if (ec) return "could not copy " + d.path().string() + ": " + ec.message();
        n++;
    }
    if (!n) { fs::remove_all(dst, ec); return "there is no save to back up yet"; }
    if (made) *made = dst;
    return "";
}
std::string saves_back_up(const std::string &label, fs::path *made, fs::path root) { return back_up(label, made, root); }

typedef void (*ResetFn)(void);
static void menu_reset(void) {  // (runtime/main.c's reboot: every guest thread has stopped)
    cloud_teardown();  // (the save as the game left it, before a restore replaces it)
    if (g_restore_from.empty()) return;
    fs::path from = g_restore_from, root = g_restore_root;
    g_restore_from.clear();
    std::string err = back_up("before restoring " + from.filename().string(), nullptr, root);
    if (!err.empty()) fprintf(stderr, "[saves] backup before restoring: %s\n", err.c_str());
    std::error_code ec;
    for (auto &d : fs::directory_iterator(from, ec)) {
        if (!d.is_directory()) continue;
        fs::path to = root / d.path().filename();
        fs::remove_all(to, ec);
        fs::copy(d.path(), to, fs::copy_options::recursive, ec);
        fprintf(stderr, "[saves] restored %s from %s%s\n", to.c_str(), from.c_str(), ec ? (" - failed: " + ec.message()).c_str() : "");
    }
    cloud_restored(root, from);
    g_backups_listed = -1;
}
__attribute__((used, section("__DATA,__rt_reset"))) static const ResetFn menu_reset_entry = menu_reset;

// ------------------------------------------------------------------ drawing (render thread)
// The look: a panel over the dimmed game - pages listed down the left, each setting a row (its name and help on the
// left, its control on the right) in rounded cards; switches for on / off, segmented buttons for short lists.
static bool g_inited;
static float g_scale;  // the UI's size: the window's height over 900 points' worth (iOS: points, for fingers)
static ImFont *g_bold, *g_title, *g_small;
static id<MTLDevice> g_dev;
static const ImVec4 C_ACCENT(0.40f, 0.84f, 0.64f, 1), C_PANEL(0.075f, 0.082f, 0.100f, 0.985f), C_SIDE(0.055f, 0.060f, 0.074f, 1);
static const ImVec4 C_CARD(0.115f, 0.125f, 0.150f, 1), C_TEXT(0.93f, 0.95f, 0.97f, 1), C_MUTED(0.60f, 0.64f, 0.69f, 1);
static const ImVec4 C_CONTROL(0.20f, 0.215f, 0.25f, 1), C_ON_ACCENT(0.04f, 0.10f, 0.07f, 1);
static ImU32 col(ImVec4 c, float a = -1) { if (a >= 0) c.w = a; return ImGui::ColorConvertFloat4ToU32(c); }

static void setup_style(float scale) {
    ImGuiStyle &st = ImGui::GetStyle();
    st = ImGuiStyle();
    ImGui::StyleColorsDark();
    st.WindowRounding = 16, st.ChildRounding = 12, st.FrameRounding = 9, st.GrabRounding = 9, st.PopupRounding = 12;
    st.TabRounding = 8, st.ScrollbarRounding = 9;
    st.WindowPadding = ImVec2(20, 16), st.FramePadding = ImVec2(12, 7), st.ItemSpacing = ImVec2(10, 9);
    st.ItemInnerSpacing = ImVec2(8, 6), st.WindowBorderSize = 0, st.PopupBorderSize = 0, st.ChildBorderSize = 0;
    st.ScrollbarSize = 12, st.GrabMinSize = 18;
#if MENU_TOUCH  // (fingers: taller rows and scroll bars, a margin around what can be touched)
    st.FramePadding = ImVec2(14, 11), st.ItemSpacing = ImVec2(12, 11), st.ItemInnerSpacing = ImVec2(10, 6);
    st.ScrollbarSize = 18, st.GrabMinSize = 26, st.TouchExtraPadding = ImVec2(4, 4);
#endif
    ImVec4 *c = st.Colors;
    c[ImGuiCol_Text] = C_TEXT;
    c[ImGuiCol_TextDisabled] = C_MUTED;
    c[ImGuiCol_WindowBg] = C_PANEL;
    c[ImGuiCol_ChildBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_PopupBg] = ImVec4(0.11f, 0.12f, 0.145f, 0.99f);
    c[ImGuiCol_ModalWindowDimBg] = ImVec4(0, 0, 0, 0.55f);
    c[ImGuiCol_FrameBg] = C_CONTROL;
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.25f, 0.27f, 0.31f, 1);
    c[ImGuiCol_FrameBgActive] = ImVec4(0.28f, 0.30f, 0.35f, 1);
    c[ImGuiCol_Button] = C_CONTROL;
    c[ImGuiCol_ButtonHovered] = ImVec4(0.25f, 0.27f, 0.31f, 1);
    c[ImGuiCol_ButtonActive] = ImVec4(0.29f, 0.31f, 0.36f, 1);
    c[ImGuiCol_Header] = ImVec4(C_ACCENT.x, C_ACCENT.y, C_ACCENT.z, 0.22f);
    c[ImGuiCol_HeaderHovered] = ImVec4(C_ACCENT.x, C_ACCENT.y, C_ACCENT.z, 0.30f);
    c[ImGuiCol_HeaderActive] = ImVec4(C_ACCENT.x, C_ACCENT.y, C_ACCENT.z, 0.40f);
    c[ImGuiCol_CheckMark] = C_ACCENT;
    c[ImGuiCol_SliderGrab] = C_ACCENT;
    c[ImGuiCol_SliderGrabActive] = ImVec4(0.55f, 0.92f, 0.75f, 1);
    c[ImGuiCol_NavCursor] = C_ACCENT;
    c[ImGuiCol_Separator] = ImVec4(1, 1, 1, 0.07f);
    c[ImGuiCol_ScrollbarBg] = ImVec4(0, 0, 0, 0);
    c[ImGuiCol_ScrollbarGrab] = ImVec4(1, 1, 1, 0.14f);
    c[ImGuiCol_ScrollbarGrabHovered] = ImVec4(1, 1, 1, 0.22f);
    c[ImGuiCol_ScrollbarGrabActive] = ImVec4(1, 1, 1, 0.30f);
    c[ImGuiCol_TextSelectedBg] = ImVec4(C_ACCENT.x, C_ACCENT.y, C_ACCENT.z, 0.35f);
    st.ScaleAllSizes(scale);
}
static const char *font_path(const char *file) {
    static char p[4][1024];
    static int k;
    char *out = p[k++ & 3];
    snprintf(out, 1024, "third_party/fonts/DejaVu/%s", file);
    if (access(out, R_OK) == 0) return out;
    NSString *r = [[NSBundle mainBundle] pathForResource:@(file) ofType:nil];  // (the app: Contents/Resources, iOS: its root)
    if (!r) return NULL;
    snprintf(out, 1024, "%s", r.UTF8String);
    return out;
}
static void setup_fonts(float scale) {
    ImGuiIO &io = ImGui::GetIO();
    io.Fonts->Clear();
    ImFontConfig fc;
    fc.OversampleH = 2;
    const char *reg = font_path("DejaVuSans.ttf"), *bold = font_path("DejaVuSans-Bold.ttf");
    if (reg) io.Fonts->AddFontFromFileTTF(reg, 17.0f * scale, &fc);
    else io.Fonts->AddFontDefault();
    g_bold = bold ? io.Fonts->AddFontFromFileTTF(bold, 17.0f * scale, &fc) : io.Fonts->Fonts[0];
    g_title = bold ? io.Fonts->AddFontFromFileTTF(bold, 27.0f * scale, &fc) : io.Fonts->Fonts[0];
    g_small = reg ? io.Fonts->AddFontFromFileTTF(reg, 14.5f * scale, &fc) : io.Fonts->Fonts[0];
}

static float em(void) { return ImGui::GetFontSize(); }
static void help_at(const char *text, float wrap) {  // (small, muted, wrapped at wrap: 0 the window's edge)
    ImGui::PushFont(g_small);
    ImGui::PushStyleColor(ImGuiCol_Text, C_MUTED);
    ImGui::PushTextWrapPos(wrap);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
    ImGui::PopFont();
}
static void help(const char *text) { help_at(text, 0); }
// A card: a rounded box of related settings, with a small heading above it (title NULL: none)
static void card_begin(const char *id, const char *title) {
    if (title) {
        ImGui::PushFont(g_small);
        ImGui::PushStyleColor(ImGuiCol_Text, C_MUTED);
        ImGui::TextUnformatted(title);
        ImGui::PopStyleColor();
        ImGui::PopFont();
    }
    ImGui::PushStyleColor(ImGuiCol_ChildBg, C_CARD);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(em() * 0.95f, em() * 0.8f));
    ImGui::BeginChild(id, ImVec2(0, 0), ImGuiChildFlags_AutoResizeY | ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                      ImGuiWindowFlags_NoScrollbar);
}
static void card_end(void) {
    ImGui::EndChild();
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    ImGui::Dummy(ImVec2(0, em() * 0.5f));
}
// A setting's row: its name (and help under it) on the left, its control right-aligned and ctrl_w wide (row_begin
// leaves the cursor there); on a narrow card the control goes under the name. row_end: the next row.
static float g_row_end;
static void row_begin(const char *label, const char *helptext, float ctrl_w) {
    float avail = ImGui::GetContentRegionAvail().x;
    ImVec2 p = ImGui::GetCursorPos();
    float lw = avail - ctrl_w - em();
    if (lw < avail * 0.34f) {  // (stacked)
        ImGui::TextUnformatted(label);
        if (helptext) help(helptext);
        g_row_end = 0;
        return;
    }
    ImGui::AlignTextToFramePadding();
    ImGui::PushTextWrapPos(p.x + lw);
    ImGui::TextUnformatted(label);
    ImGui::PopTextWrapPos();
    if (helptext) help_at(helptext, p.x + lw);
    g_row_end = ImGui::GetCursorPosY();
    ImGui::SetCursorPos(ImVec2(p.x + avail - ctrl_w, p.y));
}
static void row_end(void) {
    if (ImGui::GetCursorPosY() < g_row_end) ImGui::SetCursorPosY(g_row_end);
    ImGui::Dummy(ImVec2(0, em() * 0.15f));
}
static float toggle_w(void) { return ImGui::GetFrameHeight() * 1.8f; }
static bool toggle(const char *id, bool *v) {  // (an on / off switch)
    float h = ImGui::GetFrameHeight(), w = toggle_w();
    ImVec2 p = ImGui::GetCursorScreenPos();
    bool pressed = ImGui::InvisibleButton(id, ImVec2(w, h));
    if (pressed) *v = !*v;
    bool hov = ImGui::IsItemHovered();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    float pad = h * 0.13f, r = h * 0.5f - pad;
    ImVec4 track = *v ? C_ACCENT : ImVec4(0.27f, 0.29f, 0.33f, 1);
    if (hov) track = ImVec4(track.x * 1.08f, track.y * 1.08f, track.z * 1.08f, 1);
    dl->AddRectFilled(p, ImVec2(p.x + w, p.y + h), col(track), h * 0.5f);
    float x = *v ? p.x + w - pad - r : p.x + pad + r;
    dl->AddCircleFilled(ImVec2(x, p.y + h * 0.5f), r, IM_COL32(250, 252, 255, 255), 24);
    return pressed;
}
static float seg_w(const char *const *names, int n) {
    float m = 0;
    for (int i = 0; i < n; i++) m = fmaxf(m, ImGui::CalcTextSize(names[i]).x);
    return n * (m + em() * 1.6f);
}
static bool segmented(const char *id, int *v, const char *const *names, const int *values, int n, float w) {
    ImGui::PushID(id);
    float h = ImGui::GetFrameHeight(), bw = w / n, rr = ImGui::GetStyle().FrameRounding, in = em() * 0.16f;
    ImVec2 p0 = ImGui::GetCursorScreenPos();
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddRectFilled(p0, ImVec2(p0.x + w, p0.y + h), col(C_CONTROL), rr);
    bool changed = false;
    for (int i = 0; i < n; i++) {
        ImGui::SetCursorScreenPos(ImVec2(p0.x + i * bw, p0.y));
        ImGui::PushID(i);
        bool sel = values[i] == *v;
        if (ImGui::InvisibleButton("s", ImVec2(bw, h))) { *v = values[i]; changed = true; }
        ImVec2 a = ImGui::GetItemRectMin(), b = ImGui::GetItemRectMax();
        if (sel) dl->AddRectFilled(ImVec2(a.x + in, a.y + in), ImVec2(b.x - in, b.y - in), col(C_ACCENT), rr - in);
        else if (ImGui::IsItemHovered()) dl->AddRectFilled(ImVec2(a.x + in, a.y + in), ImVec2(b.x - in, b.y - in), IM_COL32(255, 255, 255, 18), rr - in);
        ImVec2 ts = ImGui::CalcTextSize(names[i]);
        dl->AddText(ImVec2(a.x + (bw - ts.x) * 0.5f, a.y + (h - ts.y) * 0.5f), col(sel ? C_ON_ACCENT : C_TEXT), names[i]);
        ImGui::PopID();
    }
    ImGui::PopID();
    return changed;
}
static bool combo(const char *id, int *v, const char *const *names, const int *values, int n, float w) {
    int cur = 0;
    for (int i = 0; i < n; i++) if (values[i] == *v) cur = i;
    bool changed = false;
    ImGui::SetNextItemWidth(w);
    if (ImGui::BeginCombo(id, names[cur])) {
        for (int i = 0; i < n; i++)
            if (ImGui::Selectable(names[i], i == cur)) { *v = values[i]; changed = true; }
        ImGui::EndCombo();
    }
    return changed;
}
static float combo_w(const char *const *names, int n) {
    float m = 0;
    for (int i = 0; i < n; i++) m = fmaxf(m, ImGui::CalcTextSize(names[i]).x);
    return m + ImGui::GetFrameHeight() + em() * 1.6f;
}
static bool button(const char *label, bool primary = false, float w = 0) {
    if (primary) {
        ImGui::PushStyleColor(ImGuiCol_Button, C_ACCENT);
        ImGui::PushStyleColor(ImGuiCol_ButtonHovered, ImVec4(0.50f, 0.90f, 0.72f, 1));
        ImGui::PushStyleColor(ImGuiCol_ButtonActive, ImVec4(0.58f, 0.94f, 0.78f, 1));
        ImGui::PushStyleColor(ImGuiCol_Text, C_ON_ACCENT);
    }
    bool r = ImGui::Button(label, ImVec2(w, 0));
    if (primary) ImGui::PopStyleColor(4);
    return r;
}
static bool confirm(const char *id, const char *text, const char *yes) {  // (a modal: true when confirmed)
    bool ok = false;
    ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(em() * 1.4f, em() * 1.2f));
    if (ImGui::BeginPopupModal(id, NULL, ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoTitleBar)) {
        g_popup = true;
        ImGui::PushFont(g_bold);
        ImGui::TextUnformatted(id);
        ImGui::PopFont();
        ImGui::PushTextWrapPos(em() * 24);
        ImGui::PushStyleColor(ImGuiCol_Text, C_MUTED);
        ImGui::TextUnformatted(text);
        ImGui::PopStyleColor();
        ImGui::PopTextWrapPos();
        ImGui::Dummy(ImVec2(0, em() * 0.4f));
        if (button(yes, true)) { ok = true; ImGui::CloseCurrentPopup(); }
        ImGui::SameLine();
        if (button("Cancel") || ImGui::IsKeyPressed(ImGuiKey_Escape)) ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
    }
    ImGui::PopStyleVar();
    return ok;
}
static void separator(void) {
    ImVec2 p = ImGui::GetCursorScreenPos();
    ImGui::GetWindowDrawList()->AddLine(ImVec2(p.x, p.y), ImVec2(p.x + ImGui::GetContentRegionAvail().x, p.y), IM_COL32(255, 255, 255, 16));
    ImGui::Dummy(ImVec2(0, em() * 0.35f));
}

// ---- the pages
static void page_game(void) {
    card_begin("##play", NULL);
    help(g_settings.menu_pause ? "Paused while this menu is open." : "The game keeps running while this menu is open.");
    ImGui::Dummy(ImVec2(0, em() * 0.3f));
    if (button("Resume", true)) set_open(false);
    ImGui::SameLine();
    if (button("Restart game")) ImGui::OpenPopup("Restart the game?");
#if MENU_TOUCH
    if (g_game_count > 1) {
        ImGui::SameLine();
        if (button("Switch game")) ImGui::OpenPopup("Switch game?");
    }
    if (confirm("Switch game?", "Back to the game selection. Progress since the game last saved is lost.", "Switch game")) {
        set_open(false);
        rt_request_reboot(REBOOT_TITLE);
    }
#else  // (an iOS app doesn't quit itself: the app switcher closes it)
    ImGui::SameLine();
    if (button("Quit")) ImGui::OpenPopup("Quit?");
    if (confirm("Quit?", "Progress since the game last saved is lost.", "Quit")) {
        SDL_Event q = {};
        q.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&q);
    }
#endif
    if (confirm("Restart the game?", "Progress since the game last saved is lost.", "Restart")) {
        set_open(false);
        rt_request_reboot(REBOOT_GAME);
    }
    card_end();
    card_begin("##speed", "GAME SPEED");
    {
        static const char *const n[] = {"0.5x", "1x", "1.5x", "2x", "3x"};
        static const int v[] = {50, 100, 150, 200, 300};
        int pct = (int)lroundf((g_settings.speed > 0 ? g_settings.speed : 1) * 100);
        float w = seg_w(n, 5);
        row_begin("Speed", "Faster or slower than on a Switch: the game's clock, its frames and its sound (higher or lower) "
                  "follow. Above 1x the game needs the frames to keep up.", w);
        if (segmented("##speed", &pct, n, v, 5, w)) { g_settings.speed = pct / 100.0f; settings_save(); }
        row_end();
    }
    card_end();
    card_begin("##menu", "THIS MENU");
    row_begin("Pause the game while it's open", NULL, toggle_w());
    if (toggle("##pause", &g_settings.menu_pause)) settings_save();
    row_end();
#if MENU_TOUCH
    help("Open it with the button at the top of the screen (touch the screen to show it), Home or Minus + Plus on a "
         "controller, or F1 / Esc on a keyboard.");
#else
    help("Open and close it with F1 or Esc, or Home or Minus + Plus on a controller.");
#endif
    card_end();
}

// Cloud saves (runtime/ui/cloud.mm): the bucket, this device's name, each device's save of this game
static std::mutex g_paste_mx;  // (main thread -> render thread: the clipboard's text, read where UIKit / AppKit want it)
static std::string g_pasted;
static std::atomic<bool> g_paste_ready{false};
static void paste_request(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
#if MENU_TOUCH
        NSString *s = UIPasteboard.generalPasteboard.string;
#else
        NSString *s = [NSPasteboard.generalPasteboard stringForType:NSPasteboardTypeString];
#endif
        std::lock_guard<std::mutex> l(g_paste_mx);
        g_pasted = s ? s.UTF8String : "";
        g_paste_ready = true;
    });
}
static void cloud_card(void) {
    static char conn[512];
    static std::string conn_error, pick;
    static bool restart_wanted;
    static double asked = -1;
    CloudView v = cloud_view();
    if (restart_wanted && !v.fetched.empty()) {  // (the save chosen below is here: restored by a restart, as a backup is)
        restart_wanted = false;
        std::error_code ec;
        g_restore_from = v.fetched;
        g_restore_root = fs::absolute(save_root(), ec);
        set_open(false);
        rt_request_reboot(REBOOT_GAME);
    }
    if (restart_wanted && !v.busy && !v.error.empty()) restart_wanted = false;
    card_begin("##cloud", "CLOUD SAVES");
    if (!v.configured) {
        help("Keep each device's save in your own storage bucket (Backblaze B2, or any S3-compatible one) and play the "
             "newest on any device: a game checks for a newer one when it starts.");
        ImGui::Dummy(ImVec2(0, em() * 0.2f));
        if (g_paste_ready.exchange(false)) {
            std::lock_guard<std::mutex> l(g_paste_mx);
            snprintf(conn, sizeof conn, "%s", s3::trim(g_pasted).c_str());
        }
        const ImGuiStyle &st = ImGui::GetStyle();
        float pw = ImGui::CalcTextSize("Paste").x + ImGui::CalcTextSize("Connect").x + st.FramePadding.x * 4 + st.ItemSpacing.x * 2;
        ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x - pw);
        ImGui::InputTextWithHint("##conn", "s3://<key ID>:<application key>@<endpoint>/<bucket>", conn, sizeof conn,
                                 ImGuiInputTextFlags_Password);
        ImGui::SameLine();
        if (button("Paste")) paste_request();
        ImGui::SameLine();
        if (button("Connect", true)) {
            std::string why;
            if (cloud_connect(conn, &why)) conn[0] = 0, conn_error.clear();
            else conn_error = "Can't connect: " + why;
        }
        if (!conn_error.empty()) help(conn_error.c_str());
        card_end();
        return;
    }
    if (asked < 0 || (ImGui::GetTime() - asked > 120 && !v.busy)) {  // (listed when the page is first shown, then each 2 minutes)
        asked = ImGui::GetTime();
        if (!v.listed || time(NULL) - v.listed > 60) cloud_refresh();
    }
    row_begin("Sync this device", (v.bucket + "  ·  " + v.endpoint).c_str(), toggle_w());
    if (toggle("##cloud_on", &g_settings.cloud)) settings_save();
    row_end();
    float nw = fminf(em() * 11, ImGui::GetContentRegionAvail().x * 0.45f);
    row_begin("This device's name", "What other devices call its saves", nw);
    ImGui::SetNextItemWidth(nw);
    ImGui::InputText("##device", g_settings.cloud_device, sizeof g_settings.cloud_device);
    if (ImGui::IsItemDeactivatedAfterEdit()) settings_save();
    row_end();
#if MENU_TOUCH
    row_begin("Use mobile data", "Uploads and downloads away from Wi-Fi (a save can be tens of MB)", toggle_w());
    if (toggle("##cloud_cell", &g_settings.cloud_cellular)) settings_save();
    row_end();
#endif
    std::string line = v.error.empty() ? v.status : v.error;
    if (v.progress >= 0) line += "  ·  " + std::to_string((int)(v.progress * 100)) + "%";
    else if (v.busy && line.empty()) line = "Working...";
    if (!line.empty()) {
        if (!v.error.empty()) ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.95f, 0.55f, 0.45f, 1));
        ImGui::PushTextWrapPos(0);
        ImGui::TextUnformatted(line.c_str());
        ImGui::PopTextWrapPos();
        if (!v.error.empty()) ImGui::PopStyleColor();
    }
    ImGui::Dummy(ImVec2(0, em() * 0.2f));
    ImGui::BeginDisabled(v.busy);
    if (button("Upload now")) cloud_upload_now();
    ImGui::SameLine();
    if (button("Check again")) cloud_refresh();
    ImGui::EndDisabled();
    ImGui::SameLine();
    if (button("Disconnect")) ImGui::OpenPopup("Disconnect cloud saves?");
    if (confirm("Disconnect cloud saves?", "This device stops syncing and forgets the key. The saves in the bucket stay.", "Disconnect"))
        cloud_disconnect();
    for (size_t i = 0; i < v.slots.size(); i++) {
        const CloudSlot &s = v.slots[i];
        ImGui::PushID((int)i);
        separator();
        const char *tag = s.current ? "In use here" : NULL;
        float bw = tag ? ImGui::CalcTextSize(tag).x : ImGui::CalcTextSize("Use this save").x + ImGui::GetStyle().FramePadding.x * 2;
        if (!tag && !s.same_game) bw = 0;
        float x0 = ImGui::GetCursorPosX(), avail = ImGui::GetContentRegionAvail().x;
        ImGui::BeginGroup();
        ImGui::PushTextWrapPos(x0 + avail - bw - em());
        ImGui::TextUnformatted((s.device + (s.mine ? " (this device)" : "")).c_str());
        ImGui::PopTextWrapPos();
        std::string d = "Saved " + format_time(s.saved) + "  ·  " + human_bytes(s.size);
        if (!s.same_game) d += "  ·  another version of the game" + (s.version.empty() ? "" : " (" + s.version + ")");
        help_at(d.c_str(), x0 + avail - bw - em());
        ImGui::EndGroup();
        if (bw > 0) ImGui::SameLine(x0 + avail - bw);
        if (tag) {
            ImGui::AlignTextToFramePadding();
            ImGui::TextColored(C_ACCENT, "%s", tag);
        } else if (s.same_game) {
            ImGui::BeginDisabled(v.busy);
            if (button("Use this save")) { pick = s.key; ImGui::OpenPopup("Use this save?"); }
            ImGui::EndDisabled();
        }
        if (pick == s.key) {
            std::string q = "The save from " + s.device + " (" + format_time(s.saved) +
                            ") replaces the one here, which is backed up first, and the game restarts.";
            if (confirm("Use this save?", q.c_str(), "Download and restart")) { cloud_fetch(s.key); restart_wanted = true; }
        }
        ImGui::PopID();
    }
    if (v.slots.empty() && v.listed) { separator(); help("No device has uploaded a save of this game yet."); }
    card_end();
}

static void page_saves(void) {
    double now = ImGui::GetTime();
    if (g_backups_listed < 0 || now - g_backups_listed > 5) { list_backups(); g_backups_listed = now; }
    std::error_code ec;
    fs::path root = fs::absolute(save_root(), ec);
    time_t newest = 0;
    uintmax_t bytes = 0;
    int mounts = 0;
    for (auto &d : fs::directory_iterator(save_root(), ec))
        if (is_mount(d)) { bytes += dir_bytes(d.path(), &newest); mounts++; }
    card_begin("##current", "CURRENT SAVE");
    ImGui::PushFont(g_bold);
    if (mounts) ImGui::Text("Last saved %s", format_time(newest).c_str());
    else ImGui::TextUnformatted("No save yet");
    ImGui::PopFont();
    help(mounts ? (human_bytes(bytes) + "  ·  " + root.string()).c_str() : root.c_str());
    ImGui::Dummy(ImVec2(0, em() * 0.2f));
#if MENU_TOUCH
    if (button("Show in the Files app")) {  // (shareddocuments://<path>: the Files app, at that folder)
        NSString *path = @(root.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *u = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:
                                             [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
            [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        });
    }
#else
    if (button("Open the saves folder")) {
        NSString *path = @(root.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{ [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]]; });
    }
#endif
    card_end();
    cloud_card();
    card_begin("##backups", "BACKUPS");
    help("A backup is a copy of the save. Restoring one puts it back and restarts the game, after backing up the "
         "current save first.");
    ImGui::Dummy(ImVec2(0, em() * 0.2f));
    static char label[64];
    float bw = ImGui::CalcTextSize("Back up now").x + ImGui::GetStyle().FramePadding.x * 2;
    ImGui::SetNextItemWidth(ImGui::GetContentRegionAvail().x - bw - ImGui::GetStyle().ItemSpacing.x);
    ImGui::InputTextWithHint("##label", "Name (optional)", label, sizeof label);
    ImGui::SameLine();
    if (button("Back up now", true)) {
        fs::path made;
        std::string err = back_up(label, &made);
        g_status = err.empty() ? "Backed up to " + made.filename().string() : "Backup failed: " + err;
        label[0] = 0;
        g_backups_listed = -1;
    }
    if (!g_status.empty()) help(g_status.c_str());
    ImGui::Dummy(ImVec2(0, em() * 0.3f));
    static int pick = -1;
    if (g_backups.empty()) help("No backups yet.");
    for (int i = 0; i < (int)g_backups.size(); i++) {
        const Backup &b = g_backups[i];
        ImGui::PushID(i);
        separator();
        float rw = ImGui::CalcTextSize("Restore").x + ImGui::CalcTextSize("Delete").x + ImGui::GetStyle().FramePadding.x * 4 +
                   ImGui::GetStyle().ItemSpacing.x;
        float x0 = ImGui::GetCursorPosX(), avail = ImGui::GetContentRegionAvail().x;
        ImGui::BeginGroup();
        ImGui::PushTextWrapPos(x0 + avail - rw - em());
        ImGui::TextUnformatted(b.name.c_str());
        ImGui::PopTextWrapPos();
        help((format_time(b.when) + "  ·  " + human_bytes(b.bytes)).c_str());
        ImGui::EndGroup();
        ImGui::SameLine(x0 + avail - rw);
        if (button("Restore")) { pick = i; ImGui::OpenPopup("Restore this backup?"); }
        ImGui::SameLine();
        if (button("Delete")) { pick = i; ImGui::OpenPopup("Delete this backup?"); }
        if (pick == i) {
            std::string q = "\"" + b.name + "\" replaces the current save (backed up first) and the game restarts.";
            if (confirm("Restore this backup?", q.c_str(), "Restore and restart")) {
                g_restore_from = fs::absolute(b.path, ec);
                g_restore_root = fs::absolute(save_root(), ec);
                set_open(false);
                rt_request_reboot(REBOOT_GAME);
            }
            std::string d = "\"" + b.name + "\" is deleted for good.";
            if (confirm("Delete this backup?", d.c_str(), "Delete")) {
                fs::remove_all(b.path, ec);
                g_status = ec ? "Could not delete: " + ec.message() : "Deleted " + b.name;
                g_backups_listed = -1;
            }
        }
        ImGui::PopID();
    }
    card_end();
}

static void page_time(void) {
    time_t game = (time_t)time_game_now();
    card_begin("##clock", NULL);
    ImGui::PushFont(g_title);
    ImGui::TextUnformatted(format_time(game, "%H:%M").c_str());
    ImGui::PopFont();
    ImGui::SameLine();
    ImGui::AlignTextToFramePadding();
    ImGui::TextUnformatted(format_time(game, "%A %d %B %Y").c_str());
    help("Games that follow the time of day (Animal Crossing's seasons, shops and visitors) see this clock. Animal "
         "Crossing reads it when it starts, as on a Switch: restart the game after changing it.");
    card_end();
    static bool editing;
    int mode = g_settings.time_offset != 0 || editing ? 1 : 0;
    card_begin("##source", "THE GAME'S CLOCK");
    static const char *const sn[] = {MENU_TOUCH ? "This device's" : "This Mac's", "My own"};
    static const int sv[] = {0, 1};
    float w = seg_w(sn, 2);
    row_begin("Date and time", NULL, w);
    if (segmented("##src", &mode, sn, sv, 2, w)) {
        editing = mode == 1;
        if (!mode && g_settings.time_offset) { g_settings.time_offset = 0; settings_save(); time_offset_changed(); }
    }
    row_end();
    static int y, mo, d, h, mi;
    static time_t shown = -1;
    if (shown != game / 60) {  // (the fields follow the clock until edited)
        struct tm tm;
        localtime_r(&game, &tm);
        y = tm.tm_year + 1900, mo = tm.tm_mon + 1, d = tm.tm_mday, h = tm.tm_hour, mi = tm.tm_min;
        shown = game / 60;
    }
    auto set_to = [&](time_t target) {
        g_settings.time_offset = (long long)(target - time(NULL));
        settings_save();
        time_offset_changed();
        shown = -1;
    };
    if (mode == 1) {
        separator();
        float fw = em() * 7.5f;
        bool e = false;
        struct { const char *name; int *v; } f[] = {{"Year", &y}, {"Month", &mo}, {"Day", &d}, {"Hour", &h}, {"Minute", &mi}};
        for (int i = 0; i < 5; i++) {
            if (i && i != 3) ImGui::SameLine();
            ImGui::BeginGroup();
            help(f[i].name);
            ImGui::PushID(i);
            ImGui::SetNextItemWidth(i ? fw : fw * 1.15f);
            e |= ImGui::InputInt("##v", f[i].v, 1);
            ImGui::PopID();
            ImGui::EndGroup();
        }
        if (e) shown = -2;  // (being edited: kept)
        y = y < 2000 ? 2000 : y > 2060 ? 2060 : y, mo = mo < 1 ? 1 : mo > 12 ? 12 : mo, d = d < 1 ? 1 : d > 31 ? 31 : d;
        h = h < 0 ? 0 : h > 23 ? 23 : h, mi = mi < 0 ? 0 : mi > 59 ? 59 : mi;
        ImGui::Dummy(ImVec2(0, em() * 0.2f));
        if (button("Set the clock", true)) {
            struct tm tm = {};
            tm.tm_year = y - 1900, tm.tm_mon = mo - 1, tm.tm_mday = d, tm.tm_hour = h, tm.tm_min = mi, tm.tm_isdst = -1;
            set_to(mktime(&tm));
        }
        static const char *const qn[] = {"-1 day", "+1 day", "-1 hour", "+1 hour"};
        static const int qd[] = {-86400, 86400, -3600, 3600};
        for (int i = 0; i < 4; i++) {
            ImGui::SameLine();
            if (button(qn[i])) set_to(game + qd[i]);
        }
    }
    card_end();
    card_begin("##restart", NULL);
    row_begin("Restart the game", "To start it with this clock.", ImGui::CalcTextSize("Restart").x + em() * 1.6f);
    if (button("Restart")) ImGui::OpenPopup("Restart the game?");
    row_end();
    if (confirm("Restart the game?", "Progress since the game last saved is lost.", "Restart")) {
        set_open(false);
        rt_request_reboot(REBOOT_GAME);
    }
    card_end();
}

static void page_video(void) {
    bool changed = false;
    card_begin("##screen", MENU_TOUCH ? "SCREEN" : "WINDOW");
#if !MENU_TOUCH
    row_begin("Fullscreen", "F11", toggle_w());
    if (toggle("##fs", &g_settings.fullscreen)) { g_want_fullscreen_apply = true; changed = true; }
    row_end();
#endif
    {
        static const char *const n[] = {"Fill", "16:9"};
        static const int v[] = {ASPECT_UNLOCKED, ASPECT_ORIGINAL};
        float w = seg_w(n, 2);
        row_begin("Shape", MENU_TOUCH ? "Fill the screen, or the Switch's 16:9 with bars." : "Fill the window, or the Switch's 16:9 with bars.", w);
        changed |= segmented("##shape", &g_settings.aspect, n, v, 2, w);
        row_end();
    }
    card_end();
    card_begin("##image", "IMAGE");
    {
        static const char *const n[] = {"Match the screen", "1080p (1x)", "4K (2x)", "3x", "4x", "Dynamic", "75% of the screen",
                                        "50% of the screen", "25% of the screen"};
        static const int v[] = {RES_MATCH, 1, 2, 3, 4, RES_DYNAMIC, RES_Q75, RES_Q50, RES_Q25};
        float w = combo_w(n, 9);
        row_begin("Resolution", "What the game is drawn at: higher is sharper, not smaller.", w);
        if (combo("##res", &g_settings.res_mode, n, v, 9, w)) g_settings.res_auto = false, changed = true;
        row_end();
    }
    if (HAVE_METALFX) {
        static const char *const n[] = {"Bilinear", "MetalFX"};
        static const int v[] = {UPSCALE_BILINEAR, UPSCALE_METALFX};
        float w = seg_w(n, 2);
        row_begin("Upscaler", NULL, w);
        if (segmented("##up", &g_settings.upscaler, n, v, 2, w)) g_settings.upscaler_auto = false, changed = true;
        row_end();
    }
    {
        static const char *const n[] = {"Off", "SMAA"};
        static const int v[] = {AA_OFF, AA_SMAA};
        float w = seg_w(n, 2);
        row_begin("Anti-aliasing", NULL, w);
        changed |= segmented("##aa", &g_settings.antialias, n, v, 2, w);
        row_end();
    }
    card_end();
    card_begin("##rate", "FRAME RATE");
    {
        static const char *const n[] = {"Display", "120", "60", "30"};
        static const int v[] = {0, 120, 60, 30};
        float w = seg_w(n, 4);
        row_begin("Limit", "Metroid Dread runs at the display's rate; Animal Crossing at 30.", w);
        changed |= segmented("##cap", &g_settings.fps_cap, n, v, 4, w);
        row_end();
    }
    {
        static const char *const n[] = {"Off", "60", "120"};
        static const int v[] = {0, 60, 120};
        float w = seg_w(n, 3);
        row_begin("Frame generation", "Images between a 30 fps game's frames: smoother motion, a frame of latency.", w);
        changed |= segmented("##fg", &g_settings.frame_gen, n, v, 3, w);
        row_end();
    }
    if (HAVE_METALFX) {
        int method = g_settings.frame_gen_flow ? 1 : 0;
        static const char *const n[] = {"MetalFX", "Optical flow"};
        static const int v[] = {0, 1};
        float w = seg_w(n, 2);
        row_begin("Method", "MetalFX is cleaner (60 only); optical flow also does 120.", w);
        if (segmented("##fgm", &method, n, v, 2, w)) g_settings.frame_gen_flow = method == 1, changed = true;
        row_end();
    }
    row_begin("Show the frame rate", NULL, toggle_w());
    changed |= toggle("##fps", &g_settings.show_fps);
    row_end();
    card_end();
    if (changed) settings_save();
}

static void page_audio(void) {
    card_begin("##audio", NULL);
    float pct = g_settings.volume * 100, w = em() * 13;
    row_begin("Volume", NULL, w);
    ImGui::SetNextItemWidth(w);
    if (ImGui::SliderFloat("##vol", &pct, 0, 100, "%.0f%%")) g_settings.volume = pct / 100, settings_save();
    row_end();
    row_begin("Room reverb", "The echo of rooms and caves, as the game sets it.", toggle_w());
    if (toggle("##rev", &g_settings.reverb)) settings_save();
    row_end();
    card_end();
}

static void page_controls(void) {
    bool changed = false;
    card_begin("##pad", "CONTROLLER");
#if MENU_TOUCH
    help("Pair a controller in Settings > Bluetooth: Xbox, PlayStation, Switch Pro and MFi controllers work.");
    ImGui::Dummy(ImVec2(0, em() * 0.2f));
    {
        static const char *const n[] = {"Auto", "Always", "Never"};
        static const int v[] = {TOUCH_PAD_AUTO, TOUCH_PAD_ALWAYS, TOUCH_PAD_NEVER};
        float w = seg_w(n, 3);
        row_begin("On-screen controller", "Auto: while no controller is connected.", w);
        changed |= segmented("##touch", &g_settings.touch_pad, n, v, 3, w);
        row_end();
    }
#endif
    row_begin("Vibration", NULL, toggle_w());
    changed |= toggle("##rumble", &g_settings.rumble);
    row_end();
    {
        static const char *const n[] = {"Right (A)", "Bottom"};
        static const int v[] = {MENU_CONFIRM_GAME, MENU_CONFIRM_CONTROLLER};
        float w = seg_w(n, 2);
        row_begin("Confirm in this menu", "The button that presses here: the Switch's A, or the controller's own.", w);
        changed |= segmented("##confirm", &g_settings.menu_confirm, n, v, 2, w);
        row_end();
    }
    card_end();
    card_begin("##lang", "LANGUAGE");
    {
        static int v[N_LANGUAGES];
        for (int i = 0; i < N_LANGUAGES; i++) v[i] = i;
        float w = combo_w(g_language_names, N_LANGUAGES);
        row_begin("Game language", "The system language the game is told (when it restarts).", w);
        changed |= combo("##language", &g_settings.language, g_language_names, v, N_LANGUAGES, w);
        row_end();
    }
    card_end();
    card_begin("##keys", "KEYBOARD");
    static const char *const rows[][2] = {
        {"Left stick", "W A S D"}, {"D-pad", "Arrow keys"}, {"A / B / X / Y", "K / J / L / I"}, {"L / R", "Q / E"},
        {"ZL / ZR", "1 / 3"}, {"Plus / Minus", "Enter / Backspace"}, {"Stick clicks", "F / keypad 0"},
        {"Right stick", "Keypad 8 / 5 / 4 / 6"},
    };
    help("Rebind them in nx.ini. In a game's own text entry the keys type instead.");
    ImGui::Dummy(ImVec2(0, em() * 0.2f));
    float x1 = ImGui::GetContentRegionAvail().x * 0.45f;
    for (auto &r : rows) {
        ImGui::TextUnformatted(r[0]);
        ImGui::SameLine(x1);
        ImGui::PushStyleColor(ImGuiCol_Text, C_MUTED);
        ImGui::TextUnformatted(r[1]);
        ImGui::PopStyleColor();
    }
    card_end();
    if (changed) settings_save();
}

static void draw_fps(void) {
    static double t0;
    static uint64_t g0, s0;
    static float fps, shown;
    double t = ImGui::GetTime();
    uint64_t g, s;
    renderer_frame_counts(&g, &s);
    if (t - t0 >= 0.5) {
        if (t0 > 0) fps = (float)((g - g0) / (t - t0)), shown = (float)((s - s0) / (t - t0));
        t0 = t, g0 = g, s0 = s;
    }
    ImVec2 at(12 * g_scale, 12 * g_scale);
#if MENU_TOUCH
    if (g_safe[2] > 0) at = ImVec2(g_safe[0] + 12 * g_scale, g_safe[1] + 8 * g_scale);
#endif
    ImGui::SetNextWindowPos(at);
    ImGui::SetNextWindowBgAlpha(0.55f);
    ImGui::Begin("##fps", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs |
                                    ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
    char speed[24] = "";
    if (g_settings.speed > 0 && fabsf(g_settings.speed - 1) > 0.01f) snprintf(speed, sizeof speed, "  ·  %gx", g_settings.speed);
    if (shown > fps + 1) ImGui::Text("%.0f fps (%.0f shown)%s", fps, shown, speed);
    else ImGui::Text("%.0f fps%s", fps, speed);
    ImGui::End();
}

// The screen's usable part: inside the safe area on iOS, the whole window elsewhere
static void usable_rect(ImVec2 *pos, ImVec2 *size) {
    ImGuiViewport *vp = ImGui::GetMainViewport();
    *pos = vp->Pos, *size = vp->Size;
#if MENU_TOUCH
    if (g_safe[2] > 0) *pos = ImVec2(g_safe[0], g_safe[1]), *size = ImVec2(g_safe[2], g_safe[3]);
#endif
}

static int g_page;
static void draw_menu(void) {
    static const char *const names[] = {"Game", "Saves", "Date & time", "Video", "Audio", "Controls"};
    static void (*const pages[])(void) = {page_game, page_saves, page_time, page_video, page_audio, page_controls};
    const int n = 6;
    // (test) LARECOMP_MENU_TABS_EVERY=<frames>: the next page every that many frames (screenshots of each)
    static long every = -1, at;
    if (every < 0) every = getenv("LARECOMP_MENU_TABS_EVERY") ? atol(getenv("LARECOMP_MENU_TABS_EVERY")) : 0;
    if (every > 0) { uint64_t g, sh; renderer_frame_counts(&g, &sh); if (!at) at = (long)g; g_page = (int)(((long)g - at) / every) % n; }
    static int page = getenv("LARECOMP_MENU_PAGE") ? atoi(getenv("LARECOMP_MENU_PAGE")) : -1;  // (test: open on that page)
    if (page >= 0 && page < n) g_page = page, page = -1;
    if (!g_popup && ImGui::IsKeyPressed(ImGuiKey_GamepadL1)) g_page = (g_page + n - 1) % n;  // (L / R: the pages)
    if (!g_popup && ImGui::IsKeyPressed(ImGuiKey_GamepadR1)) g_page = (g_page + 1) % n;

    ImGuiViewport *vp = ImGui::GetMainViewport();
    ImGui::GetBackgroundDrawList()->AddRectFilled(vp->Pos, ImVec2(vp->Pos.x + vp->Size.x, vp->Pos.y + vp->Size.y), IM_COL32(0, 0, 0, 150));
    ImVec2 up, us;
    usable_rect(&up, &us);
    ImVec2 size(fminf(us.x * (MENU_TOUCH ? 0.97f : 0.9f), 1120 * g_scale), fminf(us.y * (MENU_TOUCH ? 0.95f : 0.88f), 780 * g_scale));
    ImGui::SetNextWindowPos(ImVec2(up.x + us.x * 0.5f, up.y + us.y * 0.5f), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(size, ImGuiCond_Always);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(0, 0));
    ImGui::Begin("##nx", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings |
                                   ImGuiWindowFlags_NoScrollWithMouse);
    ImGui::PopStyleVar();
    float f = em(), side = fminf(fmaxf(f * 11.5f, size.x * 0.22f), f * 15);
    ImVec2 wp = ImGui::GetWindowPos();
    ImGui::GetWindowDrawList()->AddRectFilled(wp, ImVec2(wp.x + side, wp.y + size.y), col(C_SIDE), ImGui::GetStyle().WindowRounding,
                                              ImDrawFlags_RoundCornersLeft);
    // the pages, down the left
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(f * 0.8f, f * 1.0f));
    ImGui::BeginChild("##side", ImVec2(side, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened,
                      ImGuiWindowFlags_NoScrollbar);
    ImGui::PopStyleVar();
    ImGui::PushFont(g_bold);
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(menu_game_name());
    ImGui::PopTextWrapPos();
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0, f * 0.5f));
    float bh = ImGui::GetFrameHeight();  // (the pages' buttons share what's left above Resume: a phone's is short)
    float iw = ImGui::GetContentRegionAvail().x, ih = (ImGui::GetContentRegionAvail().y - bh - f * 1.2f) / n;
    ih = fminf(fmaxf(ih, f * 1.7f), f * (MENU_TOUCH ? 2.5f : 2.1f));
    ImGui::PushStyleVar(ImGuiStyleVar_ItemSpacing, ImVec2(0, f * 0.15f));
    for (int i = 0; i < n; i++) {
        ImVec2 p = ImGui::GetCursorScreenPos();
        ImGui::PushID(i);
        if (ImGui::InvisibleButton("##page", ImVec2(iw, ih))) g_page = i;
        bool hov = ImGui::IsItemHovered(), on = i == g_page;
        ImDrawList *dl = ImGui::GetWindowDrawList();
        if (on) {
            dl->AddRectFilled(p, ImVec2(p.x + iw, p.y + ih), col(C_ACCENT, 0.16f), ih * 0.3f);
            dl->AddRectFilled(ImVec2(p.x, p.y + ih * 0.26f), ImVec2(p.x + f * 0.2f, p.y + ih * 0.74f), col(C_ACCENT), f * 0.1f);
        } else if (hov) dl->AddRectFilled(p, ImVec2(p.x + iw, p.y + ih), IM_COL32(255, 255, 255, 12), ih * 0.3f);
        ImFont *font = on ? g_bold : ImGui::GetFont();
        dl->AddText(font, f, ImVec2(p.x + f * 0.85f, p.y + (ih - f) * 0.5f), col(on ? C_ACCENT : C_TEXT), names[i]);
        ImGui::PopID();
    }
    ImGui::PopStyleVar();
    if (ImGui::GetCursorPosY() < ImGui::GetWindowHeight() - bh - f) ImGui::SetCursorPosY(ImGui::GetWindowHeight() - bh - f);
    if (button("Resume", true, -FLT_MIN)) set_open(false);
    ImGui::EndChild();
    // the page
    ImGui::SameLine(0, 0);
    ImGui::PushStyleVar(ImGuiStyleVar_WindowPadding, ImVec2(f * 1.3f, f * 1.0f));
    ImGui::BeginChild("##page", ImVec2(0, 0), ImGuiChildFlags_AlwaysUseWindowPadding | ImGuiChildFlags_NavFlattened);
    ImGui::PopStyleVar();
    ImGui::PushFont(g_title);
    ImGui::TextUnformatted(names[g_page]);
    ImGui::PopFont();
    ImGui::Dummy(ImVec2(0, f * 0.3f));
    ImGui::PushID(g_page);
    pages[g_page]();
    ImGui::PopID();
    ImGui::EndChild();
    // a tap or click outside the panel closes it
    if (ImGui::IsMouseClicked(0) && !ImGui::IsWindowHovered(ImGuiHoveredFlags_RootAndChildWindows | ImGuiHoveredFlags_AllowWhenBlockedByPopup) &&
        !g_popup && !ImGui::IsPopupOpen(NULL, ImGuiPopupFlags_AnyPopupId)) {
        ImVec2 m = ImGui::GetIO().MousePos;
        if (m.x < wp.x || m.y < wp.y || m.x > wp.x + size.x || m.y > wp.y + size.y) set_open(false);
    }
    ImGui::End();
}

// ---- covers (the selection and loading screens): cache/<game>/cover.jpg, a game frame (runtime/nvn/metal.m)
static NSMutableDictionary<NSString *, id> *g_covers;  // path -> texture, or NSNull (none)
static id<MTLTexture> cover_texture(const char *path) {
    if (!path || !path[0] || !g_dev) return nil;
    if (!g_covers) g_covers = [NSMutableDictionary new];
    NSString *k = @(path);
    id t = g_covers[k];
    if (t) return t == (id)NSNull.null ? nil : (id<MTLTexture>)t;
    id<MTLTexture> tex = nil;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:k], NULL);
    CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
    if (img) {
        size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
        void *px = calloc(w * h, 4);
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
        CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
        tex = [g_dev newTextureWithDescriptor:td];
        [tex replaceRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0 withBytes:px bytesPerRow:w * 4];
        CGContextRelease(ctx); CGColorSpaceRelease(cs); free(px); CGImageRelease(img);
    }
    if (src) CFRelease(src);
    g_covers[k] = tex ? (id)tex : (id)NSNull.null;
    return tex;
}
static ImTextureID tex_id(id<MTLTexture> t) { return (ImTextureID)(intptr_t)(__bridge void *)t; }
// A cover in rect a-b, cropped to fill it (no cover: a gradient in the title's own colour, with its initials)
static void draw_cover(ImDrawList *dl, ImVec2 a, ImVec2 b, const char *cover, const char *title, float rounding, ImDrawFlags flags,
                       float dim, bool initials = true) {
    id<MTLTexture> t = cover_texture(cover);
    float w = b.x - a.x, h = b.y - a.y;
    if (t) {
        float ta = (float)t.width / t.height, ra = w / h;
        ImVec2 uv0(0, 0), uv1(1, 1);
        if (ta > ra) { float k = ra / ta; uv0.x = (1 - k) * 0.5f, uv1.x = 1 - uv0.x; }
        else { float k = ta / ra; uv0.y = (1 - k) * 0.5f, uv1.y = 1 - uv0.y; }
        int v = (int)(255 * (1 - dim));
        dl->AddImageRounded(tex_id(t), a, b, uv0, uv1, IM_COL32(v, v, v, 255), rounding, flags);
        return;
    }
    unsigned hsh = 5381;
    for (const char *c = title; *c; c++) hsh = hsh * 33 + (unsigned char)*c;
    float r, g, bl;
    ImGui::ColorConvertHSVtoRGB((hsh % 360) / 360.0f, 0.55f, 0.42f * (1 - dim), r, g, bl);
    dl->AddRectFilled(a, b, col(ImVec4(r, g, bl, 1)), rounding, flags);
    dl->AddRectFilledMultiColor(ImVec2(a.x, a.y + h * 0.5f), b, IM_COL32(0, 0, 0, 0), IM_COL32(0, 0, 0, 0), IM_COL32(0, 0, 0, 110),
                                IM_COL32(0, 0, 0, 110));
    if (!initials) return;
    char ini[8] = {0};
    int k = 0;
    for (const char *c = title; *c && k < 2; c++)
        if ((c == title || c[-1] == ' ') && ((*c >= 'A' && *c <= 'Z') || (*c >= 'a' && *c <= 'z'))) ini[k++] = *c;
    float sz = fminf(h * 0.42f, g_title->FontSize * 2.4f);
    ImVec2 ts = g_title->CalcTextSizeA(sz, FLT_MAX, 0, ini);
    dl->AddText(g_title, sz, ImVec2(a.x + (w - ts.x) * 0.5f, a.y + (h - ts.y) * 0.5f), IM_COL32(255, 255, 255, 220), ini);
}

// The game selection screen: a card for each game, its cover over its name (one without its code in the app can't be
// picked)
static const char *const *g_pick_covers;
static void draw_picker(void) {
    ImGuiViewport *vp = ImGui::GetMainViewport();
    ImDrawList *bg = ImGui::GetBackgroundDrawList();
    bg->AddRectFilledMultiColor(vp->Pos, ImVec2(vp->Pos.x + vp->Size.x, vp->Pos.y + vp->Size.y), IM_COL32(18, 22, 28, 255),
                                IM_COL32(18, 22, 28, 255), IM_COL32(6, 7, 9, 255), IM_COL32(6, 7, 9, 255));
    ImVec2 pos, size;
    usable_rect(&pos, &size);
    ImGui::SetNextWindowPos(pos);
    ImGui::SetNextWindowSize(size);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
    ImGui::Begin("##games", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
    ImGui::PopStyleColor();
    float f = em(), gap = f * 1.4f;
    int n = g_pick_n;
    float cw = fminf(f * 19, (size.x - gap * (n + 1)) / n), ih = cw * 9 / 16, chh = ih + f * 3.6f;
    float total_h = g_title->FontSize + f * 1.6f + chh;
    float y0 = fmaxf(f, (size.y - total_h) * 0.5f);
    const char *head = "Choose a game";
    ImVec2 hs = g_title->CalcTextSizeA(g_title->FontSize, FLT_MAX, 0, head);
    ImDrawList *dl = ImGui::GetWindowDrawList();
    dl->AddText(g_title, g_title->FontSize, ImVec2(pos.x + (size.x - hs.x) * 0.5f, pos.y + y0), col(C_TEXT), head);
    float x0 = (size.x - (n * cw + (n - 1) * gap)) * 0.5f, cy = y0 + g_title->FontSize + f * 1.6f, rr = f * 0.9f;
    bool focused = false;
    for (int i = 0; i < n; i++) {
        ImGui::SetCursorPos(ImVec2(x0 + i * (cw + gap), cy));
        ImGui::PushID(i);
        ImVec2 a = ImGui::GetCursorScreenPos(), b(a.x + cw, a.y + chh);
        ImGui::BeginDisabled(!g_pick_playable[i]);
        if (ImGui::InvisibleButton("##game", ImVec2(cw, chh))) g_picked = i;
        if (g_pick_playable[i] && !focused) { ImGui::SetItemDefaultFocus(); focused = true; }
        bool hot = ImGui::IsItemHovered() || ImGui::IsItemFocused();
        ImGui::EndDisabled();
        dl->AddRectFilled(a, b, col(C_CARD), rr);
        draw_cover(dl, a, ImVec2(b.x, a.y + ih), g_pick_covers ? g_pick_covers[i] : NULL, g_pick_titles[i], rr,
                   ImDrawFlags_RoundCornersTop, g_pick_playable[i] ? 0 : 0.6f);
        ImGui::PushClipRect(a, b, true);
        dl->AddText(g_bold, f * 1.15f, ImVec2(a.x + f * 0.9f, a.y + ih + f * 0.7f), col(g_pick_playable[i] ? C_TEXT : C_MUTED), g_pick_titles[i]);
        dl->AddText(g_small, g_small->FontSize, ImVec2(a.x + f * 0.9f, a.y + ih + f * 2.1f), col(C_MUTED), g_pick_details[i]);
        ImGui::PopClipRect();
        if (hot && g_pick_playable[i]) dl->AddRect(a, b, col(C_ACCENT), rr, 0, f * 0.18f);
        ImGui::PopID();
    }
    const char *tip = MENU_TOUCH ? "Tap a game to play it, or choose it with a controller." : "Click a game to play it, or choose it with a controller.";
    ImVec2 tsz = g_small->CalcTextSizeA(g_small->FontSize, FLT_MAX, 0, tip);
    dl->AddText(g_small, g_small->FontSize, ImVec2(pos.x + (size.x - tsz.x) * 0.5f, pos.y + cy + chh + f * 1.4f), col(C_MUTED), tip);
    ImGui::End();
}

// ---- the loading screen: from a game's pick to its first frame, its cover dimmed behind its name and a spinner
static pthread_t g_loading_thread;
static char g_loading_title[160], g_loading_cover[1100], g_loading_text[200];
static std::mutex g_loading_mx;  // (the status text: set from any thread)
static double g_loading_t0;
static void draw_loading(void) {
    ImGuiViewport *vp = ImGui::GetMainViewport();
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    ImVec2 a = vp->Pos, b(vp->Pos.x + vp->Size.x, vp->Pos.y + vp->Size.y);
    dl->AddRectFilled(a, b, IM_COL32(6, 7, 9, 255));
    double t = CACurrentMediaTime() - g_loading_t0;
    float in = (float)fmin(t / 0.6, 1);  // (a fade in)
    draw_cover(dl, a, b, g_loading_cover, g_loading_title, 0, 0, 1 - 0.38f * in, false);
    dl->AddRectFilledMultiColor(ImVec2(a.x, a.y + vp->Size.y * 0.45f), b, IM_COL32(0, 0, 0, 0), IM_COL32(0, 0, 0, 0),
                                IM_COL32(0, 0, 0, 200), IM_COL32(0, 0, 0, 200));
    float f = em(), cx = a.x + vp->Size.x * 0.5f, cy = a.y + vp->Size.y * 0.5f;
    ImVec2 ts = g_title->CalcTextSizeA(g_title->FontSize, FLT_MAX, 0, g_loading_title);
    dl->AddText(g_title, g_title->FontSize, ImVec2(cx - ts.x * 0.5f, cy - ts.y - f * 1.2f), col(C_TEXT, in), g_loading_title);
    float r = f * 1.1f, th = f * 0.22f, sy = cy + f * 0.9f;
    dl->AddCircle(ImVec2(cx, sy), r, IM_COL32(255, 255, 255, (int)(40 * in)), 48, th);
    float a0 = (float)fmod(t * 4.2, 2 * M_PI), len = 1.6f + 0.9f * (float)sin(t * 2.1);
    dl->PathArcTo(ImVec2(cx, sy), r, a0, a0 + len, 32);
    dl->PathStroke(col(C_ACCENT, in), 0, th);
    char text[200];
    { std::lock_guard<std::mutex> lk(g_loading_mx); snprintf(text, sizeof text, "%s", g_loading_text); }
    ImVec2 ss = g_small->CalcTextSizeA(g_small->FontSize, FLT_MAX, 0, text);
    dl->AddText(g_small, g_small->FontSize, ImVec2(cx - ss.x * 0.5f, sy + r + f * 1.1f), col(C_MUTED, in), text);
}
static void *loading_main(void *arg) {
    (void)arg;
    pthread_setname_np("nx loading screen");
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    while (!g_loading_stop) {
        @autoreleasepool {
            id<CAMetalDrawable> d = [layer nextDrawable];
            if (!d) continue;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = d.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            menu_render(dev, cb, d.texture);
            [cb presentDrawable:d];
            [cb commit];
            [cb waitUntilScheduled];
        }
    }
    return NULL;
}
extern "C" void menu_loading_status(const char *status) {
    std::lock_guard<std::mutex> lk(g_loading_mx);
    snprintf(g_loading_text, sizeof g_loading_text, "%s", status ? status : "");
}
extern "C" void menu_loading_begin(const char *title, const char *cover) {
    if (g_loading || !ui_metal_layer()) return;
    snprintf(g_loading_title, sizeof g_loading_title, "%s", title ? title : "");
    snprintf(g_loading_cover, sizeof g_loading_cover, "%s", cover ? cover : "");
    menu_loading_status("Loading");
    int pw, ph;  // (the main thread's: the layer's size before the game's loop sets it)
    SDL_GetWindowSizeInPixels(ui_window(), &pw, &ph);
    ((__bridge CAMetalLayer *)ui_metal_layer()).drawableSize = CGSizeMake(pw, ph);
    g_loading_t0 = CACurrentMediaTime();
    g_loading_stop = false;
    g_loading = true;
    if (pthread_create(&g_loading_thread, NULL, loading_main, NULL)) g_loading = false;
}
extern "C" void menu_loading_end(void) {
    if (!g_loading) return;
    if (const char *e = getenv("LARECOMP_LOADING_HOLD"))  // (tests) the loading screen stays at least that many seconds
        while (CACurrentMediaTime() - g_loading_t0 < atof(e)) usleep(20000);
    g_loading_stop = true;
    pthread_join(g_loading_thread, NULL);
    g_loading = false;
    fprintf(stderr, "[menu] loading screen: %.1f s\n", CACurrentMediaTime() - g_loading_t0);
}

// (main thread, before a game boots: no game draws) the selection screen until a game is picked; its index
extern "C" int menu_pick_game(int n, const char *const titles[], const char *const details[], const char *const covers[],
                              const bool playable[]) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    SDL_Window *w = ui_window();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    g_pick_n = n, g_pick_titles = titles, g_pick_details = details, g_pick_covers = covers, g_pick_playable = playable, g_picked = -1;
    g_picking = true;
    const char *auto_pick = getenv("LARECOMP_PICK_GAME");  // (tests) that game's index, after that many frames: "1@120"
    int auto_k = -1, auto_at = 0, frame = 0;
    if (auto_pick) sscanf(auto_pick, "%d@%d", &auto_k, &auto_at);
    while (g_picked < 0) {
        @autoreleasepool {
            SDL_Event e;
            while (SDL_PollEvent(&e)) {
                if (e.type == SDL_EVENT_QUIT) exit(0);
                if (e.type == SDL_EVENT_GAMEPAD_ADDED || e.type == SDL_EVENT_GAMEPAD_REMOVED) input_handle_event(&e);
                menu_handle_event(&e);
            }
            menu_apply_window_requests(w);
            int pw, ph;
            SDL_GetWindowSizeInPixels(w, &pw, &ph);
            layer.drawableSize = CGSizeMake(pw, ph);
            id<CAMetalDrawable> d = [layer nextDrawable];
            if (!d) continue;
            id<MTLCommandBuffer> cb = [q commandBuffer];
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = d.texture;
            rp.colorAttachments[0].loadAction = MTLLoadActionClear;
            rp.colorAttachments[0].clearColor = MTLClearColorMake(0.035, 0.04, 0.05, 1);
            rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            [[cb renderCommandEncoderWithDescriptor:rp] endEncoding];
            menu_render(dev, cb, d.texture);
            [cb presentDrawable:d];
            [cb commit];
            if (auto_k >= 0 && auto_k < n && ++frame >= auto_at) g_picked = auto_k;
        }
    }
    g_picking = false;
    {   // (the game starts with nothing held or hovered from the screen)
        std::lock_guard<std::recursive_mutex> lk(g_mx);
        ImGuiIO &io = ImGui::GetIO();
        io.AddMousePosEvent(-FLT_MAX, -FLT_MAX);
        io.ClearInputKeys();
    }
    return g_picked;
}

#if MENU_TOUCH
// The menu button, at the top of the screen in the middle (clear of a game's corners), faint over the game
static void draw_menu_button(float width) {
    float w = 44 * g_density, h = 30 * g_density, top = fmaxf((float)g_safe[1], 6 * g_density), gap = 14 * g_density;
    ImVec2 a(width * 0.5f - w * 0.5f, top), b(a.x + w, a.y + h);
    g_button[0] = a.x, g_button[1] = a.y, g_button[2] = b.x, g_button[3] = b.y, g_button_gap = gap;
    ImDrawList *dl = ImGui::GetForegroundDrawList();
    ImU32 bg = IM_COL32(20, 22, 26, 90), fg = IM_COL32(235, 240, 245, 150);
    float lw = w * 0.42f, t = fmaxf(1.5f * g_density, 1), cx = (a.x + b.x) * 0.5f, cy = (a.y + b.y) * 0.5f;
    if (double v = button_visibility(); v > 0) {  // (the menu's: only while the screen is touched)
        dl->AddRectFilled(a, b, IM_COL32(20, 22, 26, (int)(90 * v)), h * 0.5f);
        for (int i = -1; i <= 1; i++)
            dl->AddLine(ImVec2(cx - lw * 0.5f, cy + i * h * 0.2f), ImVec2(cx + lw * 0.5f, cy + i * h * 0.2f),
                        IM_COL32(235, 240, 245, (int)(150 * v)), t);
    }
    if (!g_pad_buttons) return;
    for (int side = -1; side <= 1; side += 2) {  // Minus, Plus (the on-screen controller has neither)
        float x = cx + side * (w + gap);
        dl->AddRectFilled(ImVec2(x - w * 0.5f, a.y), ImVec2(x + w * 0.5f, b.y), bg, h * 0.5f);
        float r = h * 0.22f;
        dl->AddLine(ImVec2(x - r, cy), ImVec2(x + r, cy), fg, t * 1.4f);
        if (side > 0) dl->AddLine(ImVec2(x, cy - r), ImVec2(x, cy + r), fg, t * 1.4f);
    }
}
#endif

extern "C" void menu_render(id<MTLDevice> dev, id<MTLCommandBuffer> cb, id<MTLTexture> target) {
    {   // (tests) LARECOMP_MENU_TEST_TIME=<seconds>: the clock moved that far while open; LARECOMP_MENU_CLOSE_MS=<ms>: closed
        // that long after it opened (a paused game takes no scripted input)
        static double opened;
        static int done;
        if (g_open && !opened) {
            opened = CACurrentMediaTime();
            if (getenv("LARECOMP_MENU_TEST_TIME") && !done++) {
                g_settings.time_offset += atoll(getenv("LARECOMP_MENU_TEST_TIME"));
                time_offset_changed();
            }
        }
        if (!g_open) opened = 0;
        if (g_open && getenv("LARECOMP_MENU_CLOSE_MS") && (CACurrentMediaTime() - opened) * 1000 > atof(getenv("LARECOMP_MENU_CLOSE_MS")))
            set_open(false);
    }
    bool open = g_open, fps = g_settings.show_fps, loading = g_loading;
    if (!open && !fps && !MENU_TOUCH && !g_picking && !loading) return;
    std::lock_guard<std::recursive_mutex> lk(g_mx);
    ensure_context();
    g_dev = dev;
    ImGuiIO &io = ImGui::GetIO();
    float scale = fmaxf(1.0f, roundf(target.height / 900.0f * 4) / 4);
#if MENU_TOUCH  // (in points: a phone's 15, an iPad's 18 - the same size whatever the screen's pixels)
    float points = target.height / fmaxf(g_density, 1);
    scale = roundf(g_density * (points < 600 ? 0.9f : 1.05f) * 4) / 4;
#endif
    if (!g_inited || scale != g_scale) {
        if (g_inited) ImGui_ImplMetal_DestroyFontsTexture();
        setup_fonts(scale);
        setup_style(scale);
        if (!g_inited) ImGui_ImplMetal_Init(dev);
        else ImGui_ImplMetal_CreateFontsTexture(dev);
        g_inited = true;
        g_scale = scale;
#if MENU_TOUCH
        g_font_px = 17.0f * scale;
#endif
    }
    static double last;
    double now = CACurrentMediaTime();
    io.DeltaTime = last > 0 && now > last ? (float)fmin(now - last, 0.1) : 1 / 60.0f;
    last = now;
    io.DisplaySize = ImVec2((float)target.width, (float)target.height);
    io.DisplayFramebufferScale = ImVec2(1, 1);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = target;
    rp.colorAttachments[0].loadAction = MTLLoadActionLoad;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    ImGui_ImplMetal_NewFrame(rp);
    ImGui::NewFrame();
    g_popup = false;
    if (loading) draw_loading();
    else if (g_picking) draw_picker();
    else if (open) draw_menu();
    if (fps && !g_picking && !loading) draw_fps();
#if MENU_TOUCH
    if (!open && !g_picking && !loading) draw_menu_button(target.width);
#endif
    g_text_input = io.WantTextInput;
    ImGui::Render();
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rp];
    ImGui_ImplMetal_RenderDrawData(ImGui::GetDrawData(), cb, enc);
    [enc endEncoding];
}

#else  // (Windows / Linux: no menu yet - F11 toggles fullscreen)
#include <SDL3/SDL.h>
#include <atomic>
#include <string.h>

extern "C" {
#include "../settings.h"
}

#define DREADRECOMP_VERSION "0.0.1-dev"
static std::atomic<bool> g_want_fullscreen_apply{true};
extern "C" {
const char *larecomp_version(void) { return DREADRECOMP_VERSION; }
bool menu_is_open(void) { return false; }
void menu_loading_begin(const char *title, const char *cover) { (void)title, (void)cover; }
void menu_loading_status(const char *status) { (void)status; }
void menu_loading_end(void) {}
bool menu_input_captured(void) { return false; }
bool menu_pauses_game(void) { return false; }
void menu_test_open(void) {}
int menu_keyboard_run(const char *initial, int max_len, char *out, int cap) {
    (void)max_len;
    snprintf(out, cap, "%s", initial ? initial : "");
    return 1;
}
bool menu_handle_event(const SDL_Event *e) {
    if (e->type == SDL_EVENT_KEY_DOWN && e->key.key == SDLK_F11 && !e->key.repeat) {
        g_settings.fullscreen = !g_settings.fullscreen;
        g_want_fullscreen_apply = true;
        return true;
    }
    return false;
}
extern uint32_t g_window_resize_request;
void menu_apply_window_requests(void *win) {
    SDL_Window *w = (SDL_Window *)win;
    if (g_want_fullscreen_apply.exchange(false)) SDL_SetWindowFullscreen(w, g_settings.fullscreen);
    if (uint32_t r = __atomic_exchange_n(&g_window_resize_request, 0u, __ATOMIC_RELAXED))
        SDL_SetWindowSize(w, (int)(r >> 16), (int)(r & 0xffff));
}
void menu_render(void *cmd, uint32_t target_w, uint32_t target_h) { (void)cmd, (void)target_w, (void)target_h; }
}
#endif
