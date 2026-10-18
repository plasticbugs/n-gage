/* Kernel objects: what EKA1's user side holds handles to. */
#ifndef KOBJ_H
#define KOBJ_H
#include "kern.h"
#include "rom.h"

/* ---- Symbian constants the kernel needs --------------------------------- */
#define KErrNone            0
#define KErrNotFound       (-1)
#define KErrGeneral        (-2)
#define KErrCancel         (-3)
#define KErrNoMemory       (-4)
#define KErrNotSupported   (-5)
#define KErrArgument       (-6)
#define KErrBadHandle      (-8)
#define KErrOverflow       (-9)
#define KErrUnderflow      (-10)
#define KErrAlreadyExists  (-11)
#define KErrPathNotFound   (-12)
#define KErrDied           (-13)
#define KErrInUse          (-14)
#define KErrServerTerminated (-15)
#define KErrServerBusy     (-16)
#define KErrNotReady       (-18)
#define KErrUnknown        (-19)
#define KErrCorrupt        (-20)
#define KErrAccessDenied   (-21)
#define KErrEof            (-25)
#define KErrDiskFull       (-26)
#define KErrBadName        (-28)
#define KErrTimedOut       (-33)
#define KErrAbort          (-39)
#define KRequestPending    ((s32)0x80000001)

#define KCurrentProcessHandle 0xFFFF0000u
#define KCurrentThreadHandle  0xFFFF8001u
#define KHandleNoClose        0x00008000u
#define HANDLE_THREAD_OWNED   0x40000000u
#define HANDLE_GLOBAL_THREAD  0x20000000u   /* | thread id: a message's client */

enum otype {
    O_NONE, O_PROCESS, O_THREAD, O_CHUNK, O_LIBRARY, O_SEMAPHORE, O_MUTEX,
    O_TIMER, O_SERVER, O_SESSION, O_CHANNEL, O_NOTIFIER, O_UNDERTAKER, O_DEVICE,
    O_NTYPES
};

#define NAME_MAX 80
struct kobj {
    u8  type;
    u8  global;               /* findable from any process                  */
    u16 namelen;
    s32 refs;                 /* open handles + kernel references           */
    u32 seq;                  /* creation order: find handles name objects by it */
    struct process *owner;    /* creating process (for full names)          */
    struct kobj *next;        /* all objects of this type                   */
    u16 name[NAME_MAX];
};

struct handle_ent { struct kobj *obj; u16 gen; u16 count; };
#define MAX_HANDLES 256
struct handles { struct handle_ent e[MAX_HANDLES]; };

/* ---- threads ------------------------------------------------------------ */
enum tstate { T_CREATED, T_READY, T_WAIT_REQ, T_WAIT_SEM, T_WAIT_MUTEX, T_SUSPENDED, T_DEAD };

#define MAX_TLS 32
struct thread {
    struct kobj o;
    struct ctx ctx;
    struct process *proc;
    enum tstate state;
    int  suspend_count;
    int  prio_rel;            /* as set by RThread::SetPriority              */
    int  prio;                /* effective, bigger runs first                */
    s32  reqsem;              /* request semaphore                          */
    struct kobj *wait_obj;    /* semaphore or mutex blocked on              */
    struct thread *wait_next;
    struct thread *run_next;
    u32  id;
    u32  run_stamp;           /* when it last got the CPU (round robin)      */
    struct handles *h;        /* thread-owned handles                       */
    /* thread-local state behind fast execs */
    u32  heap;                /* RHeap*                                     */
    u32  trap_handler;
    u32  active_scheduler;
    u32  trap_frame;          /* TTrap* chain head                          */
    struct { u32 key, ptr; } tls[MAX_TLS];
    /* life */
    u32  stack_base, stack_size;
    int  first_in_process;
    int  exit_type;           /* 0 kill, 1 terminate, 2 panic, 3 pending    */
    s32  exit_reason;
    u16  exit_cat[16]; int exit_catlen;
    struct logon *logons;
    u32  flags;               /* system/protected                           */
    u32  exc_handler, exc_mask;
    u64  cpu_time;
};

