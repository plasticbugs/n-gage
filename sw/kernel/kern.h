/* The NGVM kernel: what start.S and the C side share. */
#ifndef KERN_H
#define KERN_H
#include "ngvm_hw.h"

/* struct ctx: r0..r14 (user bank), pc, cpsr */
#define CTX_PC    (15 * 4)
#define CTX_CPSR  (16 * 4)

#define EXC_SWI    1
#define EXC_IRQ    2
#define EXC_UNDEF  3
#define EXC_PABT   4
#define EXC_DABT   5

#ifndef __ASSEMBLER__
typedef unsigned int   u32;
typedef unsigned short u16;
typedef unsigned char  u8;
typedef int            s32;
typedef unsigned long long u64;
typedef long long      s64;

struct ctx { u32 r[15]; u32 pc; u32 cpsr; };
extern struct ctx *cur_ctx;
void exc_dispatch(struct ctx *c, int kind);
extern char idle_loop[];

/* klib.c */
void kputc(int c);
void kputs(const char *s);
void kprintf(const char *fmt, ...);
void kpanic(const char *fmt, ...) __attribute__((noreturn));
void *memcpy(void *d, const void *s, unsigned n);
void *memset(void *d, int v, unsigned n);
int   memcmp(const void *a, const void *b, unsigned n);
#endif
#endif
