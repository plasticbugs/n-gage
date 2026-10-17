/* Client/server: servers, sessions, messages, and the descriptor copies
 * between a server and its client.
 *
 * EKA1's RMessage, written into the server's buffer on delivery (32 bytes):
 *   +00 iFunction  +04 iArgs[4]  +14 iClient (RThread handle)
 *   +18 iSessionPtr (the server's CSession*)  +1C iHandle (the message)
 * Arguments are copied as words; descriptors in them are client addresses,
 * read and written later through the RThread::ReadL/WriteL execs. */
#include "kobj.h"

#define MAX_MSGS 512
static struct message msgs[MAX_MSGS];

#define EConnect    (-1)
#define EDisConnect (-2)

static u32 msg_handle(struct message *m) { return ((u32)m->gen << 16) | (u32)(m - msgs + 1); }

struct message *msg_lookup(u32 mh)
{
    int i = (mh & 0xFFFF) - 1;
    if (i < 0 || i >= MAX_MSGS || !msgs[i].in_use || msgs[i].gen != (mh >> 16)) return 0;
    return &msgs[i];
}

static struct message *msg_alloc(void)
{
    for (int i = 0; i < MAX_MSGS; i++)
        if (!msgs[i].in_use) {
            struct message *m = &msgs[i];
            u16 g = (u16)((m->gen + 1) & 0x7FFF);
            memset(m, 0, sizeof *m);
            m->gen = g ? g : 1;
            m->in_use = 1;
            return m;
        }
    kpanic("out of IPC messages");
}

struct server *server_find(const u16 *name, int len)
{
    extern int u16_eq_fold(const u16 *, int, const u16 *, int);
    for (struct kobj *o = obj_first(O_SERVER); o; o = o->next)
        if (o->namelen && u16_eq_fold(o->name, o->namelen, name, len)) return (struct server *)o;
    return 0;
}

static void trace_msg(const char *what, struct message *m)
{
    if (!(kflags & DBGF_IPC)) return;
    kprintf("[ipc] %s ", what);
    kputs16(m->session->server->o.name, m->session->server->o.namelen);
    kprintf(" fn %d args %x %x %x %x from ", m->function, m->args[0], m->args[1], m->args[2], m->args[3]);
    kputs16(m->client->o.name, m->client->o.namelen);
    if (what[0] == 's') {
        extern void trace_des(u32 d);
        for (int i = 0; i < 4; i++) trace_des(m->args[i]);
    }
    kprintf("\n");
}

static void deliver(struct server *s, struct message *m)
{
    u32 b = s->rx_buf;
    struct thread *st = s->thread;
    extern struct process *proc_mapped(void);
    struct process *was = proc_mapped();
    if (b - NGVM_DATA_BASE < NGVM_DATA_SIZE) proc_switch_in(st->proc);
    uwrite32(b + 0x00, (u32)m->function);
    for (int i = 0; i < 4; i++) uwrite32(b + 4 + 4 * i, m->args[i]);
    uwrite32(b + 0x14, HANDLE_GLOBAL_THREAD | m->client->id);
    uwrite32(b + 0x18, m->session->session_ptr);
    uwrite32(b + 0x1C, msg_handle(m));
    if (was && was != proc_mapped()) proc_switch_in(was);
    m->delivered = 1;
    s->rx_pending = 0;
    trace_msg("deliver", m);
    request_complete(st, s->rx_status, KErrNone);
}

static void enqueue(struct server *s, struct message *m)
{
    if (s->rx_pending) { deliver(s, m); return; }
    m->next = 0;
    if (s->queue_tail) s->queue_tail->next = m; else s->queue = m;
    s->queue_tail = m;
}

int ipc_send(struct thread *t, struct session *s, s32 fn, u32 args, u32 status)
{
    if (!s->server || s->server->o.refs <= 0 || !s->server->thread ||
        s->server->thread->state == T_DEAD)
        return KErrServerTerminated;
    struct message *m = msg_alloc();
    m->function = fn;
    if (args) for (int i = 0; i < 4; i++) m->args[i] = uread32(args + 4 * i);
    m->client = t;
    m->session = s;
    m->status = status;
    s->msgs_out++;
    trace_msg("send", m);
    enqueue(s->server, m);
    return KErrNone;
}

