/*
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU General Public License, version 2, as
 * published by the Free Software Foundation.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program; if not, write to the Free Software
 * Foundation, 51 Franklin Street, Fifth Floor, Boston, MA  02110-1301, USA.
 *
 * Copyright (C) 2010-2012 Freescale Semiconductor, Inc.
 *
 * Author: Varun Sethi <varun.sethi@freescale.com>
 * Author: Scott Wood <scotwood@freescale.com>
 * Author: Mihai Caraman <mihai.caraman@freescale.com>
 *
 * This file is derived from arch/powerpc/kvm/booke_interrupts.S
 */

#include <asm/ppc_asm.h>
#include <asm/kvm_asm.h>
#include <asm/reg.h>
#include <asm/mmu-44x.h>
#include <asm/page.h>
#include <asm/asm-compat.h>
#include <asm/asm-offsets.h>
#include <asm/bitsperlong.h>
#include <asm/thread_info.h>

#ifdef CONFIG_64BIT
#include <asm/exception-64e.h>
#else
#include "../kernel/head_booke.h" /* for THREAD_NORMSAVE() */
#endif

#define LONGBYTES		(BITS_PER_LONG / 8)

#define VCPU_GPR(n)     	(VCPU_GPRS + (n * LONGBYTES))
#define VCPU_GUEST_SPRG(n)	(VCPU_GUEST_SPRGS + (n * LONGBYTES))

/* The host stack layout: */
#define HOST_R1         0 /* Implied by stwu. */
#define HOST_CALLEE_LR  PPC_LR_STKOFF
#define HOST_RUN        (HOST_CALLEE_LR + LONGBYTES)
/*
 * r2 is special: it holds 'current', and it made nonvolatile in the
 * kernel with the -ffixed-r2 gcc option.
 */
#define HOST_R2         (HOST_RUN + LONGBYTES)
#define HOST_CR         (HOST_R2 + LONGBYTES)
#define HOST_NV_GPRS    (HOST_CR + LONGBYTES)
#define HOST_NV_GPR(n)  (HOST_NV_GPRS + ((n - 14) * LONGBYTES))
#define HOST_MIN_STACK_SIZE (HOST_NV_GPR(31) + LONGBYTES)
#define HOST_STACK_SIZE ((HOST_MIN_STACK_SIZE + 15) & ~15) /* Align. */
/* LR in caller stack frame. */
#define HOST_STACK_LR	(HOST_STACK_SIZE + PPC_LR_STKOFF)

#define NEED_EMU		0x00000001 /* emulation -- save nv regs */
#define NEED_DEAR		0x00000002 /* save faulting DEAR */
#define NEED_ESR		0x00000004 /* save faulting ESR */

/*
 * On entry:
 * r4 = vcpu, r5 = srr0, r6 = srr1
 * saved in vcpu: cr, ctr, r3-r13
 */
.macro kvm_handler_common intno, srr0, flags
	/* Restore host stack pointer */
	PPC_STL	r1, VCPU_GPR(r1)(r4)
	PPC_STL	r2, VCPU_GPR(r2)(r4)
	PPC_LL	r1, VCPU_HOST_STACK(r4)
	PPC_LL	r2, HOST_R2(r1)

	mfspr	r10, SPRN_PID
	lwz	r8, VCPU_HOST_PID(r4)
	PPC_LL	r11, VCPU_SHARED(r4)
	PPC_STL	r14, VCPU_GPR(r14)(r4) /* We need a non-volatile GPR. */
	li	r14, \intno

	stw	r10, VCPU_GUEST_PID(r4)
	mtspr	SPRN_PID, r8

#ifdef CONFIG_KVM_EXIT_TIMING
	/* save exit time */
1:	mfspr	r7, SPRN_TBRU
	mfspr	r8, SPRN_TBRL
	mfspr	r9, SPRN_TBRU
	cmpw	r9, r7
	stw	r8, VCPU_TIMING_EXIT_TBL(r4)
	bne-	1b
	stw	r9, VCPU_TIMING_EXIT_TBU(r4)
