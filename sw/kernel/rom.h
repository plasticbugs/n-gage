#ifndef ROM_H
#define ROM_H
#include "kern.h"

#define ROM_ATT_DIR 0x10

/* TRomEntry */
struct rom_entry {
    u32 size;
    u32 addr;
    u8  att;
    u8  name_len;
    u16 name[1];            /* UTF-16, name_len of them; packed, unaligned */
} __attribute__((packed));

/* TRomImageHeader (EKA1): code follows at +0x64 */
struct rom_image {
    u32 uid1, uid2, uid3, uid_check;
    u32 entry;
    u32 code_addr;
    u32 data_addr;          /* initialised data, in ROM                      */
    u32 code_size;
    u32 text_size;
    u32 data_size;
    u32 bss_size;
    u32 heap_min, heap_max;
    u32 stack_size;
    u32 dll_ref_table;      /* TDllRefTable: the ROM images this one links to */
    u32 export_count;
    u32 export_dir;
    u32 checksum_code, checksum_data;
    u32 version;
    u32 flags;
    u32 priority;
    u32 data_bss_base;      /* where .data/.bss live when it runs            */
    u32 next_extension;
    u32 hw_variant;
};

const struct rom_entry *rom_find(const char *path);
const struct rom_image *rom_image(const char *path);
int rom_valid(void);
#endif
