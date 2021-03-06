/* -*-Asm-*- */
/*
 *  GRUB  --  GRand Unified Bootloader
 *  Copyright (C) 1999,2000,2001,2002,2005,2006,2007,2008,2009  Free Software Foundation, Inc.
 *
 *  GRUB is free software: you can redistribute it and/or modify
 *  it under the terms of the GNU General Public License as published by
 *  the Free Software Foundation, either version 3 of the License, or
 *  (at your option) any later version.
 *
 *  GRUB is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *  GNU General Public License for more details.
 *
 *  You should have received a copy of the GNU General Public License
 *  along with GRUB.  If not, see <http://www.gnu.org/licenses/>.
 */

#include <grub/symbol.h>
#include <grub/machine/boot.h>

/*
 *  defines for the code go here
 */

/* BEGIN TCG_Extension */
	/* Changes particularly adapted from trustedgrub and GRUB-IMA */
/* END TCG_Extension */

	/* Print message string */
#define MSG(x)	movw $x, %si; call LOCAL(message)
#define ERR(x)	movw $x, %si; jmp LOCAL(error_message)

	.file	"boot.S"

	.text

	/* Tell GAS to generate 16-bit instructions so that this code works
	   in real mode. */
	.code16

.globl _start, start;
_start:
start:
	/*
	 * _start is loaded at 0x7c00 and is jumped to with CS:IP 0:0x7c00
	 */

	/*
	 * Beginning of the sector is compatible with the FAT/HPFS BIOS
	 * parameter block.
	 */

	jmp	LOCAL(after_BPB)
	nop	/* do I care about this ??? */

	/*
	 * This space is for the BIOS parameter block!!!!  Don't change
	 * the first jump, nor start the code anywhere but right after
	 * this area.
	 */

	. = _start + GRUB_BOOT_MACHINE_BPB_START
	. = _start + 4

	/* scratch space */
mode:
	.byte	0
disk_address_packet:
sectors:
	.long	0
heads:
	.long	0
cylinders:
	.word	0
sector_start:
	.byte	0
head_start:
	.byte	0
cylinder_start:
	.word	0
	/* more space... */

	. = _start + GRUB_BOOT_MACHINE_BPB_END

	/*
	 * End of BIOS parameter block.
	 */

kernel_address:
	.word	GRUB_BOOT_MACHINE_KERNEL_ADDR

	. = _start + GRUB_BOOT_MACHINE_KERNEL_SECTOR
kernel_sector:
	.long	1, 0

	. = _start + GRUB_BOOT_MACHINE_BOOT_DRIVE
boot_drive:
	.byte 0xff	/* the disk to load kernel from */
			/* 0xff means use the boot drive */

LOCAL(after_BPB):

/* general setup */
	cli		/* we're not safe here! */

        /*
         * This is a workaround for buggy BIOSes which don't pass boot
         * drive correctly. If GRUB is installed into a HDD, check if
         * DL is masked correctly. If not, assume that the BIOS passed
         * a bogus value and set DL to 0x80, since this is the only
         * possible boot drive. If GRUB is installed into a floppy,
         * this does nothing (only jump).
         */
	. = _start + GRUB_BOOT_MACHINE_DRIVE_CHECK
boot_drive_check:
        jmp     3f	/* grub-setup may overwrite this jump */
        testb   $0x80, %dl
        jz      2f
3:
	/* Ignore %dl different from 0-0x0f and 0x80-0x8f.  */
	testb   $0x70, %dl
	jz      1f
2:
        movb    $0x80, %dl
1:
	/*
	 * ljmp to the next instruction because some bogus BIOSes
	 * jump to 07C0:0000 instead of 0000:7C00.
	 */
	ljmp	$0, $real_start

real_start:

	/* set up %ds and %ss as offset from 0 */
	xorw	%ax, %ax
	movw	%ax, %ds
	movw	%ax, %ss

	/* set up the REAL stack */
	movw	$GRUB_BOOT_MACHINE_STACK_SEG, %sp

	sti		/* we're safe again */

	/*
	 *  Check if we have a forced disk reference here
	 */
	movb   boot_drive, %al
	cmpb	$0xff, %al
	je	1f
	movb	%al, %dl
