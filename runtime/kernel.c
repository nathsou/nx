// A small Horizon kernel: handles, threads, synchronization, memory, and the SVC dispatcher.
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include "hle.h"
#include "kernel.h"
#include "game.h"
#include "settings.h"
#include <stdatomic.h>
#ifdef _WIN32
#include "platform/windows_threads.h"
#endif

// ------------------------------------------------------------------ results
#undef R_OK
#define R_OK 0
#define R_TIMEOUT 0xEA01
#define R_CANCELLED 0xEC01
#define R_INVALID_HANDLE 0xE401
#define R_INVALID_STATE 0xFA01
#define R_INVALID_ADDRESS 0xCC01
#define R_NOT_FOUND 0xF201
#define R_INVALID_ENUM 0xF001
#define R_OUT_OF_RESOURCE 0xD001

#define PSEUDO_THREAD 0xFFFF8000u
#define PSEUDO_PROCESS 0xFFFF8001u
#define WAITERS_BIT 0x40000000u

pthread_mutex_t g_klock = PTHREAD_MUTEX_INITIALIZER;
static __thread KThread *t_cur;

// ------------------------------------------------------------------ handle table
#define MAX_HANDLES 4096
static KObject *handles[MAX_HANDLES];

static uint32_t handle_alloc(KObject *o) {
    for (int i = 1; i < MAX_HANDLES; i++) {
        if (!handles[i]) {
            handles[i] = o;
            o->refs++;
            return 0x100 + i;
        }
    }
    FATAL("out of handles\n");
}

KObject *handle_get(uint32_t h) {
    if (h == PSEUDO_THREAD) return &t_cur->obj;
    if (h < 0x101 || h >= 0x100 + MAX_HANDLES) return NULL;
    return handles[h - 0x100];
}

uint32_t kernel_new_handle(KObject *o) {
    pthread_mutex_lock(&g_klock);
    uint32_t h = handle_alloc(o);
    pthread_mutex_unlock(&g_klock);
    return h;
}

static void handle_close(uint32_t h) {
    KObject *o = handle_get(h);
    if (!o || h == PSEUDO_THREAD) return;
    handles[h - 0x100] = NULL;
    o->refs--;
}

// Threads blocked in WaitSynchronization; object signals wake only these (caller holds g_klock).
static KThread *g_syncwaiters;

// Same-core preemption, approximated: on the Switch a thread that wakes a more urgent thread of its own core stops
// right there until that thread blocks again; here both run at once, and the game relies on that order in places
// (Dread's movie player frees what its dispatcher thread still waits on). wake() notes such threads (caller holds
// g_klock), and the waker, back from its SVC (rt_svc), waits until they block again - at most 5 ms.
// LARECOMP_NO_PREEMPT=1: off.
static __thread KThread *t_urgent[8];
static __thread int t_nurgent;
static void wake(KThread *t) {
    pthread_cond_signal(&t->cond);
    if (t_cur && t != t_cur && t->core == t_cur->core && t->prio < t_cur->prio && t_nurgent < 8) t_urgent[t_nurgent++] = t;
}
static void yield_to_woken(void) {
    static int off = -1;
    if (off < 0) off = getenv("LARECOMP_NO_PREEMPT") != NULL;
    if (off) { t_nurgent = 0; return; }
    uint64_t t0 = plat_now_ns();
    for (;;) {
        bool busy = false;
        pthread_mutex_lock(&g_klock);
        for (int i = 0; i < t_nurgent; i++) {
            KThread *t = t_urgent[i];
            if (!t->finished && t->wait_kind == WAIT_NONE && !t->in_sync_wait && !t->sleeping) busy = true;
        }
        pthread_mutex_unlock(&g_klock);
        // (bounded: a woken thread that keeps running must not stall its waker for long. Where the game's order matters
        // and a few ms aren't enough under load, it is fixed at the spot: runtime/hle/hooks.c, the movie dispatcher)
        if (!busy || plat_now_ns() - t0 > 5000000ull) break;
        usleep(10);
    }
    t_nurgent = 0;
}

void kernel_signal(KObject *o) {
    // caller holds g_klock
    o->signaled = true;
    for (KThread *t = g_syncwaiters; t; t = t->snext) wake(t);
}

// ------------------------------------------------------------------ time

// The game's clock: the host's at the game speed (menu: Video > Game speed, g_settings.speed; LARECOMP_TICK_SCALE=<x>
// at start). Continuous across a change of speed: (host, game) at the last change, read under a sequence counter.
// The guest's system tick and GPU timestamps follow it; its sleeps and timeouts, the emulated vsync (runtime/hle/vi.c),
// the present interval (runtime/nvn/objects.c) and the sound's rate (runtime/services/audio.c) are scaled by it.
static _Atomic uint32_t g_speed_seq;
static uint64_t g_speed_host0, g_speed_game0;
static double g_speed = 1;
double rt_speed(void) { return g_speed; }
uint64_t rt_game_ns(void) {
    uint64_t h0, g0;
    double sp;
    uint32_t s;
    do {
        while ((s = atomic_load(&g_speed_seq)) & 1) {}
        h0 = g_speed_host0, g0 = g_speed_game0, sp = g_speed;
    } while (atomic_load(&g_speed_seq) != s);
    uint64_t now = plat_now_ns();
    return sp == 1 && !g0 && !h0 ? now : g0 + (uint64_t)((double)(now - h0) * sp);
}
void rt_speed_set(double sp) {  // (any thread)
    static pthread_mutex_t mx = PTHREAD_MUTEX_INITIALIZER;
    if (sp < 0.1) sp = 0.1;
    pthread_mutex_lock(&mx);
    if (sp != g_speed) {
        uint64_t g = rt_game_ns(), h = plat_now_ns();
        atomic_fetch_add(&g_speed_seq, 1);
        g_speed_host0 = h, g_speed_game0 = g, g_speed = sp;
        atomic_fetch_add(&g_speed_seq, 1);
        LOG("[speed] the game runs at %.2fx\n", sp);
    }
    pthread_mutex_unlock(&mx);
}
// (the game's thread, each frame: the setting applied; at start, LARECOMP_TICK_SCALE)
void rt_speed_frame(void) {
    static int env = -1;
    static double env_speed;
    if (env < 0) env = getenv("LARECOMP_TICK_SCALE") && (env_speed = atof(getenv("LARECOMP_TICK_SCALE"))) > 0;
    double want = env ? env_speed : g_settings.speed > 0 ? g_settings.speed : 1;
    if (want != g_speed) rt_speed_set(want);
}
// A wait of the game's (ns of its clock) in host time
static int64_t game_wait_ns(int64_t ns) { return g_speed == 1 ? ns : (int64_t)(ns / g_speed); }

uint64_t rt_ticks(void) {  // 19.2 MHz system tick
    return (uint64_t)((__uint128_t)rt_game_ns() * 192 / 10000);
}

static void deadline(struct timespec *ts, int64_t timeout_ns) {
    timeout_ns = game_wait_ns(timeout_ns);
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec += timeout_ns / 1000000000;
    ts->tv_nsec += timeout_ns % 1000000000;
    if (ts->tv_nsec >= 1000000000) { ts->tv_sec++; ts->tv_nsec -= 1000000000; }
}

// Sleep on the current thread's condition. Returns false on timeout. Caller holds g_klock.
static pthread_cond_t g_nothread_cond = PTHREAD_COND_INITIALIZER;
// Time this thread spent blocked in the kernel (waits, sleeps): idle, not work. Frame pacing (nvn/pace.c)
// takes the presenting thread's: a frame's busy time is its period minus this.
__thread uint64_t g_blocked_ns;

// ------------------------------------------------------------------ per-core scheduling
// Horizon runs one thread at a time on each core: the most urgent runnable one (lowest priority number; among equals,
// the one already running keeps the core until it blocks or yields). Games rely on that order: a thread started on its
// creator's core doesn't run before the creator blocks (ACNH's first worker locks a mutex its creator sets up right
// after starting it), a more urgent thread woken on the waker's core runs before the waker goes on (Dread's movie
// player frees what its dispatcher still waits on), and threads that share a core never record into the same state at
// once (ACNH's layer jobs clear a render target at its first bind each frame: the first job of the core's order binds
// it, and running them in parallel let a later layer's job clear the finished UI).
// So a guest thread holds its core while it runs guest code: it takes it when it starts and after every kernel wait,
// gives it up when it waits (kwait), sleeps or yields, and at its next safe point (an SVC, an HLE call) when a more
// urgent thread of its core wants to run (it can't be stopped in between: guest code runs as native code). Threads
// whose affinity spans several cores aren't scheduled (Horizon migrates them freely). A thread that can't get its core
// within 1 s runs anyway (logged): a holder blocked in host code, outside the kernel, would otherwise hang the game.
// LARECOMP_NO_SCHED=1: off (every thread runs at once, with the old approximations: start_defer, yield_to_woken).
typedef struct {
    pthread_mutex_t m;
    pthread_cond_t cv;
    KThread *owner;
    uint64_t tickets;
    KThread *waiters[128];
    int nw;
} CoreSched;
static CoreSched g_cs[4] = {
    {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, {0}, 0},
    {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, {0}, 0},
    {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, {0}, 0},
    {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, NULL, 0, {0}, 0},
};
static int g_sched = -1;
static bool sched_on(void) {
    if (g_sched < 0) g_sched = getenv("LARECOMP_NO_SCHED") == NULL;
    return g_sched;
}
static bool sched_pinned(const KThread *t) {
    return t->core >= 0 && t->core < 4 && t->affinity && !(t->affinity & (t->affinity - 1));
}
static KThread *sched_best(CoreSched *c) {  // (c->m held) the queue's most urgent, first come among equals
    KThread *b = NULL;
    for (int i = 0; i < c->nw; i++) {
        KThread *w = c->waiters[i];
        if (!b || w->prio < b->prio || (w->prio == b->prio && w->sched_ticket < b->sched_ticket)) b = w;
    }
    return b;
}

