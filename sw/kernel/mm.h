#ifndef MM_H
#define MM_H
#include "kern.h"

void mm_init(void);
u32  mm_free_bytes(void);
int  pg_alloc(void);                 /* a zeroed RAM page, or -1 */
int  pg_alloc_run(int n);            /* n of them in a row: the first, or -1 */
void pg_free(int page);
void pt_set(int index, u32 page);
u32  pt_get_va(u32 va);
int  vm_mapped(u32 va);
u32  vm_reserve(u32 size);           /* chunk-space addresses, or 0 */
u32  vm_reserve_for(int low, u32 size); /* low: a game process's, under NGVM_LOW_BASE if it fits */
void vm_release(u32 base);
u32  vm_reserved(int *count);         /* bytes of chunk space reserved */
int  vm_commit(u32 va, u32 size);    /* 0, or -1 when RAM runs out */
void vm_decommit(u32 va, u32 size);
void vm_alias(u32 va, u32 page);     /* map someone else's page here too */
void vm_unalias(u32 base);           /* drop an alias reservation; frees nothing */
#endif
