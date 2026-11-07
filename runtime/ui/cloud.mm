// Cloud saves: each device uploads its save of each game to an S3-compatible bucket (Backblaze B2, Cloudflare R2,
// MinIO, AWS), and a game's boot uses the newest save of that game any device uploaded.
//
// - One object per device and game: [<folder>/]<game>/<device id>.nxsave, the save's folders (save/<game>/save_0,
//   ...) as a tar compressed with zstd (its frames checksummed). A device only writes its own, so two devices never
//   overwrite each other's save. Its metadata (x-amz-meta-nx-*) says which device it is from, when it was saved, which
//   version of the game, and the tar's SHA-256, checked when it's downloaded.
// - Uploads: 30 s after the game's last commit (a save is several commits), at most one every 10 minutes while
//   playing, and at once when the menu opens, the app goes to the background, or the game restarts or quits.
// - At boot: the newest save of the same game version, if it is newer than the local one, replaces it after a backup
//   of the local one (save/<game>/backups/). A save from another version is never used: a newer version's save can
//   crash an older one.
// - save/<game>/.cloud: the local save's hash and when it was saved, as last uploaded or downloaded. A local save that
//   differs from it changed since (played offline): its time is that of its newest file.
// Credentials: the endpoint, the bucket and the application key's ID in nx.ini; the key's secret in the Keychain on
// iOS, in cloud.secret (owner-only) elsewhere. LARECOMP_CLOUD=<connection> (tests): that bucket, nothing stored;
// LARECOMP_CLOUD_DEVICE=<name>: another device's name and slot; LARECOMP_CLOUD_EVERY=<s>: uploads that often at most. The transport is NSURLSession on Apple's platforms, libcurl on Linux.
#include "cloud.h"

#include "s3.h"

#if defined(__APPLE__)
#include <TargetConditionals.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#if TARGET_OS_IPHONE
#import <UIKit/UIKit.h>
#endif
#endif
#if defined(__linux__)
#include <curl/curl.h>
#endif
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zstd.h>

#include <algorithm>
#include <chrono>
#include <condition_variable>
#include <cstring>
#include <deque>
#include <functional>
#include <map>
#include <mutex>
#include <random>
#include <thread>

extern "C" {
#include "../settings.h"
#include "../game.h"
#include "menu.h"
}

namespace fs = std::filesystem;

#if defined(__APPLE__) || defined(__linux__)  // (the transport, and the menu that restores a save)

// ------------------------------------------------------------------ the bucket
struct Conn { std::string scheme = "https", host, region, bucket, prefix, key_id, secret; };

static std::string pct_decode(const std::string &s) {
    std::string out;
    for (size_t i = 0; i < s.size(); i++) {
        if (s[i] == '%' && i + 2 < s.size() && isxdigit((unsigned char)s[i + 1]) && isxdigit((unsigned char)s[i + 2]))
            out += (char)strtol(s.substr(i + 1, 2).c_str(), NULL, 16), i += 2;
        else out += s[i];
    }
    return out;
}
// "https://s3.eu-central-003.backblazeb2.com" (or without https://): the host, and the region in its name
static void parse_endpoint(std::string e, Conn *c) {
    c->scheme = "https";
    if (!e.compare(0, 8, "https://")) e = e.substr(8);
    else if (!e.compare(0, 7, "http://")) e = e.substr(7), c->scheme = "http";
    while (!e.empty() && e.back() == '/') e.pop_back();
    c->host = e;
    c->region = "us-east-1";  // (MinIO's; Cloudflare R2 takes any)
    if (!e.compare(0, 3, "s3.")) {  // s3.<region>.backblazeb2.com, s3.<region>.amazonaws.com
        size_t dot = e.find('.', 3);
        if (dot != std::string::npos && e.find('.', dot + 1) != std::string::npos) c->region = e.substr(3, dot - 3);
    }
}
static bool parse_conn(std::string s, Conn *c, std::string *why) {
    s = s3::trim(s);
    while (!s.empty() && isspace((unsigned char)s.back())) s.pop_back();
    std::string scheme = "https";
    if (!s.compare(0, 5, "s3://")) s = s.substr(5);
    else if (!s.compare(0, 10, "s3+http://")) s = s.substr(10), scheme = "http";  // (a server on the local network)
    else { *why = "it should start with s3://"; return false; }
    size_t at = s.rfind('@'), colon = s.find(':');
    if (at == std::string::npos || colon == std::string::npos || colon > at) {
        *why = "it should be s3://<key ID>:<application key>@<endpoint>/<bucket>";
        return false;
    }
    std::string where = s.substr(at + 1);
    size_t slash = where.find('/');
    if (slash == std::string::npos || slash + 1 >= where.size()) { *why = "the bucket's name is missing after the endpoint"; return false; }
    parse_endpoint(scheme + "://" + where.substr(0, slash), c);
    std::string path = where.substr(slash + 1);
    while (!path.empty() && path.back() == '/') path.pop_back();
    size_t s2 = path.find('/');
    c->bucket = path.substr(0, s2);
    c->prefix = s2 == std::string::npos ? "" : path.substr(s2 + 1);
    c->key_id = pct_decode(s.substr(0, colon));
    c->secret = pct_decode(s.substr(colon + 1, at - colon - 1));
    if (c->host.empty() || c->bucket.empty() || c->key_id.empty() || c->secret.empty()) { *why = "a part of it is empty"; return false; }
    return true;
}