/* ---- processes ---------------------------------------------------------- */
#define MAX_PDEPS 64
struct process {
    struct kobj o;
    u32  id;
    struct handles h;
    const struct rom_image *rom;      /* ROM image, or 0 if RAM-loaded       */
    struct library *code;             /* RAM-loaded: the code it runs        */
    u32  uid[3];
    u32  entry;
    u32  heap_min, heap_max, stack_size;
    u32  code_base, code_size, text_size;
    u32  data_base, data_size, bss_size;
    int  win_pages;                   /* pages of the 0x400000 data window   */
    u16  win[64];                     /* their RAM pages                     */
    u32  data_home;                   /* loader-visible alias, while loading */
    u16  cmd[256]; int cmdlen;
    u16  fname[NAME_MAX]; int fnamelen;
    int  prio;                        /* TProcessPriority                    */
    u32  flags;
    int  exit_type; s32 exit_reason;
    u16  exit_cat[16]; int exit_catlen;
    struct thread *main;
    int  nthreads;
    int  loaded;
    u32  dllref;                      /* ROM TDllRefTable: its static deps   */
    struct library *ram_deps[MAX_PDEPS]; int nram_deps; /* added by the loader */
    struct logon *logons;
    int  owner_type;
};

/* ---- libraries (code images) -------------------------------------------- */
#define MAX_LDEPS 64
struct library {
    struct kobj o;
    const struct rom_image *rom;
    u32  uid[3];
    u32  code_base, code_size, text_size;
    u32  entry;
    u32  export_dir; int export_count;
    u32  chunk;                       /* chunk-space reservation, RAM code   */
    u32  dllref;                      /* ROM TDllRefTable                    */
    struct library *deps[MAX_LDEPS]; int ndeps;
    int  loaded;
    u16  fname[NAME_MAX]; int fnamelen;
};

/* ---- chunks -------------------------------------------------------------- */
struct chunk {
    struct kobj o;
    u32 base;                         /* reservation start                   */
    u32 max;                          /* the maximum size asked for          */
    u32 reserved;                     /* addresses reserved: max, capped     */
    u32 bottom, top;                  /* committed [bottom, top)             */
    int double_ended;
};

struct semaphore { struct kobj o; s32 count; struct thread *waiters; };
struct mutex { struct kobj o; s32 count; struct thread *holder; int hold; struct thread *waiters; };

struct ktimer {
    struct kobj o;
    struct thread *thread;            /* who gets the completion             */
    u32 status;                       /* TRequestStatus* in that thread      */
    u64 expiry;                       /* us                                  */
    struct ktimer *qnext;
    int queued;
    int kind;                         /* 0 After/At, 1 Lock, 2 Inactivity    */
    u32 secs;                         /* Inactivity: the quiet time asked for */
};

/* ---- client/server ------------------------------------------------------- */
struct message;
struct server {
    struct kobj o;
    struct thread *thread;
    struct message *queue, *queue_tail;
    u32  rx_status, rx_buf;           /* outstanding Receive, if any        */
    int  rx_pending;
};

struct session {
    struct kobj o;
    struct server *server;
    struct thread *client;
    u32  session_ptr;                 /* server's CSession*                 */
    int  msgs_out;
    int  closed;
};

struct message {
    int  in_use;
    u16  gen;
    s32  function;
    u32  args[4];
    struct thread *client;
    struct session *session;
    u32  status;                      /* client's TRequestStatus*, or 0     */
    struct message *next;
    u32  client_handle;               /* RThread handle given to the server */
    int  delivered;
};

struct logon { struct thread *t; u32 status; struct logon *next; };