1:
	/* save drive reference first thing! */
	pushw	%dx

	/* print a notification message on the screen */
	MSG(notification_string)

	/* set %si to the disk address packet */
	movw	$disk_address_packet, %si

/* BEGIN TCG_Extension */
#ifndef ENABLE_TGRUB2
	/* check if LBA is supported */
	movb	$0x41, %ah
	movw	$0x55aa, %bx
	int	$0x13

	/*
	 *  %dl may have been clobbered by INT 13, AH=41H.
	 *  This happens, for example, with AST BIOS 1.04.
	 */
	popw	%dx
	pushw	%dx

	/* use CHS if fails */
	jc	LOCAL(chs_mode)
	cmpw	$0xaa55, %bx
	jne	LOCAL(chs_mode)

	andw	$1, %cx
	jz	LOCAL(chs_mode)
#endif /* ! ENABLE_TGRUB2 */
/* END TCG Extension */

lba_mode:
	xorw	%ax, %ax
	movw	%ax, 4(%si)

	incw	%ax
	/* set the mode to non-zero */
	movb	%al, -1(%si)

	/* the blocks */
	movw	%ax, 2(%si)

	/* the size and the reserved byte */
	movw	$0x0010, (%si)

	/* the absolute address */
	movl	kernel_sector, %ebx
	movl	%ebx, 8(%si)
	movl	kernel_sector + 4, %ebx
	movl	%ebx, 12(%si)

	/* the segment of buffer address */
	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, 6(%si)

/*
 * BIOS call "INT 0x13 Function 0x42" to read sectors from disk into memory
 *	Call with	%ah = 0x42
 *			%dl = drive number
 *			%ds:%si = segment:offset of disk address packet
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movb	$0x42, %ah
	int	$0x13

	/* LBA read is not supported, so fallback to CHS.  */
	jc	LOCAL(chs_mode)

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx
	jmp	LOCAL(copy_buffer)

LOCAL(chs_mode):
/* BEGIN TCG_Extension */
#ifdef ENABLE_TGRUB2
	MSG(chs_no_support_string)
	jmp     LOCAL(general_error)
#else /* ! ENABLE_TGRUB2 */
/* END TCG Extension */
	/*
	 *  Determine the hard disk geometry from the BIOS!
	 *  We do this first, so that LS-120 IDE floppies work correctly.
	 */
	movb	$8, %ah
	int	$0x13
	jnc	LOCAL(final_init)

	/*
	 *  The call failed, so maybe use the floppy probe instead.
	 */
	testb	$GRUB_BOOT_MACHINE_BIOS_HD_FLAG, %dl
	jz	LOCAL(floppy_probe)

	/* Nope, we definitely have a hard disk, and we're screwed. */
	ERR(hd_probe_error_string)

LOCAL(final_init):
	/* set the mode to zero */
	movzbl	%dh, %eax
	movb	%ah, -1(%si)

	/* save number of heads */
	incw	%ax
	movl	%eax, 4(%si)

	movzbw	%cl, %dx
	shlw	$2, %dx
	movb	%ch, %al
	movb	%dh, %ah

	/* save number of cylinders */
	incw	%ax
	movw	%ax, 8(%si)

	movzbw	%dl, %ax
	shrb	$2, %al

	/* save number of sectors */
	movl	%eax, (%si)

setup_sectors:
	/* load logical sector start (top half) */
	movl	kernel_sector + 4, %eax

	orl	%eax, %eax
	jnz	LOCAL(geometry_error)

	/* load logical sector start (bottom half) */
	movl	kernel_sector, %eax

	/* zero %edx */
	xorl	%edx, %edx

	/* divide by number of sectors */
	divl	(%si)

	/* save sector start */
	movb	%dl, %cl

	xorw	%dx, %dx	/* zero %edx */
	divl	4(%si)		/* divide by number of heads */

	/* do we need too many cylinders? */
	cmpw	8(%si), %ax
	jge	LOCAL(geometry_error)

	/* normalize sector start (1-based) */
	incb	%cl

	/* low bits of cylinder start */
	movb	%al, %ch

	/* high bits of cylinder start */
	xorb	%al, %al
	shrw	$2, %ax
	orb	%al, %cl

	/* save head start */
	movb	%dl, %al

	/* restore %dl */
	popw	%dx

	/* head start */
	movb	%al, %dh