// The application key's secret: the Keychain on iOS (this app's own, not synced to iCloud), else an owner-only file
#if TARGET_OS_IPHONE
static NSMutableDictionary *kc_query(const std::string &kid) {
    return [@{(id)kSecClass: (id)kSecClassGenericPassword, (id)kSecAttrService: @"nx cloud saves",
              (id)kSecAttrAccount: @(kid.c_str())} mutableCopy];
}
static std::string secret_get(const std::string &kid) {
    NSMutableDictionary *q = kc_query(kid);
    q[(id)kSecReturnData] = @YES;
    q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
    CFTypeRef r = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &r) != errSecSuccess || !r) return "";
    NSData *d = CFBridgingRelease(r);
    return std::string((const char *)d.bytes, d.length);
}
static void secret_clear(const std::string &kid) { SecItemDelete((__bridge CFDictionaryRef)kc_query(kid)); }
static bool secret_set(const std::string &kid, const std::string &secret) {
    secret_clear(kid);
    NSMutableDictionary *q = kc_query(kid);
    q[(id)kSecValueData] = [NSData dataWithBytes:secret.data() length:secret.size()];
    q[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;  // (uploads while locked, in the background)
    return SecItemAdd((__bridge CFDictionaryRef)q, NULL) == errSecSuccess;
}
#else
#define SECRET_FILE "cloud.secret"  // "<key ID> <secret>", in the data folder
static std::string secret_get(const std::string &kid) {
    char line[512] = "";
    FILE *f = fopen(SECRET_FILE, "r");
    if (!f) return "";
    bool ok = fgets(line, sizeof line, f) != NULL;
    fclose(f);
    std::string s = ok ? std::string(line) : "";
    while (!s.empty() && isspace((unsigned char)s.back())) s.pop_back();
    size_t sp = s.find(' ');
    return sp != std::string::npos && s.substr(0, sp) == kid ? s.substr(sp + 1) : "";
}
static void secret_clear(const std::string &kid) { (void)kid; unlink(SECRET_FILE); }
static bool secret_set(const std::string &kid, const std::string &secret) {
    unlink(SECRET_FILE ".tmp");
#ifdef _WIN32
    FILE *f = fopen(SECRET_FILE ".tmp", "w");
#else
    int fd = open(SECRET_FILE ".tmp", O_WRONLY | O_CREAT | O_EXCL, 0600);  // (only this user can read it)
    FILE *f = fd >= 0 ? fdopen(fd, "w") : NULL;
#endif
    if (!f) return false;
    bool ok = fprintf(f, "%s %s\n", kid.c_str(), secret.c_str()) > 0;
    ok = !fclose(f) && ok;
    return ok && !rename(SECRET_FILE ".tmp", SECRET_FILE);
}
#endif

static std::mutex g_secret_mx;  // (the secret, read once per key: forgotten when the key changes)
static std::string g_secret_id, g_secret;
static void secret_forget(void) {
    std::lock_guard<std::mutex> l(g_secret_mx);
    g_secret_id.clear(), g_secret.clear();
}
static bool conn(Conn *c) {
    const char *e = getenv("LARECOMP_CLOUD");
    std::string why;
    if (e && *e) return parse_conn(e, c, &why);
    if (!g_settings.cloud_endpoint[0] || !g_settings.cloud_bucket[0] || !g_settings.cloud_key_id[0]) return false;
    parse_endpoint(g_settings.cloud_endpoint, c);
    c->bucket = g_settings.cloud_bucket;
    c->prefix = g_settings.cloud_prefix;
    c->key_id = g_settings.cloud_key_id;
    std::lock_guard<std::mutex> l(g_secret_mx);
    if (g_secret_id != c->key_id) g_secret = secret_get(c->key_id), g_secret_id = c->key_id;
    c->secret = g_secret;
    return !c->secret.empty();
}

// ------------------------------------------------------------------ HTTPS
struct Resp { int status = 0; std::string body, error; std::map<std::string, std::string> headers; /* (lower-case names) */ };
using Progress = std::function<void(double)>;

#if defined(__linux__)
// libcurl: one easy handle per request (a few a minute at most), the body sent from memory, the reply's headers kept
struct CurlIo { Resp *o; const std::string *body; size_t sent = 0; const Progress *progress; bool up; };
static size_t curl_write(char *p, size_t sz, size_t n, void *u) { ((CurlIo *)u)->o->body.append(p, sz * n); return sz * n; }
static size_t curl_read(char *p, size_t sz, size_t n, void *u) {
    CurlIo *io = (CurlIo *)u;
    size_t k = std::min(sz * n, io->body->size() - io->sent);
    memcpy(p, io->body->data() + io->sent, k);
    io->sent += k;
    return k;
}
static size_t curl_header(char *p, size_t sz, size_t n, void *u) {
    std::string line(p, sz * n);
    size_t colon = line.find(':');
    if (colon != std::string::npos) {
        std::string v = line.substr(colon + 1);
        while (!v.empty() && isspace((unsigned char)v.front())) v.erase(v.begin());
        while (!v.empty() && isspace((unsigned char)v.back())) v.pop_back();
        ((CurlIo *)u)->o->headers[s3::lower(line.substr(0, colon))] = v;
    }
    return sz * n;
}
static int curl_progress(void *u, curl_off_t dlt, curl_off_t dln, curl_off_t ult, curl_off_t uln) {
    CurlIo *io = (CurlIo *)u;
    curl_off_t of = io->up ? ult : dlt, n = io->up ? uln : dln;
    if (*io->progress && of > 0) (*io->progress)((double)n / (double)of);
    return 0;
}
static Resp http_send(const std::string &method, const std::string &url, const s3::Headers &headers, const std::string &body,
                      double timeout, const Progress &progress) {
    Resp out;
    static std::once_flag once;
    std::call_once(once, [] { curl_global_init(CURL_GLOBAL_DEFAULT); });
    CURL *h = curl_easy_init();
    if (!h) { out.error = "libcurl"; return out; }
    CurlIo io{&out, &body, 0, &progress, method == "PUT"};
    struct curl_slist *hl = NULL;
    for (auto &kv : headers)
        if (s3::lower(kv.first) != "host") hl = curl_slist_append(hl, (kv.first + ": " + kv.second).c_str());
    hl = curl_slist_append(hl, "Expect:");  // (no 100-continue round trip)
    curl_easy_setopt(h, CURLOPT_URL, url.c_str());
    curl_easy_setopt(h, CURLOPT_HTTPHEADER, hl);
    curl_easy_setopt(h, CURLOPT_WRITEFUNCTION, curl_write);
    curl_easy_setopt(h, CURLOPT_WRITEDATA, &io);
    curl_easy_setopt(h, CURLOPT_HEADERFUNCTION, curl_header);
    curl_easy_setopt(h, CURLOPT_HEADERDATA, &io);
    curl_easy_setopt(h, CURLOPT_XFERINFOFUNCTION, curl_progress);
    curl_easy_setopt(h, CURLOPT_XFERINFODATA, &io);
    curl_easy_setopt(h, CURLOPT_NOPROGRESS, 0L);
    curl_easy_setopt(h, CURLOPT_NOSIGNAL, 1L);
    curl_easy_setopt(h, CURLOPT_CONNECTTIMEOUT_MS, (long)(timeout * 1000));
    // (timeout: with nothing received for that long, as NSURLRequest's timeoutInterval; the whole transfer: 10 minutes)
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_LIMIT, 1L);
    curl_easy_setopt(h, CURLOPT_LOW_SPEED_TIME, (long)(timeout > 1 ? timeout : 1));
    curl_easy_setopt(h, CURLOPT_TIMEOUT, 600L);
    if (method == "PUT") {
        curl_easy_setopt(h, CURLOPT_UPLOAD, 1L);
        curl_easy_setopt(h, CURLOPT_READFUNCTION, curl_read);
        curl_easy_setopt(h, CURLOPT_READDATA, &io);
        curl_easy_setopt(h, CURLOPT_INFILESIZE_LARGE, (curl_off_t)body.size());
    } else if (method == "HEAD") {
        curl_easy_setopt(h, CURLOPT_NOBODY, 1L);
    } else if (method != "GET") {
        curl_easy_setopt(h, CURLOPT_CUSTOMREQUEST, method.c_str());
        if (!body.empty()) {
            curl_easy_setopt(h, CURLOPT_POSTFIELDS, body.data());
            curl_easy_setopt(h, CURLOPT_POSTFIELDSIZE_LARGE, (curl_off_t)body.size());
        }
    }
    CURLcode rc = curl_easy_perform(h);
    if (rc != CURLE_OK) out.error = curl_easy_strerror(rc);
    else {
        long st = 0;
        curl_easy_getinfo(h, CURLINFO_RESPONSE_CODE, &st);
        out.status = (int)st;
    }
    curl_slist_free_all(hl);
    curl_easy_cleanup(h);
    return out;
}
#else
static Resp http_send(const std::string &method, const std::string &url, const s3::Headers &headers, const std::string &body,
                      double timeout, const Progress &progress) {
    Resp out;
    @autoreleasepool {
        static NSURLSession *sessions[2];  // ([1]: mobile data allowed)
        static std::mutex m;
        NSURLSession *session;
        {
            std::lock_guard<std::mutex> l(m);
            int k = g_settings.cloud_cellular ? 1 : 0;
            if (!sessions[k]) {
                NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
                cfg.allowsCellularAccess = k;
                cfg.timeoutIntervalForResource = 600;
                cfg.URLCache = nil;
                sessions[k] = [NSURLSession sessionWithConfiguration:cfg];
            }
            session = sessions[k];
        }
        NSMutableURLRequest *r = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@(url.c_str())]];
        r.HTTPMethod = @(method.c_str());
        r.timeoutInterval = timeout;  // (with nothing received for that long)
        for (auto &h : headers)
            if (s3::lower(h.first) != "host") [r setValue:@(h.second.c_str()) forHTTPHeaderField:@(h.first.c_str())];
        dispatch_semaphore_t done = dispatch_semaphore_create(0);
        Resp *o = &out;
        void (^handler)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *e) {
            if (e) o->error = e.localizedDescription.UTF8String ?: "network error";
            else {
                NSHTTPURLResponse *h = (NSHTTPURLResponse *)resp;
                o->status = (int)h.statusCode;
                if (data) o->body.assign((const char *)data.bytes, data.length);
                [h.allHeaderFields enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
                    (void)stop;
                    o->headers[s3::lower([key description].UTF8String)] = [val description].UTF8String;
                }];
            }
            dispatch_semaphore_signal(done);
        };
        bool up = method == "PUT";
        NSURLSessionTask *t = up ? [session uploadTaskWithRequest:r fromData:[NSData dataWithBytesNoCopy:(void *)body.data()
                                                                                                      length:body.size() freeWhenDone:NO]
                                                completionHandler:handler]
                                 : [session dataTaskWithRequest:r completionHandler:handler];
