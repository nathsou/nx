// Cloud saves (runtime/ui/cloud.mm): each device's save of each game in an S3-compatible bucket (Backblaze B2, ...),
// the newest one used at boot.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

// Main thread, in boot(): after the game is identified and the settings are loaded, before the game runs. A newer
// save of this game (same version) from any device replaces the local one, which is backed up first.
void cloud_boot(void);
// The save service, after a mount's commit (runtime/services/fs.c): an upload follows, unless more commits come.
void cloud_save_committed(void);
// Any thread: upload the save now if it changed (the menu opened, the app going to the background).
void cloud_flush(void);
// The game torn down (runtime/ui/menu.mm's reset, before it restores a backup): its save, if it changed, uploaded
void cloud_teardown(void);
// Quitting (main thread): upload the save if it changed and wait for the upload, for a few seconds at most.
void cloud_quit(void);
// The save service's lock: held while it commits, and while cloud saves read the save (runtime/services/fs.c)
void save_lock(void);
void save_unlock(void);

#ifdef __cplusplus
}
#include <ctime>
#include <filesystem>
#include <string>
#include <vector>

// The menu's Saves page (runtime/ui/menu.mm)
struct CloudSlot {
    std::string key, device, version;
    time_t saved = 0;
    unsigned long long size = 0;
    bool mine = false;       // this device's own upload
    bool same_game = false;  // the same version of the game as here (another one's save isn't used)
    bool current = false;    // the save here now
};
struct CloudView {
    bool configured = false, busy = false;
    std::string endpoint, bucket, key_id, status, error;
    float progress = -1;  // 0..1 during an upload / download, else -1
    time_t listed = 0;
    std::vector<CloudSlot> slots;
    std::filesystem::path fetched;  // a save downloaded for the menu to restore (cloud_fetch), once
};
CloudView cloud_view(void);
// "s3://<key ID>:<application key>@<endpoint>/<bucket>[/<folder>]": stored (the key's secret in the Keychain on iOS)
// and tested. false: why it can't be used.
bool cloud_connect(const std::string &connection, std::string *why);
void cloud_disconnect(void);
void cloud_refresh(void);     // the slots listed again (in the background)
void cloud_upload_now(void);  // the save uploaded (in the background), changed or not
// That slot's save downloaded into save/<game>/backups/ (in the background): CloudView::fetched when it's there
void cloud_fetch(const std::string &key);
// A backup was restored into root from the folder from (runtime/ui/menu.mm, the game down)
void cloud_restored(const std::filesystem::path &root, const std::filesystem::path &from);
// Copies the save's folders to backups/<date>[ - label] (runtime/ui/menu.mm): "" when it worked, else what went wrong
std::string saves_back_up(const std::string &label, std::filesystem::path *made, std::filesystem::path root);
#endif
