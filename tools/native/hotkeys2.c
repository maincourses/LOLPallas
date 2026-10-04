/* Offline candidate. No injection, game discovery, network or input simulation.
 * Loads only a bounded, versioned local file. Reuses the original sender.
 * Data and code are linked into separate RW and RX sections (never RWX).
 */
typedef unsigned int DWORD;
typedef unsigned short WORD;
typedef unsigned long long SIZE_T;
typedef void *HANDLE;
#define API __declspec(dllimport)
#define CAPACITY 65536u
#define MAX_ENTRIES 512u
API HANDLE __stdcall CreateFileW(const WORD *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
API int __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
API int __stdcall CloseHandle(HANDLE);
API short __stdcall GetAsyncKeyState(int);
API HANDLE __stdcall GetForegroundWindow(void);
#ifdef LPS_PORTABLE
API int __stdcall SHGetFolderPathW(HANDLE, int, HANDLE, DWORD, WORD *);
static volatile DWORD load_attempted;
#endif
extern void *copy_string(void *, const char *);
extern void original_send(const char *);

#ifndef LPS_PORTABLE
static const WORD library_path[] = L"C:\\Users\\zly\\AppData\\Local\\PallasCustomShout\\hotkeys-v2.bin";
static const char prefix[] = "{\"_lps_keys_v2\":\"";
#endif
static const char empty_scheme[] =
    "{\"0\":\"\",\"1\":\"\",\"2\":\"\",\"3\":\"\",\"4\":\"\","
    "\"5\":\"\",\"6\":\"\",\"7\":\"\",\"8\":\"\",\"9\":\"\","
    "\"10\":\"\",\"11\":\"\",\"12\":\"\",\"13\":\"\",\"14\":\"\","
    "\"15\":\"\",\"16\":\"\",\"17\":\"\",\"18\":\"\",\"19\":\"\","
    "\"title\":\"LOCAL HOTKEYS: USE LOCAL EDITOR\",\"key\":1}";
static const char failed_scheme[] =
    "{\"0\":\"\",\"1\":\"\",\"2\":\"\",\"3\":\"\",\"4\":\"\","
    "\"5\":\"\",\"6\":\"\",\"7\":\"\",\"8\":\"\",\"9\":\"\","
    "\"10\":\"\",\"11\":\"\",\"12\":\"\",\"13\":\"\",\"14\":\"\","
    "\"15\":\"\",\"16\":\"\",\"17\":\"\",\"18\":\"\",\"19\":\"\","
    "\"title\":\"LOCAL HOTKEYS LOAD FAILED\",\"key\":1}";
static volatile DWORD gate, active, generation;
static DWORD loaded_generation;
static DWORD entry_count;
static struct Entry { DWORD vk, mods, length, offset; } entries[MAX_ENTRIES];
static unsigned char blob[CAPACITY + 1], pressed[256];
static HANDLE foreground;
#ifdef LPS_PORTABLE
/* Event state is authoritative. An asynchronous query may return zero even
 * when this component has already received the modifier-down event. */
static unsigned char event_down[256], blocked[256];
#endif

static int acquire(void) { return !__atomic_exchange_n(&gate, 1, __ATOMIC_ACQUIRE); }
static void release(void) { __atomic_store_n(&gate, 0, __ATOMIC_RELEASE); }
static DWORD u32(const unsigned char *p) {
    return (DWORD)p[0] | ((DWORD)p[1] << 8) | ((DWORD)p[2] << 16) | ((DWORD)p[3] << 24);
}
static int hex8(const char *p, DWORD *out) {
    DWORD value = 0;
    for (DWORD i = 0; i < 8; ++i) {
        unsigned char c = (unsigned char)p[i];
        if (c >= '0' && c <= '9') value = (value << 4) | (c - '0');
        else if (c >= 'A' && c <= 'F') value = (value << 4) | (c - 'A' + 10);
        else return 0;
    }
    *out = value; return 1;
}
static int valid_key(DWORD vk, DWORD mods) {
    if (!mods || mods > 15) return 0;
    if (!((vk >= 0x30 && vk <= 0x39) || (vk >= 0x41 && vk <= 0x5A) ||
          (vk >= 0x60 && vk <= 0x69) || (vk >= 0x70 && vk <= 0x87) ||
          (vk >= 0x21 && vk <= 0x28) || vk == 0x2D || vk == 0x2E)) return 0;
    /* Never accept the Windows close/task-manager/security shortcuts. */
    if ((mods & 2) && vk == 0x73) return 0; /* Alt+F4 */
    if ((mods & 3) == 3 && vk == 0x2E) return 0; /* Ctrl+Alt+Delete */
    return 1;
}
static int valid_text(const unsigned char *p, DWORD n) {
    DWORD at = 0, units = 0, visible = 0;
    if (!n || n > 200) return 0;
    while (at < n) {
        DWORD cp = p[at++], extra = 0, minimum = 0;
        if (cp >= 0xC2 && cp <= 0xDF) { cp &= 31; extra = 1; minimum = 0x80; }
        else if (cp >= 0xE0 && cp <= 0xEF) { cp &= 15; extra = 2; minimum = 0x800; }
        else if (cp >= 0xF0 && cp <= 0xF4) { cp &= 7; extra = 3; minimum = 0x10000; }
        else if (cp >= 0x80) return 0;
        if (extra > n - at) return 0;
        for (DWORD j = 0; j < extra; ++j) {
            DWORD c = p[at++];
            if ((c & 0xC0) != 0x80) return 0;
            cp = (cp << 6) | (c & 63);
        }
        if (cp < minimum || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) ||
            cp < 32 || cp == 127) return 0;
        units += cp > 0xFFFF ? 2 : 1;
        if (units > 50) return 0;
        if (!(cp == 32 || cp == 0x85 || cp == 0xA0 || cp == 0x1680 ||
              (cp >= 0x2000 && cp <= 0x200A) || cp == 0x2028 || cp == 0x2029 ||
              cp == 0x202F || cp == 0x205F || cp == 0x3000)) visible = 1;
    }
    return visible != 0;
}
static int validate(DWORD length) {
#ifdef LPS_PORTABLE
    static const char magic[] = "LPSKEY3";
#else
    static const char magic[] = "LPSKEY2";
#endif
    for (DWORD i = 0; i < 8; ++i) if (blob[i] != (unsigned char)magic[i]) return 0;
#ifdef LPS_PORTABLE
    DWORD count = u32(blob + 12), at = 20;
#else
    DWORD count = u32(blob + 12), at = 16;
#endif
    if (u32(blob + 8) != length || !count || count > MAX_ENTRIES) return 0;
    DWORD seen[128];
    for (DWORD i = 0; i < 128; ++i) seen[i] = 0;
    for (DWORD i = 0; i < count; ++i) {
        if (at > length || length - at < 9) return 0;
        DWORD vk = blob[at] | ((DWORD)blob[at + 1] << 8);
        DWORD mods = blob[at + 2] | ((DWORD)blob[at + 3] << 8);
        DWORD size = u32(blob + at + 4); at += 8;
        if (!valid_key(vk, mods) || size >= length - at || blob[at + size] ||
            !valid_text(blob + at, size)) return 0;
        DWORD bit = mods * 256 + vk, mask = 1u << (bit & 31);
        if (seen[bit >> 5] & mask) return 0;
        seen[bit >> 5] |= mask;
        entries[i].vk = vk; entries[i].mods = mods;
        entries[i].length = size; entries[i].offset = at;
        at += size + 1;
    }
    if (at != length) return 0;
    entry_count = count; return 1;
}
#ifdef LPS_PORTABLE
static int LoadPortable(void) {
    DWORD ticket = __atomic_add_fetch(&generation, 1, __ATOMIC_ACQ_REL);
    __atomic_store_n(&active, 0, __ATOMIC_RELEASE);
    if (!acquire()) return 0;
    __atomic_add_fetch(&load_attempted, 1, __ATOMIC_ACQ_REL);
    int ok = 0;
    DWORD count = 0, length = 0;
    WORD path[320];
    static const WORD suffix[] = L"\\LOLPallasPortable\\hotkeys.bin";
    /* Preserve observed held keys and primary latches across a bounded retry
     * or scheme refresh; loading must not manufacture a new key press. */
    entry_count = 0;
    path[0] = 0;
    /* Reuse the already-imported Shell32 function, not usernames/env strings. */
    if (SHGetFolderPathW(0, 0x1C, 0, 0, path) != 0) goto done;
    while (length < 260 && path[length]) ++length;
    if (!length || length + sizeof(suffix) / sizeof(WORD) > 260) goto done;
    for (DWORD i = 0; i < sizeof(suffix) / sizeof(WORD); ++i) path[length + i] = suffix[i];
    HANDLE file = CreateFileW(path, 0x80000000u, 1, 0, 3, 0x00200080u, 0);
    if (!file || file == (HANDLE)(SIZE_T)-1) goto done;
    ok = ReadFile(file, blob, CAPACITY + 1, &count, 0);
    CloseHandle(file);
    if (!ok || count < 30 || count > CAPACITY) { ok = 0; goto done; }
    DWORD hash = 2166136261u;
    for (DWORD i = 20; i < count; ++i) hash = (hash ^ blob[i]) * 16777619u;
    ok = hash == u32(blob + 16) && validate(count);
done:
    loaded_generation = ticket;
    if (ok) __atomic_store_n(&load_attempted, 0, __ATOMIC_RELEASE);
    __atomic_store_n(&active, (DWORD)ok, __ATOMIC_RELEASE);
    release(); return ok;
}
static int PreviewScheme(char *out) {
    DWORD at = 0;
    out[at++] = '{';
    for (DWORD slot = 0; slot < 20; ++slot) {
        if (slot) out[at++] = ',';
        out[at++] = '"';
        if (slot >= 10) out[at++] = '1';
        out[at++] = (char)('0' + slot % 10);
        out[at++] = '"'; out[at++] = ':'; out[at++] = '"';
        /* The native panel's fixed digit labels must remain truthful. Other
         * independent bindings live in the editor, not misleading panel rows. */
        DWORD vk = slot == 9 ? 0x30 : 0x31 + slot;
        if (slot < 10) for (DWORD i = 0; i < entry_count; ++i) {
            if (entries[i].vk != vk || entries[i].mods != 8) continue;
            for (DWORD j = 0; j < entries[i].length; ++j) {
                unsigned char value = blob[entries[i].offset + j];
                if (at + 3 >= 1950) return 0;
                if (value == '"' || value == '\\') out[at++] = '\\';
                out[at++] = (char)value;
            }
            break;
        }
        out[at++] = '"';
    }
    static const char end[] = ",\"title\":\"LOCAL HOTKEYS: ~+DIGITS PREVIEW\",\"key\":1}";
    for (DWORD i = 0; i < sizeof(end); ++i) out[at++] = end[i];
    return 1;
}
void *ReadLocalScheme(void *destination, const char *source) {
    (void)source;
    /* Incoming cloud text does not supply/override any local records. */
    if (!LoadPortable() || !acquire()) return copy_string(destination, failed_scheme);
    char preview[2046];
    int ok = __atomic_load_n(&active, __ATOMIC_ACQUIRE) &&
        loaded_generation == __atomic_load_n(&generation, __ATOMIC_ACQUIRE) && PreviewScheme(preview);
    release();
    return copy_string(destination, ok ? preview : failed_scheme);
}
#else
void *ReadLocalScheme(void *destination, const char *source) {
    /* Invalidate before attempting the gate: contention fails closed. */
    DWORD ticket = __atomic_add_fetch(&generation, 1, __ATOMIC_ACQ_REL);
    __atomic_store_n(&active, 0, __ATOMIC_RELEASE);
    if (!acquire()) return copy_string(destination, failed_scheme);
    int ok = 0;
    DWORD length = 0, expected = 0, count = 0;
    entry_count = 0; foreground = 0;
    for (DWORD i = 0; i < 256; ++i) pressed[i] = 0;
    for (DWORD i = 0; i < sizeof(prefix) - 1; ++i) {
        if (!source || source[i] != prefix[i]) goto done;
    }
    const char *token = source + sizeof(prefix) - 1;
    if (!hex8(token, &length) || token[8] != ':' || !hex8(token + 9, &expected) ||
        token[17] != '"' || token[18] != ',' || length < 26 || length > CAPACITY) goto done;
    HANDLE file = CreateFileW(library_path, 0x80000000u, 1, 0, 3, 0x00200080u, 0);
    if (!file || file == (HANDLE)(SIZE_T)-1) goto done;
    ok = ReadFile(file, blob, length + 1, &count, 0);
    CloseHandle(file);
    if (!ok || count != length) { ok = 0; goto done; }
    DWORD hash = 2166136261u;
    for (DWORD i = 0; i < length; ++i) hash = (hash ^ blob[i]) * 16777619u;
    ok = hash == expected && validate(length);
done:
    loaded_generation = ticket;
    __atomic_store_n(&active, (DWORD)ok, __ATOMIC_RELEASE);
    release();
    return copy_string(destination, ok ? empty_scheme : failed_scheme);
}
#endif