#if TARGET_OS_IPHONE
        // (an upload carries on for a while when the app goes to the background)
        __block UIBackgroundTaskIdentifier bg = UIBackgroundTaskInvalid;
        UIApplication *app = UIApplication.sharedApplication;
        bg = [app beginBackgroundTaskWithName:@"nx cloud save" expirationHandler:^{
            [t cancel];
            [app endBackgroundTask:bg];
            bg = UIBackgroundTaskInvalid;
        }];
#endif
        [t resume];
        while (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC)))
            if (progress) {
                int64_t n = up ? t.countOfBytesSent : t.countOfBytesReceived;
                int64_t of = up ? t.countOfBytesExpectedToSend : t.countOfBytesExpectedToReceive;
                if (of > 0) progress((double)n / of);
            }
#if TARGET_OS_IPHONE
        if (bg != UIBackgroundTaskInvalid) [app endBackgroundTask:bg];
#endif
    }
    return out;
}
#endif

// A request to the bucket (key: an object in it, "" the bucket itself), signed. Its error: the network's, or S3's.
static Resp request(const Conn &c, const std::string &method, const std::string &key,
                    const std::vector<std::pair<std::string, std::string>> &query, const std::string &body, s3::Headers extra,
                    double timeout, const Progress &progress = nullptr) {
    std::string path = "/" + c.bucket + (key.empty() ? "" : "/" + key);
    s3::Headers h = {{"host", c.host}};
    h.insert(h.end(), extra.begin(), extra.end());
    std::string qs = s3::sign(method, path, query, h, s3::sha256_hex(body), c.region, c.key_id, c.secret, time(NULL));
    std::string url = c.scheme + "://" + c.host + s3::encode(path, true) + (qs.empty() ? "" : "?" + qs);
    Resp r = http_send(method, url, h, body, timeout, progress);
    if (r.error.empty() && r.status / 100 != 2) {
        std::string code = s3::xml_one(r.body, "Code"), msg = s3::xml_one(r.body, "Message");
        r.error = code.empty() ? "the server answered " + std::to_string(r.status) : code + (msg.empty() ? "" : ": " + msg);
        if (r.status == 403 && code.empty()) r.error = "access denied (403): check the key and its bucket";
        if (r.status == 404 && method == "GET" && key.empty()) r.error = "there is no bucket named " + c.bucket;
    }
    return r;
}