#endif

	oris	r8, r6, MSR_CE@h
	PPC_STD(r6, VCPU_SHARED_MSR, r11)
	ori	r8, r8, MSR_ME | MSR_RI
	PPC_STL	r5, VCPU_PC(r4)

	/*
	 * Make sure CE/ME/RI are set (if appropriate for exception type)
	 * whether or not the guest had it set.  Since mfmsr/mtmsr are
	 * somewhat expensive, skip in the common case where the guest
	 * had all these bits set (and thus they're still set if
	 * appropriate for the exception type).
	 */
	cmpw	r6, r8
	beq	1f
	mfmsr	r7
	.if	\srr0 != SPRN_MCSRR0 && \srr0 != SPRN_CSRR0
	oris	r7, r7, MSR_CE@h
	.endif
	.if	\srr0 != SPRN_MCSRR0
	ori	r7, r7, MSR_ME | MSR_RI
	.endif
	mtmsr	r7
1:

	.if	\flags & NEED_EMU
	/*
	 * This assumes you have external PID support.
	 * To support a bookehv CPU without external PID, you'll
	 * need to look up the TLB entry and create a temporary mapping.
	 *
	 * FIXME: we don't currently handle if the lwepx faults.  PR-mode
	 * booke doesn't handle it either.  Since Linux doesn't use
	 * broadcast tlbivax anymore, the only way this should happen is
	 * if the guest maps its memory execute-but-not-read, or if we
	 * somehow take a TLB miss in the middle of this entry code and
	 * evict the relevant entry.  On e500mc, all kernel lowmem is
	 * bolted into TLB1 large page mappings, and we don't use
	 * broadcast invalidates, so we should not take a TLB miss here.
	 *
	 * Later we'll need to deal with faults here.  Disallowing guest
	 * mappings that are execute-but-not-read could be an option on
	 * e500mc, but not on chips with an LRAT if it is used.
	 */

	mfspr	r3, SPRN_EPLC	/* will already have correct ELPID and EGS */
	PPC_STL	r15, VCPU_GPR(r15)(r4)
	PPC_STL	r16, VCPU_GPR(r16)(r4)
	PPC_STL	r17, VCPU_GPR(r17)(r4)
	PPC_STL	r18, VCPU_GPR(r18)(r4)
	PPC_STL	r19, VCPU_GPR(r19)(r4)
	mr	r8, r3
	PPC_STL	r20, VCPU_GPR(r20)(r4)
	rlwimi	r8, r6, EPC_EAS_SHIFT - MSR_IR_LG, EPC_EAS
	PPC_STL	r21, VCPU_GPR(r21)(r4)
	rlwimi	r8, r6, EPC_EPR_SHIFT - MSR_PR_LG, EPC_EPR
	PPC_STL	r22, VCPU_GPR(r22)(r4)
	rlwimi	r8, r10, EPC_EPID_SHIFT, EPC_EPID
	PPC_STL	r23, VCPU_GPR(r23)(r4)
	PPC_STL	r24, VCPU_GPR(r24)(r4)
	PPC_STL	r25, VCPU_GPR(r25)(r4)
	PPC_STL	r26, VCPU_GPR(r26)(r4)
	PPC_STL	r27, VCPU_GPR(r27)(r4)
	PPC_STL	r28, VCPU_GPR(r28)(r4)
	PPC_STL	r29, VCPU_GPR(r29)(r4)
	PPC_STL	r30, VCPU_GPR(r30)(r4)
	PPC_STL	r31, VCPU_GPR(r31)(r4)
	mtspr	SPRN_EPLC, r8

	/* disable preemption, so we are sure we hit the fixup handler */
#ifdef CONFIG_PPC64
	clrrdi	r8,r1,THREAD_SHIFT
#else
	rlwinm	r8,r1,0,0,31-THREAD_SHIFT       /* current thread_info */
#endif
	li	r7, 1
	stw	r7, TI_PREEMPT(r8)

	isync

	/*
	 * In case the read goes wrong, we catch it and write an invalid value
	 * in LAST_INST instead.
	 */
1:	lwepx	r9, 0, r5
2:
.section .fixup, "ax"
3:	li	r9, KVM_INST_FETCH_FAILED
	b	2b
.previous
.section __ex_table,"a"
	PPC_LONG_ALIGN
	PPC_LONG 1b,3b
.previous

	mtspr	SPRN_EPLC, r3
	li	r7, 0
	stw	r7, TI_PREEMPT(r8)
	stw	r9, VCPU_LAST_INST(r4)
	.endif

	.if	\flags & NEED_ESR
	mfspr	r8, SPRN_ESR
	PPC_STL	r8, VCPU_FAULT_ESR(r4)
	.endif

	.if	\flags & NEED_DEAR
	mfspr	r9, SPRN_DEAR
	PPC_STL	r9, VCPU_FAULT_DEAR(r4)
	.endif

	b	kvmppc_resume_host