void ipc_receive(struct thread *t, struct server *s, u32 status, u32 buf)
{
    s->rx_status = status;
    s->rx_buf = buf;
    s->rx_pending = 1;
    struct message *m = s->queue;
    if (m) {
        s->queue = m->next;
        if (!s->queue) s->queue_tail = 0;
        deliver(s, m);
    }
}

void ipc_receive_cancel(struct server *s)
{
    if (!s->rx_pending) return;
    s->rx_pending = 0;
    request_complete(s->thread, s->rx_status, KErrCancel);
}

int ipc_complete(struct thread *t, u32 mh, s32 reason)
{
    struct message *m = msg_lookup(mh);
    if (!m) { kprintf("[ipc] complete of a dead message %x\n", mh); return KErrBadHandle; }
    if (kflags & DBGF_IPC) kprintf("[ipc] complete fn %d -> %d\n", m->function, reason);
    struct session *s = m->session;
    s->msgs_out--;
    if (m->status) request_complete(m->client, m->status, reason);
    m->in_use = 0;
    if (m->function == EDisConnect) obj_unref(&s->o);
    return KErrNone;
}

void ipc_set_session_ptr(u32 mh, u32 ptr)
{
    struct message *m = msg_lookup(mh);
    if (m) m->session->session_ptr = ptr;
}

/* The client closed its handle: tell the server, and let the session go
 * when the server has completed the disconnect. */
void session_close(struct thread *t, struct session *s)
{
    if (s->closed || !s->server) return;
    s->closed = 1;
    if (!s->session_ptr) return;        /* never connected */
    obj_ref(&s->o);                     /* held by the message            */
    if (ipc_send(t, s, EDisConnect, 0, 0) != KErrNone) obj_unref(&s->o);
}

/* ---- copies between a server and its client ------------------------------ */
/* Read the client's descriptor at cdes into the server's local descriptor
 * ldes, starting `offset` units in.  unit: 1 or 2 bytes. */
int ipc_read(struct thread *client, u32 cdes, u32 ldes, int offset, int unit)
{
    extern struct process *proc_mapped(void);
    static u8 buf[4096];
    if (offset < 0) return KErrArgument;
    struct process *was = proc_mapped();
    int lmax = des_maxlen(ldes);
    proc_switch_in(client->proc);
    int clen = des_len(cdes);
    int n = clen - offset;
    if (n < 0) n = 0;
    if (n > lmax) n = lmax;
    u32 src = des_ptr(cdes) + offset * unit;
    int done = 0;
    /* through a bounce buffer: the two may be in different data windows */
    while (done < n) {
        int k = (n - done) * unit > (int)sizeof buf ? (int)sizeof buf / unit : n - done;
        proc_switch_in(client->proc);
        ucopy_from(buf, src + done * unit, k * unit);
        proc_switch_in(was);
        ucopy_to(des_ptr(ldes) + done * unit, buf, k * unit);
        done += k;
    }
    proc_switch_in(was);
    des_setlen(ldes, n);
    return KErrNone;
}

int ipc_write(struct thread *client, u32 cdes, u32 ldes, int offset, int unit)
{
    extern struct process *proc_mapped(void);
    static u8 buf[4096];
    if (offset < 0) return KErrArgument;
    struct process *was = proc_mapped();
    int n = des_len(ldes);
    u32 src = des_ptr(ldes);
    proc_switch_in(client->proc);
    int cmax = des_maxlen(cdes);
    if (offset + n > cmax) { proc_switch_in(was); return KErrOverflow; }
    u32 dst = des_ptr(cdes) + offset * unit;
    proc_switch_in(was);
    int done = 0;
    while (done < n) {
        int k = (n - done) * unit > (int)sizeof buf ? (int)sizeof buf / unit : n - done;
        proc_switch_in(was);
        ucopy_from(buf, src + done * unit, k * unit);
        proc_switch_in(client->proc);
        ucopy_to(dst + done * unit, buf, k * unit);
        done += k;
    }
    proc_switch_in(client->proc);
    des_setlen(cdes, offset + n);
    proc_switch_in(was);
    return KErrNone;
}

int ipc_des_len(struct thread *client, u32 cdes, int max)
{
    extern struct process *proc_mapped(void);
    struct process *was = proc_mapped();
    proc_switch_in(client->proc);
    int r = max ? des_maxlen(cdes) : des_len(cdes);
    proc_switch_in(was);
    return r;
}
