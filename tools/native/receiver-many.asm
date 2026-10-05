# JSON index i maps to (i / 10) * 10 + ((i + 1) % 10).
# Input EDI=i, R8D=i+1. Preserve RDI/RSI/R9 and the original stack.
# The first twenty slots remain exactly as in the verified two-bank version.
.intel_syntax noprefix
.text
.globl receiver_many_index
receiver_many_index:
    mov eax, edi
    xor edx, edx
    mov ecx, 10
    div ecx
    cmp edx, 9
    jne .Ldone
    sub r8d, 10
.Ldone:
    .org 26, 0x90
    movsxd rcx, r8d
    # RET is only for our isolated assembler fixture, not copied into the DLL.
    ret
