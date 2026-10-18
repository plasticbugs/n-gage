/* The game: started as the phone's application launcher starts any app.
 *
 * The drive image names the .app to run (the launch record, ngvm_hw.h).
 * AppArc starts an application as a process of AppRun.exe whose command
 * line is the .app's path (the boot does this for SysAp, Startup, ...), so
 * NGVM does the same once the application framework is up: a short thread,
 * in a process of its own, calls EUser's RProcess::Create(AppRun, path)
 * and Resume, and exits.
 *
 * The phone itself never reaches its idle screen -- Startup waits for SIM
 * and security states that only a modem would give -- so nothing else
 * would ever start the game. */
#include "kobj.h"

#define EUSER_HANDLE_CLOSE     172      /* RHandleBase::Close()                              */
#define EUSER_PROCESS_CREATE   292      /* RProcess::Create(const TDesC&, const TDesC&, TOwnerType) */
#define EUSER_PROCESS_RESUME   953      /* RProcess::Resume()                                */

/* the servers an application needs before AppRun can start one */
static const char *const needs[] = { "Windowserver", "Fontbitmapserver", "AppListServer", "EikAppUiServer", 0 };
#define SETTLE_US 2000000                /* and then this long, for the boot to quieten */

static u16 exe[] = u"Z:\\System\\Programs\\AppRun.exe";
static u16 app[NGVM_LAUNCH_MAX];
static struct { u32 len, ptr; } d_exe, d_app;   /* TPtrC16: length | EPtrC << 28, pointer */
static u32 f_create, f_resume, f_close;
u64 launch_due = ~0ull;
static int state;                                /* 0 none, 1 waiting, 2 settling, 3 done */

void launch_init(void)
{
    const char *rec = (const char *)(NGVM_DRIVE_BASE + NGVM_LAUNCH_OFF);
    if (IO(IO_DRIVE_SIZE) < 512 || memcmp(rec, NGVM_LAUNCH_MAGIC, 8)) return;
    int n = 0;
    for (const char *s = rec + 8; *s && n < NGVM_LAUNCH_MAX - 1; s++) app[n++] = (u8)*s;
    d_exe.len = (sizeof exe / 2 - 1) | (1u << 28); d_exe.ptr = (u32)exe;
    d_app.len = n | (1u << 28);                    d_app.ptr = (u32)app;
    f_create = euser_export(EUSER_PROCESS_CREATE);
    f_resume = euser_export(EUSER_PROCESS_RESUME);
    f_close = euser_export(EUSER_HANDLE_CLOSE);
    kprintf("[launch] will run ");
    kputs16(app, n);
    kprintf("\n");
    state = 1;
    launch_due = 0;
}

/* Runs in user mode, as the launcher thread's function. */
static s32 launcher(u32 unused)
{
    u32 proc = 0;                                  /* RProcess */
    s32 r = ((s32 (*)(u32 *, void *, void *, int))f_create)(&proc, &d_exe, &d_app, 0);
    if (r == KErrNone) {
        ((void (*)(u32 *))f_resume)(&proc);
        ((void (*)(u32 *))f_close)(&proc);
    }
    return r;
}

static int servers_up(void)
{
    for (int i = 0; needs[i]; i++) {
        u16 n[32];
        int k = 0;
        while (needs[i][k]) { n[k] = (u8)needs[i][k]; k++; }
        if (!server_find(n, k)) return 0;
    }
    return 1;
}

void launch_poll(void)
{
    u64 now = now_us();
    if (now < launch_due) return;
    if (state == 1) {
        launch_due = now + 100000;                 /* look again in 0.1 s */
        if (servers_up()) { state = 2; launch_due = now + SETTLE_US; }
        return;
    }
    if (state != 2) { launch_due = ~0ull; return; }
    state = 3;
    launch_due = ~0ull;
    struct process *p = proc_new(u"NGVMLaunch", 10);
    p->exit_type = 3;
    struct thread *t = thread_create(p, (u32)launcher, 0, 0x2000, 0, 0x1000, 0x10000, 1);
    obj_set_name_a(&t->o, "Main");
    thread_resume(t);
    kprintf("[launch] starting AppRun\n");
}