static void sched_acquire(KThread *t) {
    if (!t || !sched_on() || t->sched_core >= 0 || !sched_pinned(t)) return;
    CoreSched *c = &g_cs[t->core];
    pthread_mutex_lock(&c->m);
    t->sched_ticket = ++c->tickets;
    if (c->nw < 128) c->waiters[c->nw++] = t;
    t->sched_waiting = true;
    if (c->owner && c->owner->prio > t->prio) c->owner->sched_preempt = true;  // more urgent: the holder yields
    uint64_t t0 = plat_now_ns();
    bool forced = false;
    while (!(c->owner == NULL && sched_best(c) == t) && !g_rt_unwind) {
        if (plat_now_ns() - t0 > 1000000000ull) { forced = true; break; }
        struct timespec ts;
        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_nsec += 5000000;
        if (ts.tv_nsec >= 1000000000) ts.tv_sec++, ts.tv_nsec -= 1000000000;
        pthread_cond_timedwait(&c->cv, &c->m, &ts);
    }
    for (int i = 0; i < c->nw; i++)
        if (c->waiters[i] == t) { c->waiters[i] = c->waiters[--c->nw]; break; }
    t->sched_waiting = false;
    if (!c->owner) c->owner = t, t->sched_core = t->core;
    static int logs = -1;  // LARECOMP_LOG_SCHED=<n>: the first n acquisitions and releases
    if (logs < 0) logs = getenv("LARECOMP_LOG_SCHED") ? atoi(getenv("LARECOMP_LOG_SCHED")) : 0;
    if (logs > 0) { logs--; LOG("[sched] %#x takes core %d%s (owner %#x)\n", t->handle, t->core, forced ? " (forced)" : "", c->owner ? c->owner->handle : 0); }
    pthread_mutex_unlock(&c->m);
    if (forced) {
        static int nlog;
        if (nlog++ < 20)
            LOG("[sched] thread %#x (prio %d, core %d) waited 1 s for its core (held by %#x): runs anyway\n", t->handle,
                t->prio, t->core, c->owner ? c->owner->handle : 0);
    }
}

static void sched_release(KThread *t) {
    if (!t || t->sched_core < 0) return;
    CoreSched *c = &g_cs[t->sched_core];
    pthread_mutex_lock(&c->m);
    if (getenv("LARECOMP_LOG_SCHED") && t->handle == 0x116) LOG("[sched] %#x releases core %d (owner %#x)\n", t->handle, t->sched_core, c->owner ? c->owner->handle : 0);
    if (c->owner == t) c->owner = NULL;
    t->sched_core = -1;
    pthread_cond_broadcast(&c->cv);
    pthread_mutex_unlock(&c->m);
}

// Host code about to block a guest thread outside the kernel (the render queue's fence waits: a GPU wait, a kernel
// wait on the Switch): the core goes to the next thread of its queue meanwhile; it's taken back at the next safe point.
void kernel_block_begin(void) {
    KThread *t = t_cur;
    if (t && t->sched_core >= 0) { sched_release(t); t->sched_resched = true; }
}

// A safe point (SVC entry / exit, HLE call): give the core to a more urgent thread that wants it; take it back after
// a wait gave it up.
void kernel_sched_point(void) {
    KThread *t = t_cur;
    if (!t || !sched_on()) return;
    if (t->sched_preempt) {
        t->sched_preempt = false;
        sched_release(t);
        sched_acquire(t);
    } else if (t->sched_resched || (t->sched_core < 0 && sched_pinned(t))) {
        t->sched_resched = false;
        sched_acquire(t);
    }
}

static bool kwait(int64_t timeout_ns, const struct timespec *ts) {
    pthread_cond_t *cv = t_cur ? &t_cur->cond : &g_nothread_cond;
    if (t_cur && t_cur->sched_core >= 0) { sched_release(t_cur); t_cur->sched_resched = true; }  // (blocked: not runnable)
    uint64_t t0 = plat_now_ns();
    bool r = true;
    if (timeout_ns < 0) pthread_cond_wait(cv, &g_klock);
    else r = pthread_cond_timedwait(cv, &g_klock, ts) == 0;
    g_blocked_ns += plat_now_ns() - t0;
    return r;
}

// ------------------------------------------------------------------ memory map
typedef struct { uint64_t addr, size; uint32_t type, perm; } Region;
static Region regions[1024];
static int nregions;
static uint64_t heap_size;
static uint64_t tls_next = TLS_BASE;
uint64_t kernel_heap_size(void) { return heap_size; }  // bytes from HEAP_BASE set by SetHeapSize
// Writable guest data regions (heap, mapped/physical memory, module .data): for debug/runtime memory scans.
int kernel_data_regions(uint64_t *addr, uint64_t *size, int max) {
    int n = 0;
    for (int i = 0; i < nregions && n < max; i++)
        if ((regions[i].perm & 2) && regions[i].type != 0xB && regions[i].type != 0xC) {
            addr[n] = regions[i].addr; size[n] = regions[i].size; n++;
        }
    return n;
}

static void region_add(uint64_t addr, uint64_t size, uint32_t type, uint32_t perm) {
    if (nregions == 1024) FATAL("too many regions\n");
    plat_commit(addr, size);  // back it before the OS writes there (Windows: file reads into the heap)
    int i = nregions++;
    while (i > 0 && regions[i - 1].addr > addr) { regions[i] = regions[i - 1]; i--; }
    regions[i] = (Region){addr, size, type, perm};
}

static void region_remove(uint64_t addr) {
    for (int i = 0; i < nregions; i++) {
        if (regions[i].addr == addr) {
            memmove(&regions[i], &regions[i + 1], (nregions - i - 1) * sizeof(Region));
            nregions--;
            return;
        }
    }
}

static void query_memory(uint64_t addr, uint64_t out) {
    uint64_t prev_end = 0;
    uint64_t info[5] = {0};  // addr, size, type|attr<<32, perm|ipc<<32, device|pad<<32
    for (int i = 0; i < nregions; i++) {
        Region *r = &regions[i];
        if (addr >= r->addr && addr < r->addr + r->size) {
            info[0] = r->addr;
            info[1] = r->size;
            info[2] = r->type;
            info[3] = r->perm;
            memcpy((void *)out, info, 0x28);
            return;
        }
        if (addr < r->addr) {
            info[0] = prev_end;
            info[1] = r->addr - prev_end;
            memcpy((void *)out, info, 0x28);
            return;
        }
        prev_end = r->addr + r->size;
    }
    info[0] = prev_end;
    info[1] = (1ull << 39) - prev_end;
    memcpy((void *)out, info, 0x28);
}

// ------------------------------------------------------------------ threads
static uint64_t next_thread_id = 0x50;

// ------------------------------------------------------------------ in-place reboot
// Recompiled guest code can't be killed from outside, so a reboot (runtime/main.c) sets g_rt_unwind, wakes every
// waiting thread, and each guest thread longjmps back to thread_main at its next safe point: rt_svc (entry and
// exit), an HLE call (runtime/dispatch.c), or a kernel wait (which returns early while g_rt_unwind is set). The
// frames dropped are recompiled code (its state lives in guest memory, which is wiped next) and HLE functions;
// none of those hold a host lock across a call into the guest, so nothing stays locked. svcExitThread ends a
// thread the same way.
volatile int g_rt_unwind;
static KThread *g_threads;  // every thread of this boot (g_klock)

void rt_unwind_point(void) {
    if (__builtin_expect(g_rt_unwind, 0) && t_cur) longjmp(t_cur->unwind, 1);
}

