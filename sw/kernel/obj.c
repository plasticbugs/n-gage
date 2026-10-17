/* Kernel objects, their names, and the handle tables that point at them. */
#include "kobj.h"
#include "mm.h"

/* ---- the kernel heap: first fit over a fixed arena ---------------------- */
#define ARENA_SIZE (512 * 1024)
static u32 arena[ARENA_SIZE / 4];
struct blk { u32 size; struct blk *next; };   /* size includes the header   */
static struct blk *free_list;

static void heap_init(void)
{
    free_list = (struct blk *)arena;
    free_list->size = ARENA_SIZE;
    free_list->next = 0;
}

/* The arena is in the kernel image, which is 1 MB at most; past it the heap
 * grows in steps of chunk-space memory. */
#define GROW_SIZE (1024 * 1024)
static int grow(void)
{
    u32 b = vm_reserve(GROW_SIZE);
    if (!b || vm_commit(b, GROW_SIZE)) return 0;
    struct blk *n = (struct blk *)b;
    n->size = GROW_SIZE;
    kfree(n + 1);
    if (kflags & DBGF_SCHED) kprintf("[kern] kernel heap grows by %u at %p\n", GROW_SIZE, b);
    return 1;
}

void *kmalloc(u32 size)
{
    size = (size + sizeof(struct blk) + 7) & ~7u;
    if (size > GROW_SIZE) kpanic("kmalloc %u: too big", size);
again:
    for (struct blk **pp = &free_list; *pp; pp = &(*pp)->next) {
        struct blk *b = *pp;
        if (b->size < size) continue;
        if (b->size - size >= 64) {               /* split off the tail     */
            struct blk *rest = (struct blk *)((u8 *)b + size);
            rest->size = b->size - size;
            rest->next = b->next;
            *pp = rest;
            b->size = size;
        } else {
            *pp = b->next;
        }
        return b + 1;
    }
    if (grow()) goto again;
    kpanic("kmalloc %u: kernel heap exhausted", size);
}

void *kzalloc(u32 size)
{
    void *p = kmalloc(size);
    memset(p, 0, size);
    return p;
}

void kfree(void *p)
{
    if (!p) return;
    struct blk *b = (struct blk *)p - 1;
    /* insert in address order and merge with the neighbours */
    struct blk **pp = &free_list;
    while (*pp && *pp < b) pp = &(*pp)->next;
    b->next = *pp;
    *pp = b;
    if (b->next && (u8 *)b + b->size == (u8 *)b->next) {
        b->size += b->next->size;
        b->next = b->next->next;
    }
    if (pp != &free_list) {
        struct blk *prev = (struct blk *)((u8 *)pp - __builtin_offsetof(struct blk, next));
        if ((u8 *)prev + prev->size == (u8 *)b) {
            prev->size += b->size;
            prev->next = b->next;
        }
    }
}

/* ---- objects ---------------------------------------------------------------- */
static struct kobj *by_type[O_NTYPES];

static const char *const tnames[O_NTYPES] = {
    "none", "process", "thread", "chunk", "library", "semaphore", "mutex",
    "timer", "server", "session", "channel", "notifier", "undertaker", "device",
};
const char *otype_name(int t) { return t < O_NTYPES ? tnames[t] : "?"; }

void obj_init(void) { heap_init(); }

struct kobj *obj_new(int type, u32 size, struct process *owner)
{
    struct kobj *o = kzalloc(size);
    o->type = type;
    o->owner = owner;
    static u32 seq;
    o->refs = 0;
    o->seq = ++seq & 0x0FFFFFFF;
    o->next = by_type[type];
    by_type[type] = o;
    return o;
}

struct kobj *obj_first(int type) { return by_type[type]; }

struct kobj *obj_by_seq(int type, u32 seq)
{
    for (struct kobj *o = by_type[type]; o; o = o->next) if (o->seq == seq) return o;
    return 0;
}

/* Symbian's Match: '*' any run, '?' any one character, case folded. */
static int fold16(int c) { return (c >= 'a' && c <= 'z') ? c - 32 : c; }
static int match16(const u16 *p, int pn, const u16 *s, int sn)
{
    if (!pn) return !sn;
    if (*p == '*') {
        for (int i = 0; i <= sn; i++) if (match16(p + 1, pn - 1, s + i, sn - i)) return 1;
        return 0;
    }
    if (!sn) return 0;
    if (*p != '?' && fold16(*p) != fold16(*s)) return 0;
    return match16(p + 1, pn - 1, s + 1, sn - 1);
}

