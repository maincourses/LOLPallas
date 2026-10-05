/* OFFLINE ONLY. Four groups of twenty; the verified reader/path/protocol stays
 * unchanged. This object is never loaded into a game by the builder or tests.
 * A reserved, default-constructed std::string slot owns state (legal SSO "00").
 * No writable PE section, controller-field reuse, new imports or global state.
 */
#define LPS_LIBRARY_CAPACITY 65536
#define LPS_EMPTY_EIGHTY 1
#define SendNonempty LegacySendNonempty
#include "library20.c"
#undef SendNonempty

#define MESSAGE_COUNT 80
#define VECTOR_COUNT 81
#define STRIDE 32
#define MAX_UNITS 100
#define INVALID_SLOT (~(SIZE_T)0)

SIZE_T BankNormalize(void *controller, DWORD vk, DWORD event) {
    if (!controller) return INVALID_SLOT;
    unsigned char *c = (unsigned char *)controller;
    unsigned char *begin = *(unsigned char **)(c + 0x40);
    unsigned char *end = *(unsigned char **)(c + 0x48);
    /* Do not touch the extra slot in old/partial/foreign vector layouts. */
    if (!begin || (SIZE_T)end < (SIZE_T)begin ||
        (SIZE_T)end - (SIZE_T)begin != VECTOR_COUNT * STRIDE)
        return INVALID_SLOT;
    unsigned char *s = begin + MESSAGE_COUNT * STRIDE;
    if (*(SIZE_T *)(s + 24) != 15) return INVALID_SLOT;
    SIZE_T size = *(SIZE_T *)(s + 16);
    if (!size) {
        if (s[0]) return INVALID_SLOT;
        s[0] = '0'; s[1] = '0'; s[2] = 0;
        *(SIZE_T *)(s + 16) = 2;
    } else if (size != 2 || s[0] < '0' || s[0] > '3' ||
               s[1] < '0' || s[1] > '2' || s[2]) return INVALID_SLOT;
    DWORD bank = s[0] - '0';
    if (vk == 0x21 || vk == 0x22) { /* PageUp / PageDown */
        DWORD latch = vk == 0x21 ? 1 : 2;
        if (event == 0x100 && c[0x92] && s[1] == '0') {
            s[0] = (unsigned char)('0' + ((bank + (latch == 1 ? 3 : 1)) & 3));
            s[1] = (unsigned char)('0' + latch);
        } else if (event == 0x101 && s[1] == '0' + latch) s[1] = '0';
        return INVALID_SLOT; /* A bank change NEVER sends a message. */
    }
    if (event != 0x100 && event != 0x101) return INVALID_SLOT;
    DWORD local, statistic;
    if (vk >= 0x30 && vk <= 0x39) {
        local = vk - 0x30;
        statistic = vk;
    } else if (vk >= 0x70 && vk <= 0x79) {
        local = (vk - 0x70 + 1) % 10 + 10;
        statistic = 0x30 + local % 10;
    } else return INVALID_SLOT;
    return ((SIZE_T)statistic << 32) | (bank * 20 + local);
}

/* The guard measures UTF-16 units from valid UTF-8, without truncation. It is
 * NOT a claim that the game accepts or safely handles one hundred units. */
static int bounded_utf8(const unsigned char *p) {
    if (!p || !*p) return 0;
    DWORD units = 0, bytes = 0;
    while (*p) {
        DWORD n, cp, minimum;
        unsigned char first = *p++;
        if (first < 0x80) { n = 0; cp = first; minimum = 0; }
        else if (first >= 0xC2 && first <= 0xDF) { n = 1; cp = first & 31; minimum = 0x80; }
        else if (first >= 0xE0 && first <= 0xEF) { n = 2; cp = first & 15; minimum = 0x800; }
        else if (first >= 0xF0 && first <= 0xF4) { n = 3; cp = first & 7; minimum = 0x10000; }
        else return 0;
        bytes += n + 1;
        if (bytes > MAX_UNITS * 4) return 0;
        for (DWORD i = 0; i < n; ++i) {
            unsigned char next = *p;
            if (next < 0x80 || next > 0xBF) return 0; /* Includes NUL: don't read past it. */
            ++p;
            cp = (cp << 6) | (next & 63);
        }
        if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) ||
            cp < 32 || cp == 127) return 0;
        units += cp > 0xFFFF ? 2 : 1;
        if (units > MAX_UNITS) return 0;
    }
    return 1;
}

void SendNonempty(const char *text) {
    if (bounded_utf8((const unsigned char *)text)) original_send(text);
}

/* Adapter for the two existing CALL sites: RBX controller, R8 key, EDX event.
 * Return EAX slot and ECX native statistic digit; preserve RDX/R8/R9/R10.
 * Win64 aligned shadow space and explicit unwind metadata (not a naked hook).
 */
__asm__(
    ".text\n"
    ".globl BankNormalizeWrapper\n"
    ".seh_proc BankNormalizeWrapper\n"
    "BankNormalizeWrapper:\n"
    "subq $0x48, %rsp\n"
    ".seh_stackalloc 0x48\n"
    ".seh_endprologue\n"
    "movq %rdx, 0x20(%rsp)\n"
    "movq %r8, 0x28(%rsp)\n"
    "movq %r9, 0x30(%rsp)\n"
    "movq %r10, 0x38(%rsp)\n"
    "movl %edx, %r9d\n"
    "movq %rbx, %rcx\n"
    "movq %r8, %rdx\n"
    "movl %r9d, %r8d\n"
    "callq BankNormalize\n"
    "movq 0x20(%rsp), %rdx\n"
    "movq 0x28(%rsp), %r8\n"
    "movq 0x30(%rsp), %r9\n"
    "movq 0x38(%rsp), %r10\n"
    "movq %rax, %rcx\n"
    "shrq $32, %rcx\n"
    "addq $0x48, %rsp\n"
    "retq\n"
    ".seh_endproc\n"
);
