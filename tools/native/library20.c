/* OFFLINE EXPERIMENT. No loader/injection, network, game discovery or writes.
 * The only readable file is this profile-specific, bounded local library.
 * Existing imports and the original std::string copier/sender are reused.
 */
typedef unsigned int DWORD;
typedef unsigned long long SIZE_T;
typedef unsigned short WCHAR;
typedef void *HANDLE;
#define API __declspec(dllimport)
API HANDLE __stdcall CreateFileW(const WCHAR *, DWORD, DWORD, void *, DWORD, DWORD, HANDLE);
API int __stdcall ReadFile(HANDLE, void *, DWORD, DWORD *, void *);
API int __stdcall CloseHandle(HANDLE);
API HANDLE __stdcall GetProcessHeap(void);
API void *__stdcall HeapAlloc(HANDLE, DWORD, SIZE_T);
API int __stdcall HeapFree(HANDLE, DWORD, void *);
extern void *copy_string(void *, const char *);
extern void original_send(const char *);

/* The capacity control changes ONLY this bound. Default builds must reproduce
 * the user-verified 8 KiB DLL byte-for-byte; no new format, path or loader. */
#ifndef LPS_LIBRARY_CAPACITY
#define LPS_LIBRARY_CAPACITY 8192
#endif
#if LPS_LIBRARY_CAPACITY != 8192 && LPS_LIBRARY_CAPACITY != 65536
#error Unsupported local-library capacity control
#endif

static const WCHAR library_path[] = L"C:\\Users\\zly\\AppData\\Local\\PallasCustomShout\\library20-v1.json";
static const char prefix[] = "{\"_lps_local_v1\":\"";
static const char empty_scheme[] =
    "{\"0\":\"\",\"1\":\"\",\"2\":\"\",\"3\":\"\",\"4\":\"\","
    "\"5\":\"\",\"6\":\"\",\"7\":\"\",\"8\":\"\",\"9\":\"\","
    "\"10\":\"\",\"11\":\"\",\"12\":\"\",\"13\":\"\",\"14\":\"\","
    "\"15\":\"\",\"16\":\"\",\"17\":\"\",\"18\":\"\",\"19\":\"\","
    "\"title\":\"LOCAL LIBRARY LOAD FAILED\",\"key\":1}";

static int hex8(const char *p, DWORD *value) {
    DWORD result = 0;
    for (DWORD i = 0; i < 8; ++i) {
        unsigned char c = (unsigned char)p[i];
        DWORD digit;
        if (c >= '0' && c <= '9') digit = c - '0';
        else if (c >= 'A' && c <= 'F') digit = c - 'A' + 10;
        else return 0;
        result = (result << 4) | digit;
    }
    *value = result;
    return 1;
}

void *ReadLocalScheme(void *destination, const char *source) {
    DWORD length = 0, expected = 0, count = 0;
    for (DWORD i = 0; i < sizeof(prefix) - 1; ++i) {
        if (source[i] != prefix[i]) return copy_string(destination, source);
    }
    const char *token = source + sizeof(prefix) - 1;
    /* Check sequentially: a truncated token never reads past its first NUL. */
    if (!hex8(token, &length) || token[8] != ':' ||
        !hex8(token + 9, &expected) || token[17] != '"' || token[18] != ',' ||
        length < 2 || length > LPS_LIBRARY_CAPACITY) return copy_string(destination, empty_scheme);
    HANDLE file = CreateFileW(library_path, 0x80000000u, 1, 0, 3, 0x00200080u, 0);
    if (file == (HANDLE)(SIZE_T)-1 || !file) return copy_string(destination, empty_scheme);
    HANDLE heap = GetProcessHeap();
    char *data = heap ? (char *)HeapAlloc(heap, 0, (SIZE_T)length + 1) : 0;
    if (!data) {
        CloseHandle(file);
        return copy_string(destination, empty_scheme);
    }
    /* Asking for one extra byte also rejects a file longer than the token. */
    int ok = ReadFile(file, data, length + 1, &count, 0);
    CloseHandle(file);
    if (ok && count == length) {
        DWORD hash = 2166136261u;
        for (DWORD i = 0; i < length; ++i) {
            unsigned char c = (unsigned char)data[i];
            if (!c) { ok = 0; break; }
            hash = (hash ^ c) * 16777619u;
        }
        ok = ok && hash == expected;
    } else ok = 0;
    data[length] = 0;
    void *result = copy_string(destination, ok ? data : empty_scheme);
    HeapFree(heap, 0, data);
    return result;
}

/* A failed library replaces all twenty entries with empty strings. Never pass
 * those empties to the original sender. Normal nonempty messages are unchanged.
 */
void SendNonempty(const char *text) {
    if (text && *text) original_send(text);
}