/* TFindXxx::Next(TFullName& aResult): the next object, in creation order,
 * after the one *phandle names, whose full name matches. */
int obj_find_next(int type, u32 presult, u32 phandle, u32 match)
{
    u16 pat[2 * NAME_MAX], full[2 * NAME_MAX];
    int pn = des_read16(match, pat, 2 * NAME_MAX);
    u32 after = uread32(phandle) & 0x0FFFFFFF;
    struct kobj *best = 0;
    int bestn = 0;
    u16 bestname[2 * NAME_MAX];
    for (struct kobj *o = by_type[type]; o; o = o->next) {
        if (o->seq <= after || (best && o->seq >= best->seq)) continue;
        if (type == O_THREAD && ((struct thread *)o)->state == T_DEAD) continue;
        int n = obj_full_name(o, full, 2 * NAME_MAX);
        if (!match16(pat, pn, full, n)) continue;
        best = o;
        bestn = n;
        memcpy(bestname, full, n * 2);
    }
    if (!best) return KErrNotFound;
    uwrite32(phandle, ((u32)type << 28) | best->seq);
    des_write16(presult, bestname, bestn);
    return KErrNone;
}

void obj_set_name(struct kobj *o, const u16 *name, int len)
{
    if (len > NAME_MAX) len = NAME_MAX;
    memcpy(o->name, name, len * 2);
    o->namelen = len;
}

void obj_set_name_a(struct kobj *o, const char *name)
{
    int n = 0;
    while (name[n] && n < NAME_MAX) { o->name[n] = (u8)name[n]; n++; }
    o->namelen = n;
}

/* "owner::name", as EKA1 forms full names: a thread's owner is its process,
 * and a process's full name is its name alone.  So is a server's: server
 * names are one global namespace (TFindServer("AlarmAlertServer")). */
int obj_full_name(struct kobj *o, u16 *buf, int max)
{
    int n = 0;
    if (o->owner && o->type != O_PROCESS && o->type != O_SERVER) {
        n = obj_full_name(&o->owner->o, buf, max);
        if (n + 2 <= max) { buf[n++] = ':'; buf[n++] = ':'; }
    }
    for (int i = 0; i < o->namelen && n < max; i++) buf[n++] = o->name[i];
    return n;
}

static void obj_destroy(struct kobj *o)
{
    /* threads and processes stay (as zombies) for exit information; the
     * rest go back to the heap */
    if (o->type == O_THREAD || o->type == O_PROCESS || o->type == O_LIBRARY) return;
    for (struct kobj **pp = &by_type[o->type]; *pp; pp = &(*pp)->next)
        if (*pp == o) { *pp = o->next; break; }
    if (o->type == O_CHUNK) {
        struct chunk *c = (struct chunk *)o;
        extern void vm_release(u32);
        if (c->base) vm_release(c->base);
    }
    if (o->type == O_TIMER) timer_dequeue((struct ktimer *)o);
    kfree(o);
}

void obj_ref(struct kobj *o) { o->refs++; }

void obj_unref(struct kobj *o)
{
    if (--o->refs <= 0) obj_destroy(o);
}

/* ---- handles ----------------------------------------------------------------
 * A handle is (generation << 16) | (slot + 1), with HANDLE_THREAD_OWNED set
 * when it lives in the thread's table rather than the process's.  Bit 15
 * (KHandleNoClose) is never part of a slot.  HANDLE_GLOBAL_THREAD marks the
 * handle a server is given for a message's client: it names the thread by
 * id, is valid in any process, and closing it does nothing. */
#define HGEN_MASK 0xFFF

static struct handles *table_for(struct thread *t, int thread_owned)
{
    if (!thread_owned) return &t->proc->h;
    if (!t->h) t->h = kzalloc(sizeof(struct handles));
    return t->h;
}

/* As EKA1's object index: an object already in the table gets its existing
 * handle back with one more open on it, and the handle lasts until it has
 * been closed as often as it was made. */