// Start order, approximated: on the Switch a thread started on its creator's core, with the same priority or less
// urgent, doesn't run before the creator blocks (waits, sleeps, yields): nothing preempts the creator for it. Games rely
// on it - ACNH's first worker locks a mutex its creator sets up right after starting it. Here every thread runs at
// once, so a new thread holds back until its creator's next blocking call (block_seq), its exit, or 500 ms.
// LARECOMP_NO_START_DEFER=1: off.
static void start_defer(KThread *t) {
    KThread *c = t->start_after;
    uint64_t t0 = plat_now_ns();
    while (!c->finished && c->block_seq == t->start_seq && !g_rt_unwind) {
        if (plat_now_ns() - t0 > 500000000ull) {
            LOG("[kernel] thread %#x: its creator %#x hasn't blocked in 500 ms: starting anyway\n", t->handle, c->handle);
            break;
        }
        usleep(20);
    }
}

static void *thread_main(void *arg) {
    KThread *t = arg;
    t_cur = t;
    t->sched_core = -1;
    if (sched_on()) sched_acquire(t);
    else if (t->start_after) start_defer(t);
    plat_thread_guest(t->prio);
    if (t->is_main) plat_thread_perf_core(PLAT_PERF_GAME);  // (the game's frame runs here)
    crash_handler_install();
    rt_set_fpcr(0);
    if (!setjmp(t->unwind)) guest_call(&t->cpu, t->entry);
    sched_release(t);
    pthread_mutex_lock(&g_klock);
    t->finished = true;
    if (getenv("LARECOMP_LOG_MOVIE")) LOG("[thread] handle %#x entry %llx arg %llx exited t=%llu\n", t->handle,
                                           (unsigned long long)t->entry, (unsigned long long)t->cpu.x[0],
                                           (unsigned long long)(plat_now_ns() / 1000));
    kernel_signal(&t->obj);
    pthread_mutex_unlock(&g_klock);
    t_cur = NULL;
    return NULL;
}

static int g_default_core;  // main.npdm's (the process's default core: what core -2 means)

static KThread *thread_new(uint64_t entry, uint64_t arg, uint64_t stack_top, int prio, int core) {
    KThread *t = calloc(1, sizeof *t);
    t->sched_core = -1;
    if (core == -2) core = g_default_core;
    t->affinity = core >= 0 && core < 4 ? 1ull << core : 0xF;
    pthread_cond_init(&t->cond, NULL);
    t->obj.type = KOBJ_THREAD;
    t->entry = entry;
    t->prio = prio;
    t->core = core < 0 ? 0 : core;
    t->cpu.x[0] = arg;
    t->cpu.sp = stack_top & ~15ull;
    t->cpu.excl_addr = ~0ull;
    t->cpu.thread = t;
    pthread_mutex_lock(&g_klock);  // (two guest threads may create threads at once: one id and TLS slot each)
    t->id = next_thread_id++;
    t->tlr = tls_next;
    tls_next += 0x200;
    t->cpu.tpidrro = t->tlr;
    t->anext = g_threads;
    g_threads = t;
    pthread_mutex_unlock(&g_klock);
    return t;
}

static void thread_start(KThread *t) {
#ifdef _WIN32
    t->host = guest_thread_create(thread_main, t, 256u << 20);
    if (!t->host) FATAL("Could not create a game thread.\n");
    t->started = true;
#else
    pthread_attr_t attr;
    pthread_attr_init(&attr);
    pthread_attr_setstacksize(&attr, 256ull << 20);  // guest recursion runs on the host stack
    t->started = true;
    pthread_create(&t->host, &attr, thread_main, t);
    pthread_attr_destroy(&attr);
#endif
}

KThread *kernel_create_main_thread(uint64_t entry, uint64_t stack_size, int prio, int core) {
    uint64_t stack = STACK_BASE + STACK_SIZE - ((stack_size + 0xFFFF) & ~0xFFFFull);
    region_add(stack, stack_size, 0xB, 3);
    g_default_core = core >= 0 && core < 4 ? core : 0;
    KThread *t = thread_new(entry, 0, stack + stack_size, prio, g_default_core);
    t->is_main = true;
    t->handle = kernel_new_handle(&t->obj);
    return t;
}

static KThread *g_main_thread;  // (g_klock) for hang_watch
static void *hang_watch(void *arg);

void kernel_run_main(KThread *t, uint64_t x0, uint64_t x1, uint64_t x2, uint64_t x3, uint64_t x4) {
    t->cpu.x[0] = x0; t->cpu.x[1] = x1; t->cpu.x[2] = x2; t->cpu.x[3] = x3; t->cpu.x[4] = x4;
    thread_start(t);  // the host main thread goes on to run the window event loop
    pthread_mutex_lock(&g_klock);
    g_main_thread = t;
    pthread_mutex_unlock(&g_klock);
    static bool watching;
    const char *e = getenv("LARECOMP_HANG_DUMP");
    uint64_t s = e ? strtoull(e, NULL, 10) : 30;
    if (!watching && s) {
        watching = true;
        pthread_t w;
        if (!pthread_create(&w, NULL, hang_watch, (void *)(uintptr_t)s)) pthread_detach(w);
    }
}

// LARECOMP_DUMP_THREADS_AT=<seconds>[,...] (debugging): every thread's state at those times after boot
static void *dump_at(void *arg) {
    const char *e = arg;
    uint64_t t0 = plat_now_ns();
    for (char *p = (char *)e; p && *p;) {
        double at = strtod(p, &p);
        while (*p == ',') p++;
        uint64_t when = t0 + (uint64_t)(at * 1e9), now = plat_now_ns();
        if (when > now) usleep((useconds_t)((when - now) / 1000));
        LOG("[threads] ===== at %.1f s =====\n", at);
        kernel_dump_threads("[threads]");
    }
    return NULL;
}
__attribute__((constructor)) static void dump_at_start(void) {
    const char *e = getenv("LARECOMP_DUMP_THREADS_AT");
    pthread_t w;
    if (e && *e && !pthread_create(&w, NULL, dump_at, (void *)e)) pthread_detach(w);
}

uint32_t kernel_current_thread_handle(void) { return t_cur ? t_cur->handle : 0; }
Cpu *kernel_current_cpu(void) { return t_cur ? &t_cur->cpu : NULL; }
KThread *kernel_current_thread(void) { return t_cur; }
uint64_t kernel_current_thread_id(void) { return t_cur ? t_cur->id : 0; }

// ------------------------------------------------------------------ mutex / condvar (Horizon semantics)
// Mutex word: owner handle | WAITERS_BIT. Waiting threads sleep on the global cond and are handed ownership.

static uint32_t *u32p(uint64_t a) { return (uint32_t *)(uintptr_t)a; }

