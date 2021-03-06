#include "threads/loader.h"

#### Kernel loader.

#### This code should be stored in the first sector of a hard disk.
#### When the BIOS runs, it loads this code at physical address
#### 0x7c00-0x7e00 (512 bytes) and jumps to the beginning of it,
#### in real mode.  The loader loads the kernel into memory and jumps
#### to its entry point, which is the start function in start.S.
####
#### The BIOS passes in the drive that the loader was read from as
#### DL, with floppy drives numbered 0x00, 0x01, ... and hard drives
#### numbered 0x80, 0x81, ...  We want to support booting a kernel on
#### a different drive from the loader, so we don't take advantage of
#### this.

#### Runs in real mode, which is a 16-bit segment.
	.code16

#### Set up segment registers.
#### Set stack to grow downward from 60 kB (after boot, the kernel
#### continues to use this stack for its initial thread).
	sub %ax, %ax
	mov %ax, %ds
	mov %ax, %ss
	mov $0xf000, %esp

#### Configure serial port so we can report progress without connected VGA.
#### See [IntrList] for details.
####	
#### Interrupt 0x14 when AH is 0 is used for serial port initilization
#### input: AL (port parameters) , DX for port number
#### 	Bitfields for port parameters:
#### 	Bit(s)  Description     (Table 00300)
####	7-5    data rate (110,150,300,600,1200,2400,4800,9600 bps)
####	4-3    parity (00 or 10 = none, 01 = odd, 11 = even)
####	2      stop bits (set = 2, clear = 1)
####	1-0    data bits (00 = 5, 01 = 6, 10 = 7, 11 = 8)
#### 0xe3 = 0b11100011
#### output: AH line status (0xff for failure) and AL modem status
	sub %dx, %dx			# Serial port 0.
	mov $0xe3, %al			# 9600 bps, N-8-1.
	int $0x14			# Destroys AX.

	call puts			# subroutine written below 
	.string "PiLo"			# simply inserts this below call instr

	
#### Read the partition table on each system hard disk and scan for a
#### partition of type 0x20, which is the type that we use for a
#### Pintos kernel.
####
#### Read [Partitions] for a description of the partition table format
#### that we parse.
####
#### We print out status messages to show the disk and partition being
#### scanned, e.g. hda1234 as we scan four partitions on the first
#### hard disk.
	mov $0x80, %dl			# Hard disk 0.
read_mbr:
	sub %ebx, %ebx			# Sector 0.
	mov $0x2000, %ax		# Use 0x20000 for buffer.
	mov %ax, %es
	call read_sector
	jc no_such_drive

	# Print hd[a-z].
	call puts
	.string " hd"
	mov %dl, %al
	add $'a' - 0x80, %al
	call putc

	# Check for MBR signature--if not present, it's not a
	# partitioned hard disk.
	cmpw $0xaa55, %es:510
	jne next_drive

	mov $446, %si			# Offset of partition table entry 1.
	mov $'1', %al			# Just to print 1 for first entry
check_partition:
	# Is it an unused partition?
	cmpl $0, %es:(%si)
	je next_partition

	# Print [1-4].
	call putc

	# Is it a Pintos kernel partition?
	# 0x20 is an unused partition type
	cmpb $0x20, %es:4(%si)
	jne next_partition

	# Is it a bootable partition? (0x00 do not boot, 0x80 bootable)
	cmpb $0x80, %es:(%si)
	je load_kernel

next_partition:
	# No match for this partition, go on to the next one.
	add $16, %si			# Offset to next partition table entry.
	inc %al
	cmp $510, %si
	jb check_partition

next_drive:
	# No match on this drive, go on to the next one.
	inc %dl
	jnc read_mbr

no_such_drive:
no_boot_partition:
	# Didn't find a Pintos kernel partition anywhere, give up.
	call puts
	.string "\rNot found\r"

	# Notify BIOS that boot failed.  See [IntrList].
	int $0x18

#### We found a kernel.  The kernel's drive is in DL.  The partition
#### table entry for the kernel's partition is at ES:SI.  Our job now
#### is to read the kernel from disk and jump to its start address.

load_kernel:
	call puts
	.string "\rLoading"

	# Figure out number of sectors to read.  A Pintos kernel is
	# just an ELF format object, which doesn't have an
	# easy-to-read field to identify its own size (see [ELF1]).
	# But we limit Pintos kernels to 512 kB for other reasons, so
	# it's easy enough to just read the entire contents of the
	# partition or 512 kB from disk, whichever is smaller.
	# EBP = number of sectors
	mov %es:12(%si), %ecx		# es:12(si) = size of partition 
	cmp $1024, %ecx			# Cap size at 512 kB (1024 sector)
	jbe 1f				# jump if less or equal 
	mov $1024, %cx
1:
	mov %es:8(%si), %ebx		# es:8(si) =  first sector number
	mov $0x2000, %ax		# Start load address: 0x20000

next_sector:
	# Read one sector into memory.
	mov %ax, %es			# ES:0000 -> load address
	call read_sector
	jc read_failed

	# Print '.' as progress indicator once every 16 sectors == 8 kB.
	test $15, %bl
	jnz 1f
	call puts
	.string "."
1:

	# Advance memory pointer and disk sector.
	# To explain why we're adding 0x20:
	# 0x20 = dec(32), remember that we're saving the data in a buffer
	# at AX:0000 (which will be ES:0000) once we go next_sector and then
	# call read_sector
	# The physical address of AX:0000 = AX * 16 + 0000
	# So changing AX by dec(32) changes the physical address by 512
	# which is exactly the sector size
	add $0x20, %ax
	# EBX is used in read_sector as the first 32 bits of the sector to read
	# we sat it at first to the number of the first sector of the parition
	# and now we increment to the next sector
	inc %bx
	# cbx = partition size (sectors) or 1024 if the parititon size is
	# more than 1024 sectors (above)
	loop next_sector
	
	call puts
	.string "\r"

