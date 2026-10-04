# Stackless leaf helper: only volatile registers and flags are modified.
# Input: R8 = virtual key; preserve RDX (message type) and R8.
# Return EAX = string slot 0..19, ECX = original digit VK 0x30..0x39.
# Invalid key returns EAX=-1. There are no imports, API calls or global state.
.intel_syntax noprefix
.text
.globl normalize20
normalize20:
    lea rax, [r8 - 0x30]
    cmp rax, 9
    jbe .Ldigit
    lea rax, [r8 - 0x70]
    cmp rax, 9
    ja .Linvalid
    lea ecx, [rax + 1]
    cmp ecx, 10
    jne .Lwrapped
    xor ecx, ecx
.Lwrapped:
    lea eax, [rcx + 10]
    add ecx, 0x30
    ret
.Ldigit:
    mov ecx, r8d
    ret
.Linvalid:
    or eax, -1
    ret
