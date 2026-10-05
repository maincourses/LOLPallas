# OWN-PROCESS ONLY. Exercise the adapter's original implicit RBX/R8/EDX ABI.
# It records outputs, does not execute or link Tencent code or real game send.
.text
.globl TestBankAdapter
.seh_proc TestBankAdapter
TestBankAdapter:
    pushq %rbx
    .seh_pushreg %rbx
    pushq %rdi
    .seh_pushreg %rdi
    subq $0x28, %rsp
    .seh_stackalloc 0x28
    .seh_endprologue
    movq %r9, %rdi
    movq %rcx, %rbx
    movl %r8d, %eax
    movl %edx, %r8d
    movl %eax, %edx
    movl $0x55667788, %r9d
    movl $0x11223344, %r10d
    callq BankNormalizeWrapper
    movq %rax, 0(%rdi)
    movq %rcx, 8(%rdi)
    movq %rdx, 16(%rdi)
    movq %r8, 24(%rdi)
    movq %r9, 32(%rdi)
    movq %r10, 40(%rdi)
    movq %rbx, 48(%rdi)
    addq $0x28, %rsp
    popq %rdi
    popq %rbx
    retq
.seh_endproc
