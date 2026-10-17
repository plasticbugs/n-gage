/* Vectors, mode stacks, and the one way into and out of the kernel.
 *
 * Every exception that comes from user code saves the whole user context into
 * *cur_ctx, calls exc_dispatch(ctx, kind) in C with IRQs off, and returns by
 * restoring *cur_ctx -- which the C side may have pointed at another thread.
 * The kernel never runs with IRQs on and is never re-entered, so there is one
 * kernel stack.  User code never runs in a privileged mode (the idle loop is a
 * user thread too), so every IRQ arrives from user mode.
 */
#include "kern.h"

    .section .vectors, "ax"
    .arm
    .global _start
_start:
    b   reset
    b   undef_entry
    b   swi_entry
    b   pabt_entry
    b   dabt_entry
    b   .
    b   irq_entry
    b   .

    .text
reset:
    /* a stack for each mode we can be in; IRQs and FIQs stay off */
    msr cpsr_c, #0xD2               @ IRQ
    ldr sp, =__irq_stack_top
    msr cpsr_c, #0xD7               @ abort
    ldr sp, =__abt_stack_top
    msr cpsr_c, #0xDB               @ undefined
    ldr sp, =__und_stack_top
    msr cpsr_c, #0xD3               @ SVC
    ldr sp, =__svc_stack_top

    ldr r0, =__bss_start
    ldr r1, =__bss_end
    mov r2, #0
1:  cmp r0, r1
    strlo r2, [r0], #4
    blo 1b

    bl  kmain                       @ builds the first threads, sets cur_ctx
    b   ctx_restore

/* Save the interrupted user context.  Entered in the exception's mode with
 * lr = the address to resume at; r0 is pushed on that mode's stack first. */
.macro SAVE kind, adj
    .if \adj
    sub lr, lr, #\adj
    .endif
    str r0, [sp, #-4]!
    ldr r0, =cur_ctx
    ldr r0, [r0]
    add r0, r0, #4
    stmia r0, {r1-r14}^             @ the user bank's r1..r14
    nop
    sub r0, r0, #4
    str lr, [r0, #CTX_PC]
    mrs lr, spsr
    str lr, [r0, #CTX_CPSR]
    ldr lr, [sp], #4
    str lr, [r0, #0]
    /* continue in SVC mode whatever the exception was */
    msr cpsr_c, #0xD3
    mov r1, #\kind
    bl  exc_dispatch
    b   ctx_restore
.endm

swi_entry:   SAVE EXC_SWI, 0
irq_entry:   SAVE EXC_IRQ, 4
undef_entry: SAVE EXC_UNDEF, 4      @ lr points past the instruction (ARM)
pabt_entry:  SAVE EXC_PABT, 4
dabt_entry:  SAVE EXC_DABT, 8

    .global ctx_restore
ctx_restore:
    msr cpsr_c, #0xD3
    ldr r0, =cur_ctx
    ldr r0, [r0]
    ldr r1, [r0, #CTX_CPSR]
    msr spsr_cxsf, r1
    ldr lr, [r0, #CTX_PC]
    ldmia r0, {r0-r14}^
    nop
    movs pc, lr

/* Where every thread starts, in user mode.  The kernel sets
 *   r4 func, r5 its argument, r6 heap min (0: the thread already has a
 *   heap), r7 heap max, r8 UserHeap::ChunkHeap, r9 User::SwitchHeap,
 *   r10 User::StartThread
 * and EUser does the rest; StartThread does not return. */
    .global thread_tramp
thread_tramp:
    cmp r6, #0
    beq 1f
    mov r0, #0                      @ no name: a local, anonymous chunk
    mov r1, r6
    mov r2, r7
    mov r3, #0x1000                 @ grow by a page at a time
    mov lr, pc
    bx  r8
    cmp r0, #0
    beq 2f
    mov lr, pc
    bx  r9
1:  mov r0, r4
    mov r1, r5
    mov lr, pc
    bx  r10
2:  swi 0xFFFFFF                    @ no heap: the kernel reports it
    b   2b

/* The idle thread: a user-mode loop the harness recognises by its address
 * and fast-forwards to the next interrupt. */
    .global idle_loop
idle_loop:
    b   idle_loop

    .ltorg
