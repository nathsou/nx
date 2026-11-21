// Offline check of the shader translator against every shader a game ships: each graphics shader blob in its romfs
// (any file, Yaz0- or zstd-compressed ones decompressed first: Dread's system/shd/*.bshdat, ACNH's Shader/*.szs and
// Layout/*.zs ...; found by the NVN code header magic 0x12345678, the stage from the Maxwell SPH after it) is translated
// to GLSL (runtime/nvn/maxwell/translate.c) and compiled to SPIR-V. Reports translation failures and compile errors,
// one line per unique blob, plus totals.
//
// This is the Vulkan backend's version (Linux / Windows): GLSL, compiled to SPIR-V with shaderc as
// runtime/nvn/vulkan/shaders.c does (no device needed). The Metal one is tools/shader_corpus.m.
// build: make build/shader_corpus (Linux)
// usage: build/shader_corpus <romfs> [--no-compile] [--dump dir] [--chunks <log2 bytes>] [--lazy]
#include <shaderc/shaderc.h>
#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "shader.h"
#include "yaz0.h"
#include <sys/stat.h>
#include <zstd.h>

static uint64_t fnv(const uint8_t *p, size_t n) {
    uint64_t h = 1469598103934665603ull;
    for (size_t i = 0; i < n; i++) h = (h ^ p[i]) * 1099511628211ull;
    return h;
}

#define MAX_SEEN (1 << 20)
static uint64_t seen[MAX_SEEN];
static int nseen;
static bool seen_add(uint64_t h) {
    for (int i = 0; i < nseen; i++) if (seen[i] == h) return false;
    if (nseen < MAX_SEEN) seen[nseen++] = h;
    return true;
}

static shaderc_compiler_t comp;
static bool compile = true, glsl = true;
static const char *dump;
static int files, blobs, unique, tfail, cfail, by_stage[6];

// The file's bytes, decompressed when it is Yaz0 or zstd (NULL: unreadable)
static uint8_t *load(const char *path, size_t *n) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    fseek(f, 0, SEEK_END);
    long fl = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (fl < 0) { fclose(f); return NULL; }
    size_t len = (size_t)fl;
    uint8_t *p = malloc(len ? len : 1);
    if (fread(p, 1, len, f) != len) { fclose(f); free(p); return NULL; }
    fclose(f);
    if (yaz0_size(p, len)) { uint8_t *o = yaz0_decompress(p, len, n); free(p); return o; }
    if (len >= 4 && !memcmp(p, "\x28\xb5\x2f\xfd", 4)) {
        unsigned long long sz = ZSTD_getFrameContentSize(p, len);
        if (sz == ZSTD_CONTENTSIZE_ERROR || sz == ZSTD_CONTENTSIZE_UNKNOWN || sz > (1u << 30)) return NULL;
        uint8_t *out = malloc(sz ? sz : 1);
        size_t got = ZSTD_decompress(out, sz, p, len);
        free(p);
        if (ZSTD_isError(got)) { free(out); return NULL; }
        *n = got;
        return out;
    }
    *n = len;
    return p;
}