.endm

#ifdef CONFIG_64BIT
/*
 * For input register values, see arch/powerpc/include/asm/kvm_booke_hv_asm.h
 */
.macro kvm_handler intno scratch, paca_ex, ex_r10, ex_r11, srr0, srr1, flags
 _GLOBAL(kvmppc_handler_\intno\()_\srr1)
	mr	r11, r4
	/*
	 * Get vcpu from Paca: paca->__current.thread->kvm_vcpu
	 */
	PPC_LL	r4, PACACURRENT(r13)
	PPC_LL	r4, (THREAD + THREAD_KVM_VCPU)(r4)
	stw	r10, VCPU_CR(r4)
	PPC_STL r11, VCPU_GPR(r4)(r4)
	PPC_STL	r5, VCPU_GPR(r5)(r4)
	mfspr	r5, \scratch
	PPC_STL	r6, VCPU_GPR(r6)(r4)
	PPC_STL	r8, VCPU_GPR(r8)(r4)
	PPC_STL	r9, VCPU_GPR(r9)(r4)
	PPC_STL r5, VCPU_GPR(r13)(r4)
	PPC_LL	r6, (\paca_ex + \ex_r10)(r13)
	PPC_LL	r8, (\paca_ex + \ex_r11)(r13)
	PPC_STL r3, VCPU_GPR(r3)(r4)
	PPC_STL r7, VCPU_GPR(r7)(r4)
	PPC_STL r12, VCPU_GPR(r12)(r4)
	PPC_STL r6, VCPU_GPR(r10)(r4)
	PPC_STL r8, VCPU_GPR(r11)(r4)
	mfctr	r5
	PPC_STL	r5, VCPU_CTR(r4)
	mfspr	r5, \srr0
	mfspr	r6, \srr1
	kvm_handler_common \intno, \srr0, \flags
.endm

#define EX_PARAMS(type) 	    \
	SPRN_SPRG_##type##_SCRATCH, \
	PACA_EX##type, 		    \
	EX_R10, 		    \
	EX_R11

kvm_handler BOOKE_INTERRUPT_CRITICAL, EX_PARAMS(CRIT), \
	SPRN_CSRR0, SPRN_CSRR1, 0
kvm_handler BOOKE_INTERRUPT_MACHINE_CHECK, EX_PARAMS(MC), \
	SPRN_MCSRR0, SPRN_MCSRR1, 0
kvm_handler BOOKE_INTERRUPT_DATA_STORAGE, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1,(NEED_EMU | NEED_DEAR | NEED_ESR)
kvm_handler BOOKE_INTERRUPT_INST_STORAGE, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, NEED_ESR
kvm_handler BOOKE_INTERRUPT_EXTERNAL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_ALIGNMENT, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1,(NEED_DEAR | NEED_ESR)
kvm_handler BOOKE_INTERRUPT_PROGRAM, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1,NEED_ESR
kvm_handler BOOKE_INTERRUPT_FP_UNAVAIL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_AP_UNAVAIL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_DECREMENTER, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_FIT, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_WATCHDOG, EX_PARAMS(CRIT),\
	SPRN_CSRR0, SPRN_CSRR1, 0
/*
 * Only bolted TLB miss exception handlers are supported for now
 */
kvm_handler BOOKE_INTERRUPT_DTLB_MISS, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, (NEED_EMU | NEED_DEAR | NEED_ESR)
kvm_handler BOOKE_INTERRUPT_ITLB_MISS, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_UNAVAIL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_FP_DATA, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_FP_ROUND, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_PERFORMANCE_MONITOR, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_DOORBELL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_DOORBELL_CRITICAL, EX_PARAMS(CRIT), \
	SPRN_CSRR0, SPRN_CSRR1, 0
kvm_handler BOOKE_INTERRUPT_HV_PRIV, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, NEED_EMU
kvm_handler BOOKE_INTERRUPT_HV_SYSCALL, EX_PARAMS(GEN), \
	SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_GUEST_DBELL, EX_PARAMS(GEN), \
	SPRN_GSRR0, SPRN_GSRR1, 0
kvm_handler BOOKE_INTERRUPT_GUEST_DBELL_CRIT, EX_PARAMS(CRIT), \
	SPRN_CSRR0, SPRN_CSRR1, 0