#### Transfer control to the kernel that we loaded.  We read the start
#### address out of the ELF header (see [ELF1]) and convert it from a
#### 32-bit linear address into a 16:16 segment:offset address for
#### real mode, then jump to the converted address.  The 80x86 doesn't
#### have an instruction to jump to an absolute segment:offset kept in
#### registers, so in fact we store the address in a temporary memory
#### location, then jump indirectly through that location.  To save 4
#### bytes in the loader, we reuse 4 bytes of the loader's code for
#### this temporary pointer.

	mov $0x2000, %ax
	mov %ax, %es
	# 0x2000 = 8192 (and remember: phys = seg * 16 + off)
	# 0x18 = 24
	# es:0x18 = 8192 * 16 + 24 = 131096 = 0x20024
	# Kernel is at 0x20000 + 0x24 (because ELF stores the address
	# for the entry point at the 32th byte)
	mov %es:0x18, %dx
	# start and dx only contain the first 16 bits of the address (offset)
	mov %dx, start
	# the last two bytes of start now contain the segment address
	movw $0x2000, start + 2
	# make a long jump to the address contained in start
	ljmp *start

read_failed:
start:
	# Disk sector read failed.
	call puts
1:	.string "\rBad read\r"

	# Notify BIOS that boot failed.  See [IntrList].
	int $0x18

#### Print string subroutine.  To save space in the loader, this
#### subroutine takes its null-terminated string argument from the
#### code stream just after the call, and then returns to the byte
#### just after the terminating null.  This subroutine preserves all
#### general-purpose registers.
# ss:esp has the address of the instruction right next to 'call puts'
# because call X pushes the address of the next thing in the obj file
# in the stack
# which is the address of the string (using .string directive)
puts:	xchg %si, %ss:(%esp) 
	push %ax
next_char:
	# we're addressing the string literal
	# stored using the .string
	mov %cs:(%si), %al
	inc %si
	test %al, %al
	jz 1f
	call putc
	jmp next_char
1:	pop %ax
	# whatever was in si before this call should get back to it
	xchg %si, %ss:(%esp)
	ret

#### Character output subroutine.  Prints the character in AL to the
#### VGA display and serial port 0, using BIOS services (see
#### [IntrList]).  Preserves all general-purpose registers.
####
#### If called upon to output a carriage return, this subroutine
#### automatically supplies the following line feed.

putc:	pusha

1:	sub %bh, %bh			# Page 0.
	mov $0x0e, %ah			# Teletype output service.
	int $0x10

	mov $0x01, %ah			# Serial port output service.
	sub %dx, %dx			# Serial port 0.
2:	int $0x14			# Destroys AH.
	test $0x80, %ah			# Output timed out?
	jz 3f
	movw $0x9090, 2b		# Turn "int $0x14" above into NOPs.

3:
	cmp $'\r', %al
	jne popa_ret
	mov $'\n', %al
	jmp 1b

	
#### Sector read subroutine.  Takes a drive number in DL (0x80 = hard
#### disk 0, 0x81 = hard disk 1, ...) and a sector number in EBX, and
#### reads the specified sector into memory at ES:0000.  Returns with
#### carry set on error, clear otherwise.  Preserves all
#### general-purpose registers.
####
#### Uses BIOS interrupt 0x13 used for sector-based IO with the hard-drives and
#### 	floppy drives.
#### input: DL: contains disk ID (0x00 for floppy 1 0x01 for floppy 2 etc
####		and 0x80 for hdd1 and 0x81 for hdd2 etc)
####	    AH: Function (0x42 read sectors from drive, 0x43 write)
####	    Disk Address Packet 16 bytes (Pointed to by DS:SI):
####		[0] 	Size of the packet (usually 16)
####		[1]	Always 0
####		[2-3]	Number of sectors to transfer
####		[4-7]	Transfer buffer (16 bit segment : 16 bit offset)
####		[8-15]	absolute number of the start sector to read from
#### output: AH return code	, CF set on error
read_sector:
	pusha
	sub %ax, %ax
	push %ax			# LBA sector number [48:63]
	push %ax			# LBA sector number [32:47]
	push %ebx			# LBA sector number [0:31]
	push %es			# Buffer segment (filled before call)
	push %ax			# Buffer offset (always 0)
	push $1				# Number of sectors to read
	push $16			# Packet size (sets first two bytes)
	mov $0x42, %ah			# Extended read
	mov %sp, %si			# DS:SI -> packet (SI points to packet)
	int $0x13			# Error code in CF
	popa				# Pop 16 bytes (the packet)
popa_ret:
	popa				# Registers before the call
	ret				# Error code still in CF

	
#### Command-line arguments and their count.
#### This is written by the `pintos' utility and read by the kernel.
#### The loader itself does not do anything with the command line.
	.org LOADER_ARG_CNT - LOADER_BASE
	.fill LOADER_ARG_CNT_LEN, 1, 0

	.org LOADER_ARGS - LOADER_BASE
	.fill LOADER_ARGS_LEN, 1, 0

#### Partition table.
	.org LOADER_PARTS - LOADER_BASE
	.fill LOADER_PARTS_LEN, 1, 0

#### Boot-sector signature for BIOS inspection.
	.org LOADER_SIG - LOADER_BASE
	.word 0xaa55
