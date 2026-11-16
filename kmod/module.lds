SECTIONS {
	/DISCARD/ : {
		*(.discard)
		*(.discard.*)
		*(.eh_frame)
	}

	__ksymtab		0 : { *(SORT(___ksymtab+*)) }
	__ksymtab_gpl		0 : { *(SORT(___ksymtab_gpl+*)) }
	__ksymtab_unused	0 : { *(SORT(___ksymtab_unused+*)) }
	__ksymtab_unused_gpl	0 : { *(SORT(___ksymtab_unused_gpl+*)) }
	__ksymtab_gpl_future	0 : { *(SORT(___ksymtab_gpl_future+*)) }
	__kcrctab		0 : { *(SORT(___kcrctab+*)) }
	__kcrctab_gpl		0 : { *(SORT(___kcrctab_gpl+*)) }
	__kcrctab_unused	0 : { *(SORT(___kcrctab_unused+*)) }
	__kcrctab_unused_gpl	0 : { *(SORT(___kcrctab_unused_gpl+*)) }
	__kcrctab_gpl_future	0 : { *(SORT(___kcrctab_gpl_future+*)) }

	.init_array		0 : ALIGN(8) { *(SORT(.init_array.*)) *(.init_array) }

	.altinstructions	0 : ALIGN(8) { KEEP(*(.altinstructions)) }
	__bug_table		0 : ALIGN(8) { KEEP(*(__bug_table)) }
	__jump_table		0 : ALIGN(8) { KEEP(*(__jump_table)) }

	__patchable_function_entries : { *(__patchable_function_entries) }

	.bss : {
		*(.bss .bss.[0-9a-zA-Z_]*)
		*(.bss..L*)
	}

	.data : {
		*(.data .data.[0-9a-zA-Z_]*)
		*(.data..L*)
	}

	.rodata : {
		*(.rodata.._start)
		*(.rodata .rodata.[0-9a-zA-Z_]*)
		*(.rodata..L*)
		*(.rodata.._end)
	}

	.text : ALIGN(4096) {
		*(.text.._start)
		*(.text.__cfi_check)
		*(.text .text.[0-9a-zA-Z_]*)
		__cfi_jt_start = .;
		*(.text..L.cfi.jumptable .text..L.cfi.jumptable.*)
		__cfi_jt_end = .;
		*(.text.._end)
		*(.text.._fips140_unchecked)
	}

	.plt 0 : { BYTE(0) }
	.init.plt 0 : { BYTE(0) }
	.text.ftrace_trampoline 0 : { BYTE(0) }
}