kvm_handler BOOKE_INTERRUPT_DEBUG, EX_PARAMS(DBG), \
	SPRN_DSRR0, SPRN_DSRR1, 0
kvm_handler BOOKE_INTERRUPT_DEBUG, EX_PARAMS(CRIT), \
	SPRN_CSRR0, SPRN_CSRR1, 0
#else
/*
 * For input register values, see arch/powerpc/include/asm/kvm_booke_hv_asm.h
 */
.macro kvm_handler intno srr0, srr1, flags
_GLOBAL(kvmppc_handler_\intno\()_\srr1)
	PPC_LL	r11, THREAD_KVM_VCPU(r10)
	PPC_STL r3, VCPU_GPR(r3)(r11)
	mfspr	r3, SPRN_SPRG_RSCRATCH0
	PPC_STL	r4, VCPU_GPR(r4)(r11)
	PPC_LL	r4, THREAD_NORMSAVE(0)(r10)
	PPC_STL	r5, VCPU_GPR(r5)(r11)
	stw	r13, VCPU_CR(r11)
	mfspr	r5, \srr0
	PPC_STL	r3, VCPU_GPR(r10)(r11)
	PPC_LL	r3, THREAD_NORMSAVE(2)(r10)
	PPC_STL	r6, VCPU_GPR(r6)(r11)
	PPC_STL	r4, VCPU_GPR(r11)(r11)
	mfspr	r6, \srr1
	PPC_STL	r7, VCPU_GPR(r7)(r11)
	PPC_STL	r8, VCPU_GPR(r8)(r11)
	PPC_STL	r9, VCPU_GPR(r9)(r11)
	PPC_STL r3, VCPU_GPR(r13)(r11)
	mfctr	r7
	PPC_STL	r12, VCPU_GPR(r12)(r11)
	PPC_STL	r7, VCPU_CTR(r11)
	mr	r4, r11
	kvm_handler_common \intno, \srr0, \flags
.endm

.macro kvm_lvl_handler intno scratch srr0, srr1, flags
_GLOBAL(kvmppc_handler_\intno\()_\srr1)
	mfspr	r10, SPRN_SPRG_THREAD
	PPC_LL	r11, THREAD_KVM_VCPU(r10)
	PPC_STL r3, VCPU_GPR(r3)(r11)
	mfspr	r3, \scratch
	PPC_STL	r4, VCPU_GPR(r4)(r11)
	PPC_LL	r4, GPR9(r8)
	PPC_STL	r5, VCPU_GPR(r5)(r11)
	stw	r9, VCPU_CR(r11)
	mfspr	r5, \srr0
	PPC_STL	r3, VCPU_GPR(r8)(r11)
	PPC_LL	r3, GPR10(r8)
	PPC_STL	r6, VCPU_GPR(r6)(r11)
	PPC_STL	r4, VCPU_GPR(r9)(r11)
	mfspr	r6, \srr1
	PPC_LL	r4, GPR11(r8)
	PPC_STL	r7, VCPU_GPR(r7)(r11)
	PPC_STL r3, VCPU_GPR(r10)(r11)
	mfctr	r7
	PPC_STL	r12, VCPU_GPR(r12)(r11)
	PPC_STL r13, VCPU_GPR(r13)(r11)
	PPC_STL	r4, VCPU_GPR(r11)(r11)
	PPC_STL	r7, VCPU_CTR(r11)
	mr	r4, r11
	kvm_handler_common \intno, \srr0, \flags
.endm

kvm_lvl_handler BOOKE_INTERRUPT_CRITICAL, \
	SPRN_SPRG_RSCRATCH_CRIT, SPRN_CSRR0, SPRN_CSRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_MACHINE_CHECK, \
	SPRN_SPRG_RSCRATCH_MC, SPRN_MCSRR0, SPRN_MCSRR1, 0
kvm_handler BOOKE_INTERRUPT_DATA_STORAGE, \
	SPRN_SRR0, SPRN_SRR1, (NEED_EMU | NEED_DEAR)
kvm_handler BOOKE_INTERRUPT_INST_STORAGE, SPRN_SRR0, SPRN_SRR1, NEED_ESR
kvm_handler BOOKE_INTERRUPT_EXTERNAL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_ALIGNMENT, \
	SPRN_SRR0, SPRN_SRR1, (NEED_DEAR | NEED_ESR)
