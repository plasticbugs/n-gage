/* Kernel entry, the exception dispatcher, and boot.
 *
 * Boot starts the file server as EKA1 does: EFile is the first process, and
 * it starts EStart, which starts the rest of the system. */
#include "kobj.h"
#include "mm.h"

struct ctx *cur_ctx;
int kflags;

static void user_fault(struct ctx *c, int kind)
{
    static const char *const kinds[] = { "", "swi", "irq", "undefined instruction", "prefetch abort", "data abort" };
    kprintf("[kern] %s in thread ", kinds[kind]);
    kputs16(cur->o.name, cur->o.namelen);
    kprintf(" of ");
    kputs16(cur->proc->o.name, cur->proc->o.namelen);
    kprintf(" at pc %p (cpsr %x)\n", c->pc, c->cpsr);
    for (int i = 0; i < 15; i += 4)
        kprintf("  r%d %08x  r%d %08x  r%d %08x  r%d %08x\n", i, c->r[i], i + 1, c->r[i + 1],
                i + 2, c->r[i + 2], i + 3, i + 3 < 15 ? c->r[i + 3] : c->pc);
    /* EKA1 panics the thread KERN-EXEC 3; stop instead while bringing up */
    kpanic("user fault");
}

void exc_dispatch(struct ctx *c, int kind)
{
    if ((c->cpsr & 0x1F) != 0x10) kpanic("exception %d in kernel mode, pc %p", kind, c->pc);
    switch (kind) {
    case EXC_SWI: {
        u32 n = (c->cpsr & 0x20) ? (*(u16 *)(c->pc - 2) & 0xFF) : (*(u32 *)(c->pc - 4) & 0x00FFFFFF);
        if (n == 0xFFFFFF) {
            int nres;
            u32 rb = vm_reserved(&nres);
            kprintf("[kern] thread ");
            kputs16(cur->o.name, cur->o.namelen);
            kprintf(" of ");
            kputs16(cur->proc->o.name, cur->proc->o.namelen);
            kprintf(": heap %x..%x; RAM free %x, chunk space %x in %d reservations\n",
                    c->r[6], c->r[7], mm_free_bytes(), rb, nres);
            for (struct kobj *o = obj_first(O_CHUNK); o; o = o->next) {
                struct chunk *k = (struct chunk *)o;
                if (k->max < 0x200000) continue;
                kprintf("  chunk %x max %x committed %x ", k->base, k->max, k->top - k->bottom);
                kputs16(o->owner ? o->owner->o.name : (const u16 *)u"-", o->owner ? o->owner->o.namelen : 1);
                kprintf("::");
                kputs16(o->name, o->namelen);
                kprintf("\n");
            }
            kpanic("thread start: no heap");
        }
        exec_dispatch(c, n);
        break;
    }
    case EXC_IRQ: {
        u32 st = IO(IO_IRQ_STATUS);
        IO(IO_IRQ_STATUS) = st;
        if (st & IRQ_TIMER) timer_tick();
        break;
    }
    default:
        user_fault(c, kind);
    }
    schedule();
}

static struct process *kproc;

static void boot_idle(void)
{
    u16 n[] = { 'E', 'K', 'e', 'r', 'n' };
    kproc = proc_new(n, 5);
    kproc->exit_type = 3;
    kproc->prio = 0;
    struct thread *t = (struct thread *)obj_new(O_THREAD, sizeof(struct thread), kproc);
    obj_set_name_a(&t->o, "Null");
    t->proc = kproc;
    t->ctx.pc = (u32)idle_loop;
    t->ctx.cpsr = 0x10;
    t->state = T_READY;
    t->prio = 0;
    t->exit_type = 3;
    idle_thread = t;
    cur = t;
    cur_ctx = &t->ctx;
}

void kmain(void)
{
    kflags = IO(IO_DBG_FLAGS);
    kprintf("NGVM kernel\n");
    if (!rom_valid()) kpanic("no firmware image at %p", NGVM_ROM_BASE);
    mm_init();
    obj_init();
    boot_idle();
    extern void drive_init(void);
    drive_init();

    const char *fs = "Z:\\System\\Libs\\EFile.exe";
    const struct rom_image *img = rom_image(fs);
    if (!img) kpanic("%s not in the firmware", fs);
    struct process *p = proc_from_rom(img, fs);
    p->main->suspend_count = 0;
    kprintf("EFile: entry %p data %p+%x bss %x\n", img->entry, img->data_bss_base, img->data_size, img->bss_size);

    sched_init();
    schedule();
}