/*
 * BIOS call "INT 0x13 Function 0x2" to read sectors from disk into memory
 *	Call with	%ah = 0x2
 *			%al = number of sectors
 *			%ch = cylinder
 *			%cl = sector (bits 6-7 are high bits of "cylinder")
 *			%dh = head
 *			%dl = drive (0x80 for hard disk, 0x0 for floppy disk)
 *			%es:%bx = segment:offset of buffer
 *	Return:
 *			%al = 0x0 on success; err code on failure
 */

	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx
	movw	%bx, %es	/* load %es segment with disk buffer */

	xorw	%bx, %bx	/* %bx = 0, put it at 0 in the segment */
	movw	$0x0201, %ax	/* function 2 */
	int	$0x13

	jc	LOCAL(read_error)

	movw	%es, %bx
#endif /* ! ENABLE_TGRUB2 */
/* End TCG Extension */
LOCAL(copy_buffer):

	/*
	 * We need to save %cx and %si because the startup code in
	 * kernel uses them without initializing them.
	 */
	pusha
	pushw	%ds

	movw	$0x100, %cx
	movw	%bx, %ds
	xorw	%si, %si
	movw	$GRUB_BOOT_MACHINE_KERNEL_ADDR, %di
	movw	%si, %es

	cld

	rep
	movsw

	popw	%ds
	popa


/* BEGIN TCG Extension */
#ifdef ENABLE_TGRUB2
	pusha

	/* hash and measure 512 bytes at the beginning of kernel_address (diskboot.img) */

	/* Check for TPM availability */
/*
 * BIOS call "INT 1Ah, (AH)=BBh,(AL)=00h" TCG_StatusCheck
 *	Call with	%ah = 0xBB
 *				%al = 0x00
 *
 *	Return:	%eax = TCG_STATUS == 0 if the system supports the TCG BIOS calls.
 *			%ebx = 'TCPA'
 *
 * Ref:
 *  TCG PC Client Specific Implementation Specification for Conventional BIOS v1.21,
 *  Section 13.7 (page 115)
 */
tcg_statuscheck:
	movw    $0xBB00, %ax		/* TCG_StatusCheck */
	int     $0x1A
  test	%eax, %eax
	jz	tcg_compacthashlogextendevent			/* if eax == 0 */
	cmpb 	$0x24, %al   /* TCG_PC_TPM_DEACTIVATED */
  jne  error_no_tpm

error_tpm_deactivated:
  MSG(deactivatedTPM_error_string)
  jmp	LOCAL(general_error)
error_no_tpm:
	MSG(noTPM_error_string)
	jmp	LOCAL(general_error)

/*
 * BIOS call "INT 1Ah, (AH)=BBh, (AL)=07h" TCG_CompactHashLogExtendEvent
 *
 * Performs hashing of the event or the event data, extends the event to a PCR, and then
 * places the resulting TCG_PCClientPCREventStruc into the event log
 *
 * Call with	%ah = 0xBB
 *				%al = 0x07
 *				%es:%di = segment:offset of the pointer to the start of the data buffer to be hashed
 *				%esi = The informative value to be placed into the event field
 *				%ebx = 'TCPA'
 *				%ecx = The length, in bytes, of the buffer referenced by ES:DI
 *				%edx = The PCR number (PCRIndex) to which the hashed result is to be extended
 *
 * Return:		%eax = TCG_STATUS
 *				%edx = Event number of the event that was logged
 *
 * Ref:
 *  TCG PC Client Specific Implementation Specification for Conventional BIOS v1.21,
 *  Section 13.14 (page 126)
 */
tcg_compacthashlogextendevent:

	movw    $0xBB07, %ax			/* TCG_CompactHashLogExtendEvent */

	movw	$0x0, %bx
	movw	%bx, %es

	movl	$GRUB_BOOT_MACHINE_KERNEL_ADDR, %edi

	xorl	%esi, %esi

	movl    $0x41504354, %ebx	/* EBX = "TCPA" */
	movl 	$0x200, %ecx		/* Length = 512 Byte */
	movl	$0x8, %edx			/* PCR 8 */

	int     $0x1A
	test	%eax, %eax
	jz		tcg_end				/* if eax != 0 */
	MSG(tcg_error_string)
	jmp	LOCAL(general_error)