kvm_handler BOOKE_INTERRUPT_PROGRAM, SPRN_SRR0, SPRN_SRR1, NEED_ESR
kvm_handler BOOKE_INTERRUPT_FP_UNAVAIL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SYSCALL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_AP_UNAVAIL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_DECREMENTER, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_FIT, SPRN_SRR0, SPRN_SRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_WATCHDOG, \
	SPRN_SPRG_RSCRATCH_CRIT, SPRN_CSRR0, SPRN_CSRR1, 0
kvm_handler BOOKE_INTERRUPT_DTLB_MISS, \
	SPRN_SRR0, SPRN_SRR1, (NEED_EMU | NEED_DEAR | NEED_ESR)
kvm_handler BOOKE_INTERRUPT_ITLB_MISS, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_UNAVAIL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_FP_DATA, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_SPE_FP_ROUND, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_PERFORMANCE_MONITOR, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_DOORBELL, SPRN_SRR0, SPRN_SRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_DOORBELL_CRITICAL, \
	SPRN_SPRG_RSCRATCH_CRIT, SPRN_CSRR0, SPRN_CSRR1, 0
kvm_handler BOOKE_INTERRUPT_HV_PRIV, SPRN_SRR0, SPRN_SRR1, NEED_EMU
kvm_handler BOOKE_INTERRUPT_HV_SYSCALL, SPRN_SRR0, SPRN_SRR1, 0
kvm_handler BOOKE_INTERRUPT_GUEST_DBELL, SPRN_GSRR0, SPRN_GSRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_GUEST_DBELL_CRIT, \
	SPRN_SPRG_RSCRATCH_CRIT, SPRN_CSRR0, SPRN_CSRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_DEBUG, \
	SPRN_SPRG_RSCRATCH_CRIT, SPRN_CSRR0, SPRN_CSRR1, 0
kvm_lvl_handler BOOKE_INTERRUPT_DEBUG, \
	SPRN_SPRG_RSCRATCH_DBG, SPRN_DSRR0, SPRN_DSRR1, 0
#endif

/* Registers:
 *  SPRG_SCRATCH0: guest r10
 *  r4: vcpu pointer
 *  r11: vcpu->arch.shared
 *  r14: KVM exit number
 */
_GLOBAL(kvmppc_resume_host)
	/* Save remaining volatile guest register state to vcpu. */
	mfspr	r3, SPRN_VRSAVE
	PPC_STL	r0, VCPU_GPR(r0)(r4)
	mflr	r5
	mfspr	r6, SPRN_SPRG4
	PPC_STL	r5, VCPU_LR(r4)
	mfspr	r7, SPRN_SPRG5
	stw	r3, VCPU_VRSAVE(r4)
	PPC_STD(r6, VCPU_SHARED_SPRG4, r11)
	mfspr	r8, SPRN_SPRG6
	PPC_STD(r7, VCPU_SHARED_SPRG5, r11)
	mfspr	r9, SPRN_SPRG7
	PPC_STD(r8, VCPU_SHARED_SPRG6, r11)
	mfxer	r3
	PPC_STD(r9, VCPU_SHARED_SPRG7, r11)

	/* save guest MAS registers and restore host mas4 & mas6 */
	mfspr	r5, SPRN_MAS0
	PPC_STL	r3, VCPU_XER(r4)
	mfspr	r6, SPRN_MAS1
	stw	r5, VCPU_SHARED_MAS0(r11)
	mfspr	r7, SPRN_MAS2
	stw	r6, VCPU_SHARED_MAS1(r11)
	PPC_STD(r7, VCPU_SHARED_MAS2, r11)
	mfspr	r5, SPRN_MAS3
	mfspr	r6, SPRN_MAS4
	stw	r5, VCPU_SHARED_MAS7_3+4(r11)
	mfspr	r7, SPRN_MAS6
	stw	r6, VCPU_SHARED_MAS4(r11)
	mfspr	r5, SPRN_MAS7
	lwz	r6, VCPU_HOST_MAS4(r4)
	stw	r7, VCPU_SHARED_MAS6(r11)
	lwz	r8, VCPU_HOST_MAS6(r4)
	mtspr	SPRN_MAS4, r6
	stw	r5, VCPU_SHARED_MAS7_3+0(r11)
	mtspr	SPRN_MAS6, r8
	/* Enable MAS register updates via exception */
	mfspr	r3, SPRN_EPCR
	rlwinm	r3, r3, 0, ~SPRN_EPCR_DMIUH
	mtspr	SPRN_EPCR, r3
	isync

	/* Switch to kernel stack and jump to handler. */
	PPC_LL	r3, HOST_RUN(r1)
	mr	r5, r14 /* intno */
	mr	r14, r4 /* Save vcpu pointer. */
	bl	kvmppc_handle_exit

	/* Restore vcpu pointer and the nonvolatiles we used. */
	mr	r4, r14
	PPC_LL	r14, VCPU_GPR(r14)(r4)

	andi.	r5, r3, RESUME_FLAG_NV
	beq	skip_nv_load
	PPC_LL	r15, VCPU_GPR(r15)(r4)
	PPC_LL	r16, VCPU_GPR(r16)(r4)
	PPC_LL	r17, VCPU_GPR(r17)(r4)
	PPC_LL	r18, VCPU_GPR(r18)(r4)
	PPC_LL	r19, VCPU_GPR(r19)(r4)
	PPC_LL	r20, VCPU_GPR(r20)(r4)
	PPC_LL	r21, VCPU_GPR(r21)(r4)
	PPC_LL	r22, VCPU_GPR(r22)(r4)
	PPC_LL	r23, VCPU_GPR(r23)(r4)
	PPC_LL	r24, VCPU_GPR(r24)(r4)
	PPC_LL	r25, VCPU_GPR(r25)(r4)
	PPC_LL	r26, VCPU_GPR(r26)(r4)
	PPC_LL	r27, VCPU_GPR(r27)(r4)
	PPC_LL	r28, VCPU_GPR(r28)(r4)
	PPC_LL	r29, VCPU_GPR(r29)(r4)
	PPC_LL	r30, VCPU_GPR(r30)(r4)
	PPC_LL	r31, VCPU_GPR(r31)(r4)