static void scan_file(const char *path, const char *name) {
    size_t n = 0;
    uint8_t *p = NULL;
    p = load(path, &n);
    if (!p) return;
    // blob starts (4-byte aligned magic with a plausible SPH), each running to the next start or the file end
    size_t *starts = malloc(sizeof *starts * 65536);
    int ns = 0;
    for (size_t o = 0; o + 0x80 <= n && ns < 65536; o += 4) {
        if (*(const uint32_t *)(p + o) != 0x12345678u) continue;
        uint32_t sph0 = *(const uint32_t *)(p + o + 0x30);
        uint32_t type = (sph0 >> 10) & 0xF, ver = (sph0 >> 5) & 0x1F;
        if ((type == 1 || type == 5) && ver == 3) starts[ns++] = o;
    }
    if (ns) files++;
    if (getenv("CORPUS_LIST")) {  // (which files hold shaders: names and counts only)
        if (ns) printf("FILE %s %d\n", name, ns);
        free(starts);
        free(p);
        return;
    }
    for (int i = 0; i < ns; i++) {
        size_t o = starts[i], end = i + 1 < ns ? starts[i + 1] : n;
        uint32_t type = (*(const uint32_t *)(p + o + 0x30) >> 10) & 0xF;
        int stage = type == 1 ? STAGE_VERTEX : STAGE_FRAGMENT;
        blobs++;
        if (!seen_add(fnv(p + o, end - o > 0x4000 ? 0x4000 : end - o))) continue;
        unique++;
        by_stage[stage]++;
        ShaderKey key;
        memset(&key, 0, sizeof key);
        key.glsl = glsl;
        ShaderInfo *si = maxwell_translate(p + o, end - o, stage, &key);
        if (!si->msl) {
            tfail++;
            printf("TRANSLATE %s+%#zx %s: %s\n", name, o, stage == STAGE_VERTEX ? "vs" : "fs", si->error[0] ? si->error : "?");
            maxwell_free(si);
            continue;
        }
        if (dump) {
            char dp[2048];
            snprintf(dp, sizeof dp, "%s/%s_%zx_%s.glsl", dump, name, o, stage == STAGE_VERTEX ? "vs" : "fs");
            for (char *q = dp + strlen(dump) + 1; *q; q++) if (*q == '/') *q = '_';
            FILE *f = fopen(dp, "w");
            if (f) { fputs(si->msl, f); fclose(f); }
        }
        if (compile) {
            shaderc_compile_options_t opt = shaderc_compile_options_initialize();
            shaderc_compile_options_set_target_env(opt, shaderc_target_env_vulkan, shaderc_env_version_vulkan_1_3);
            shaderc_compilation_result_t r = shaderc_compile_into_spv(comp, si->msl, strlen(si->msl),
                stage == STAGE_VERTEX ? shaderc_vertex_shader : shaderc_fragment_shader, name, "main", opt);
            shaderc_compile_options_release(opt);
            if (shaderc_result_get_compilation_status(r) != shaderc_compilation_status_success) {
                cfail++;
                const char *msg = shaderc_result_get_error_message(r), *e = strstr(msg, "error:");
                const char *first = e ? e : msg, *nl = strchr(first, '\n');
                printf("COMPILE %s+%#zx %s: %.*s\n", name, o, stage == STAGE_VERTEX ? "vs" : "fs",
                       nl ? (int)(nl - first) : (int)strlen(first), first);
            }
            shaderc_result_release(r);
        }
        maxwell_free(si);
    }
    free(starts);
    free(p);
}

static void walk(const char *dir, const char *rel, int depth) {
    DIR *d = depth < 12 ? opendir(dir) : NULL;
    if (!d) return;
    struct dirent *e;
    while ((e = readdir(d))) {
        if (e->d_name[0] == '.') continue;
        char path[2048], r[2048];
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        snprintf(r, sizeof r, "%s%s%s", rel, *rel ? "/" : "", e->d_name);
        struct stat sb;
        if (stat(path, &sb)) continue;
        if (S_ISDIR(sb.st_mode)) walk(path, r, depth + 1);
        else scan_file(path, r);
    }
    closedir(d);
}

int main(int argc, char **argv) {
    {
        if (argc < 2) { fprintf(stderr, "usage: %s <romfs> [--no-compile] [--dump dir]\n", argv[0]); return 2; }
        const char *dir = argv[1];
        for (int i = 2; i < argc; i++) {
            if (!strcmp(argv[i], "--no-compile")) compile = false;
            else if (!strcmp(argv[i], "--glsl")) glsl = true;
            else if (!strcmp(argv[i], "--dump") && i + 1 < argc) dump = argv[++i];
            // (the guest heap as the runtime may bind it: --chunks <log2 bytes> windows, --lazy imported chunks)
            else if (!strcmp(argv[i], "--chunks") && i + 1 < argc) maxwell_gmem_chunk_shift = (uint32_t)atoi(argv[++i]);
            else if (!strcmp(argv[i], "--lazy")) maxwell_gmem_lazy = true;
        }
        comp = shaderc_compiler_initialize();
        maxwell_gmem_base = 0x7240000000ull;  // (rt.h HEAP_BASE, GPU_SPAN)
        maxwell_gmem_size = 0x110000000ull;
        walk(dir, "", 0);
        printf("files %d, blobs %d, unique %d (vs %d, fs %d): translate failures %d, compile failures %d\n", files, blobs,
               unique, by_stage[STAGE_VERTEX], by_stage[STAGE_FRAGMENT], tfail, cfail);
        return tfail || cfail ? 1 : 0;
    }
}