tcg_end:
	popa

#endif /* ENABLE_TGRUB2 */
/* END TCG Extension */

	/* boot kernel */
	jmp	*(kernel_address)

/* END OF MAIN LOOP */

/*
 * BIOS Geometry translation error (past the end of the disk geometry!).
 */
LOCAL(geometry_error):
	ERR(geometry_error_string)

/*
 * Read error on the disk.
 */
LOCAL(read_error):
	movw	$read_error_string, %si
LOCAL(error_message):
	call	LOCAL(message)
LOCAL(general_error):
	MSG(general_error_string)

/* go here when you need to stop the machine hard after an error condition */
        /* tell the BIOS a boot failure, which may result in no effect */
        /* int	$0x18 */
LOCAL(stop):
	jmp	LOCAL(stop)

notification_string:	.asciz "TrustedGRUB2 "
geometry_error_string:	.asciz "Geom"
hd_probe_error_string:	.asciz "Hard Disk"
read_error_string:	.asciz "Read"
general_error_string:	.asciz " Error\r\n"

/* BEGIN TCG_Extension */
#ifdef ENABLE_TGRUB2
chs_no_support_string:	.string "CHSNA"
tcg_error_string:	.string "TPM "
noTPM_error_string:	.string "No TPM found"
deactivatedTPM_error_string: .string "TPM deactivated"
#endif /* ENABLE_TGRUB2 */
/* END TCG Extension */

/*
 * message: write the string pointed to by %si
 *
 *   WARNING: trashes %si, %ax, and %bx
 */

	/*
	 * Use BIOS "int 10H Function 0Eh" to write character in teletype mode
	 *	%ah = 0xe	%al = character
	 *	%bh = page	%bl = foreground color (graphics modes)
	 */
1:
	movw	$0x0001, %bx
	movb	$0xe, %ah
	int	$0x10		/* display a byte */
LOCAL(message):
	lodsb
	cmpb	$0, %al
	jne	1b	/* if not end of string, jmp to display */
	ret

	/*
	 *  Windows NT breaks compatibility by embedding a magic
	 *  number here.
	 */

	. = _start + GRUB_BOOT_MACHINE_WINDOWS_NT_MAGIC
nt_magic:
	.long 0
	.word 0

	/*
	 *  This is where an MBR would go if on a hard disk.  The code
	 *  here isn't even referenced unless we're on a floppy.  Kinda
	 *  sneaky, huh?
	 */

	. = _start + GRUB_BOOT_MACHINE_PART_START
part_start:

/* BEGIN TCG_Extension */
#ifndef ENABLE_TGRUB2
probe_values:
	.byte	36, 18, 15, 9, 0

LOCAL(floppy_probe):
/*
 *  Perform floppy probe.
 */

	movw	$probe_values - 1, %si

LOCAL(probe_loop):
	/* reset floppy controller INT 13h AH=0 */
	xorw	%ax, %ax
	int	$0x13

	incw	%si
	movb	(%si), %cl

	/* if number of sectors is 0, display error and die */
	cmpb	$0, %cl
	jne	1f

/*
 * Floppy disk probe failure.
 */
	MSG(fd_probe_error_string)
	jmp	LOCAL(general_error)

/* "Floppy" */
fd_probe_error_string:	.asciz "Floppy"

1:
	/* perform read */
	movw	$GRUB_BOOT_MACHINE_BUFFER_SEG, %bx
	movw	%bx, %es
	xorw	%bx, %bx
	movw	$0x201, %ax
	movb	$0, %ch
	movb	$0, %dh
	int	$0x13

	/* if error, jump to "LOCAL(probe_loop)" */
	jc	LOCAL(probe_loop)

	/* %cl is already the correct value! */
	movb	$1, %dh
	movb	$79, %ch

	jmp	LOCAL(final_init)
#endif /* ! ENABLE_TGRUB2 */
/* END TCG Extension */

	. = _start + GRUB_BOOT_MACHINE_PART_END

/* the last 2 bytes in the sector 0 contain the signature */
	.word	GRUB_BOOT_MACHINE_SIGNATURE