skip_nv_load:
	/* Should we return to the guest? */
	andi.	r5, r3, RESUME_FLAG_HOST
	beq	lightweight_exit

	srawi	r3, r3, 2 /* Shift -ERR back down. */

heavyweight_exit:
	/* Not returning to guest. */
	PPC_LL	r5, HOST_STACK_LR(r1)
	lwz	r6, HOST_CR(r1)

	/*
	 * We already saved guest volatile register state; now save the
	 * non-volatiles.
	 */

	PPC_STL	r15, VCPU_GPR(r15)(r4)
	PPC_STL	r16, VCPU_GPR(r16)(r4)
	PPC_STL	r17, VCPU_GPR(r17)(r4)
	PPC_STL	r18, VCPU_GPR(r18)(r4)
	PPC_STL	r19, VCPU_GPR(r19)(r4)
	PPC_STL	r20, VCPU_GPR(r20)(r4)
	PPC_STL	r21, VCPU_GPR(r21)(r4)
	PPC_STL	r22, VCPU_GPR(r22)(r4)
	PPC_STL	r23, VCPU_GPR(r23)(r4)
	PPC_STL	r24, VCPU_GPR(r24)(r4)
	PPC_STL	r25, VCPU_GPR(r25)(r4)
	PPC_STL	r26, VCPU_GPR(r26)(r4)
	PPC_STL	r27, VCPU_GPR(r27)(r4)
	PPC_STL	r28, VCPU_GPR(r28)(r4)
	PPC_STL	r29, VCPU_GPR(r29)(r4)
	PPC_STL	r30, VCPU_GPR(r30)(r4)
	PPC_STL	r31, VCPU_GPR(r31)(r4)

	/* Load host non-volatile register state from host stack. */
	PPC_LL	r14, HOST_NV_GPR(r14)(r1)
	PPC_LL	r15, HOST_NV_GPR(r15)(r1)
	PPC_LL	r16, HOST_NV_GPR(r16)(r1)
	PPC_LL	r17, HOST_NV_GPR(r17)(r1)
	PPC_LL	r18, HOST_NV_GPR(r18)(r1)
	PPC_LL	r19, HOST_NV_GPR(r19)(r1)
	PPC_LL	r20, HOST_NV_GPR(r20)(r1)
	PPC_LL	r21, HOST_NV_GPR(r21)(r1)
	PPC_LL	r22, HOST_NV_GPR(r22)(r1)
	PPC_LL	r23, HOST_NV_GPR(r23)(r1)
	PPC_LL	r24, HOST_NV_GPR(r24)(r1)
	PPC_LL	r25, HOST_NV_GPR(r25)(r1)
	PPC_LL	r26, HOST_NV_GPR(r26)(r1)
	PPC_LL	r27, HOST_NV_GPR(r27)(r1)
	PPC_LL	r28, HOST_NV_GPR(r28)(r1)
	PPC_LL	r29, HOST_NV_GPR(r29)(r1)
	PPC_LL	r30, HOST_NV_GPR(r30)(r1)
	PPC_LL	r31, HOST_NV_GPR(r31)(r1)

	/* Return to kvm_vcpu_run(). */
	mtlr	r5
	mtcr	r6
	addi	r1, r1, HOST_STACK_SIZE
	/* r3 still contains the return code from kvmppc_handle_exit(). */
	blr

