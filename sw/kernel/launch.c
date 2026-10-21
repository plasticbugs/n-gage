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
 * would ever start the game.
 *
 * For the same reason the Starter never runs the second half of its list
 * (Starter_Arm.RSC: NcnList, Satsvr, CalenSvr, CbsServer, BtServer, ...),
 * which waits for that idle state.  Of those, games use BtServer: Ghost
 * Recon's profile screen connects to it through BTSrvClient.dll, which
 * starts the server itself when it is not running -- asking for UID3
 * 0x10005999, the client's own, where BtServer.exe is 0x10005950, so the
 * loader refuses (KErrNotSupported) and the game waits for ever.  The
 * launcher starts it, as the Starter would have, before the game.
 *
 * The message server stays up, as the phone's SMS watcher and NcnList (the
 * Starter's second half again) keep it, each with a session open for good.
 * Here the watcher finds no SMS stack and closes its session, Sysamob and
 * MailInit exit, and the server, with no session left, exits at 17 s.  A
 * game's CMsvSession then starts it again and asks before it has loaded its
 * store: Shadowkey is answered KErrNotReady, shows an error and exits.  A
 * keeper thread holds a session from when the launcher starts.
 *
 * First the launcher says what the Phone application would: no call.  The
 * Phone app publishes the System Agent's current-call state once its call
 * engine is up, which needs the modem, so here it is never published and
 * RSystemAgent::GetState answers KErrUnknown.  Games read that as a call in
 * progress: Snakes pauses its music at start and plays it only if a
 * message-server event happens to resume it. */
#include "kobj.h"

#define EUSER_HANDLE_CLOSE     172      /* RHandleBase::Close()                              */
#define EUSER_PROCESS_CREATE   292      /* RProcess::Create(const TDesC&, const TDesC&, TOwnerType) */
#define EUSER_PROCESS_RESUME   953      /* RProcess::Resume()                                */
#define EUSER_SEND_RECEIVE     972      /* RSessionBase::SendReceive(TInt, TAny*) const      */
#define EUSER_WAIT_ANY         1209     /* User::WaitForAnyRequest()                         */
#define MSGS_CONNECT           33       /* RMsvServerSession::Connect(RFs&), which never reads the RFs */
#define SYSAGT_CONNECT         20       /* RSystemAgentBase::Connect()                       */
#define SA_SET_STATE           9        /* the message RSAVarChangeNotify::NotifySaVarChangeL sends */
#define KUidCurrentCall        0x100052CB
#define ESACallNone            0

/* the servers an application needs before AppRun can start one */
static const char *const needs[] = { "Windowserver", "Fontbitmapserver", "AppListServer", "EikAppUiServer",
                                     "SystemAgent", 0 };
#define SETTLE_US 2000000                /* and then this long, for the boot to quieten */

static u16 exe[] = u"Z:\\System\\Programs\\AppRun.exe";
static u16 bt[] = u"Z:\\System\\Programs\\BtServer.exe";
static u16 app[NGVM_LAUNCH_MAX];
static struct { u32 len, ptr; } d_exe, d_app, d_bt, d_none;   /* TPtrC16: length | EPtrC << 28, pointer */
static u32 f_create, f_resume, f_close, f_send, f_sa_connect, f_wait_any, f_msv_connect;
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
    d_bt.len = (sizeof bt / 2 - 1) | (1u << 28);   d_bt.ptr = (u32)bt;
    d_none.len = 1u << 28;                         d_none.ptr = (u32)bt;
    f_create = euser_export(EUSER_PROCESS_CREATE);
    f_resume = euser_export(EUSER_PROCESS_RESUME);
    f_close = euser_export(EUSER_HANDLE_CLOSE);
    f_send = euser_export(EUSER_SEND_RECEIVE);
    const struct rom_image *sa = rom_image("\\System\\Libs\\Sysagt.dll");
    if (sa) f_sa_connect = uread32(sa->export_dir + 4 * (SYSAGT_CONNECT - 1));
    f_wait_any = euser_export(EUSER_WAIT_ANY);
    const struct rom_image *msgs = rom_image("\\System\\Libs\\Msgs.dll");
    if (msgs) f_msv_connect = uread32(msgs->export_dir + 4 * (MSGS_CONNECT - 1));
    kprintf("[launch] will run ");
    kputs16(app, n);
    kprintf("\n");
    state = 1;
    launch_due = 0;
}

/* Runs in user mode, as the launcher thread's function. */
static s32 launcher(u32 unused)
{
    u32 sa[2] = { 0, 0 };                          /* RSAVarChangeNotify: an RSessionBase */
    if (f_sa_connect && ((s32 (*)(u32 *))f_sa_connect)(sa) == KErrNone) {
        u32 set[2] = { KUidCurrentCall, ESACallNone };
        ((s32 (*)(u32 *, int, u32 *))f_send)(sa, SA_SET_STATE, set);
        ((void (*)(u32 *))f_close)(sa);
    }
    u32 proc = 0;                                  /* RProcess */
    if (((s32 (*)(u32 *, void *, void *, int))f_create)(&proc, &d_bt, &d_none, 0) == KErrNone) {
        ((void (*)(u32 *))f_resume)(&proc);
        ((void (*)(u32 *))f_close)(&proc);
    }
    s32 r = ((s32 (*)(u32 *, void *, void *, int))f_create)(&proc, &d_exe, &d_app, 0);
    if (r == KErrNone) {
        ((void (*)(u32 *))f_resume)(&proc);
        ((void (*)(u32 *))f_close)(&proc);
        for (;;) ((void (*)(void))f_wait_any)();   /* the process stays, and the keeper's session */
    }
    return r;
}

/* Runs in user mode: a message-server session, held while the phone runs.
 * RMsvServerSession is a session handle, a word, and its buffer's pointer;
 * Msgs.dll has no static data, so it is called where it lies in the ROM. */
static s32 keeper(u32 unused)
{
    u32 msv[8] = { 0 };
    s32 r = ((s32 (*)(u32 *))f_msv_connect)(msv);
    if (r != KErrNone) return r;
    for (;;) ((void (*)(void))f_wait_any)();
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
    /* At priority 0, as proc_new leaves it, the launcher runs only when the
     * CPU is otherwise idle: the game starts once the boot has quietened, as
     * a player would start it from the phone's menu.  The scheduler never
     * lends it time (sched.c); started sooner, a game can draw before the
     * phone's splash screen and stay under it. */
    struct process *p = proc_new(u"NGVMLaunch", 10);
    p->exit_type = 3;
    p->low = 1;                                    /* what it starts is the game */
    struct thread *t = thread_create(p, (u32)launcher, 0, 0x2000, 0, 0x1000, 0x10000, 1);
    obj_set_name_a(&t->o, "Main");
    thread_resume(t);
    if (f_msv_connect) {                           /* at once, while the boot's server is up */
        struct thread *k = thread_create(p, (u32)keeper, 0, 0x2000, 0, 0x2000, 0x10000, 0);
        obj_set_name_a(&k->o, "MsvKeeper");
        k->prio_rel = 350;                         /* absolute, as the boot's own */
        thread_reprioritise(k);
        thread_resume(k);
    }
    kprintf("[launch] starting AppRun\n");
}
