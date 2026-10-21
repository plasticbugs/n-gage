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
 * The connection database the boot creates (EtelServer, C:\System\Data\
 * Cdbv2.dat) is empty: the phone's ships with its records, and this ROM has
 * no DefaultCdbv2.dat to copy.  Call of Duty's Arena client reads the Id of
 * the first modem with Hidden=0 without asking whether there is one, and
 * DBMS panics it (DBMS-server 3, no row).  The launcher adds one modem, the
 * phone's own data port, when the table has none.
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
#define EUSER_TRAP_CLEANUP     746      /* CTrapCleanup::New()                               */
#define EUSER_LEAVE_IF_ERROR   627      /* User::LeaveIfError(TInt)                          */
#define EUSER_PUSHL            858      /* CleanupStack::PushL(CBase*)                       */
#define EUSER_POP_DESTROY      825      /* CleanupStack::PopAndDestroy(TInt)                 */
#define EUSER_TRAP             1148     /* TTrap::Trap(TInt&)                                */
#define EUSER_UNTRAP           1164     /* TTrap::UnTrap()                                   */
#define CDB_NEWL               27       /* CCommsDatabase::NewL(TCommDbDatabaseType)         */
#define CDB_OPEN_TABLE         31       /* CCommsDatabaseBase::OpenTableLC(const TDesC&)     */
#define CDB_FIRST              18       /* CCommsDbTableView::GotoFirstRecord()              */
#define CDB_INSERT             22       /* CCommsDbTableView::InsertRecord(TUint32&)         */
#define CDB_WRITE_TEXT         76       /* CCommsDbTableView::WriteTextL(const TDesC&, const TDesC16&) */
#define CDB_PUT                37       /* CCommsDbTableView::PutRecordChanges(TBool, TBool) */
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
struct ptrc { u32 len, ptr; };                  /* TPtrC16: length | EPtrC << 28, pointer */
static struct ptrc d_exe, d_app, d_bt, d_none;
static u32 f_create, f_resume, f_close, f_send, f_sa_connect, f_wait_any, f_msv_connect;
static u32 f_trap_cleanup, f_leave_if, f_pushl, f_pop_destroy, f_trap, f_untrap;
static u32 f_cdb_new, f_cdb_open, f_cdb_first, f_cdb_insert, f_cdb_write, f_cdb_put;
static const u16 *const modem[][2] = {             /* the record: column, value */
    { u"Name", u"Data port" }, { u"PortName", u"DATAPORT::0" }, { u"CSYName", u"DATAPORT" },
    { u"TSYName", u"PHONETSY" }, { 0, 0 } };

static u32 dll_export(const struct rom_image *im, int ord) { return im ? uread32(im->export_dir + 4 * (ord - 1)) : 0; }
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
    f_sa_connect = dll_export(rom_image("\\System\\Libs\\Sysagt.dll"), SYSAGT_CONNECT);
    f_wait_any = euser_export(EUSER_WAIT_ANY);
    f_msv_connect = dll_export(rom_image("\\System\\Libs\\Msgs.dll"), MSGS_CONNECT);
    f_trap_cleanup = euser_export(EUSER_TRAP_CLEANUP);
    f_leave_if = euser_export(EUSER_LEAVE_IF_ERROR);
    f_pushl = euser_export(EUSER_PUSHL);
    f_pop_destroy = euser_export(EUSER_POP_DESTROY);
    f_trap = euser_export(EUSER_TRAP);
    f_untrap = euser_export(EUSER_UNTRAP);
    const struct rom_image *cdb = rom_image("\\System\\Libs\\Commdb.dll");
    f_cdb_new = dll_export(cdb, CDB_NEWL);
    f_cdb_open = dll_export(cdb, CDB_OPEN_TABLE);
    f_cdb_first = dll_export(cdb, CDB_FIRST);
    f_cdb_insert = dll_export(cdb, CDB_INSERT);
    f_cdb_write = dll_export(cdb, CDB_WRITE_TEXT);
    f_cdb_put = dll_export(cdb, CDB_PUT);
    kprintf("[launch] will run ");
    kputs16(app, n);
    kprintf("\n");
    state = 1;
    launch_due = 0;
}

static void ptrc(struct ptrc *d, const u16 *s)
{
    u32 n = 0;
    while (s[n]) n++;
    d->len = n | 1u << 28;
    d->ptr = (u32)s;
}

/* Runs in user mode, under a trap: CommDb's calls leave, and the L calls
 * push onto the cleanup stack.  A modem when the table has none. */
static void add_modem(void)
{
    struct ptrc t, v;
    u32 *db = ((u32 *(*)(int))f_cdb_new)(0);       /* EDatabaseTypeUnspecified: as it is */
    ((void (*)(u32 *))f_pushl)(db);
    ptrc(&t, u"Modem");
    u32 *view = ((u32 *(*)(u32 *, struct ptrc *))f_cdb_open)(db, &t);
    if (((s32 (*)(u32 *))f_cdb_first)(view) == KErrNotFound) {
        u32 id;
        ((s32 (*)(s32))f_leave_if)(((s32 (*)(u32 *, u32 *))f_cdb_insert)(view, &id));
        for (int i = 0; modem[i][0]; i++) {
            ptrc(&t, modem[i][0]);
            ptrc(&v, modem[i][1]);
            ((void (*)(u32 *, struct ptrc *, struct ptrc *))f_cdb_write)(view, &t, &v);
        }
        ((s32 (*)(s32))f_leave_if)(((s32 (*)(u32 *, int, int))f_cdb_put)(view, 0, 0));   /* not hidden */
    }
    ((void (*)(int))f_pop_destroy)(2);
}

/* TRAP(r, fn()): TTrap::Trap returns 0, and again 1 when fn leaves, with r
 * the leave's code.  Nothing but r is used after the second return. */
static __attribute__((noinline)) s32 trapped(void (*fn)(void))
{
    u32 trap[19];                                  /* TTrap: iState[16], iNext, iResult, iHandler */
    volatile s32 r = 0;
    if (((s32 (*)(u32 *, volatile s32 *))f_trap)(trap, &r) == 0) {
        fn();
        ((void (*)(void))f_untrap)();
    }
    return r;
}

/* Runs in user mode, as the launcher thread's function. */
static s32 launcher(u32 unused)
{
    if (f_cdb_new && ((void *(*)(void))f_trap_cleanup)()) {
        s32 r = trapped(add_modem);
        kprintf("[launch] CommDb modem: %d\n", r);
    }
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