/* Registers:
 *  r3: kvm_run pointer
 *  r4: vcpu pointer
 */
_GLOBAL(__kvmppc_vcpu_run)
	stwu	r1, -HOST_STACK_SIZE(r1)
	PPC_STL	r1, VCPU_HOST_STACK(r4)	/* Save stack pointer to vcpu. */

	/* Save host state to stack. */
	PPC_STL	r3, HOST_RUN(r1)
	mflr	r3
	mfcr	r5
	PPC_STL	r3, HOST_STACK_LR(r1)

	stw	r5, HOST_CR(r1)

	/* Save host non-volatile register state to stack. */
	PPC_STL	r14, HOST_NV_GPR(r14)(r1)
	PPC_STL	r15, HOST_NV_GPR(r15)(r1)
	PPC_STL	r16, HOST_NV_GPR(r16)(r1)
	PPC_STL	r17, HOST_NV_GPR(r17)(r1)
	PPC_STL	r18, HOST_NV_GPR(r18)(r1)
	PPC_STL	r19, HOST_NV_GPR(r19)(r1)
	PPC_STL	r20, HOST_NV_GPR(r20)(r1)
	PPC_STL	r21, HOST_NV_GPR(r21)(r1)
	PPC_STL	r22, HOST_NV_GPR(r22)(r1)
	PPC_STL	r23, HOST_NV_GPR(r23)(r1)
	PPC_STL	r24, HOST_NV_GPR(r24)(r1)
	PPC_STL	r25, HOST_NV_GPR(r25)(r1)
	PPC_STL	r26, HOST_NV_GPR(r26)(r1)
	PPC_STL	r27, HOST_NV_GPR(r27)(r1)
	PPC_STL	r28, HOST_NV_GPR(r28)(r1)
	PPC_STL	r29, HOST_NV_GPR(r29)(r1)
	PPC_STL	r30, HOST_NV_GPR(r30)(r1)
	PPC_STL	r31, HOST_NV_GPR(r31)(r1)

	/* Load guest non-volatiles. */
	PPC_LL	r14, VCPU_GPR(r14)(r4)
	PPC_LL	r15, VCPU_GPR(r15)(r4)
	PPC_LL	r16, VCPU_GPR(r16)(r4)
	PPC_LL	r17, VCPU_GPR(r17)(r4)
	PPC_LL	r18, VCPU_GPR(r18)(r4)
	PPC_LL	r19, VCPU_GPR(r19)(r4)
	PPC_LL	r20, VCPU_GPR(r20)(r4)
	PPC_LL	r21, VCPU_GPR(r21)(r4)
	PPC_LL	r22, VCPU_GPR(r22)(r4)
	PPC_LL	r23, VCPU_GPR(r23)(r4)
	PPC_LL	r24, VCPU_GPR(r24)(r4)
	PPC_LL	r25, VCPU_GPR(r25)(r4)
	PPC_LL	r26, VCPU_GPR(r26)(r4)
	PPC_LL	r27, VCPU_GPR(r27)(r4)
	PPC_LL	r28, VCPU_GPR(r28)(r4)
	PPC_LL	r29, VCPU_GPR(r29)(r4)
	PPC_LL	r30, VCPU_GPR(r30)(r4)
	PPC_LL	r31, VCPU_GPR(r31)(r4)


