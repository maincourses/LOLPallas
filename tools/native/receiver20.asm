# At the original fragment entry, R8D = message-index + 1 (indices 0..19).
# First bank maps JSON 0..9 to slots 1..9,0; second to slots 11..19,10.
# Preserve R9 (source std::string), RSI (object) and RDI (loop index).
.intel_syntax noprefix
.text
.globl receiver20_index
receiver20_index:
    cmp edi, 9
    jne .Lsecond
    xor r8d, r8d
    jmp .Ldone
.Lsecond:
    cmp edi, 19
    jne .Ldone
    mov r8d, 10
.Ldone:
    .org 26, 0x90
    movsxd rcx, r8d
