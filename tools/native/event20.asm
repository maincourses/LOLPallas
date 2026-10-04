# Original callback's first AL load is replaced with CALL to this leaf.
# Normalize ONLY F10 WM_SYSKEYDOWN/UP; other system events remain untouched.
# Restore the displaced AL load; preserve RCX, R8, R9 and all nonvolatiles.
.intel_syntax noprefix
.text
.globl event20
event20:
    cmp r8, 0x79
    jne .Ldone
    cmp edx, 0x104
    je .Ldown
    cmp edx, 0x105
    jne .Ldone
    mov edx, 0x101
    jmp .Ldone
.Ldown:
    mov edx, 0x100
.Ldone:
    mov al, byte ptr [rcx + 0x91]
    ret