lightweight_exit:
	PPC_STL	r2, HOST_R2(r1)

	mfspr	r3, SPRN_PID
	stw	r3, VCPU_HOST_PID(r4)
	lwz	r3, VCPU_GUEST_PID(r4)
	mtspr	SPRN_PID, r3

	PPC_LL	r11, VCPU_SHARED(r4)
	/* Disable MAS register updates via exception */
	mfspr	r3, SPRN_EPCR
	oris	r3, r3, SPRN_EPCR_DMIUH@h
	mtspr	SPRN_EPCR, r3
	isync
	/* Save host mas4 and mas6 and load guest MAS registers */
	mfspr	r3, SPRN_MAS4
	stw	r3, VCPU_HOST_MAS4(r4)
	mfspr	r3, SPRN_MAS6
	stw	r3, VCPU_HOST_MAS6(r4)
	lwz	r3, VCPU_SHARED_MAS0(r11)
	lwz	r5, VCPU_SHARED_MAS1(r11)
	PPC_LD(r6, VCPU_SHARED_MAS2, r11)
	lwz	r7, VCPU_SHARED_MAS7_3+4(r11)
	lwz	r8, VCPU_SHARED_MAS4(r11)
	mtspr	SPRN_MAS0, r3
	mtspr	SPRN_MAS1, r5
	mtspr	SPRN_MAS2, r6
	mtspr	SPRN_MAS3, r7
	mtspr	SPRN_MAS4, r8
	lwz	r3, VCPU_SHARED_MAS6(r11)
	lwz	r5, VCPU_SHARED_MAS7_3+0(r11)
	mtspr	SPRN_MAS6, r3
	mtspr	SPRN_MAS7, r5

	/*
	 * Host interrupt handlers may have clobbered these guest-readable
	 * SPRGs, so we need to reload them here with the guest's values.
	 */
	lwz	r3, VCPU_VRSAVE(r4)
	PPC_LD(r5, VCPU_SHARED_SPRG4, r11)
	mtspr	SPRN_VRSAVE, r3
	PPC_LD(r6, VCPU_SHARED_SPRG5, r11)
	mtspr	SPRN_SPRG4W, r5
	PPC_LD(r7, VCPU_SHARED_SPRG6, r11)
	mtspr	SPRN_SPRG5W, r6
	PPC_LD(r8, VCPU_SHARED_SPRG7, r11)
	mtspr	SPRN_SPRG6W, r7
	mtspr	SPRN_SPRG7W, r8

	/* Load some guest volatiles. */
	PPC_LL	r3, VCPU_LR(r4)
	PPC_LL	r5, VCPU_XER(r4)
	PPC_LL	r6, VCPU_CTR(r4)
	lwz	r7, VCPU_CR(r4)
	PPC_LL	r8, VCPU_PC(r4)
	PPC_LD(r9, VCPU_SHARED_MSR, r11)
	PPC_LL	r0, VCPU_GPR(r0)(r4)
	PPC_LL	r1, VCPU_GPR(r1)(r4)
	PPC_LL	r2, VCPU_GPR(r2)(r4)
	PPC_LL	r10, VCPU_GPR(r10)(r4)
	PPC_LL	r11, VCPU_GPR(r11)(r4)
	PPC_LL	r12, VCPU_GPR(r12)(r4)
	PPC_LL	r13, VCPU_GPR(r13)(r4)
	mtlr	r3
	mtxer	r5
	mtctr	r6
	mtsrr0	r8
	mtsrr1	r9

#ifdef CONFIG_KVM_EXIT_TIMING
	/* save enter time */
1:
	mfspr	r6, SPRN_TBRU
	mfspr	r9, SPRN_TBRL
	mfspr	r8, SPRN_TBRU
	cmpw	r8, r6
	stw	r9, VCPU_TIMING_LAST_ENTER_TBL(r4)
	bne	1b
	stw	r8, VCPU_TIMING_LAST_ENTER_TBU(r4)
#endif

	/*
	 * Don't execute any instruction which can change CR after
	 * below instruction.
	 */
	mtcr	r7

	/* Finish loading guest volatiles and jump to guest. */
	PPC_LL	r5, VCPU_GPR(r5)(r4)
	PPC_LL	r6, VCPU_GPR(r6)(r4)
	PPC_LL	r7, VCPU_GPR(r7)(r4)
	PPC_LL	r8, VCPU_GPR(r8)(r4)
	PPC_LL	r9, VCPU_GPR(r9)(r4)

	PPC_LL	r3, VCPU_GPR(r3)(r4)
	PPC_LL	r4, VCPU_GPR(r4)(r4)
	rfi
