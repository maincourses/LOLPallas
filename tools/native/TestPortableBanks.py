"""Own-process native bank tests; never load Tencent modules or send messages."""
from __future__ import annotations

import ctypes
import os
from pathlib import Path
import sys
import tempfile
import struct
import json
import base64

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
base = k.VirtualAlloc(None, 0x110000, 0x3000, 0x04)
if not base:
    raise ctypes.WinError(ctypes.get_last_error())
try:
    imports = {name: base + rva for name, rva in {**lib.IMPORT_RVAS, **lib.PORTABLE_IMPORT_RVAS}.items()}
    imports.update(copy_string=base+0x18000, original_send=base+0x18020)
    code, exports, _, _ = lib.Coff(obj).link(base, 0, imports)
    ctypes.memmove(base, code, len(code))
    # Real Kernel32 imports with an owned Shell32 path stub. This tests only our
    # C reader and a temp library, not Tencent code or a live game file.
    kernel = ctypes.WinDLL("kernel32")
    for name,rva in lib.IMPORT_RVAS.items():
        fn=getattr(kernel,name.removeprefix("__imp_"))
        ctypes.c_void_p.from_address(base+rva).value=ctypes.cast(fn,ctypes.c_void_p).value
    scratch=tempfile.mkdtemp(prefix="LPS-native-")
    callbacks=[]
    WIN=ctypes.WINFUNCTYPE
    def folder(_hwnd,_csidl,_token,_flags,target):
        raw=(scratch+"\0").encode("utf-16-le")
        ctypes.memmove(target,raw,len(raw))
        return 0
    folder_fn=WIN(ctypes.c_int,ctypes.c_void_p,ctypes.c_int,ctypes.c_void_p,ctypes.c_uint32,ctypes.c_void_p)(folder)
    callbacks.append(folder_fn)
    ctypes.c_void_p.from_address(base+lib.PORTABLE_IMPORT_RVAS["__imp_SHGetFolderPathW"]).value=ctypes.cast(folder_fn,ctypes.c_void_p).value
    def copy(dest,src):
        raw=ctypes.string_at(src)+b"\0"
        ctypes.memmove(dest,raw,len(raw))
        return dest
    copy_fn=WIN(ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p)(copy)
    callbacks.append(copy_fn)
    ctypes.memmove(base+0x18000,b"\x48\xB8"+struct.pack("<Q",ctypes.cast(copy_fn,ctypes.c_void_p).value)+b"\xFF\xE0",12)
    ctypes.memmove(base+0x18020,b"\xC3",1)
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
    library=Path(scratch)/"LPS"/"library.json"
    library.parent.mkdir()
    raw=b'{"0":"hello","title":"test","key":1}'
    library.write_bytes(raw)
    token=f'{len(raw):08X}:{lib.fnv1a(raw):08X}'
    source=ctypes.create_string_buffer(('{'+'"_lps_local_v1":"'+token+'","0":""}').encode("ascii"))
    dest=ctypes.create_string_buffer(65537)
    read=WIN(ctypes.c_void_p,ctypes.c_void_p,ctypes.c_void_p)(exports["ReadLocalScheme"])
    assert read(ctypes.addressof(dest),ctypes.addressof(source))==ctypes.addressof(dest)
    assert dest.value==raw, dest.value[:100]
    library.write_bytes(raw+b"x")
    read(ctypes.addressof(dest),ctypes.addressof(source))
    assert b"LOCAL LIBRARY LOAD FAILED" in dest.value
    print("own-process native LocalAppData reader, length/checksum fail-close: OK")
    # Also exercise the *real* Shell32 import and the currently installed
    # profile path. The stub above proves parsing but cannot catch a wrong
    # CSIDL, import thunk or app-data path on this machine.
    live = Path(os.environ["LOCALAPPDATA"]) / "LPS" / "library.json"
    if live.is_file():
        actual = live.read_bytes()
        response=json.loads((live.parent/"r.json").read_bytes())
        real_source=ctypes.create_string_buffer(base64.b64decode(response["shout_message"]))
        shell32=ctypes.WinDLL("shell32")
        folder_real=shell32.SHGetFolderPathW
        ctypes.c_void_p.from_address(base+lib.PORTABLE_IMPORT_RVAS["__imp_SHGetFolderPathW"]).value=ctypes.cast(folder_real,ctypes.c_void_p).value
        read(ctypes.addressof(dest),ctypes.addressof(real_source))
        assert dest.value == actual, (len(dest.value),len(actual),dest.value[:100])
        print("own-process native real LocalAppData reader: OK")
finally:
    if "scratch" in locals():
        p=Path(scratch)
        if p.parent==Path(tempfile.gettempdir()) and p.name.startswith("LPS-native-"):
            import shutil
            shutil.rmtree(p)
    k.VirtualFree(base,0,0x8000)
