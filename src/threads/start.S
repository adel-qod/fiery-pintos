	#include "threads/loader.h"

#### Kernel startup code.

#### The loader (in loader.S) loads the kernel at physical address
#### 0x20000 (128 kB) and jumps to "start", defined here.  This code
#### switches from real mode to 32-bit protected mode and calls
#### main().

/* Flags in control register 0. */
#define CR0_PE 0x00000001      /* Protection Enable. */
#define CR0_EM 0x00000004      /* (Floating-point) Emulation. */
#define CR0_PG 0x80000000      /* Paging. */
#define CR0_WP 0x00010000      /* Write-Protect enable in kernel mode. */

	.section .start

# The following code runs in real mode, which is a 16-bit code segment.
	.code16

.func start
.globl start
start:

# The loader called into us with CS = 0x2000, SS = 0x0000, ESP = 0xf000,
# but we should initialize the other segment registers.

	mov $0x2000, %ax
	mov %ax, %ds
	mov %ax, %es

# Set string instructions to go upward.
	cld

#### Get memory size, via interrupt 15h function 88h (see [IntrList]),
#### which returns AX = (kB of physical memory) - 1024.  This only
#### works for memory sizes <= 65 MB, which should be fine for our
#### purposes.  We cap memory at 64 MB because that's all we prepare
#### page tables for, below.

	movb $0x88, %ah
	int $0x15
	addl $1024, %eax	# Total kB memory
	cmp $0x10000, %eax	# Cap at 64 MB
	jbe 1f
	mov $0x10000, %eax
1:	shrl $2, %eax		# (shift right by two = divide by 4)
				# now eax contains the number of 4K pages
	# init_ram_pages is available at an address in 32-bit flat memory
	# (because that's what the linker links against) so we cannot use its
	# address directly. We subtract from it the 0xc0000000 which is where
	# the linker thinks our kernel is loaded in virtual memory
	# We then subtract 0x20000 to convert this physical address to a DS
	# relative address (since DS is at 0x2000)
	# (the .code16 doesn't change addressing, it just changes code
	# generation in the assembler to 16-bit)
	# The addresses in this section are still in 16-bit so we use the
	# addr32 prefix to notify the assembler that the instruction here
	# operates on memory with 32-bit addresses
	addr32 movl %eax, init_ram_pages - LOADER_PHYS_BASE - 0x20000

#### Enable A20.  Address line 20 is tied low when the machine boots,
#### which prevents addressing memory about 1 MB.  This code fixes it.

#### we're gonna use the keyboard controller to enable A20 as it's
#### the most portable way to do this

#### Keyboard controller port mapping:
#### Port	Read/Write	Descripton
#### 0x60	Read		Read Input Buffer
#### 0x60	Write		Write Output Buffer
#### 0x64	Read		Read Status Register
#### 0x64	Write		Send Command to controller

#### Status returned in one byte means:
#### Bit 0 (output buffer status)
#### Bit 1 (output buffer status) if 1 full, if 0 empty
#### (other bits are not as important to us now)
# Poll status register while busy.
# Check that input buffer is not full
1:	inb $0x64, %al
	testb $0x2, %al
	jnz 1b

#### Important byte commands to controller:
#### 0xAD	Disable Keyboard
#### 0xAE	Enable Keyboard
#### 0xC0	Read Input Port
#### 0xD0	Read Output Port
#### 0xD1	Write Output Port
# Tell controller we wanna use Output Port
	movb $0xd1, %al
	outb %al, $0x64

# Poll status register while busy.
# Check that input buffer is not full
1:	inb $0x64, %al
	testb $0x2, %al
	jnz 1b

# Enable A20 line.
# Bit 0 is for CPU reset (clear to reset), Bit 1 is used to control A20 line
	movb $0xdf, %al
	outb %al, $0x60

# Poll status register while busy.
# (needed because keyboard controller is really slow) so gotta make
# sure it's done before moving on
1:	inb $0x64, %al
	testb $0x2, %al
	jnz 1b

#### Create temporary page directory and page table and set page
#### directory base register.

# Create page directory at 0xf000 (60 kB) and fill with zeroes.
	mov $0xf00, %ax
	mov %ax, %es
	subl %eax, %eax
	subl %edi, %edi
	movl $0x400, %ecx # 1024 page directory entry, each table maps 4 MBs
	# so a complete directory maps up to 4 GBs
	#
	# repeat stos cx times, stos stores whatever is in ax
	# to where di points to using the es as an offset
	# incrementing (or decrmenting depending direction flag) di by 4
	# (stos is one the instructions that uses di/si offsets with es segment
	#  instead ds)
	rep stosl

# Add PDEs to point to page tables for the first 64 MB of RAM.
# Also add identical PDEs starting at LOADER_PHYS_BASE.
# See [IA32-v3a] section 3.7.6 "Page-Directory and Page-Table Entries"
# for a description of the bits in %eax. (or the arch.txt file in my-info)
	## check tmp
	## (0x10007) = address of 0x10000, user accessible, writable
	movl $0x10007, %eax
	movl $0x11, %ecx # adding 11 page tables * 4 MB each = 44 MB (twice -
	# we're adding same entries at two different places)
	subl %edi, %edi
