# Assembly specification used to check the embedded bytes in PallasTwenty.py.
# Compile as Windows x64 COFF; no live DLL is linked or loaded by this file.
.intel_syntax noprefix
.text
.globl keyboard20_body
keyboard20_body:
    call normalize20_target
    test eax, eax
    js .Lexit
    mov edi, ecx
    mov ecx, eax
    shl rcx, 5
    add rcx, qword ptr [rbx + 0x40]
    cmp rcx, qword ptr [rbx + 0x48]
    jae .Lexit
    mov byte ptr [rbx + 0x93], 1
    cmp qword ptr [rcx + 0x18], 0x10
    jb .Lsend
    mov rcx, qword ptr [rcx]
.Lsend:
    call original_sender_target
    # Keep the original ten counters and fixed 48-byte statistics packet.
    # Each digit and its F-key counterpart contribute to the same counter.
    inc dword ptr [rbx + rdi * 4 - 0x28]
    jmp .Lexit
    # Original key-up branches target VA 0x180042579 exactly.
    .org 62, 0x90
.Lkeyup:
    # EAX remains WM_KEYUP=0x101 along the untouched original entry paths.
    cmp edx, eax
    jne .Lexit
    call normalize20_target
    test eax, eax
    js .Lexit
    mov byte ptr [rbx + 0x93], 0
    .org 83, 0x90
.Lexit:
# The existing epilogue starts here and is NOT replaced.