// Try to take mutex `m` for `tag`, or mark it contended. Returns true if acquired. Uses CAS so a
// concurrent user-space unlock (owner storing 0) is never overwritten.
static bool mutex_acquire_or_mark(uint64_t m, uint32_t tag) {
    for (;;) {
        uint32_t v = __atomic_load_n(u32p(m), __ATOMIC_SEQ_CST);
        if (v == 0) {
            if (__atomic_compare_exchange_n(u32p(m), &v, tag, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) return true;
        } else {
            if ((v & WAITERS_BIT) ||
                __atomic_compare_exchange_n(u32p(m), &v, v | WAITERS_BIT, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST))
                return false;
        }
    }
}

// Pick a thread waiting on mutex `addr` and give it ownership. Caller holds g_klock.
static void mutex_release(uint64_t addr) {
    KThread *next = NULL;
    int count = 0;
    for (KThread *t = g_waitlist; t; t = t->wnext) {
        if (t->wait_kind == WAIT_MUTEX && t->wait_addr == addr) {
            if (!next || t->prio < next->prio) next = t;
            count++;
        }
    }
    if (!next) {
        __atomic_store_n(u32p(addr), 0, __ATOMIC_SEQ_CST);
        return;
    }
    __atomic_store_n(u32p(addr), next->handle | (count > 1 ? WAITERS_BIT : 0), __ATOMIC_SEQ_CST);
    next->wait_kind = WAIT_NONE;
    next->wait_result = R_OK;
    wake(next);
}

KThread *g_waitlist;

// At the end: the wakers take the most urgent waiter and, among equals, the first found - the longest waiting, as
// Horizon (first in, first out within a priority). Added at the head, the latest waiter won every tie.
static void waitlist_add(KThread *t) {
    KThread **p = &g_waitlist;
    while (*p) p = &(*p)->wnext;
    t->wnext = NULL;
    *p = t;
}
static void waitlist_remove(KThread *t) {
    for (KThread **p = &g_waitlist; *p; p = &(*p)->wnext)
        if (*p == t) { *p = t->wnext; return; }
}

// Block until wait_kind is cleared by a waker, timeout, or a reboot. Caller holds g_klock.
// CancelSynchronization doesn't end these waits (mutex, condition variable, address arbiter), as on Horizon: its flag
// is for the thread's next WaitSynchronization only. Ending them used the flag up there (a cancel meant to wake a
// thread out of a WaitSynchronization could be lost), and the SDK's untimed condition variable wait treats any
// result but success as fatal.
static uint32_t block_current(int64_t timeout_ns) {
    KThread *t = t_cur;
    struct timespec ts;
    if (timeout_ns >= 0) deadline(&ts, timeout_ns);
    t->wait_since = plat_now_ns();
    waitlist_add(t);
    while (t->wait_kind != WAIT_NONE) {
        if (g_rt_unwind) {  // reboot: give up the wait (the thread unwinds when its svc returns)
            t->wait_kind = WAIT_NONE;
            t->wait_result = R_CANCELLED;
            break;
        }
        if (!kwait(timeout_ns, &ts)) {
            if (t->wait_kind == WAIT_NONE) break;  // (woken just as the time ran out: the waker's result stands)
            t->wait_kind = WAIT_NONE;
            t->wait_result = R_TIMEOUT;
            break;
        }
    }
    waitlist_remove(t);
    return t->wait_result;
}

// (diagnostics) the last KTRACE_N condition variable (untimed waits) / mutex kernel calls, lock-free, for the [hang] dump: what each
// thread did with which key / mutex word, and the words before and after. LARECOMP_KTRACE=0 turns it off.
enum { KT_WAIT, KT_WAIT_END, KT_SIGNAL, KT_LOCK, KT_LOCK_END, KT_UNLOCK };
#define KTRACE_N 256
typedef struct { uint64_t ns, tid, addr, addr2; uint32_t w0, w1, w2, arg, kind; } KTrace;
static KTrace ktrace[KTRACE_N];
static uint64_t ktrace_n;  // (__atomic builtins)
static int ktrace_on = -1;
static void kt(uint32_t kind, uint64_t addr, uint64_t addr2, uint32_t w0, uint32_t w1, uint32_t w2, uint32_t arg) {
    if (ktrace_on < 0) ktrace_on = !getenv("LARECOMP_KTRACE") || atoi(getenv("LARECOMP_KTRACE")) != 0;
    if (!ktrace_on) return;
    KTrace *e = &ktrace[__atomic_fetch_add(&ktrace_n, 1, __ATOMIC_RELAXED) % KTRACE_N];
    *e = (KTrace){plat_now_ns(), t_cur ? t_cur->id : 0, addr, addr2, w0, w1, w2, arg, kind};
}
static uint32_t rdw(uint64_t a) { return a ? __atomic_load_n(u32p(a), __ATOMIC_SEQ_CST) : 0; }
// Keys used with timed waits (periodic pollers, e.g. a 1 ms timer thread) would fill the ring within a second: their
// waits and signals are left out (g_klock).
static uint64_t kt_timed[16];
static bool kt_timed_key(uint64_t key, bool add) {
    for (int i = 0; i < 16; i++) {
        if (kt_timed[i] == key) return true;
        if (!kt_timed[i] && add) { kt_timed[i] = key; return true; }
    }
    return false;
}

static uint32_t svc_arbitrate_lock(uint32_t owner, uint64_t addr, uint32_t tag) {
    pthread_mutex_lock(&g_klock);
    uint32_t v = __atomic_load_n(u32p(addr), __ATOMIC_SEQ_CST);
    kt(KT_LOCK, addr, 0, v, 0, owner, tag);
    if (v != (owner | WAITERS_BIT)) {
        pthread_mutex_unlock(&g_klock);
        return R_OK;
    }
    KThread *t = t_cur;
    t->wait_kind = WAIT_MUTEX;
    t->wait_addr = addr;
    t->wait_tag = tag;
    uint32_t r = block_current(-1);
    kt(KT_LOCK_END, addr, 0, rdw(addr), 0, 0, r);
    pthread_mutex_unlock(&g_klock);
    return r == R_CANCELLED ? R_OK : r;
}

static uint32_t svc_arbitrate_unlock(uint64_t addr) {
    pthread_mutex_lock(&g_klock);
    uint32_t before = rdw(addr);
    mutex_release(addr);
    kt(KT_UNLOCK, addr, 0, before, rdw(addr), 0, 0);
    pthread_mutex_unlock(&g_klock);
    return R_OK;
}

static uint32_t svc_wait_process_wide_key(uint64_t mutex, uint64_t key, uint32_t tag, int64_t timeout) {
    static long late_us = -1;  // (test) LARECOMP_DEBUG_CV_LATE_WAIT=<us>: every condition variable wait starts that late
    if (late_us < 0) late_us = getenv("LARECOMP_DEBUG_CV_LATE_WAIT") ? atol(getenv("LARECOMP_DEBUG_CV_LATE_WAIT")) : 0;
    if (late_us > 0) usleep((useconds_t)late_us);  // (forces notify-before-wait races in the game's code: hle/delegate_null.c)
    pthread_mutex_lock(&g_klock);
    KThread *t = t_cur;
    uint32_t mbefore = rdw(mutex), kbefore = rdw(key);
    mutex_release(mutex);
    bool traced = !kt_timed_key(key, timeout >= 0);
    if (traced) kt(KT_WAIT, key, mutex, kbefore, mbefore, rdw(mutex), 0xffffffffu);
    t->wait_kind = WAIT_CONDVAR;
    t->wait_addr = key;
    t->wait_mutex = mutex;
    t->wait_tag = tag;
    __atomic_store_n(u32p(key), 1, __ATOMIC_SEQ_CST);
    // Timed out / cancelled: returns without the mutex, as Horizon does - nn::os takes it again itself (TimedWait on
    // 0xEA01 calls the critical section's Enter). Taking it here as well left the thread holding it when Enter ran:
    // Enter saw its own handle in the lock word and ArbitrateLock waited on itself forever (issue #19's thread dump: a
    // controller thread's timer-event wait).
    uint32_t r = block_current(timeout);
    if (traced) kt(KT_WAIT_END, key, mutex, rdw(key), rdw(mutex), 0, r);
    pthread_mutex_unlock(&g_klock);
    return r;
}

static void svc_signal_process_wide_key(uint64_t key, int32_t count) {
    pthread_mutex_lock(&g_klock);
    uint32_t kbefore = rdw(key);
    int woken = 0;
    bool any_left = false;
    for (;;) {
        if (count > 0 && woken >= count) break;
        KThread *best = NULL;
        for (KThread *t = g_waitlist; t; t = t->wnext)
            if (t->wait_kind == WAIT_CONDVAR && t->wait_addr == key && (!best || t->prio < best->prio)) best = t;
        if (!best) break;
        woken++;
        // the woken thread must reacquire its mutex
        uint64_t m = best->wait_mutex;
        best->wait_result = R_OK;
        if (mutex_acquire_or_mark(m, best->wait_tag)) {
            best->wait_kind = WAIT_NONE;
            wake(best);
        } else {
            best->wait_kind = WAIT_MUTEX;
            best->wait_addr = m;
        }
    }
    for (KThread *t = g_waitlist; t; t = t->wnext)
        if (t->wait_kind == WAIT_CONDVAR && t->wait_addr == key) any_left = true;
    if (!any_left) __atomic_store_n(u32p(key), 0, __ATOMIC_SEQ_CST);
    if (!kt_timed_key(key, false)) kt(KT_SIGNAL, key, 0, kbefore, rdw(key), (uint32_t)woken, (uint32_t)count);
    pthread_mutex_unlock(&g_klock);
}

// ------------------------------------------------------------------ address arbiter
enum { ARB_WAIT_LESS = 0, ARB_DEC_WAIT_LESS = 1, ARB_WAIT_EQ = 2 };
enum { ARB_SIGNAL = 0, ARB_SIGNAL_INC_EQ = 1, ARB_SIGNAL_MOD_EQ = 2 };

static uint32_t svc_wait_for_address(uint64_t addr, uint32_t type, int32_t value, int64_t timeout) {
    pthread_mutex_lock(&g_klock);
    int32_t cur = (int32_t)__atomic_load_n(u32p(addr), __ATOMIC_SEQ_CST);
    bool wait;
    if (type == ARB_WAIT_LESS) wait = cur < value;
    else if (type == ARB_DEC_WAIT_LESS) {
        // Atomically, as Horizon: the game changes these words in user space (exclusive load / store, no kernel
        // lock), and a plain store of the value read before overwrote such a change - a lost signal.
        uint32_t v = (uint32_t)cur;
        while ((wait = (int32_t)v < value) &&
               !__atomic_compare_exchange_n(u32p(addr), &v, v - 1, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {}
    } else if (type == ARB_WAIT_EQ) wait = cur == value;
    else { pthread_mutex_unlock(&g_klock); return R_INVALID_ENUM; }
    if (!wait) { pthread_mutex_unlock(&g_klock); return R_INVALID_STATE; }
    if (timeout == 0) { pthread_mutex_unlock(&g_klock); return R_TIMEOUT; }
    t_cur->wait_kind = WAIT_ARBITER;
    t_cur->wait_addr = addr;
    uint32_t r = block_current(timeout);
    pthread_mutex_unlock(&g_klock);
    return r;
}

static int arbiter_wake(uint64_t addr, int32_t count) {  // (the most urgent waiters first, as Horizon)
    int woken = 0;
    while (count <= 0 || woken < count) {
        KThread *best = NULL;
        for (KThread *t = g_waitlist; t; t = t->wnext)
            if (t->wait_kind == WAIT_ARBITER && t->wait_addr == addr && (!best || t->prio < best->prio)) best = t;
        if (!best) break;
        best->wait_kind = WAIT_NONE;
        best->wait_result = R_OK;
        wake(best);
        woken++;
    }
    return woken;
}

// The word at addr from `expected` to `desired` if it still holds `expected` (user space may change it any time).
static bool arbiter_update(uint64_t addr, int32_t expected, int32_t desired) {
    uint32_t e = (uint32_t)expected;
    return __atomic_compare_exchange_n(u32p(addr), &e, (uint32_t)desired, false, __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
}

static uint32_t svc_signal_to_address(uint64_t addr, uint32_t type, int32_t value, int32_t count) {
    pthread_mutex_lock(&g_klock);
    uint32_t r = R_OK;
    if (type == ARB_SIGNAL) {
        arbiter_wake(addr, count);
    } else if (type == ARB_SIGNAL_INC_EQ) {
        if (!arbiter_update(addr, value, value + 1)) r = R_INVALID_STATE;
        else arbiter_wake(addr, count);
    } else if (type == ARB_SIGNAL_MOD_EQ) {
        int waiting = 0;
        for (KThread *t = g_waitlist; t; t = t->wnext)
            if (t->wait_kind == WAIT_ARBITER && t->wait_addr == addr) waiting++;
        int32_t nv;
        if (count <= 0) nv = waiting > 0 ? value - 2 : value + 1;
        else nv = waiting == 0 ? value + 1 : (waiting <= count ? value - 1 : value);
        if (!arbiter_update(addr, value, nv)) r = R_INVALID_STATE;
        else arbiter_wake(addr, count);
    } else {
        r = R_INVALID_ENUM;
    }
    pthread_mutex_unlock(&g_klock);
    return r;
}

// ------------------------------------------------------------------ wait synchronization

static uint32_t svc_wait_synchronization(uint64_t handles_ptr, int32_t count, int64_t timeout, int32_t *index) {
    pthread_mutex_lock(&g_klock);
    struct timespec ts;
    if (timeout > 0) deadline(&ts, timeout);
    KThread *t = t_cur;
    uint32_t *hs = (uint32_t *)(uintptr_t)handles_ptr;
    uint32_t r;
    if (ENV("LARECOMP_VSYNC_BT")) {  // (debug) who waits for the display's vsync event: the game's frame loop
        extern uint32_t vi_vsync_handle(void);
        static int shown;
        for (int i = 0; i < count && shown < 2; i++)
            if (hs[i] && hs[i] == vi_vsync_handle()) {
                shown++;
                LOG("[vsync-bt] wait on vsync (%d handles, timeout %lld) lr %llx:\n", count, (long long)timeout,
                    (unsigned long long)(t ? t->cpu.x[30] : 0));
                plat_print_backtrace();
            }
    }
    for (;;) {
        for (int i = 0; i < count; i++) {
            KObject *o = handle_get(hs[i]);
            if (!o) { r = R_INVALID_HANDLE; goto out; }
            if (o->signaled) { *index = i; r = R_OK; goto out; }
        }
        if (timeout == 0) { r = R_TIMEOUT; goto out; }  // (before the cancel: a poll leaves it for the next real wait)
        if (t->cancel) { t->cancel = false; r = R_CANCELLED; goto out; }
        if (g_rt_unwind) { r = R_CANCELLED; goto out; }
        t->in_sync_wait = true;
        t->wait_since = plat_now_ns();
        t->sync_handles = handles_ptr, t->sync_count = count;
        t->snext = g_syncwaiters;
        g_syncwaiters = t;
        bool ok = kwait(timeout < 0 ? -1 : timeout, &ts);
        for (KThread **p = &g_syncwaiters; *p; p = &(*p)->snext)
            if (*p == t) { *p = t->snext; break; }
        t->in_sync_wait = false;
        if (!ok) { r = R_TIMEOUT; goto out; }
    }
out:
    pthread_mutex_unlock(&g_klock);
    return r;
}

// ------------------------------------------------------------------ debug output
static void debug_string(uint64_t p, uint64_t len) {
    fprintf(stderr, "[guest] %.*s", (int)len, (const char *)(uintptr_t)p);
    if (len && ((const char *)(uintptr_t)p)[len - 1] != '\n') fputc('\n', stderr);
}

// ------------------------------------------------------------------ SVC dispatch
static int trace_svc = -1;

static void svc_impl(Cpu *c, uint32_t imm, uint64_t pc);

static _Atomic uint64_t svc_wait_ns[32][0x80], svc_calls[32][0x80];
static int prof_svc = -1;

static void svc_entry(Cpu *c, uint32_t imm, uint64_t pc);
void rt_svc(Cpu *c, uint32_t imm, uint64_t pc) {
    rt_unwind_point();
    kernel_sched_point();
    svc_entry(c, imm, pc);
    if (sched_on()) t_nurgent = 0, kernel_sched_point();
    else if (t_nurgent) yield_to_woken();
    rt_unwind_point();
}

static void svc_entry(Cpu *c, uint32_t imm, uint64_t pc) {
    // (the calls that can block or yield: SleepThread, WaitSynchronization, ArbitrateLock, WaitProcessWideKeyAtomic,
    // WaitForAddress - see start_defer)
    if (t_cur && (imm == 0x0B || imm == 0x18 || imm == 0x1A || imm == 0x1C || imm == 0x34)) t_cur->block_seq++;
    if (prof_svc < 0) prof_svc = ENV("LARECOMP_PROF_SVC") != NULL;
    if (prof_svc && imm < 0x80) {
        uint64_t a0 = c->x[0], a1 = c->x[1], a2 = c->x[2], a3 = c->x[3], lr = c->x[30];
        uint32_t h0 = imm == 0x18 && a2 ? *(uint32_t *)(uintptr_t)a1 : 0;
        uint64_t t0 = plat_now_ns();
        svc_impl(c, imm, pc);
        uint64_t dt = plat_now_ns() - t0;
        static _Atomic int nslow;
        if (((t_cur && t_cur->id == 80 && (imm == 0x18 || imm == 0x34)) || (dt > 10000000 && imm != 0x0b && imm != 0x1c)) && nslow < 20000) {
            nslow++;
            LOG("[slow] t%llu svc%02x %llums a=%llx,%llx,%llx,%llx h0=%x lr=%llx\n", (unsigned long long)(t_cur ? t_cur->id : 0), imm,
                (unsigned long long)(dt / 1000000), (unsigned long long)a0, (unsigned long long)a1, (unsigned long long)a2, (unsigned long long)a3, h0, (unsigned long long)lr);
        }
        unsigned tid = t_cur ? (unsigned)(t_cur->id & 31) : 31;
        svc_wait_ns[tid][imm] += dt;
        svc_calls[tid][imm]++;
        static _Atomic uint64_t last;
        uint64_t now = plat_now_ns();
        if (now - last > 2000000000ull) {
            last = now;
            for (int t = 0; t < 32; t++) {
                int any = 0;
                for (int i = 0; i < 0x80; i++)
                    if (svc_calls[t][i]) {
                        if (!any) { LOG("[svcprof] t%d", t); any = 1; }
                        LOG(" %02x:%llu/%llums", i, (unsigned long long)svc_calls[t][i], (unsigned long long)(svc_wait_ns[t][i] / 1000000));
                        svc_calls[t][i] = 0; svc_wait_ns[t][i] = 0;
                    }
                if (any) LOG("\n");
            }
        }
        return;
    }
    if (trace_svc < 0) trace_svc = getenv("LARECOMP_TRACE_SVC") != NULL;
    if (!trace_svc) return svc_impl(c, imm, pc);
    uint64_t in[4] = {c->x[0], c->x[1], c->x[2], c->x[3]};
    svc_impl(c, imm, pc);
    LOG("[svc] %02x(%llx, %llx, %llx, %llx) -> %llx %llx %llx  @%llx\n", imm, in[0], in[1], in[2], in[3], c->x[0],
        c->x[1], c->x[2], pc);
}

static void svc_impl(Cpu *c, uint32_t imm, uint64_t pc) {
    uint64_t *x = c->x;
    switch (imm) {
    case 0x01: {  // SetHeapSize
        uint64_t size = x[1];
        LOG("[kernel] SetHeapSize %#llx\n", (unsigned long long)size);
        if (size > HEAP_MAX) { x[0] = R_OUT_OF_RESOURCE; break; }
        heap_size = size;
        region_remove(HEAP_BASE);
        if (size) region_add(HEAP_BASE, size, 5, 3);
        x[0] = R_OK;
        x[1] = HEAP_BASE;
        break;
    }
    case 0x02: case 0x03: x[0] = R_OK; break;  // SetMemoryPermission / SetMemoryAttribute
    case 0x04:  // MapMemory(dst, src, size): src is inaccessible while mapped, so copying is equivalent
        memcpy((void *)x[0], (void *)x[1], x[2]);
        region_add(x[0], x[2], 0xB, 3);
        x[0] = R_OK;
        break;
    case 0x05:  // UnmapMemory(dst, src, size): copy back
        memcpy((void *)x[1], (void *)x[0], x[2]);
        region_remove(x[0]);
        x[0] = R_OK;
        break;
    case 0x06:  // QueryMemory(out_info, _, addr)
        query_memory(x[2], x[0]);
        x[0] = R_OK;
        x[1] = 0;
        break;
    case 0x07: LOG("ExitProcess\n"); exit(0);
    case 0x08: {  // CreateThread(_, entry, arg, stack_top, prio, core)
        KThread *t = thread_new(x[1], x[2], x[3], (int)x[4], (int)(int32_t)x[5]);
        t->handle = kernel_new_handle(&t->obj);
        LOG("[kernel] CreateThread entry=%llx arg=%llx stack=%llx prio=%d core=%d -> %x\n", x[1], x[2], x[3], (int)x[4], (int)(int32_t)x[5], t->handle);
        x[0] = R_OK;
        x[1] = t->handle;
        break;
    }
    case 0x09: {  // StartThread
        KObject *o = handle_get((uint32_t)x[0]);
        if (!o || o->type != KOBJ_THREAD) { x[0] = R_INVALID_HANDLE; break; }
        KThread *nt = (KThread *)o;
        static int defer = -1;
        if (defer < 0) defer = getenv("LARECOMP_NO_START_DEFER") == NULL;
        if (defer && !sched_on() && t_cur && nt->core == t_cur->core && nt->prio >= t_cur->prio)
            nt->start_after = t_cur, nt->start_seq = t_cur->block_seq;
        thread_start(nt);
        x[0] = R_OK;
        break;
    }
    case 0x0A: longjmp(t_cur->unwind, 1);  // ExitThread: back to thread_main, which signals the thread object
    case 0x0B: {  // SleepThread (in slices of at most 50 ms: a reboot doesn't wait out a long sleep)
        int64_t ns = (int64_t)x[0];
        if (ns <= 0) {  // a yield: the core goes to the next thread of its queue (equal priority included)
            if (t_cur->sched_core >= 0) { sched_release(t_cur); t_cur->sched_resched = true; }
            else sched_yield();
            break;
        }
        if (t_cur->sched_core >= 0) { sched_release(t_cur); t_cur->sched_resched = true; }
        t_cur->sleeping = true;
        for (uint64_t end = plat_now_ns() + (uint64_t)game_wait_ns(ns), now; !g_rt_unwind && (now = plat_now_ns()) < end;) {
            uint64_t d = end - now < 50000000 ? end - now : 50000000;
            struct timespec ts = {(time_t)(d / 1000000000), (long)(d % 1000000000)};
            nanosleep(&ts, NULL);
            g_blocked_ns += plat_now_ns() - now;
        }
        t_cur->sleeping = false;
        break;
    }
    case 0x0C: {  // GetThreadPriority(_, handle)
        KObject *o = handle_get((uint32_t)x[1]);
        x[0] = o ? R_OK : R_INVALID_HANDLE;
        x[1] = o ? (uint64_t)((KThread *)o)->prio : 0;
        break;
    }
    case 0x0D: {  // SetThreadPriority
        KObject *o = handle_get((uint32_t)x[0]);
        if (o) ((KThread *)o)->prio = (int)x[1];
        x[0] = o ? R_OK : R_INVALID_HANDLE;
        break;
    }
    case 0x0E: {  // GetThreadCoreMask(_, _, handle)
        KObject *o = handle_get((uint32_t)x[2]);
        x[0] = o ? R_OK : R_INVALID_HANDLE;
        x[1] = o ? (uint64_t)((KThread *)o)->core : 0;
        x[2] = o ? ((KThread *)o)->affinity : 0xF;
        break;
    }
    case 0x0F: {  // SetThreadCoreMask(handle, ideal core, affinity): ideal -1 any core of the mask, -2 the process's
                  // default, -3 keep it (only the mask changes)
        KObject *o = handle_get((uint32_t)x[0]);
        if (!o || o->type != KOBJ_THREAD) { x[0] = R_INVALID_HANDLE; break; }
        KThread *t = (KThread *)o;
        int ideal = (int)(int32_t)x[1];
        uint64_t mask = x[2] & 0xF;
        if (ideal == -2) ideal = g_default_core, mask = 1ull << ideal;
        else if (ideal == -3) ideal = t->core;
        if (!mask) mask = t->affinity;
        if (ideal == -1 || !(mask >> ideal & 1)) ideal = mask ? __builtin_ctzll(mask) : t->core;
        if (getenv("LARECOMP_LOG_THREADS"))
            LOG("[kernel] thread %#x: core %d -> %d (mask %#llx)\n", t->handle, t->core, ideal, (unsigned long long)mask);
        if (t == t_cur && t->sched_core >= 0 && t->sched_core != ideal) { sched_release(t); t->sched_resched = true; }
        t->core = ideal;
        t->affinity = mask;
        x[0] = R_OK;
        break;
    }
    case 0x10: x[0] = t_cur->core; break;  // GetCurrentProcessorNumber
    case 0x11: case 0x12: case 0x17: {  // SignalEvent / ClearEvent / ResetSignal
        pthread_mutex_lock(&g_klock);
        KObject *o = handle_get((uint32_t)x[0]);
        if (!o) x[0] = R_INVALID_HANDLE;
        else {
            KObject *ev = o->type == KOBJ_EVENT ? o : NULL;
            if (!ev) x[0] = R_INVALID_HANDLE;
            else {
                if (imm == 0x11) kernel_signal(ev);
                else if (imm == 0x17 && !ev->signaled) { x[0] = R_INVALID_STATE; pthread_mutex_unlock(&g_klock); break; }
                else ev->signaled = false;
                x[0] = R_OK;
            }
        }
        pthread_mutex_unlock(&g_klock);
        break;
    }
    case 0x13: {  // MapSharedMemory(handle, addr, size, perm)
        KObject *o = handle_get((uint32_t)x[0]);
        if (!o || o->type != KOBJ_SHMEM) { x[0] = R_INVALID_HANDLE; break; }
        KSharedMem *s = (KSharedMem *)o;
        memset((void *)x[1], 0, x[2]);
        s->guest_addr = x[1];  // HLE services write straight into the guest's mapping
        region_add(x[1], x[2], 6, 3);
        if (s->on_map) s->on_map(s);
        x[0] = R_OK;
        break;
    }
    case 0x14: region_remove(x[1]); x[0] = R_OK; break;  // UnmapSharedMemory
    case 0x15: {  // CreateTransferMemory(_, addr, size, perm)
        KTransferMem *t = calloc(1, sizeof *t);
        t->obj.type = KOBJ_TMEM;
        t->addr = x[1];
        t->size = x[2];
        x[0] = R_OK;
        x[1] = kernel_new_handle(&t->obj);
        break;
    }
    case 0x16:  // CloseHandle
        pthread_mutex_lock(&g_klock);
        handle_close((uint32_t)x[0]);
        pthread_mutex_unlock(&g_klock);
        x[0] = R_OK;
        break;
    case 0x18: {  // WaitSynchronization(_, handles, count, timeout)
        int32_t idx = -1;
        x[0] = svc_wait_synchronization(x[1], (int32_t)x[2], (int64_t)x[3], &idx);
        x[1] = (uint32_t)idx;
        break;
    }
    case 0x19: {  // CancelSynchronization
        pthread_mutex_lock(&g_klock);
        KObject *o = handle_get((uint32_t)x[0]);
        if (o && o->type == KOBJ_THREAD) {
            ((KThread *)o)->cancel = true;
            wake((KThread *)o);
            x[0] = R_OK;
        } else x[0] = R_INVALID_HANDLE;
        pthread_mutex_unlock(&g_klock);
        break;
    }
    case 0x1A: x[0] = svc_arbitrate_lock((uint32_t)x[0], x[1], (uint32_t)x[2]); break;
    case 0x1B: x[0] = svc_arbitrate_unlock(x[0]); break;
    case 0x1C: x[0] = svc_wait_process_wide_key(x[0], x[1], (uint32_t)x[2], (int64_t)x[3]); break;
    case 0x1D: svc_signal_process_wide_key(x[0], (int32_t)x[1]); x[0] = R_OK; break;
    case 0x1E: x[0] = rt_ticks(); break;
    case 0x1F: {  // ConnectToNamedPort(_, name)
        uint32_t h = ipc_connect_named_port((const char *)(uintptr_t)x[1]);
        x[0] = h ? R_OK : R_NOT_FOUND;
        x[1] = h;
        break;
    }
    case 0x21: x[0] = ipc_handle_request(c, (uint32_t)x[0]); break;  // SendSyncRequest
    case 0x22: {  // SendSyncRequestWithUserBuffer(buf, size, handle)
        uint64_t saved = c->tpidrro;
        c->tpidrro = x[0];
        x[0] = ipc_handle_request(c, (uint32_t)x[2]);
        c->tpidrro = saved;
        break;
    }
    case 0x24: x[0] = R_OK; x[1] = 0x81; break;  // GetProcessId
    case 0x25: {  // GetThreadId(_, handle)
        KObject *o = handle_get((uint32_t)x[1]);
        x[0] = o ? R_OK : R_INVALID_HANDLE;
        x[1] = o ? ((KThread *)o)->id : 0;
        break;
    }
    case 0x26:  // Break
        if (x[0] & 0x80000000u) { LOG("[kernel] Break notification %llx\n", x[0]); x[0] = R_OK; break; }
        FATAL("svcBreak(reason=%llx, info=%llx, size=%llx) at %llx\n", x[0], x[1], x[2], pc);
    case 0x27: debug_string(x[0], x[1]); x[0] = R_OK; break;
    case 0x29: {  // GetInfo(_, id0, handle, id1)
        uint32_t id0 = (uint32_t)x[1];
        uint64_t v = 0;
        uint32_t r = R_OK;
        switch (id0) {
        case 0: v = 0xF; break;
        case 1: v = 0xFFFFFFFFFFFFFFFFull; break;
        case 2: v = ALIAS_BASE; break;
        case 3: v = ALIAS_SIZE; break;
        case 4: v = HEAP_BASE; break;
        case 5: v = HEAP_MAX; break;
        case 6: case 21: v = 0xCD500000ull; break;  // application memory (3.2 GB, as on hardware)
        case 7: case 22: {  // used: the heap, the loaded modules with their bss (Dread's main alone is 1.8 GB: the
            // SDK sizes the heap as total - used, and asked for more than the pool without it), plus some slack
            uint64_t mods = 0;
            for (int i = 0; i < g_nmodules; i++) mods += g_modules[i].size;
            static long long slack = -1;  // LARECOMP_USED_SLACK=<bytes> (experiments): instead of 64 MB
            if (slack < 0) slack = getenv("LARECOMP_USED_SLACK") ? strtoll(getenv("LARECOMP_USED_SLACK"), NULL, 0) : 0x4000000;
            v = heap_size + mods + (uint64_t)slack;
            break;
        }
        case 8: v = 0; break;
        case 9: v = 0; break;
        case 11: v = ((uint64_t)arc4random() << 32) | arc4random(); break;
        case 12: v = GUEST_LO; break;
        case 13: v = GUEST_HI - GUEST_LO; break;
        case 14: v = STACK_BASE; break;
        case 15: v = STACK_SIZE; break;
        case 16: case 17: v = 0; break;
        case 18: v = g_game.title_id; break;  // program id (main.npdm)
        case 20: v = 0; break;
        default: r = R_INVALID_ENUM; LOG("[kernel] GetInfo unknown id %u/%llu\n", id0, x[3]);
        }
        x[0] = r;
        x[1] = v;
        break;
    }
    case 0x2C:  // MapPhysicalMemory(addr, size)
        memset((void *)x[0], 0, x[1]);
        region_add(x[0], x[1], 0x7, 3);
        x[0] = R_OK;
        break;
    case 0x2D:  // UnmapPhysicalMemory
        region_remove(x[0]);
        x[0] = R_OK;
        break;
    case 0x34: x[0] = svc_wait_for_address(x[0], (uint32_t)x[1], (int32_t)x[2], (int64_t)x[3]); break;
    case 0x35: x[0] = svc_signal_to_address(x[0], (uint32_t)x[1], (int32_t)x[2], (int32_t)x[3]); break;
    case 0x45: {  // CreateEvent -> w1 writable, w2 readable
        KObject *ev = calloc(1, sizeof *ev);
        ev->type = KOBJ_EVENT;
        x[0] = R_OK;
        x[1] = kernel_new_handle(ev);
        x[2] = kernel_new_handle(ev);
        if (ENV("LARECOMP_PROF_SVC")) LOG("[evt] guest w=%llx r=%llx lr=%llx\n", (unsigned long long)x[1], (unsigned long long)x[2], (unsigned long long)x[30]);
        break;
    }
    default:
        FATAL("unimplemented svc 0x%x at %llx (x0=%llx x1=%llx x2=%llx)\n", imm, pc, x[0], x[1], x[2]);
    }
}

// Reboot, step 1: stop every guest thread (see rt_unwind_point) and join it. `idle` keeps the window responsive.
void kernel_stop_threads(void (*idle)(void)) {
    g_rt_unwind = 1;
    uint64_t t0 = plat_now_ns(), logged = t0;
    for (;;) {
        int live = 0;
        pthread_mutex_lock(&g_klock);
        for (KThread *t = g_threads; t; t = t->anext)
            if (t->started && !t->finished) { live++; wake(t); }
        pthread_cond_broadcast(&g_nothread_cond);
        pthread_mutex_unlock(&g_klock);
        if (!live) break;
        uint64_t now = plat_now_ns();
        if (now - logged > 3000000000ull) {  // (a thread that never reaches a safe point: who and where)
            logged = now;
            LOG("[reboot] still waiting for %d guest threads after %llums:\n", live, (unsigned long long)((now - t0) / 1000000));
            for (KThread *t = g_threads; t; t = t->anext)
                if (t->started && !t->finished)
                    LOG("[reboot]   thread %llu (entry %llx) pc %llx lr %llx wait %d sync %d\n", (unsigned long long)t->id,
                        (unsigned long long)t->entry, (unsigned long long)t->cpu.pc, (unsigned long long)t->cpu.x[30],
                        t->wait_kind, t->in_sync_wait);
        }
        if (idle) idle();
        usleep(2000);
    }
    int n = 0;
    for (KThread *t = g_threads; t; t = t->anext)
        if (t->started) {
#ifdef _WIN32
            if (!guest_thread_join(t->host)) FATAL("Could not join a game thread.\n");
#else
            pthread_join(t->host, NULL);
#endif
            n++;
        }
    LOG("[reboot] %d guest threads stopped in %llums\n", n, (unsigned long long)((plat_now_ns() - t0) / 1000000));
}

// (diagnostics) every guest thread and what it waits on, with the guest frame chain (x29 / x30 pairs on the guest
// stack: the game function that waits). Doesn't wait for g_klock: a hang may hold it (then says so).
void kernel_dump_threads(const char *prefix) {
    bool locked = false;
    for (int i = 0; i < 100 && !(locked = pthread_mutex_trylock(&g_klock) == 0); i++) usleep(1000);
    if (!locked) LOG("%s g_klock held for 100+ ms: read without it\n", prefix);
    static const char *const kinds[] = {"-", "mutex", "condvar", "arbiter"};
    extern const char *hle_name_at(uint64_t pc);
    uint64_t now = plat_now_ns();
    for (KThread *t = g_threads; t; t = t->anext) {
        if (!t->started || t->finished) continue;
        bool waiting = t->wait_kind != WAIT_NONE || t->in_sync_wait;
        const char *hle = hle_name_at(t->cpu.pc);  // (pc: the last call through dispatch; an HLE one: its name)
        LOG("%s thread %llu h %x prio %d core %d entry %llx pc %llx%s%s%s lr %llx wait %s addr %llx mutex %llx tag %x%s%s for %llu ms\n",
            prefix, (unsigned long long)t->id, t->handle, t->prio, t->core, (unsigned long long)t->entry,
            (unsigned long long)t->cpu.pc, hle ? " (" : "", hle ? hle : "", hle ? ")" : "", (unsigned long long)t->cpu.x[30],
            (unsigned)t->wait_kind < 4 ? kinds[t->wait_kind] : "?", (unsigned long long)t->wait_addr,
            (unsigned long long)t->wait_mutex, t->wait_tag,
            t->in_sync_wait ? " in WaitSynchronization" : "", t->cancel ? " (cancel pending)" : "",
            waiting ? (unsigned long long)((now - t->wait_since) / 1000000) : 0ull);
        if (t->wait_kind == WAIT_CONDVAR || t->wait_kind == WAIT_MUTEX) {
            uint64_t m = t->wait_kind == WAIT_CONDVAR ? t->wait_mutex : t->wait_addr;
            LOG("%s   mutex word %x%s\n", prefix, *(volatile uint32_t *)(uintptr_t)m,
                t->wait_kind == WAIT_CONDVAR ? "" : " (waiting to be handed it)");
        }
        for (int i = 0; t->in_sync_wait && i < t->sync_count && i < 8; i++) {
            uint32_t h = ((const uint32_t *)(uintptr_t)t->sync_handles)[i];
            KObject *o = h > 0x100 && h - 0x100 < MAX_HANDLES ? handles[h - 0x100] : NULL;
            LOG("%s   handle %x type %d%s\n", prefix, h, o ? (int)o->type : 0, o && o->signaled ? " signaled" : "");
        }
        uint64_t fp = t->cpu.x[29];  // guest frames: [fp] = caller's fp, [fp + 8] = return address
        for (int i = 0; i < 12 && fp >= STACK_BASE && fp < STACK_BASE + STACK_SIZE && !(fp & 15); i++) {
            LOG("%s   frame %d: lr %llx\n", prefix, i, (unsigned long long)*(uint64_t *)(uintptr_t)(fp + 8));
            uint64_t up = *(uint64_t *)(uintptr_t)fp;
            if (up <= fp) break;
            fp = up;
        }
    }
    {   // the kernel trace: oldest first
        static const char *const kn[] = {"cv-wait", "cv-wait-end", "cv-signal", "arb-lock", "arb-lock-end", "arb-unlock"};
        uint64_t n = __atomic_load_n(&ktrace_n, __ATOMIC_RELAXED), first = n > KTRACE_N ? n - KTRACE_N : 0;
        LOG("%s kernel trace, last %llu of %llu (ms before now; words before -> after):\n", prefix,
            (unsigned long long)(n - first), (unsigned long long)n);
        for (uint64_t i = first; i < n; i++) {
            const KTrace *e = &ktrace[i % KTRACE_N];
            long long ago = (long long)(now - e->ns) / 1000000;
            switch (e->kind) {
            case KT_WAIT: LOG("%s  -%lld t%llu cv-wait key %llx (%x) mutex %llx %x -> %x\n", prefix, ago,
                              (unsigned long long)e->tid, (unsigned long long)e->addr, e->w0, (unsigned long long)e->addr2,
                              e->w1, e->w2); break;
            case KT_WAIT_END: LOG("%s  -%lld t%llu cv-wait-end key %llx (%x) mutex %llx (%x) r %x\n", prefix, ago,
                                  (unsigned long long)e->tid, (unsigned long long)e->addr, e->w0, (unsigned long long)e->addr2,
                                  e->w1, e->arg); break;
            case KT_SIGNAL: LOG("%s  -%lld t%llu cv-signal key %llx %x -> %x count %d woke %u\n", prefix, ago,
                                (unsigned long long)e->tid, (unsigned long long)e->addr, e->w0, e->w1, (int)e->arg, e->w2); break;
            default: LOG("%s  -%lld t%llu %s mutex %llx %x -> %x owner %x tag/r %x\n", prefix, ago, (unsigned long long)e->tid,
                         kn[e->kind < 6 ? e->kind : 0], (unsigned long long)e->addr, e->w0, e->w1, e->w2, e->arg);
            }
        }
    }
    if (locked) pthread_mutex_unlock(&g_klock);
}

// The hang dump, one facility for the whole runtime. LARECOMP_HANG_DUMP=<s> (default 30, 0 off), checked every
// second from the main guest thread's start:
// - the main guest thread in one kernel wait that long (startup hangs on Windows with few cores leave no other trace)
// - the renderer's own checks (runtime/nvn/rqueue.c, kernel_hang_hooks): no frame presented twice that long after the
//   GPU device setup, presenting stopped that long, or one noted host wait (GPU fence, queue, nextDrawable /
//   vkAcquire...) that long
// -> "[hang]" lines: why, the renderer's state (render thread queue, what each noted thread waits on), every guest
// thread with its kernel wait and guest frames, and the kernel trace. At most 6 dumps per run.
static bool (*hang_check_fn)(uint64_t limit_ns, char *why, size_t n);
static void (*hang_state_fn)(const char *prefix);
void kernel_hang_hooks(bool (*check)(uint64_t limit_ns, char *why, size_t n), void (*state)(const char *prefix)) {
    __atomic_store_n(&hang_state_fn, state, __ATOMIC_RELEASE);
    __atomic_store_n(&hang_check_fn, check, __ATOMIC_RELEASE);
}
static void *hang_watch(void *arg) {
    uint64_t s = (uint64_t)(uintptr_t)arg, dumped_since = 0;
    for (int dumps = 0; dumps < 6;) {
        sleep(1);
        char why[256];
        int n = 0;
        pthread_mutex_lock(&g_klock);
        KThread *m = g_main_thread;  // (the current boot's: kernel_reset clears it)
        uint64_t since = m ? m->wait_since : 0, now = plat_now_ns();
        bool stuck = m && m->started && !m->finished && (m->wait_kind != WAIT_NONE || m->in_sync_wait) && since < now &&
                     now - since >= s * 1000000000ull && since != dumped_since;
        pthread_mutex_unlock(&g_klock);
        if (stuck) {
            n = snprintf(why, sizeof why, "main guest thread in one kernel wait for %llu s", (unsigned long long)s);
            dumped_since = since;
        }
        bool (*check)(uint64_t, char *, size_t) = __atomic_load_n(&hang_check_fn, __ATOMIC_ACQUIRE);  // (every second: it keeps its own "reported" state)
        if (check && check(s * 1000000000ull, why + n + (n ? 2 : 0), sizeof why - (size_t)n - 2)) {
            if (n) why[n] = ';', why[n + 1] = ' ';
            n = 1;
        }
        if (!n) continue;
        LOG("[hang] ===== %s =====\n", why);
        void (*state)(const char *) = __atomic_load_n(&hang_state_fn, __ATOMIC_ACQUIRE);
        if (state) state("[hang]");
        kernel_dump_threads("[hang]");
        LOG("[hang] =====\n");
        dumps++;
    }
    return NULL;
}

// Reboot, step 2 (threads stopped): a fresh kernel. Kernel objects are leaked rather than freed: host statics
// can still point at some (vi.c's vsync event, signalled by its host timer thread).
void kernel_reset(void) {
    pthread_mutex_lock(&g_klock);
    for (KThread *t = g_threads, *next; t; t = next) {
        next = t->anext;
        pthread_cond_destroy(&t->cond);
        free(t);
    }
    g_threads = NULL;
    g_main_thread = NULL;
    g_waitlist = NULL;
    g_syncwaiters = NULL;
    memset(handles, 0, sizeof handles);
    nregions = 0;
    heap_size = 0;
    tls_next = TLS_BASE;
    next_thread_id = 0x50;
    g_rt_unwind = 0;
    pthread_mutex_unlock(&g_klock);
}

void kernel_init(void) {
    // Reserve the heap, alias, stack, and TLS regions.
    region_add(TLS_BASE, TLS_SIZE, 0xC, 3);
    for (int i = 0; i < g_nmodules; i++) {
        Module *m = &g_modules[i];
        region_add(m->base + m->text_off, m->ro_off - m->text_off, 3, 5);
        region_add(m->base + m->ro_off, m->data_off - m->ro_off, 3, 1);
        region_add(m->base + m->data_off, m->size - m->data_off, 4, 3);
    }
}

KEvent *kernel_create_event_pair(uint32_t *w, uint32_t *r) {
    KObject *ev = calloc(1, sizeof *ev);
    ev->type = KOBJ_EVENT;
    *w = kernel_new_handle(ev);
    *r = kernel_new_handle(ev);
    if (ENV("LARECOMP_PROF_SVC")) { const char *s = plat_symbol((uint64_t)(uintptr_t)__builtin_return_address(0), NULL); LOG("[evt] hle w=%x r=%x from %s\n", *w, *r, s ? s : "?"); }
    return ev;
}

KSharedMem *kernel_create_shared_memory(uint64_t size, void (*on_map)(KSharedMem *), uint32_t *handle) {
    KSharedMem *s = calloc(1, sizeof *s);
    s->obj.type = KOBJ_SHMEM;
    s->size = size;
    s->on_map = on_map;
    *handle = kernel_new_handle(&s->obj);
    return s;
}

// Same-core preemption, approximated where the game relies on it (runtime/hle/hooks.c). On the Switch a thread that
// wakes a more urgent thread of its own core stops right there until that thread blocks again; here both run at once.
// The caller waits until no more urgent thread of its core is runnable (in a wait, asleep, or not started), at most
// max_ns. (nxnative's "core_preempt", for the same movie-player race.)
void kernel_yield_to_urgent(uint64_t max_ns) {
    KThread *me = t_cur;
    if (!me) return;
    if (sched_on()) {  // (the core goes to the more urgent threads that want it: they run first)
        if (me->sched_core >= 0) { sched_release(me); sched_acquire(me); }
        return;
    }
    uint64_t t0 = plat_now_ns();
    for (;;) {
        bool busy = false;
        pthread_mutex_lock(&g_klock);
        for (KThread *t = g_threads; t && !busy; t = t->anext)
            if (t != me && t->started && !t->finished && t->core == me->core && t->prio < me->prio &&
                t->wait_kind == WAIT_NONE && !t->in_sync_wait && !t->sleeping)
                busy = true;
        pthread_mutex_unlock(&g_klock);
        if (!busy || plat_now_ns() - t0 > max_ns) return;
        usleep(20);
    }
}
