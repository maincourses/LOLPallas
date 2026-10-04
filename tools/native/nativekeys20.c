/* Native twenty-key compatibility receiver; 64 KiB storage stays unchanged.
 * CustomKeyboard is compiled for layout compatibility but is NEVER hooked.
 * No timers, global keyboard service, injection, network or synthetic input.
 */
#define LPS_NATIVE_KEYS 1
#include "hotkeys3.c"