1:	movl %eax, %es:(%di) # es still holds base for page directory
	# LOADER_PHYS_BASE >> 20 yields 0xc00 which is 3072
	# So we're also putting the _same_ PDEs at the begining of our directory
	# and at the last fourth (3072 / 4 = 768, / 4 because each 4 bytes make
	# a single entry) so entries 768 to 1024 of the directory also map to
	# the same area that %eax maps to which makes sense considering that
	# we'll eventually stop using the first mapping at the begining of
	# this directory and keep using the one in the last fourth of it
	# for kernel addressing (see boot.txt for why we're doing this)
	# remember, linear address is pde address : page table address : offset
	# so by setting the highest fourth of PDEs like this we're mapping the
	# addresses beyond 0xc0000000 (last GB of memory) to the first 64 MBs in
	# physical RAM
	#
	# (Copied from the online helper documentation)
	# The Pintos kernel only wants the latter mapping, but there's a
	# chicken-and-egg problem if we don't include the former: our current
	# virtual address is roughly 0x20000, the location where the loader put
	# us, and we can't jump to 0xc0020000 until we turn on the page table,
	# but if we turn on the page table without jumping there, then we've
	# just pulled the rug out from under ourselves.
	movl %eax, %es:LOADER_PHYS_BASE >> 20(%di)
	addw $4, %di
	# each table holds 1024 entries and each entry is 4 bytes so 
	# each table is 4k length so change address in entry accordingly
	addl $0x1000, %eax 
	loop 1b

# Set up page tables for one-to-one linear to physical map for the
# first 64 MB of RAM.
# See [IA32-v3a] section 3.7.6 "Page-Directory and Page-Table Entries"
# for a description of the bits in %eax. (or the arch.txt file in my-info)
# These PTEs are pointed to by two PDEs (one at the begining of the Page
#  Directory and one at the last 4th of it - see boot.txt for why we're doing this)
	movw $0x1000, %ax
	movw %ax, %es # es:00 points to the first page table now
	movl $0x7, %eax		# present, writeable, user accessiable
	movl $0x4000, %ecx # 16384 * 4096 = so mapping the whole first 64 MBs
	subl %edi, %edi
1:	movl %eax, %es:(%di)
	addw $4, %di
	addl $0x1000, %eax # every page maps 4 KBs so add 4096 to addr
	loop 1b

# Set page directory base register.
	movl $0xf000, %eax
	movl %eax, %cr3

#### Switch to protected mode.

# First, disable interrupts.  We won't set up the IDT until we get
# into C code, so any interrupt would blow us away.

	cli

# Protected mode requires a GDT, so point the GDTR to our GDT.
# We need a data32 prefix to ensure that all 32 bits of the GDT
# descriptor are loaded (default is to load only 24 bits).
# The CPU doesn't need an addr32 prefix but ELF doesn't do 16-bit
# relocations.
# Again to know why (- LOADER_PHYS_BASE - 0x20000) check line 49 of this file 
	data32 addr32 lgdt gdtdesc - LOADER_PHYS_BASE - 0x20000

# Then we turn on the following bits in CR0:
#    PE (Protect Enable): this turns on protected mode.
#    PG (Paging): turns on paging.
#    WP (Write Protect): if unset, ring 0 code ignores
#       write-protect bits in page tables (!).
#    EM (Emulation): forces floating-point instructions to trap.
#       We don't support floating point.
	movl %cr0, %eax
	orl $CR0_PE | CR0_PG | CR0_WP | CR0_EM, %eax
	movl %eax, %cr0

# We're now in protected mode in a 16-bit segment.  The CPU still has
# the real-mode code segment cached in %cs's segment descriptor.  We
# need to reload %cs, and the easiest way is to use a far jump.
# Because we're not running in a 32-bit segment the data32 prefix is
# needed to jump to a 32-bit offset in the target segment.
# ljmp takes a base register _contents_ to use as a base and an address
# and sets the %cs to the said _contents_ (segment selector)
	data32 ljmp $SEL_KCSEG, $1f

# We're now in protected mode in a 32-bit segment.
# Let the assembler know.

	.code32

# Reload all the other segment registers and the stack pointer to
# point into our new GDT.
# SEL_KDSEG is the data segement selector 
1:	mov $SEL_KDSEG, %ax
	mov %ax, %ds
	mov %ax, %es
	mov %ax, %fs
	mov %ax, %gs
	mov %ax, %ss
	addl $LOADER_PHYS_BASE, %esp
	movl $0, %ebp			# Null-terminate main()'s backtrace

#### Call main().

	call main

# main() shouldn't ever return.  If it does, spin.

1:	jmp 1b
.endfunc

#### GDT
#### Find below the description for the segments 
	.align 8
gdt:
	.quad 0x0000000000000000	# Null segment.  Not used by CPU.
	.quad 0x00cf9a000000ffff	# System code, base 0, limit 4 GB.
	.quad 0x00cf92000000ffff        # System data, base 0, limit 4 GB.

gdtdesc:
	.word	gdtdesc - gdt - 1	# Size of the GDT, minus 1 byte.
	.long	gdt			# Address of the GDT.


#### Segments description (for flags meaning, refer to pintos/my-info/arch.txt)
## -------------- System Code -------------------------
## 00000000 (base 24:31)
##
## 1  1   0  0 (flags)
## G  S   0  0
##
## 1111 (limit 16:19)
##
## 1    00    1  1    0  1			0
## pr  prvl   1  ex   C  readable		0
##
## 00000000 (base 16:23)
## 0000000000000000 (base 0:15) 
## 1111111111111111 (limit 0:15)

## -------------- System Data -------------------------
## 00000000 (base 24:31)
##
## 1  1  0  0 (flags)
## G  S  0  0
##
## 1111 (limit 16:19)
##
## 1    00    1  0   0  1                0 (Access byte)
## pr   prvl  1  Ex  D  writable         0
#
## 00000000 (base 16:23)
## 0000000000000000 (base 0:15)
## 1111111111111111 (limit 0:15)
	
#### Physical memory size in 4 kB pages.  This is exported to the rest
#### of the kernel.d
.globl init_ram_pages
init_ram_pages:
	.long 0
