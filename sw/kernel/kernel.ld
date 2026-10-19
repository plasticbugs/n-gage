/* The kernel lives in the first megabyte of RAM; vectors at 0.
 *
 * .data is loaded as a copy just past .text and copied into place by
 * start.S at every boot, so a core reset -- which runs the kernel again
 * without the Pocket loading it again -- starts from the image's values and
 * not the last run's.  The copy is never written. */
ENTRY(_start)
SECTIONS {
    . = 0;
    .text : { KEEP(*(.vectors)) *(.text*) *(.rodata*) }
    . = ALIGN(4);
    __data_load = .;
    . += 0x400;
    .data : AT(__data_load) { __data_start = .; *(.data*) . = ALIGN(4); __data_end = .; }
    ASSERT(__data_end - __data_start <= 0x400, ".data outgrew the room for its copy")
    .bss (NOLOAD) : { __bss_start = .; *(.bss*) *(COMMON) . = ALIGN(4); __bss_end = .; }
    .stacks (NOLOAD) : {
        . = ALIGN(8);
        . += 0x4000; __svc_stack_top = .;
        . += 0x400;  __irq_stack_top = .;
        . += 0x400;  __abt_stack_top = .;
        . += 0x400;  __und_stack_top = .;
        __kernel_end = .;
    }
    ASSERT(__kernel_end <= 0x100000, "the kernel is over its megabyte")
    /DISCARD/ : { *(.ARM.exidx*) *(.comment) }
}
