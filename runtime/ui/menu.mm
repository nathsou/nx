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
// The game selection screen (menu_pick_game, main thread): its games, and the one picked
static bool g_picking;
static int g_pick_n, g_picked = -1;
static const char *const *g_pick_titles, *const *g_pick_details;
static const bool *g_pick_playable;

extern "C" {

const char *larecomp_version(void) { return DREADRECOMP_VERSION; }

bool menu_is_open(void) { return g_open; }
bool menu_input_captured(void) { return g_open; }
bool menu_pauses_game(void) { return g_open && g_settings.menu_pause && !rt_reboot_requested(); }

static void set_open(bool on) {
    if (g_open == on) return;
    g_open = on;
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
    touch_pad_update(g_open || g_picking);
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

typedef void (*ResetFn)(void);
static void menu_reset(void) {  // (runtime/main.c's reboot: every guest thread has stopped)
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
    g_backups_listed = -1;
}
__attribute__((used, section("__DATA,__rt_reset"))) static const ResetFn menu_reset_entry = menu_reset;

// ------------------------------------------------------------------ drawing (render thread)
static bool g_inited;
static float g_scale;  // the UI's size: the window's height over 900 points' worth
static void setup_style(float scale) {
    ImGuiStyle &st = ImGui::GetStyle();
    st = ImGuiStyle();
    ImGui::StyleColorsDark();
    st.WindowRounding = 10, st.FrameRounding = 6, st.GrabRounding = 6, st.TabRounding = 6, st.PopupRounding = 8;
    st.WindowPadding = ImVec2(18, 14), st.FramePadding = ImVec2(10, 6), st.ItemSpacing = ImVec2(10, 8);
#if MENU_TOUCH  // (fingers: taller rows and scroll bars, a margin around what can be touched)
    st.FramePadding = ImVec2(14, 11), st.ItemSpacing = ImVec2(12, 10), st.ItemInnerSpacing = ImVec2(10, 6);
    st.ScrollbarSize = 22, st.GrabMinSize = 26, st.TouchExtraPadding = ImVec2(4, 4), st.TabBarBorderSize = 2;
    st.WindowPadding = ImVec2(20, 16);
#endif
    ImVec4 *c = st.Colors;
    c[ImGuiCol_WindowBg] = ImVec4(0.08f, 0.09f, 0.11f, 0.96f);
    c[ImGuiCol_PopupBg] = ImVec4(0.10f, 0.11f, 0.14f, 0.98f);
    c[ImGuiCol_Header] = ImVec4(0.20f, 0.45f, 0.35f, 0.55f);
    c[ImGuiCol_HeaderHovered] = ImVec4(0.24f, 0.55f, 0.42f, 0.80f);
    c[ImGuiCol_HeaderActive] = ImVec4(0.26f, 0.62f, 0.47f, 1.00f);
    c[ImGuiCol_Button] = ImVec4(0.20f, 0.45f, 0.35f, 0.60f);
    c[ImGuiCol_ButtonHovered] = ImVec4(0.24f, 0.55f, 0.42f, 1.00f);
    c[ImGuiCol_ButtonActive] = ImVec4(0.26f, 0.62f, 0.47f, 1.00f);
    c[ImGuiCol_Tab] = ImVec4(0.16f, 0.30f, 0.25f, 0.85f);
    c[ImGuiCol_TabHovered] = ImVec4(0.24f, 0.55f, 0.42f, 1.00f);
    c[ImGuiCol_TabSelected] = ImVec4(0.22f, 0.50f, 0.39f, 1.00f);
    c[ImGuiCol_FrameBg] = ImVec4(0.16f, 0.18f, 0.21f, 1.00f);
    c[ImGuiCol_FrameBgHovered] = ImVec4(0.21f, 0.24f, 0.28f, 1.00f);
    c[ImGuiCol_CheckMark] = ImVec4(0.45f, 0.85f, 0.65f, 1.00f);
    c[ImGuiCol_SliderGrab] = ImVec4(0.45f, 0.85f, 0.65f, 1.00f);
    c[ImGuiCol_NavCursor] = ImVec4(0.45f, 0.85f, 0.65f, 1.00f);
    st.ScaleAllSizes(scale);
}
static const char *font_path(const char *file) {
    static char p[1024];
    snprintf(p, sizeof p, "third_party/fonts/DejaVu/%s", file);
    if (access(p, R_OK) == 0) return p;
    NSString *r = [[NSBundle mainBundle] pathForResource:@(file) ofType:nil];  // (the app: Contents/Resources)
    return r ? r.UTF8String : NULL;
}
static void setup_fonts(float scale) {
    ImGuiIO &io = ImGui::GetIO();
    io.Fonts->Clear();
    ImFontConfig fc;
    fc.OversampleH = 2;
    const char *p = font_path("DejaVuSans.ttf");
    if (p) io.Fonts->AddFontFromFileTTF(p, 17.0f * scale, &fc);
    else io.Fonts->AddFontDefault();
}

static void help(const char *text) {
    ImGui::PushStyleColor(ImGuiCol_Text, ImVec4(0.62f, 0.66f, 0.70f, 1));
    ImGui::PushTextWrapPos(0);
    ImGui::TextUnformatted(text);
    ImGui::PopTextWrapPos();
    ImGui::PopStyleColor();
}
static bool combo(const char *label, int *v, const char *const *names, const int *values, int n) {
    int cur = 0;
    for (int i = 0; i < n; i++) if (values[i] == *v) cur = i;
    bool changed = false;
    if (ImGui::BeginCombo(label, names[cur])) {
        for (int i = 0; i < n; i++)
            if (ImGui::Selectable(names[i], i == cur)) { *v = values[i]; changed = true; }
        ImGui::EndCombo();
    }
    return changed;
}
static bool confirm(const char *id, const char *text, const char *yes) {  // (a modal: true when confirmed)
    bool ok = false;
    ImGui::SetNextWindowPos(ImGui::GetMainViewport()->GetCenter(), ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    if (ImGui::BeginPopupModal(id, NULL, ImGuiWindowFlags_AlwaysAutoResize)) {
        g_popup = true;
        ImGui::PushTextWrapPos(ImGui::GetFontSize() * 28);
        ImGui::TextUnformatted(text);
        ImGui::PopTextWrapPos();
        ImGui::Spacing();
        if (ImGui::Button(yes)) { ok = true; ImGui::CloseCurrentPopup(); }
        ImGui::SameLine();
        if (ImGui::Button("Cancel") || ImGui::IsKeyPressed(ImGuiKey_Escape)) ImGui::CloseCurrentPopup();
        ImGui::EndPopup();
    }
    return ok;
}

static void tab_game(void) {
    ImGui::Text("%s", menu_game_name());
    help(g_settings.menu_pause ? "The game is paused while this menu is open." : "The game keeps running while this menu is open.");
    ImGui::Spacing();
    if (ImGui::Button("Resume")) set_open(false);
    ImGui::SameLine();
    if (ImGui::Button("Restart game")) ImGui::OpenPopup("Restart?");
#if !MENU_TOUCH  // (an iOS app doesn't quit itself: the app switcher closes it)
    ImGui::SameLine();
    if (ImGui::Button("Quit")) ImGui::OpenPopup("Quit?");
#endif
#if MENU_TOUCH
    if (g_game_count > 1) {
        ImGui::SameLine();
        if (ImGui::Button("Switch game")) ImGui::OpenPopup("Switch game?");
    }
    if (confirm("Switch game?", "Go back to the game selection? Progress since the game last saved is lost.", "Switch game")) {
        set_open(false);
        rt_request_reboot(REBOOT_TITLE);
    }
#endif
    if (confirm("Restart?", "Restart the game? Progress since the game last saved is lost.", "Restart")) {
        set_open(false);
        rt_request_reboot(REBOOT_GAME);
    }
    if (confirm("Quit?", "Quit? Progress since the game last saved is lost.", "Quit")) {
        SDL_Event q = {};
        q.type = SDL_EVENT_QUIT;
        SDL_PushEvent(&q);
    }
    ImGui::Spacing();
    ImGui::SeparatorText("Menu");
    if (ImGui::Checkbox("Pause the game while this menu is open", &g_settings.menu_pause)) settings_save();
#if MENU_TOUCH
    help("Open this menu with the button at the top of the screen (touch the screen to show it), or Home - or Minus "
         "and Plus together - on a controller (F1 or Esc on a keyboard).");
#else
    help("Open and close this menu with F1 or Esc, or Home - or Minus and Plus together - on a controller.");
#endif
}

static void tab_saves(void) {
    double now = ImGui::GetTime();
    if (g_backups_listed < 0 || now - g_backups_listed > 5) { list_backups(); g_backups_listed = now; }
    std::error_code ec;
    fs::path root = fs::absolute(save_root(), ec);
    help("The game saves into the folders below (it writes them when it saves, as on a Switch). A backup is a copy of "
         "them; restoring one copies it back and restarts the game, after backing up the current save first.");
    ImGui::Spacing();
    time_t newest = 0;
    uintmax_t bytes = 0;
    int mounts = 0;
    for (auto &d : fs::directory_iterator(save_root(), ec))
        if (is_mount(d)) { bytes += dir_bytes(d.path(), &newest); mounts++; }
    ImGui::SeparatorText("Current save");
    if (mounts) ImGui::Text("Last written %s  (%s)", format_time(newest).c_str(), human_bytes(bytes).c_str());
    else ImGui::TextUnformatted("No save yet.");
    ImGui::PushStyleColor(ImGuiCol_Text, ImGui::GetStyle().Colors[ImGuiCol_TextDisabled]);
    ImGui::TextWrapped("%s", root.c_str());
    ImGui::PopStyleColor();
#if MENU_TOUCH
    if (ImGui::Button("Show in the Files app")) {  // (shareddocuments://<path>: the Files app, at that folder)
        NSString *path = @(root.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{
            NSURL *u = [NSURL URLWithString:[@"shareddocuments://" stringByAppendingString:
                                             [path stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet]]];
            [UIApplication.sharedApplication openURL:u options:@{} completionHandler:nil];
        });
    }
#else
    if (ImGui::Button("Open the saves folder")) {
        NSString *path = @(root.c_str());
        dispatch_async(dispatch_get_main_queue(), ^{ [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:path]]; });
    }
#endif
    ImGui::SeparatorText("Backups");
    static char label[64];
    ImGui::SetNextItemWidth(ImGui::GetFontSize() * 14);
    ImGui::InputTextWithHint("##label", "name (optional)", label, sizeof label);
    ImGui::SameLine();
    if (ImGui::Button("Back up now")) {
        fs::path made;
        std::string err = back_up(label, &made);
        g_status = err.empty() ? "Backed up to " + made.filename().string() : "Backup failed: " + err;
        label[0] = 0;
        g_backups_listed = -1;
    }
    if (!g_status.empty()) help(g_status.c_str());
    static int pick = -1;
    if (g_backups.empty()) help("No backups yet. (Copies of save folders put in backups/ appear here too.)");
    else if (ImGui::BeginTable("backups", 4, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH | ImGuiTableFlags_SizingStretchProp)) {
        ImGui::TableSetupColumn("Name", ImGuiTableColumnFlags_WidthStretch, 3);
        ImGui::TableSetupColumn("Date", ImGuiTableColumnFlags_WidthStretch, 2);
        ImGui::TableSetupColumn("Size", ImGuiTableColumnFlags_WidthStretch, 1);
        ImGui::TableSetupColumn("", ImGuiTableColumnFlags_WidthFixed);
        ImGui::TableHeadersRow();
        for (int i = 0; i < (int)g_backups.size(); i++) {
            const Backup &b = g_backups[i];
            ImGui::PushID(i);
            ImGui::TableNextRow();
            ImGui::TableNextColumn(); ImGui::TextUnformatted(b.name.c_str());
            ImGui::TableNextColumn(); ImGui::TextUnformatted(format_time(b.when).c_str());
            ImGui::TableNextColumn(); ImGui::TextUnformatted(human_bytes(b.bytes).c_str());
            ImGui::TableNextColumn();
            if (ImGui::SmallButton("Restore")) { pick = i; ImGui::OpenPopup("Restore?"); }
            ImGui::SameLine();
            if (ImGui::SmallButton("Delete")) { pick = i; ImGui::OpenPopup("Delete?"); }
            if (pick == i) {
                std::string q = "Restore \"" + b.name + "\"? The game restarts with it. Your current save is backed up first.";
                if (confirm("Restore?", q.c_str(), "Restore and restart")) {
                    g_restore_from = fs::absolute(b.path, ec);
                    g_restore_root = fs::absolute(save_root(), ec);
                    set_open(false);
                    rt_request_reboot(REBOOT_GAME);
                }
                std::string d = "Delete the backup \"" + b.name + "\"? This can't be undone.";
                if (confirm("Delete?", d.c_str(), "Delete")) {
                    fs::remove_all(b.path, ec);
                    g_status = ec ? "Could not delete: " + ec.message() : "Deleted " + b.name;
                    g_backups_listed = -1;
                }
            }
            ImGui::PopID();
        }
        ImGui::EndTable();
    }
}

static void tab_time(void) {
    time_t game = (time_t)time_game_now();
    ImGui::Text("The game's clock:  %s", format_time(game, "%A %d %B %Y, %H:%M:%S").c_str());
    help("Games that follow the time of day (Animal Crossing's seasons, shops, visitors) see this clock. Animal Crossing "
         "reads it when it starts, as on a Switch: restart the game after changing it. It treats a jump as time travel.");
    ImGui::Spacing();
    bool custom = g_settings.time_offset != 0;
    if (ImGui::RadioButton(MENU_TOUCH ? "This device's date and time" : "This Mac's date and time", !custom) && custom) {
        g_settings.time_offset = 0;
        settings_save();
        time_offset_changed();
    }
    ImGui::SameLine();
    ImGui::RadioButton("A date and time of my own", custom);
    static int y, mo, d, h, mi;
    static time_t shown = -1;
    if (shown != game / 60) {  // (the fields follow the clock until edited)
        struct tm tm;
        localtime_r(&game, &tm);
        y = tm.tm_year + 1900, mo = tm.tm_mon + 1, d = tm.tm_mday, h = tm.tm_hour, mi = tm.tm_min;
        shown = game / 60;
    }
    ImGui::SeparatorText("Set the game's clock");
    float w = ImGui::GetFontSize() * 7.5f;
    ImGui::SetNextItemWidth(w * 1.2f); bool e1 = ImGui::InputInt("Year", &y, 1);
    ImGui::SameLine(); ImGui::SetNextItemWidth(w); bool e2 = ImGui::InputInt("Month", &mo, 1);
    ImGui::SameLine(); ImGui::SetNextItemWidth(w); bool e3 = ImGui::InputInt("Day", &d, 1);
    ImGui::SetNextItemWidth(w * 1.2f); bool e4 = ImGui::InputInt("Hour", &h, 1);
    ImGui::SameLine(); ImGui::SetNextItemWidth(w); bool e5 = ImGui::InputInt("Minute", &mi, 1);
    if (e1 || e2 || e3 || e4 || e5) shown = -2;  // (being edited: kept)
    y = y < 2000 ? 2000 : y > 2060 ? 2060 : y, mo = mo < 1 ? 1 : mo > 12 ? 12 : mo, d = d < 1 ? 1 : d > 31 ? 31 : d;
    h = h < 0 ? 0 : h > 23 ? 23 : h, mi = mi < 0 ? 0 : mi > 59 ? 59 : mi;
    auto set_to = [&](time_t target) {
        g_settings.time_offset = (long long)(target - time(NULL));
        settings_save();
        time_offset_changed();
        shown = -1;
    };
    if (ImGui::Button("Set the clock")) {
        struct tm tm = {};
        tm.tm_year = y - 1900, tm.tm_mon = mo - 1, tm.tm_mday = d, tm.tm_hour = h, tm.tm_min = mi, tm.tm_isdst = -1;
        set_to(mktime(&tm));
    }
    ImGui::SameLine();
    if (ImGui::Button("-1 day")) set_to(game - 86400);
    ImGui::SameLine();
    if (ImGui::Button("+1 day")) set_to(game + 86400);
    ImGui::SameLine();
    if (ImGui::Button("-1 hour")) set_to(game - 3600);
    ImGui::SameLine();
    if (ImGui::Button("+1 hour")) set_to(game + 3600);
    ImGui::Spacing();
    if (ImGui::Button("Restart the game with this clock")) ImGui::OpenPopup("Restart now?");
    if (confirm("Restart now?", "Restart the game? Progress since the game last saved is lost.", "Restart")) {
        set_open(false);
        rt_request_reboot(REBOOT_GAME);
    }
}

static void tab_video(void) {
    bool changed = false;
    ImGui::SeparatorText(MENU_TOUCH ? "Screen" : "Window");
#if !MENU_TOUCH
    if (ImGui::Checkbox("Fullscreen (F11)", &g_settings.fullscreen)) { g_want_fullscreen_apply = true; changed = true; }
#endif
    {
        static const char *const n[] = {"Fill the window", "16:9 with bars"};
        static const int v[] = {ASPECT_UNLOCKED, ASPECT_ORIGINAL};
        changed |= combo("Shape", &g_settings.aspect, n, v, 2);
    }
    ImGui::SeparatorText("Image");
    {
        static const char *const n[] = {"Match the window", "1080p (1x)", "4K (2x)", "3x", "4x", "Dynamic", "75% of the window",
                                        "50% of the window", "25% of the window"};
        static const int v[] = {RES_MATCH, 1, 2, 3, 4, RES_DYNAMIC, RES_Q75, RES_Q50, RES_Q25};
        if (combo("Resolution", &g_settings.res_mode, n, v, 9)) g_settings.res_auto = false, changed = true;
        help("What the game is drawn at. The game lays out its screen for 1080p: higher draws it sharper, not smaller.");
    }
    {
        static const char *const n[] = {"Bilinear", "MetalFX"};
        static const int v[] = {UPSCALE_BILINEAR, UPSCALE_METALFX};
        if (combo("Upscaler", &g_settings.upscaler, n, v, HAVE_METALFX ? 2 : 1)) g_settings.upscaler_auto = false, changed = true;
        static const char *const an[] = {"Off", "SMAA"};
        static const int av[] = {AA_OFF, AA_SMAA};
        changed |= combo("Anti-aliasing", &g_settings.antialias, an, av, 2);
    }
    ImGui::SeparatorText("Frame rate");
    {
        static const char *const n[] = {"The display's refresh rate", "120 fps", "60 fps", "30 fps"};
        static const int v[] = {0, 120, 60, 30};
        changed |= combo("Limit", &g_settings.fps_cap, n, v, 4);
        help("For games that run at the display's rate (Metroid Dread). Animal Crossing runs at 30 fps: frame "
             "generation shows it at 60 or 120.");
        static const char *const fn[] = {"Off", "60 fps", "120 fps"};
        static const int fv[] = {0, 60, 120};
        changed |= combo("Frame generation", &g_settings.frame_gen, fn, fv, 3);
        int method = g_settings.frame_gen_flow ? 1 : 0;
        static const char *const mn[] = {"MetalFX (motion vectors)", "Optical flow"};
        static const int mv[] = {0, 1};
        if (HAVE_METALFX && combo("Method", &method, mn, mv, 2)) g_settings.frame_gen_flow = method == 1, changed = true;
        help("Images between a 30 fps game's frames: smoother motion, the game's speed unchanged, about a display frame "
             "of latency. MetalFX is cleaner (60 only); optical flow also does 120.");
        changed |= ImGui::Checkbox("Show the frame rate", &g_settings.show_fps);
    }
    if (changed) settings_save();
}

static void tab_audio(void) {
    float pct = g_settings.volume * 100;
    if (ImGui::SliderFloat("Volume", &pct, 0, 100, "%.0f%%")) g_settings.volume = pct / 100, settings_save();
    if (ImGui::Checkbox("Room reverb", &g_settings.reverb)) settings_save();
    help("The reverb of rooms and caves, as the game sets it.");
}

static void tab_controls(void) {
    static const char *const rows[][2] = {
        {"Left stick", "W A S D"}, {"D-pad", "Arrow keys"}, {"A / B / X / Y", "K / J / L / I"}, {"L / R", "Q / E"},
        {"ZL / ZR", "1 / 3"}, {"Plus / Minus", "Enter / Backspace"}, {"Stick clicks", "F / keypad 0"},
        {"Right stick", "Keypad 8 / 5 / 4 / 6"},
    };
#if MENU_TOUCH
    help("Play with a controller: pair it in Settings > Bluetooth (Xbox, PlayStation, Switch Pro and MFi controllers). "
         "A keyboard works too, with these keys (rebind them in nx.ini):");
#else
    help("The keyboard's default controls (rebind them in nx.ini). In a game's own text entry the keys type instead.");
#endif
    if (ImGui::BeginTable("keys", 2, ImGuiTableFlags_RowBg | ImGuiTableFlags_BordersInnerH)) {
        for (auto &r : rows) {
            ImGui::TableNextRow();
            ImGui::TableNextColumn(); ImGui::TextUnformatted(r[0]);
            ImGui::TableNextColumn(); ImGui::TextUnformatted(r[1]);
        }
        ImGui::EndTable();
    }
    ImGui::SeparatorText("Controller");
    bool changed = false;
#if MENU_TOUCH
    {
        static const char *const n[] = {"While no controller is connected", "Always", "Never"};
        static const int v[] = {TOUCH_PAD_AUTO, TOUCH_PAD_ALWAYS, TOUCH_PAD_NEVER};
        changed |= combo("On-screen controller", &g_settings.touch_pad, n, v, 3);
        help("Buttons over the game for playing by touch. Its bottom button is B, as on a Switch.");
    }
#endif
    changed |= ImGui::Checkbox("Vibration", &g_settings.rumble);
    static const char *const n[] = {"On the right (A, as on a Switch)", "At the bottom"};
    static const int v[] = {MENU_CONFIRM_GAME, MENU_CONFIRM_CONTROLLER};
    changed |= combo("Confirm in this menu", &g_settings.menu_confirm, n, v, 2);
    ImGui::SeparatorText("Language");
    int lang = g_settings.language;
    if (ImGui::BeginCombo("Game language", g_language_names[lang < N_LANGUAGES ? lang : 0])) {
        for (int i = 0; i < N_LANGUAGES; i++)
            if (ImGui::Selectable(g_language_names[i], i == lang)) g_settings.language = i, changed = true;
        ImGui::EndCombo();
    }
    help("The system language the game is told (it applies when the game restarts).");
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
    ImGui::SetNextWindowPos(ImVec2(12 * g_scale, 12 * g_scale));
    ImGui::SetNextWindowBgAlpha(0.55f);
    ImGui::Begin("##fps", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_AlwaysAutoResize | ImGuiWindowFlags_NoInputs |
                                    ImGuiWindowFlags_NoNav | ImGuiWindowFlags_NoFocusOnAppearing);
    if (shown > fps + 1) ImGui::Text("%.0f fps (%.0f shown)", fps, shown);
    else ImGui::Text("%.0f fps", fps);
    ImGui::End();
}

static void draw_menu(void) {
    ImGuiViewport *vp = ImGui::GetMainViewport();
    ImVec2 size(fminf(vp->Size.x * 0.9f, 980 * g_scale), fminf(vp->Size.y * 0.88f, 760 * g_scale));
    ImVec2 center = vp->GetCenter();
#if MENU_TOUCH  // (inside the safe area; a phone's short side all of it)
    if (g_safe[2] > 0) {
        ImVec2 o(g_safe[0], g_safe[1]), sa(g_safe[2], g_safe[3]);
        size = ImVec2(fminf(sa.x * 0.96f, 980 * g_scale), fminf(sa.y * 0.94f, 760 * g_scale));
        center = ImVec2(o.x + sa.x * 0.5f, o.y + sa.y * 0.5f);
    }
#endif
    ImGui::SetNextWindowPos(center, ImGuiCond_Always, ImVec2(0.5f, 0.5f));
    ImGui::SetNextWindowSize(size, ImGuiCond_Always);
    bool open = true;
    ImGui::Begin("nx", &open, ImGuiWindowFlags_NoResize | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoCollapse | ImGuiWindowFlags_NoSavedSettings);
    if (!open) set_open(false);
    ImGui::PushItemWidth(ImGui::GetFontSize() * 20);  // (the settings' fields: their labels beside them)
    // (test) LARECOMP_MENU_TABS_EVERY=<frames>: the next tab every that many frames (screenshots of each)
    static long every = -1, at;
    if (every < 0) every = getenv("LARECOMP_MENU_TABS_EVERY") ? atol(getenv("LARECOMP_MENU_TABS_EVERY")) : 0;
    int want = -1;
    if (every > 0) { uint64_t g, sh; renderer_frame_counts(&g, &sh); if (!at) at = (long)g; want = (int)(((long)g - at) / every) % 6; }
    static const char *const names[] = {"Game", "Saves", "Date & time", "Video", "Audio", "Controls"};
    static void (*const tabs[])(void) = {tab_game, tab_saves, tab_time, tab_video, tab_audio, tab_controls};
    if (ImGui::BeginTabBar("tabs")) {
        for (int i = 0; i < 6; i++)
            if (ImGui::BeginTabItem(names[i], NULL, want == i ? ImGuiTabItemFlags_SetSelected : 0)) {
                ImGui::BeginChild("##tab", ImVec2(0, 0), ImGuiChildFlags_NavFlattened);  // (scrolls under the tabs, which stay)
                tabs[i]();
                ImGui::EndChild();
                ImGui::EndTabItem();
            }
        ImGui::EndTabBar();
    }
    ImGui::PopItemWidth();
    ImGui::End();
}

// The game selection screen: a card for each game (one without its game code in the app can't be picked)
static void draw_picker(void) {
    ImGuiViewport *vp = ImGui::GetMainViewport();
    ImVec2 pos = vp->Pos, size = vp->Size;
#if MENU_TOUCH
    if (g_safe[2] > 0) pos = ImVec2(g_safe[0], g_safe[1]), size = ImVec2(g_safe[2], g_safe[3]);
#endif
    ImGui::SetNextWindowPos(pos);
    ImGui::SetNextWindowSize(size);
    ImGui::PushStyleColor(ImGuiCol_WindowBg, ImVec4(0, 0, 0, 0));
    ImGui::PushStyleVar(ImGuiStyleVar_WindowBorderSize, 0);
    ImGui::Begin("##games", NULL, ImGuiWindowFlags_NoDecoration | ImGuiWindowFlags_NoMove | ImGuiWindowFlags_NoSavedSettings);
    ImGui::PopStyleVar();
    ImGui::PopStyleColor();
    float fs = ImGui::GetFontSize(), cw = fminf(size.x * 0.8f, fs * 30), ch = fs * 4.2f;
    float total = fs * 4 + g_pick_n * (ch + fs);
    ImGui::SetCursorPosY(fmaxf(fs, (size.y - total) * 0.5f));
    ImGui::SetWindowFontScale(1.6f);
    float tw = ImGui::CalcTextSize("Choose a game").x;
    ImGui::SetCursorPosX((size.x - tw) * 0.5f);
    ImGui::TextUnformatted("Choose a game");
    ImGui::SetWindowFontScale(1);
    ImGui::Dummy(ImVec2(0, fs));
    ImGui::PushStyleVar(ImGuiStyleVar_FrameRounding, fs * 0.6f);
    bool focused = false;
    for (int i = 0; i < g_pick_n; i++) {
        ImGui::PushID(i);
        ImGui::SetCursorPosX((size.x - cw) * 0.5f);
        ImVec2 at = ImGui::GetCursorScreenPos();
        ImGui::BeginDisabled(!g_pick_playable[i]);
        if (ImGui::Button("##game", ImVec2(cw, ch))) g_picked = i;
        if (g_pick_playable[i] && !focused) { ImGui::SetItemDefaultFocus(); focused = true; }
        ImGui::EndDisabled();
        ImDrawList *dl = ImGui::GetWindowDrawList();  // (the title over the version: two sizes on one button)
        ImU32 text = ImGui::GetColorU32(g_pick_playable[i] ? ImGuiCol_Text : ImGuiCol_TextDisabled);
        ImFont *font = ImGui::GetFont();
        dl->AddText(font, fs * 1.3f, ImVec2(at.x + fs * 1.2f, at.y + ch * 0.5f - fs * 1.35f), text, g_pick_titles[i]);
        dl->AddText(font, fs, ImVec2(at.x + fs * 1.2f, at.y + ch * 0.5f + fs * 0.2f), ImGui::GetColorU32(ImGuiCol_TextDisabled),
                    g_pick_details[i]);
        ImGui::Dummy(ImVec2(0, fs * 0.4f));
        ImGui::PopID();
    }
    ImGui::PopStyleVar();
    ImGui::End();
}

extern "C" void *ui_metal_layer(void);
extern "C" void *ui_metal_device(void);
extern "C" SDL_Window *ui_window(void);
extern "C" void input_handle_event(const SDL_Event *e);

// (main thread, before a game boots: no game draws) the selection screen until a game is picked; its index
extern "C" int menu_pick_game(int n, const char *const titles[], const char *const details[], const bool playable[]) {
    id<MTLDevice> dev = (__bridge id<MTLDevice>)ui_metal_device();
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ui_metal_layer();
    SDL_Window *w = ui_window();
    id<MTLCommandQueue> q = [dev newCommandQueue];
    g_pick_n = n, g_pick_titles = titles, g_pick_details = details, g_pick_playable = playable, g_picked = -1;
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
    bool open = g_open, fps = g_settings.show_fps;
    if (!open && !fps && !MENU_TOUCH && !g_picking) return;
    std::lock_guard<std::recursive_mutex> lk(g_mx);
    ensure_context();
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
    if (g_picking) draw_picker();
    else if (open) draw_menu();
    if (fps && !g_picking) draw_fps();
#if MENU_TOUCH
    if (!open && !g_picking) draw_menu_button(target.width);
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
