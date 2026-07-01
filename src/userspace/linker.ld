ENTRY(_start)

/*
 * Keep the ELF and program-header tables inside the first PT_LOAD mapping.
 * Besides making AT_PHDR valid, this matches the layout expected by normal
 * System V ELF loaders and by the dynamic-runtime capable Tunix loader.
 */
PHDRS
{
    text   PT_LOAD FILEHDR PHDRS FLAGS(5); /* R|X */
    rodata PT_LOAD               FLAGS(4); /* R   */
    data   PT_LOAD               FLAGS(6); /* R|W */
}

SECTIONS
{
    /* Reserve the first page for FILEHDR/PHDRS and start code on a clean page. */
    . = 0x400000 + SIZEOF_HEADERS;
    .text : ALIGN(0x1000) { *(.text .text.*) } :text
    .rodata : ALIGN(0x1000) { *(.rodata .rodata.*) } :rodata
    .data : ALIGN(0x1000) { *(.data .data.*) } :data
    .bss : ALIGN(0x1000) { *(.bss .bss.*) *(COMMON) } :data
    /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
