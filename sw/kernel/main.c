/* Kernel entry and the exception dispatcher. */
#include "kern.h"

struct ctx *cur_ctx;
static struct ctx idle_ctx;

void exc_dispatch(struct ctx *c, int kind)
{
    switch (kind) {
    case EXC_SWI: {
        u32 n = (c->cpsr & 0x20) ? (*(u16 *)(c->pc - 2) & 0xFF)
                                 : (*(u32 *)(c->pc - 4) & 0x00FFFFFF);
        kpanic("unimplemented exec %x from pc %p lr %p", n, c->pc, c->r[14]);
    }
    case EXC_IRQ:
        IO(IO_IRQ_STATUS) = IO(IO_IRQ_STATUS);
        return;
    default:
        kpanic("exception %d at pc %p cpsr %x", kind, c->pc, c->cpsr);
    }
}

void kmain(void)
{
    kprintf("NGVM kernel\n");
    idle_ctx.pc = (u32)idle_loop;
    idle_ctx.cpsr = 0x10;
    cur_ctx = &idle_ctx;
    kpanic("nothing to run yet");
}