/* ---- obj.c ---------------------------------------------------------------- */
void *kmalloc(u32 size);
void  kfree(void *p);
void *kzalloc(u32 size);
void  obj_init(void);
struct kobj *obj_new(int type, u32 size, struct process *owner);
void  obj_set_name(struct kobj *o, const u16 *name, int len);
void  obj_set_name_a(struct kobj *o, const char *name);
int   obj_full_name(struct kobj *o, u16 *buf, int max);
void  obj_ref(struct kobj *o);
void  obj_unref(struct kobj *o);
struct kobj *obj_first(int type);
struct kobj *obj_by_seq(int type, u32 seq);
int   obj_find_next(int type, u32 presult, u32 phandle, u32 match);
u32   handle_make(struct thread *t, struct kobj *o, int thread_owned);
u32   handle_make_pair(struct thread *a, struct thread *b, struct kobj *o, int thread_owned);
struct kobj *handle_lookup(struct thread *t, u32 h, int type);
int   handle_close(struct thread *t, u32 h);
const char *otype_name(int type);

extern struct thread *cur;            /* the running thread                 */
extern int kflags;                    /* IO_DBG_FLAGS at boot               */

/* ---- user memory and descriptors (umem.c) ------------------------------------ */
u32  uread32(u32 a);
void uwrite32(u32 a, u32 v);
void ucopy_from(void *dst, u32 src, u32 n);
void ucopy_to(u32 dst, const void *src, u32 n);
int  des_len(u32 d);
int  des_maxlen(u32 d);
u32  des_ptr(u32 d);
void des_setlen(u32 d, int len);
int  des_read16(u32 d, u16 *buf, int max);     /* units read               */
int  des_write16(u32 d, const u16 *buf, int n);/* KErrOverflow if too long */
int  des_write8(u32 d, const u8 *buf, int n);
void kputs16(const u16 *s, int n);
void kputdes16(u32 d);

/* ---- sched.c -------------------------------------------------------------- */
void sched_init(void);
void sched_add(struct thread *t);
void sched_block(struct thread *t, enum tstate st);
void sched_wake(struct thread *t);
void schedule(void);
void thread_signal(struct thread *t, int n);
void request_complete(struct thread *t, u32 status, s32 value);
u64  now_us(void);
void timer_queue(struct ktimer *k, u64 when);
void timer_dequeue(struct ktimer *k);
void timer_tick(void);
void activity(void);                  /* user activity: inactivity timers restart */
/* ---- launch.c --------------------------------------------------------------- */
void launch_init(void);               /* read the drive's launch record      */
void launch_poll(void);               /* from the timer: start it when due   */
extern u64 launch_due;                /* when to look again; ~0: never       */
void thread_exit(struct thread *t, int type, s32 reason, const u16 *cat, int catlen);
extern struct thread *idle_thread;
void sem_signal(struct semaphore *s, int n);
int  sem_wait(struct semaphore *s);           /* 1 if the caller blocked */
int  mutex_wait(struct mutex *m);
void mutex_signal(struct mutex *m);

/* ---- proc.c --------------------------------------------------------------- */
struct process *proc_new(const u16 *path, int n);
struct process *proc_from_rom(const struct rom_image *img, const char *fname);
struct thread *thread_create(struct process *p, u32 func, u32 ptr, u32 stack, u32 heap,
                             u32 heap_min, u32 heap_max, int first);
void proc_switch_in(struct process *p);     /* 0: unmap the data window */
void thread_reprioritise(struct thread *t);
u32  proc_static_calls(struct process *p, u32 *list, int max);
struct library *lib_for_rom(const struct rom_image *img);
u32  euser_export(int ord);           /* EUser.dll's export by ordinal       */
void lib_add_dep(struct library *l, struct library *dep);
void proc_add_dep(struct process *p, struct library *dep);
void proc_kill(struct process *p, int type, s32 reason, const u16 *cat, int catlen);

/* ---- ipc.c ---------------------------------------------------------------- */
struct server *server_find(const u16 *name, int len);
int  ipc_send(struct thread *t, struct session *s, s32 fn, u32 args, u32 status);
void ipc_receive(struct thread *t, struct server *s, u32 status, u32 buf);
int  ipc_complete(struct thread *t, u32 mh, s32 reason);
struct message *msg_lookup(u32 mh);
void ipc_deliver(struct server *s);

/* ---- exec.c --------------------------------------------------------------- */
void exec_dispatch(struct ctx *c, u32 n);
int  executor(struct thread *t, u32 attr, u32 args, u32 status);

#endif
