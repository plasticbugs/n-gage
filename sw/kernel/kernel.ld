/* The kernel lives in the first megabyte of RAM; vectors at 0. */
ENTRY(_start)
MEMORY { KRAM (rwx) : ORIGIN = 0x00000000, LENGTH = 1M }
SECTIONS {
    .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) } > KRAM
    .data : { *(.data*) } > KRAM
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; } > KRAM
    .stacks (NOLOAD) : {
        . = ALIGN(8);
        . += 0x4000; __svc_stack_top = .;
        . += 0x400;  __irq_stack_top = .;
        . += 0x400;  __abt_stack_top = .;
        . += 0x400;  __und_stack_top = .;
        __kernel_end = .;
    } > KRAM
    /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
