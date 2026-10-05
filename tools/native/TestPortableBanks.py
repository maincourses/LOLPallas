"""Own-process native bank tests; never load Tencent modules or send messages."""
from __future__ import annotations

import ctypes
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(Path(__file__).parent))
import PallasLibrary as lib

obj = (ROOT / "build/portable-banks10/library80-banks.obj").read_bytes()
k = ctypes.WinDLL("kernel32", use_last_error=True)
k.VirtualAlloc.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_uint32]
k.VirtualAlloc.restype = ctypes.c_void_p
k.VirtualProtect.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32, ctypes.c_void_p]
k.VirtualProtect.restype = ctypes.c_int
k.VirtualFree.argtypes = [ctypes.c_void_p, ctypes.c_size_t, ctypes.c_uint32]
base = k.VirtualAlloc(None, 0x20000, 0x3000, 0x04)
if not base:
    raise ctypes.WinError(ctypes.get_last_error())
try:
    imports = {name: base + rva for name, rva in {**lib.IMPORT_RVAS, **lib.PORTABLE_IMPORT_RVAS}.items()}
    imports.update(copy_string=base+0x18000, original_send=base+0x18020)
    code, exports, _, _ = lib.Coff(obj).link(base, 0, imports)
    ctypes.memmove(base, code, len(code))
    old = ctypes.c_uint32()
    if not k.VirtualProtect(base, 0x20000, 0x20, ctypes.byref(old)):
        raise ctypes.WinError(ctypes.get_last_error())
    normalize = ctypes.WINFUNCTYPE(ctypes.c_uint64,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_uint32)(exports["BankNormalize"])

    def run(active: int) -> None:
        vector = ctypes.create_string_buffer(81 * 32)
        begin = ctypes.addressof(vector)
        for index in range(active):
            ctypes.c_uint64.from_address(begin + index*32 + 16).value = 1
            ctypes.c_uint64.from_address(begin + index*32 + 24).value = 15
        ctypes.c_uint64.from_address(begin + 80*32 + 24).value = 15
        ctrl = ctypes.create_string_buffer(0x100)
        address = ctypes.addressof(ctrl)
        ctypes.c_uint64.from_address(address + 0x40).value = begin
        ctypes.c_uint64.from_address(address + 0x48).value = begin + 81*32
        ctrl[0x92] = 1
        invalid = (1 << 64) - 1
        def press(vk):
            assert normalize(address,vk,0x100) == invalid
            assert normalize(address,vk,0x101) == invalid
        assert normalize(address,0x31,0x100) & 0xFFFFFFFF == 1
        banks = (active + 9)//10
        for expected in range(1,banks):
            press(0x22)
            result = normalize(address,0x31,0x100)
            assert result & 0xFFFFFFFF == expected*10+1, (active,expected,result)
        press(0x22)
        assert normalize(address,0x31,0x100) & 0xFFFFFFFF == 1
        press(0x21)
        assert normalize(address,0x30,0x100) & 0xFFFFFFFF == (banks-1)*10
    for n in (20,21,29,30,31,79,80):
        run(n)
    print("own-process native bank cycling: 20, 21, 29, 30, 31, 79, 80 OK")
finally:
    k.VirtualFree(base,0,0x8000)