// ------------------------------------------------------------------ the save as a tar
struct Snap {
    std::string root, game, build, version, tar, hash;
    time_t newest = 0;  // its newest file's time
    bool any = false;   // a save at all (a file in a mount)
};
struct Entry { std::string name; fs::path path; bool dir; };

static bool is_mount_name(const std::string &n) { return n != "backups" && n != "album" && !n.empty() && n[0] != '.'; }
static void collect(const fs::path &dir, const std::string &rel, std::vector<Entry> &out, Snap *s) {
    std::vector<std::string> names;
    std::error_code ec;
    for (auto &d : fs::directory_iterator(dir, ec)) names.push_back(d.path().filename().string());
    std::sort(names.begin(), names.end());
    for (auto &n : names) {
        fs::path p = dir / n;
        if (n.size() > 8 && !n.compare(n.size() - 8, 8, ".pending")) continue;  // (a commit's working copy)
        struct stat st;
        if (stat(p.c_str(), &st)) continue;
        if (S_ISDIR(st.st_mode)) {
            out.push_back({rel + n, p, true});
            collect(p, rel + n + "/", out, s);
        } else if (S_ISREG(st.st_mode)) {
            out.push_back({rel + n, p, false});
            s->any = true;
            if (st.st_mtime > s->newest) s->newest = st.st_mtime;
        }
    }
}
static void tar_add(std::string &t, const std::string &name, const std::string &data, bool dir) {
    char h[512] = {0};
    std::string n = dir ? name + "/" : name, prefix;
    if (n.size() > 100) {  // (ustar: a prefix of up to 155 characters, cut at a '/')
        size_t cut = n.rfind('/', n.size() - 2);
        while (cut != std::string::npos && (cut > 155 || n.size() - cut - 1 > 100)) cut = cut ? n.rfind('/', cut - 1) : std::string::npos;
        if (cut != std::string::npos) prefix = n.substr(0, cut), n = n.substr(cut + 1);
    }
    memcpy(h, n.data(), std::min<size_t>(n.size(), 100));
    snprintf(h + 100, 8, "%07o", dir ? 0755 : 0644);
    snprintf(h + 108, 8, "%07o", 0);
    snprintf(h + 116, 8, "%07o", 0);
    snprintf(h + 124, 12, "%011llo", (unsigned long long)(dir ? 0 : data.size()));
    snprintf(h + 136, 12, "%011o", 0);  // (no times: the same save is the same tar, byte for byte)
    h[156] = dir ? '5' : '0';
    memcpy(h + 257, "ustar", 6);
    memcpy(h + 263, "00", 2);
    memcpy(h + 345, prefix.data(), std::min<size_t>(prefix.size(), 155));
    memset(h + 148, ' ', 8);
    unsigned sum = 0;
    for (int i = 0; i < 512; i++) sum += (unsigned char)h[i];
    snprintf(h + 148, 8, "%06o", sum);
    t.append(h, 512);
    if (dir) return;
    t += data;
    t.append((512 - data.size() % 512) % 512, '\0');
}
static bool read_file(const fs::path &p, std::string *out) {
    FILE *f = fopen(p.c_str(), "rb");
    if (!f) return false;
    out->clear();
    char buf[1 << 16];
    size_t n;
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) out->append(buf, n);
    bool ok = !ferror(f);
    fclose(f);
    return ok;
}
// The save's folders as a tar, read under the save service's lock (never half a commit)
static bool snapshot(Snap *s, std::string *why) {
    std::vector<Entry> entries;
    std::vector<std::string> mounts;
    std::error_code ec;
    save_lock();
    for (auto &d : fs::directory_iterator(s->root, ec))
        if (d.is_directory(ec) && is_mount_name(d.path().filename().string())) mounts.push_back(d.path().filename().string());
    std::sort(mounts.begin(), mounts.end());
    for (auto &m : mounts) {
        entries.push_back({m, fs::path(s->root) / m, true});
        collect(fs::path(s->root) / m, m + "/", entries, s);
    }
    s->tar.clear();
    bool ok = true;
    std::string data;
    for (auto &e : entries) {
        if (!e.dir && !read_file(e.path, &data)) { *why = "could not read " + e.path.string() + ": " + strerror(errno); ok = false; break; }
        tar_add(s->tar, e.name, e.dir ? "" : data, e.dir);
    }
    save_unlock();
    if (!ok) return false;
    s->tar.append(1024, '\0');
    s->hash = s3::sha256_hex(s->tar);
    return true;
}
struct TarEntry { std::string name; bool dir; size_t off, size; };
// The entries of a downloaded tar: false (and why) for anything but plain files and folders under the save's own
static bool tar_list(const std::string &t, std::vector<TarEntry> *out, std::string *why) {
    for (size_t at = 0; at + 512 <= t.size();) {
        const unsigned char *h = (const unsigned char *)t.data() + at;
        bool zero = true;
        for (int i = 0; i < 512 && zero; i++) zero = !h[i];
        if (zero) return true;
        unsigned sum = 0;
        for (int i = 0; i < 512; i++) sum += i >= 148 && i < 156 ? ' ' : h[i];
        if (strtoul(std::string((const char *)h + 148, 8).c_str(), NULL, 8) != sum) { *why = "the save is damaged (a bad tar header)"; return false; }
        size_t size = strtoull(std::string((const char *)h + 124, 12).c_str(), NULL, 8);
        std::string name((const char *)h, strnlen((const char *)h, 100)), prefix((const char *)h + 345, strnlen((const char *)h + 345, 155));
        if (!prefix.empty()) name = prefix + "/" + name;
        char type = (char)h[156];
        bool dir = type == '5';
        while (!name.empty() && name.back() == '/') name.pop_back();
        if (at + 512 + size > t.size()) { *why = "the save is damaged (cut short)"; return false; }
        bool safe = !name.empty() && name[0] != '/' && name.find('\\') == std::string::npos && name.find('\0') == std::string::npos;
        for (size_t b = 0; safe && b <= name.size();) {
            size_t e = name.find('/', b);
            if (e == std::string::npos) e = name.size();
            std::string part = name.substr(b, e - b);
            safe = !part.empty() && part != "." && part != "..";
            b = e + 1;
        }
        if (!safe || (type != '0' && type != '\0' && !dir)) { *why = "the save has an entry nx doesn't take: " + name; return false; }
        out->push_back({name, dir, at + 512, size});
        at += 512 + (size + 511) / 512 * 512;
    }
    return true;
}
static bool tar_extract(const std::string &t, const fs::path &dst, std::string *why) {
    std::vector<TarEntry> list;
    if (!tar_list(t, &list, why)) return false;
    std::error_code ec;
    fs::create_directories(dst, ec);
    for (auto &e : list) {
        fs::path p = dst / e.name;
        if (e.dir) { fs::create_directories(p, ec); continue; }
        fs::create_directories(p.parent_path(), ec);
        FILE *f = fopen(p.c_str(), "wb");
        bool ok = f && fwrite(t.data() + e.off, 1, e.size, f) == e.size && !fflush(f);
#ifndef _WIN32
        ok = ok && !fsync(fileno(f));  // (on disk before the save it replaces goes)
#endif
        if (f) ok = !fclose(f) && ok;
        if (!ok) { *why = "could not write " + p.string() + ": " + strerror(errno); return false; }
    }
    return true;
}