static u32 hval(struct handles *h, int i, int towned)
{
    return ((u32)h->e[i].gen << 16) | (u32)(i + 1) | (towned ? HANDLE_THREAD_OWNED : 0);
}

static void slot_take(struct handles *h, int i, struct kobj *o, u16 gen)
{
    h->e[i].obj = o;
    h->e[i].gen = gen;
    h->e[i].count = 1;
    obj_ref(o);
}

static u16 next_gen(u16 g) { g = (g + 1) & HGEN_MASK; return g ? g : 1; }

u32 handle_make(struct thread *t, struct kobj *o, int thread_owned)
{
    struct handles *h = table_for(t, thread_owned);
    for (int i = 0; i < MAX_HANDLES; i++)
        if (h->e[i].obj == o) { h->e[i].count++; return hval(h, i, thread_owned); }
    for (int i = 0; i < MAX_HANDLES; i++)
        if (!h->e[i].obj) { slot_take(h, i, o, next_gen(h->e[i].gen)); return hval(h, i, thread_owned); }
    kpanic("handle table full (%s)", thread_owned ? "thread" : "process");
}

/* One handle value, valid for two threads: the loader gives its client the
 * handle it made for itself, and closes its own.  In one table that is two
 * opens of one entry; in two, the same slot and generation in both. */
u32 handle_make_pair(struct thread *a, struct thread *b, struct kobj *o, int thread_owned)
{
    struct handles *ha = table_for(a, thread_owned), *hb = table_for(b, thread_owned);
    if (ha == hb) { handle_make(a, o, thread_owned); return handle_make(b, o, thread_owned); }
    for (int i = 0; i < MAX_HANDLES; i++) {
        if (ha->e[i].obj || hb->e[i].obj) continue;
        u16 g = next_gen(ha->e[i].gen > hb->e[i].gen ? ha->e[i].gen : hb->e[i].gen);
        slot_take(ha, i, o, g);
        slot_take(hb, i, o, g);
        return hval(ha, i, thread_owned);
    }
    kpanic("handle tables full");
}

extern struct thread *thread_by_id(u32 id);

struct kobj *handle_lookup(struct thread *t, u32 h, int type)
{
    struct kobj *o = 0;
    u32 hm = h & ~KHandleNoClose;
    if (hm == KCurrentProcessHandle) o = &t->proc->o;
    else if (hm == (KCurrentThreadHandle & ~KHandleNoClose)) o = &t->o;
    else if ((h & 0xF0000000u) == HANDLE_GLOBAL_THREAD) o = (struct kobj *)thread_by_id(h & 0xFFFFFFF);
    else if (!(h & 0x80000000u)) {
        struct handles *tab = (h & HANDLE_THREAD_OWNED) ? t->h : &t->proc->h;
        int i = (h & 0x7FFF) - 1;
        if (tab && i >= 0 && i < MAX_HANDLES && tab->e[i].obj && tab->e[i].gen == ((h >> 16) & HGEN_MASK))
            o = tab->e[i].obj;
    }
    if (o && type && o->type != type) return 0;
    return o;
}

int handle_close(struct thread *t, u32 h)
{
    if (h & (0x80000000u | KHandleNoClose)) return KErrNone;
    if ((h & 0xF0000000u) == HANDLE_GLOBAL_THREAD) return KErrNone;
    struct handles *tab = (h & HANDLE_THREAD_OWNED) ? t->h : &t->proc->h;
    int i = (h & 0x7FFF) - 1;
    if (!tab || i < 0 || i >= MAX_HANDLES || !tab->e[i].obj || tab->e[i].gen != ((h >> 16) & HGEN_MASK)) {
        if (kflags & DBGF_EXEC)
            kprintf("[kern] close %x: bad (table %p obj %p gen %d)\n", h, tab, tab && i >= 0 && i < MAX_HANDLES ? tab->e[i].obj : 0,
                    tab && i >= 0 && i < MAX_HANDLES ? tab->e[i].gen : -1);
        return KErrBadHandle;
    }
    struct kobj *o = tab->e[i].obj;
    if (--tab->e[i].count > 0) return KErrNone;
    tab->e[i].obj = 0;
    if (o->type == O_SESSION) {
        extern void session_close(struct thread *t, struct session *s);
        session_close(t, (struct session *)o);
    }
    obj_unref(o);
    return KErrNone;
}
