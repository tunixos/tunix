ENTRY(kernel_entry)
SECTIONS
{
    . = 0xFFFFFFFF80100000;

    .text ALIGN(4K) : AT(ADDR(.text) - 0xFFFFFFFF80000000)
    {
        *(.text*)
    }

    .rodata ALIGN(4K) : AT(ADDR(.rodata) - 0xFFFFFFFF80000000)
    {
        *(.rodata*)
    }

    .data ALIGN(4K) : AT(ADDR(.data) - 0xFFFFFFFF80000000)
    {
        *(.data*)
    }

    .bss ALIGN(4K) : AT(ADDR(.bss) - 0xFFFFFFFF80000000)
    {
        __bss_start = .;
        *(COMMON)
        *(.bss*)
        kernel_end = .;
        . += 0x200000;
        kernel_reserve_end = .;
    }

    /* pmm_init puts its page bitmap and reference counts at kernel_end, so the
       kernel has to own that space rather than assume somebody mapped past its
       image. It used to work only because the old bootloader mapped a generous
       slab; a loader that maps exactly the program headers — as any of them is
       entitled to — faulted on the first write.
       The bound is exact rather than generous: PMM_DIRECT_MAP_LIMIT is 1792 MiB,
       so at most 458752 pages, costing one bit each for the bitmap and two
       bytes each for the counts. That is 952 KiB; two megabytes leaves room for
       the alignment and for the limit to grow. */
    ASSERT((kernel_reserve_end - 0xFFFFFFFF80000000) < 0x02000000,
           "kernel image overlaps the 32 MiB initramfs staging area")
}
