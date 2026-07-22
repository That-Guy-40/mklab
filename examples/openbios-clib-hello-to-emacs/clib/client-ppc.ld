ENTRY(_start)
SECTIONS {
  . = 0x01000000;
  .text : { *(.text._start) *(.text*) }
  .rodata : { *(.rodata*) }
  .data : { *(.data* .got2* .got* .sdata* .fixup) }
  .bss : { *(.bss* .sbss* COMMON) }
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) }
}