static std::string zpack(const std::string &s) {
    ZSTD_CCtx *c = ZSTD_createCCtx();
    ZSTD_CCtx_setParameter(c, ZSTD_c_compressionLevel, 3);
    ZSTD_CCtx_setParameter(c, ZSTD_c_checksumFlag, 1);
    std::string out(ZSTD_compressBound(s.size()), '\0');
    size_t n = ZSTD_compress2(c, &out[0], out.size(), s.data(), s.size());
    ZSTD_freeCCtx(c);
    if (ZSTD_isError(n)) return "";
    out.resize(n);
    return out;
}
static bool zunpack(const std::string &z, std::string *out, std::string *why) {
    unsigned long long n = ZSTD_getFrameContentSize(z.data(), z.size());
    if (n == ZSTD_CONTENTSIZE_ERROR || n == ZSTD_CONTENTSIZE_UNKNOWN || n > (1ull << 31)) { *why = "the download isn't a save"; return false; }
    out->resize(n);
    size_t r = ZSTD_decompress(&(*out)[0], n, z.data(), z.size());
    if (ZSTD_isError(r) || r != n) { *why = std::string("the save is damaged: ") + (ZSTD_isError(r) ? ZSTD_getErrorName(r) : "short"); return false; }
    return true;
}

// ------------------------------------------------------------------ what was last synced (save/<game>/.cloud)
struct State { std::string hash; time_t saved = 0; };
static State state_read(const fs::path &dir) {
    State s;
    FILE *f = fopen((dir / ".cloud").c_str(), "r");
    char line[256];
    while (f && fgets(line, sizeof line, f)) {
        char k[32], v[128];
        if (sscanf(line, "%31[^=]=%127s", k, v) != 2) continue;
        if (!strcmp(k, "hash")) s.hash = v;
        else if (!strcmp(k, "saved")) s.saved = (time_t)atoll(v);
    }
    if (f) fclose(f);
    return s;
}
static void state_write(const fs::path &dir, const State &s) {
    fs::path tmp = dir / ".cloud.tmp";
    FILE *f = fopen(tmp.c_str(), "w");
    if (!f) return;
    fprintf(f, "hash=%s\nsaved=%lld\n", s.hash.c_str(), (long long)s.saved);
    if (!fclose(f)) rename(tmp.c_str(), (dir / ".cloud").c_str());
}
// When the save here was saved: as synced, or (changed since) its newest file's time
static time_t local_saved(const Snap &s) {
    if (!s.any) return 0;
    State st = state_read(s.root);
    return st.hash == s.hash ? st.saved : s.newest;
}

// ------------------------------------------------------------------ slots
struct Slot { std::string key, device, device_id, build, version, hash; time_t saved = 0; unsigned long long size = 0; };

static std::string game_prefix(const Conn &c, const std::string &game) { return (c.prefix.empty() ? "" : c.prefix + "/") + game + "/"; }
static std::string device_id(void) {
    const char *e = getenv("LARECOMP_CLOUD_DEVICE");
    return e && *e ? std::string(e) : std::string(g_settings.cloud_device_id);
}
static std::string device_name(void) {
    const char *e = getenv("LARECOMP_CLOUD_DEVICE");
    return e && *e ? std::string(e) : std::string(g_settings.cloud_device);
}
static std::string slot_key(const Conn &c, const std::string &game) { return game_prefix(c, game) + device_id() + ".nxsave"; }

// The game's slots, each with its metadata (one HEAD each: a few devices)
static bool list_slots(const Conn &c, const std::string &game, std::vector<Slot> *out, std::string *why) {
    Resp r = request(c, "GET", "", {{"list-type", "2"}, {"prefix", game_prefix(c, game)}}, "", {}, 10);
    if (!r.error.empty()) { *why = r.error; return false; }
    out->clear();
    for (auto &item : s3::xml_all(r.body, "Contents")) {
        Slot s;
        s.key = s3::xml_one(item, "Key");
        s.size = strtoull(s3::xml_one(item, "Size").c_str(), NULL, 10);
        if (s.key.size() < 7 || s.key.compare(s.key.size() - 7, 7, ".nxsave")) continue;
        Resp h = request(c, "HEAD", s.key, {}, "", {}, 10);
        if (!h.error.empty()) { *why = h.error; return false; }
        s.device = pct_decode(h.headers["x-amz-meta-nx-device"]);
        s.device_id = s.key.substr(s.key.rfind('/') + 1, s.key.size() - s.key.rfind('/') - 8);
        s.build = h.headers["x-amz-meta-nx-build"];
        s.version = pct_decode(h.headers["x-amz-meta-nx-version"]);
        s.hash = h.headers["x-amz-meta-nx-hash"];
        s.saved = (time_t)atoll(h.headers["x-amz-meta-nx-saved"].c_str());
        if (s.device.empty()) s.device = s.device_id;
        if (s.hash.size() == 64 && s.saved > 0) out->push_back(s);
    }
    std::sort(out->begin(), out->end(), [](const Slot &a, const Slot &b) { return a.saved > b.saved; });
    return true;
}
static bool download(const Conn &c, const Slot &s, std::string *tar, std::string *why, const Progress &p) {
    Resp r = request(c, "GET", s.key, {}, "", {}, 30, p);
    if (!r.error.empty()) { *why = r.error; return false; }
    if (!zunpack(r.body, tar, why)) return false;
    if (s3::sha256_hex(*tar) != s.hash) { *why = "the save is damaged (its checksum doesn't match)"; return false; }
    std::vector<TarEntry> list;
    return tar_list(*tar, &list, why);
}

