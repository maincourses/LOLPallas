/* Own minimal module: tests normal Windows loading, never a Tencent DLL. */
__declspec(dllimport) void *__stdcall GetForegroundWindow(void);
__declspec(dllexport) int FixtureProbe(void) {
    return GetForegroundWindow() != 0;
}