#ifndef LPS_PORTABLE
void CustomKeyboard(void *object, DWORD message, SIZE_T key, SIZE_T unused) {
    (void)object; (void)unused;
#ifdef LPS_PORTABLE
    if (key >= 256 || (message != 0x100 && message != 0x101 &&
        message != 0x104 && message != 0x105)) return;
    /* Load once on the first real keyboard callback if cloud receive has not
     * run. No startup send, global hook, timers, synthetic input or retry loop. */
    if (!__atomic_load_n(&load_attempted, __ATOMIC_ACQUIRE)) LoadPortable();
    if (!acquire()) return;
#else
    if (key >= 256 || (message != 0x100 && message != 0x101 &&
        message != 0x104 && message != 0x105) || !acquire()) return;
#endif
    if (!__atomic_load_n(&active, __ATOMIC_ACQUIRE) ||
        loaded_generation != __atomic_load_n(&generation, __ATOMIC_ACQUIRE)) { release(); return; }
    HANDLE current = GetForegroundWindow();
    if (!current) { release(); return; }
    if (current != foreground) {
        foreground = current;
        for (DWORD i = 0; i < 256; ++i) pressed[i] = 0;
    }
    if (message == 0x101 || message == 0x105) { pressed[key] = 0; release(); return; }
    if (pressed[key]) { release(); return; }
    /* Latch even a nonmatching primary press: adding modifiers afterwards
     * must not turn OS autorepeat into a newly pressed shortcut. */
    pressed[key] = 1;
    if (GetAsyncKeyState(0x5B) < 0 || GetAsyncKeyState(0x5C) < 0) { release(); return; }
    DWORD mods = 0;
    if (GetAsyncKeyState(0x11) < 0) mods |= 1;
    if (GetAsyncKeyState(0x12) < 0) mods |= 2;
    if (GetAsyncKeyState(0x10) < 0) mods |= 4;
    if (GetAsyncKeyState(0xC0) < 0) mods |= 8;
    char text[201];
    DWORD length = 0;
    for (DWORD i = 0; i < entry_count; ++i) {
        if (entries[i].vk == key && entries[i].mods == mods) {
            length = entries[i].length;
            for (DWORD j = 0; j < length; ++j) text[j] = (char)blob[entries[i].offset + j];
            text[length] = 0; break;
        }
    }
    release();
    /* Never hold the gate while calling an external/reentrant sender. */
    if (length) original_send(text);
}
#else
static DWORD EventModifiers(void) {
    DWORD mask = 0;
    if (event_down[0x11] || event_down[0xA2] || event_down[0xA3]) mask |= 1;
    if (event_down[0x12] || event_down[0xA4] || event_down[0xA5]) mask |= 2;
    if (event_down[0x10] || event_down[0xA0] || event_down[0xA1]) mask |= 4;
    if (event_down[0xC0]) mask |= 8;
    return mask;
}
static void ResetEventState(void) {
    for (DWORD i = 0; i < 256; ++i) {
        blocked[i] |= event_down[i];
        event_down[i] = 0; pressed[i] = 0;
    }
}
static void UpdatePanel(void *object) {
    unsigned char *controller = (unsigned char *)object;
    DWORD panel_mask = controller[0x91] ? 8 : 1;
    unsigned char held = (EventModifiers() & panel_mask) != 0;
    if (held && !controller[0x92]) {
        /* Same fixed statistics slot as the original callback. */
        DWORD *count = (DWORD *)(controller + 0xC0); *count += 1;
    }
    controller[0x92] = held;
}
void CustomKeyboard(void *object, DWORD message, SIZE_T key, SIZE_T unused) {
    (void)unused;
    if (!object || key >= 256 || (message != 0x100 && message != 0x101 &&
        message != 0x104 && message != 0x105) || !acquire()) return;
    HANDLE current = GetForegroundWindow();
    if (current != foreground || !current) {
        foreground = current; ResetEventState();
    }
    if (message == 0x101 || message == 0x105) {
        blocked[key] = 0; pressed[key] = 0; event_down[key] = 0;
        UpdatePanel(object); release(); return;
    }
    if (!current || blocked[key] || pressed[key]) { UpdatePanel(object); release(); return; }
    pressed[key] = 1; event_down[key] = 1; UpdatePanel(object);
    if (!__atomic_load_n(&active, __ATOMIC_ACQUIRE) &&
        __atomic_load_n(&load_attempted, __ATOMIC_ACQUIRE) < 3) {
        /* Stop after three consecutive failed reads, only on fresh user key
         * events. No timer, polling, synthetic input or autorepeat retry loop. */
        release(); LoadPortable(); if (!acquire()) return;
    }
    if (!__atomic_load_n(&active, __ATOMIC_ACQUIRE) ||
        loaded_generation != __atomic_load_n(&generation, __ATOMIC_ACQUIRE) ||
        !event_down[key] || blocked[key]) { release(); return; }
    /* Event-observed Win state plus conservative physical Win suppression.
     * Async state is NEVER used to decide a Ctrl/Alt/Shift/~ match. */
    if (event_down[0x5B] || event_down[0x5C] ||
        GetAsyncKeyState(0x5B) < 0 || GetAsyncKeyState(0x5C) < 0) { release(); return; }
    DWORD mods = EventModifiers();
    char text[201]; DWORD length = 0;
    for (DWORD i = 0; i < entry_count; ++i) {
        if (entries[i].vk == key && entries[i].mods == mods) {
            length = entries[i].length;
            for (DWORD j = 0; j < length; ++j) text[j] = (char)blob[entries[i].offset + j];
            text[length] = 0; break;
        }
    }
    release();
    if (length) original_send(text);
}
#endif

void SendNonempty(const char *text) { if (text && *text) original_send(text); }