// ------------------------------------------------------------------ state shared with the menu and the worker
struct Game { std::string root, key, build, version; };
static std::mutex g_lock;  // all below
static std::condition_variable g_wake, g_idle;
static Game g_game_now;  // the booted game's
static bool g_dirty, g_flush, g_working, g_torn_down, g_started;
static double g_dirty_at, g_uploaded_at = -1e9;
static std::deque<std::function<void()>> g_jobs;
static CloudView g_view;
static std::vector<Slot> g_slots;  // (g_view.slots, with what the menu doesn't show)

static double mono(void) { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
static std::string fmt_time(time_t t, const char *f = "%a %d %b, %H:%M") {
    char s[64];
    struct tm tm;
    localtime_r(&t, &tm);
    strftime(s, sizeof s, f, &tm);
    return s;
}
static std::string mb(unsigned long long n) {
    char s[32];
    snprintf(s, sizeof s, n >= (1u << 20) ? "%.1f MB" : "%.0f KB", n >= (1u << 20) ? n / 1048576.0 : n / 1024.0);
    return s;
}
static void status(const std::string &s, bool error = false) {  // (g_lock held)
    if (error) g_view.error = s;
    else g_view.status = s, g_view.error.clear();
    fprintf(stderr, "[cloud] %s\n", s.c_str());
}
static void publish_slots(const std::vector<Slot> &slots, const Game &g, const std::string &local_hash) {  // (g_lock held)
    g_slots = slots;
    g_view.slots.clear();
    std::string me = device_id();
    for (auto &s : slots) {
        CloudSlot v;
        v.key = s.key, v.device = s.device, v.version = s.version, v.saved = s.saved, v.size = s.size;
        v.mine = s.device_id == me;
        v.same_game = s.build == g.build;
        v.current = s.hash == local_hash;
        g_view.slots.push_back(v);
    }
    g_view.listed = time(NULL);
}
static void enqueue(std::function<void()> job);

static void upload(const Snap &s) {
    Conn c;
    if (!conn(&c)) return;
    {
        std::lock_guard<std::mutex> l(g_lock);
        g_view.busy = true, g_view.progress = 0;
        status("Uploading the save (" + mb(s.tar.size()) + ")");
    }
    std::string z = zpack(s.tar);
    if (z.empty()) { std::lock_guard<std::mutex> l(g_lock); g_view.busy = false; status("Upload failed: couldn't compress the save", true); return; }
    time_t saved = local_saved(s);
    s3::Headers meta = {{"x-amz-meta-nx-device", s3::encode(device_name())},
                        {"x-amz-meta-nx-saved", std::to_string((long long)saved)},
                        {"x-amz-meta-nx-build", s.build},
                        {"x-amz-meta-nx-version", s3::encode(s.version)},
                        {"x-amz-meta-nx-hash", s.hash}};
    Resp r = request(c, "PUT", slot_key(c, s.game), {}, z, meta, 30, [](double p) {
        std::lock_guard<std::mutex> l(g_lock);
        g_view.progress = (float)p;
    });
    std::lock_guard<std::mutex> l(g_lock);
    g_view.busy = false, g_view.progress = -1;
    if (!r.error.empty()) {
        status("Upload failed: " + r.error + " (trying again in 2 minutes)", true);
        if (s.root == g_game_now.root) g_dirty = true, g_dirty_at = mono() + 120 - 30;
        return;
    }
    state_write(s.root, {s.hash, saved});
    g_uploaded_at = mono();
    status("Uploaded at " + fmt_time(time(NULL), "%H:%M") + " (" + mb(z.size()) + ")");
    if (s.root != g_game_now.root) return;
    std::vector<Slot> slots = g_slots;  // (this device's slot, as it is now)
    std::string me = device_id();
    slots.erase(std::remove_if(slots.begin(), slots.end(), [&](const Slot &x) { return x.device_id == me; }), slots.end());
    Slot mine;
    mine.key = slot_key(c, s.game), mine.device = device_name(), mine.device_id = me, mine.build = s.build;
    mine.version = s.version, mine.hash = s.hash, mine.saved = saved, mine.size = z.size();
    slots.push_back(mine);
    std::sort(slots.begin(), slots.end(), [](const Slot &a, const Slot &b) { return a.saved > b.saved; });
    publish_slots(slots, g_game_now, s.hash);
}
static Snap snap_of(const Game &g) {
    Snap s;
    s.root = g.root, s.game = g.key, s.build = g.build, s.version = g.version;
    return s;
}
// The booted game's save uploaded if it changed since it was last synced (force: changed or not)
static void upload_current(const Game &g, bool force) {
    Snap s = snap_of(g);
    std::string why;
    if (!snapshot(&s, &why)) { std::lock_guard<std::mutex> l(g_lock); status("Upload failed: " + why, true); return; }
    if (!s.any || (!force && state_read(s.root).hash == s.hash)) {
        fprintf(stderr, "[cloud] the save is as last synced: not uploaded\n");
        return;
    }
    upload(s);
}

static void worker(void) {
    std::unique_lock<std::mutex> l(g_lock);
    for (;;) {
        if (!g_jobs.empty()) {
            auto job = g_jobs.front();
            g_jobs.pop_front();
            g_working = true;
            l.unlock();
            job();
            l.lock();
            g_working = false;
            g_idle.notify_all();
            continue;
        }
        static const double every = getenv("LARECOMP_CLOUD_EVERY") ? atof(getenv("LARECOMP_CLOUD_EVERY")) : 600;  // (tests)
        double now = mono(), due = std::max(g_dirty_at + 30, g_uploaded_at + every);
        if (g_dirty && (g_flush || now >= due)) {
            g_dirty = g_flush = false;
            Game g = g_game_now;
            g_working = true;
            l.unlock();
            Conn c;
            if (g_settings.cloud && conn(&c)) upload_current(g, false);
            l.lock();
            g_working = false;
            g_idle.notify_all();
            continue;
        }
        g_flush = false;
        if (g_dirty) g_wake.wait_for(l, std::chrono::duration<double>(due - now));
        else g_wake.wait(l);
    }
}
static void enqueue(std::function<void()> job) {
    std::lock_guard<std::mutex> l(g_lock);
    if (!g_started) { g_started = true; std::thread(worker).detach(); }
    g_jobs.push_back(std::move(job));
    g_wake.notify_all();
}

// ------------------------------------------------------------------ the engine's calls
static void ensure_device(void) {
    if (g_settings.cloud_device_id[0]) return;
    std::string name;
#if TARGET_OS_IPHONE
    name = UIDevice.currentDevice.model.UTF8String;  // ("iPhone", "iPad": iOS doesn't tell apps the device's own name)
#elif defined(__linux__)
    char host[256] = "";
    if (gethostname(host, sizeof host - 1) == 0) name = host;
    if (name.empty()) name = "Linux";
#else
    name = NSHost.currentHost.localizedName.UTF8String ?: "Mac";
#endif
    if (name.empty()) name = "device";
    std::string id;
    for (char ch : name)
        if (isalnum((unsigned char)ch) && id.size() < 24) id += ch;
        else if ((ch == ' ' || ch == '-') && !id.empty() && id.back() != '-') id += '-';
    while (!id.empty() && id.back() == '-') id.pop_back();
    char tail[8];
    snprintf(tail, sizeof tail, "-%04x", (unsigned)(std::random_device{}() & 0xffff));
    snprintf(g_settings.cloud_device_id, sizeof g_settings.cloud_device_id, "%s%s", id.empty() ? "device" : id.c_str(), tail);
    if (!g_settings.cloud_device[0]) snprintf(g_settings.cloud_device, sizeof g_settings.cloud_device, "%s", name.c_str());
    settings_save();
}

extern "C" void cloud_boot(void) {
    Game g;
    const char *dir = getenv("LARECOMP_SAVE_DIR");  // (as the save service picks it: runtime/services/fs.c)
    g.root = dir ? dir : std::string("save/") + g_game.key;
    g.key = g_game.key;
    static const char hex[] = "0123456789ABCDEF";
    for (uint8_t b : g_game.build_id) g.build += hex[b >> 4], g.build += hex[b & 15];
    g.version = g_game.version ? g_game.version->label : "";
    {
        std::lock_guard<std::mutex> l(g_lock);
        g_game_now = g, g_dirty = g_flush = g_torn_down = false;
        g_slots.clear();
        g_view.slots.clear(), g_view.fetched.clear(), g_view.listed = 0;
    }
    Conn c;
    if (!conn(&c)) return;
    ensure_device();
    if (!g_settings.cloud) return;
    menu_loading_status("Checking the cloud saves");
    std::error_code ec;
    fs::create_directories(g.root, ec);
    Snap local = snap_of(g);
    std::string why;
    if (!snapshot(&local, &why)) { std::lock_guard<std::mutex> l(g_lock); status(why, true); return; }
    time_t mine = local_saved(local);
    std::vector<Slot> slots;
    if (!list_slots(c, g.key, &slots, &why)) {
        std::lock_guard<std::mutex> l(g_lock);
        status("Couldn't check the cloud saves: " + why, true);
        return;
    }
    const Slot *best = NULL, *other = NULL;
    for (auto &s : slots) {
        if (s.hash == local.hash || s.saved <= mine) continue;
        if (s.build == g.build) { if (!best) best = &s; }
        else if (!other) other = &s;
    }
    std::string note;
    if (best) {
        std::string what = "the save from " + best->device + " (" + fmt_time(best->saved) + ")";
        menu_loading_status(("Downloading " + what).c_str());
        std::string tar;
        bool ok = download(c, *best, &tar, &why, [&](double p) {
            char s[300];
            snprintf(s, sizeof s, "Downloading the save from %s: %d%%", best->device.c_str(), (int)(p * 100));
            menu_loading_status(s);
        });
        if (ok) {  // (into place: the local save backed up first; nothing replaced if that fails)
            fs::path in = fs::path(g.root) / ".cloud-incoming";
            fs::remove_all(in, ec);
            ok = tar_extract(tar, in, &why);
            if (ok && local.any) {
                std::string err = saves_back_up("before the save from " + best->device, nullptr, g.root);
                if (!err.empty()) ok = false, why = "couldn't back up the save here first (" + err + ")";
            }
            if (ok) {
                for (auto &d : fs::directory_iterator(g.root, ec))
                    if (d.is_directory() && is_mount_name(d.path().filename().string())) fs::remove_all(d.path(), ec);
                for (auto &d : fs::directory_iterator(in, ec))  // (the save's folders only)
                    if (d.is_directory() && is_mount_name(d.path().filename().string()))
                        fs::rename(d.path(), fs::path(g.root) / d.path().filename(), ec);
                state_write(g.root, {best->hash, best->saved});
                local.hash = best->hash, local.any = true;
                note = "Using " + what;
            }
            fs::remove_all(in, ec);
        }
        if (!ok) note = "Couldn't use " + what + ": " + why;
    } else if (other)
        note = "The save from " + other->device + " (" + fmt_time(other->saved) + ") is from another version of the game" +
               (other->version.empty() ? "" : " (" + other->version + ")") + ": not used";
    bool up = local.any;
    for (auto &s : slots) if (s.hash == local.hash) up = false;  // (already there: this device's, or the one just used)
    {
        std::lock_guard<std::mutex> l(g_lock);
        publish_slots(slots, g, local.hash);
        if (!note.empty()) status(note, note.compare(0, 6, "Using ") != 0);
        else if (!up) status("Up to date (" + fmt_time(time(NULL), "%H:%M") + ")");
    }
    if (up) enqueue([g] { upload_current(g, true); });  // (a save here that the bucket doesn't have)
}

extern "C" void cloud_save_committed(void) {
    std::lock_guard<std::mutex> l(g_lock);
    g_dirty = true, g_dirty_at = mono();
    if (!g_started) { g_started = true; std::thread(worker).detach(); }
    g_wake.notify_all();
}
extern "C" void cloud_flush(void) {
    std::lock_guard<std::mutex> l(g_lock);
    if (!g_dirty) return;
    g_flush = true;
    g_wake.notify_all();
}
// The game is going down (a restart, another game, a backup restored: runtime/ui/menu.mm's reset, first): its save as
// it is now, uploaded after
extern "C" void cloud_teardown(void) {
    Game g;
    {
        std::lock_guard<std::mutex> l(g_lock);
        if (g_torn_down || !g_dirty) return;
        g_torn_down = true, g_dirty = false;
        g = g_game_now;
    }
    Conn c;
    if (!g_settings.cloud || !conn(&c)) return;
    Snap s = snap_of(g);
    std::string why;
    if (!snapshot(&s, &why) || !s.any || state_read(s.root).hash == s.hash) return;
    enqueue([s] { upload(s); });
}
extern "C" void cloud_quit(void) {
    cloud_teardown();
    std::unique_lock<std::mutex> l(g_lock);
    g_idle.wait_for(l, std::chrono::seconds(20), [] { return g_jobs.empty() && !g_working; });
}

// ------------------------------------------------------------------ the menu's
CloudView cloud_view(void) {
    std::lock_guard<std::mutex> l(g_lock);
    CloudView v = g_view;
    Conn c;
    v.configured = conn(&c);
    v.endpoint = c.scheme + "://" + c.host, v.bucket = c.bucket + (c.prefix.empty() ? "" : "/" + c.prefix), v.key_id = c.key_id;
    v.busy = v.busy || g_working || !g_jobs.empty();
    g_view.fetched.clear();
    return v;
}
static void refresh_job(bool upload_missing) {
    Conn c;
    Game g;
    {
        std::lock_guard<std::mutex> l(g_lock);
        g = g_game_now;
    }
    if (g.key.empty() || !conn(&c)) return;
    {
        std::lock_guard<std::mutex> l(g_lock);
        status("Checking the cloud saves");
    }
    Snap local = snap_of(g);
    std::string why;
    std::vector<Slot> slots;
    bool ok = snapshot(&local, &why) && list_slots(c, g.key, &slots, &why);
    bool up = upload_missing && local.any;
    for (auto &s : slots) if (s.hash == local.hash) up = false;
    {
        std::lock_guard<std::mutex> l(g_lock);
        if (!ok) { status("Couldn't check the cloud saves: " + why, true); return; }
        publish_slots(slots, g, local.hash);
        status("Checked at " + fmt_time(time(NULL), "%H:%M"));
    }
    if (up) upload(local);
}
bool cloud_connect(const std::string &connection, std::string *why) {
    Conn c;
    if (!parse_conn(connection, &c, why)) return false;
    if (!secret_set(c.key_id, c.secret)) { *why = "couldn't store the key on this device"; return false; }
    secret_forget();
    snprintf(g_settings.cloud_endpoint, sizeof g_settings.cloud_endpoint, "%s://%s", c.scheme.c_str(), c.host.c_str());
    snprintf(g_settings.cloud_bucket, sizeof g_settings.cloud_bucket, "%s", c.bucket.c_str());
    snprintf(g_settings.cloud_prefix, sizeof g_settings.cloud_prefix, "%s", c.prefix.c_str());
    snprintf(g_settings.cloud_key_id, sizeof g_settings.cloud_key_id, "%s", c.key_id.c_str());
    g_settings.cloud = true;
    ensure_device();
    settings_save();
    enqueue([] { refresh_job(true); });
    return true;
}
void cloud_disconnect(void) {
    if (g_settings.cloud_key_id[0]) secret_clear(g_settings.cloud_key_id);
    secret_forget();
    g_settings.cloud_endpoint[0] = g_settings.cloud_bucket[0] = g_settings.cloud_prefix[0] = g_settings.cloud_key_id[0] = 0;
    settings_save();
    std::lock_guard<std::mutex> l(g_lock);
    g_slots.clear();
    g_view = CloudView();
}
void cloud_refresh(void) { enqueue([] { refresh_job(false); }); }
void cloud_upload_now(void) {
    enqueue([] {
        Game g;
        {
            std::lock_guard<std::mutex> l(g_lock);
            g = g_game_now, g_dirty = false;
        }
        if (!g.key.empty()) upload_current(g, true);
    });
}
void cloud_fetch(const std::string &key) {
    enqueue([key] {
        Conn c;
        Slot s;
        Game g;
        {
            std::lock_guard<std::mutex> l(g_lock);
            g = g_game_now;
            for (auto &x : g_slots) if (x.key == key) s = x;
            g_view.busy = true, g_view.progress = 0;
            status("Downloading the save from " + s.device);
        }
        std::string tar, why;
        bool ok = !s.key.empty() && conn(&c) && download(c, s, &tar, &why, [](double p) {
            std::lock_guard<std::mutex> l(g_lock);
            g_view.progress = (float)p;
        });
        fs::path dst;
        if (ok) {  // (a backup: the menu restores it, as any other, with a restart)
            std::string name = fmt_time(time(NULL), "%Y-%m-%d %H-%M-%S") + " - from " + s.device;
            for (char &ch : name) if (ch == '/' || ch == ':' || ch == '\\') ch = '-';
            dst = fs::path(g.root) / "backups" / name;
            ok = tar_extract(tar, dst, &why);
            if (ok) state_write(dst, {s.hash, s.saved});  // (what it is: cloud_restored keeps it)
            else { std::error_code ec; fs::remove_all(dst, ec); }
        }
        std::lock_guard<std::mutex> l(g_lock);
        g_view.busy = false, g_view.progress = -1;
        if (!ok) { status("Download failed: " + (why.empty() ? std::string("the save is gone") : why), true); return; }
        status("Downloaded the save from " + s.device);
        g_view.fetched = dst;
    });
}
// A backup was restored into root (runtime/ui/menu.mm, while the game is down): a cloud save keeps what it is; any
// other is the newest save from now on (the other devices take it)
void cloud_restored(const fs::path &root, const fs::path &from) {
    State st = state_read(from);
    if (!st.hash.empty()) { state_write(root, st); return; }
    Snap s;
    s.root = root.string();
    std::string why;
    if (snapshot(&s, &why) && s.any) state_write(root, {s.hash, time(NULL)});
}

#else  // other platforms (Windows): no cloud saves yet
extern "C" void cloud_boot(void) {}
extern "C" void cloud_save_committed(void) {}
extern "C" void cloud_flush(void) {}
extern "C" void cloud_teardown(void) {}
extern "C" void cloud_quit(void) {}
#endif
