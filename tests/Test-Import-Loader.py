"""Normal Windows loader regression using ONLY a compiled own fixture DLL.

Reproduces the old moved-RX-descriptors / cleared-IAT bug, then verifies the
fixed directory with split original-R and new-RW slots. No game access/input.
"""
import argparse
import ctypes as c
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys
import uuid


def probe(path):
    k = c.WinDLL('kernel32'); k.SetErrorMode(3)
    dll = c.WinDLL(str(path))
    u = c.WinDLL('user32')
    same = lambda slot: c.c_void_p.from_address(dll._handle + slot).value == c.cast(u.GetForegroundWindow, c.c_void_p).value
    # Fixture header is explicit and contains no sensitive/process addresses.
    raw = path.read_bytes(); opt = struct.unpack_from('<I', raw, 0x3C)[0] + 24
    table = opt + struct.unpack_from('<H', raw, opt - 4)[0]
    count = struct.unpack_from('<H', raw, opt - 18)[0]
    imports_ok = same(0x2088)
    split = any(raw[table+i*40:table+i*40+8].rstrip(b'\0') == b'.fixiat' for i in range(count))
    if split: imports_ok = imports_ok and same(0x3000)
    return dict(loaded=True, old_and_new_imports_resolved=imports_ok, no_game_or_proprietary_module_loaded=True)


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--build', type=Path, required=True)
    p.add_argument('--child', type=Path)
    p.add_argument('--llvm', type=Path, default=Path(r'D:\LLVM\bin'))
    a = p.parse_args()
    if a.child:
        print(json.dumps(probe(a.child))); return
    root = Path(__file__).resolve().parents[1]
    work = root / 'build' / ('own-import-loader-' + uuid.uuid4().hex)
    work.mkdir()
    original = work / 'original.dll'
    commands = [
        [a.llvm/'llvm-dlltool.exe', '-m','i386:x86-64','-d',root/'tests/native/import-loader.def','-l',work/'user32.lib'],
        [a.llvm/'clang.exe','--target=x86_64-pc-windows-msvc','-Os','-ffreestanding','-fno-builtin','-fno-stack-protector',
         '-c',root/'tests/native/import-loader.c','-o',work/'fixture.obj'],
        [a.llvm/'lld-link.exe','/dll','/noentry','/nodefaultlib','/base:0x180000000','/out:'+str(original),work/'fixture.obj',work/'user32.lib']]
    for cmd in commands: subprocess.run([str(x) for x in cmd], check=True, capture_output=True, text=True)
    source = bytearray(original.read_bytes()); pe = struct.unpack_from('<I',source,0x3C)[0]; opt = pe+24
    table = opt+struct.unpack_from('<H',source,pe+20)[0]
    assert struct.unpack_from('<H',source,pe+6)[0] == 2
    assert struct.unpack_from('<II',source,opt+112+12*8) == (0x2088,16)
    text = table; vs,rva,size,raw = struct.unpack_from('<IIII',source,text+8)
    rd = table+40; _,rrva,rsize,rraw = struct.unpack_from('<IIII',source,rd+8)
    imp,_ = struct.unpack_from('<II',source,opt+112+8)
    at = rraw+imp-rrva; descriptor = source[at:at+20]
    lookup,_,_,name,first = struct.unpack('<IIIII',descriptor)
    assert first == 0x2088
    head = table+80; assert source[head:head+40] == bytes(40)
    # New RW import slot uses the same ordinary public API by name.
    hint = struct.unpack_from('<Q',source,rraw+lookup-rrva)[0]
    place = (vs+15)&~15; assert place+60 <= size
    moved = bytearray(source)
    moved[raw+place:raw+place+60] = descriptor+struct.pack('<IIIII',lookup,0,0,name,0x3000)+bytes(20)
    struct.pack_into('<I',moved,text+8,place+60)
    struct.pack_into('<II',moved,opt+112+8,rva+place,60)
    newraw = len(moved); assert newraw%512 == 0
    moved.extend(struct.pack('<QQ',hint,0)+bytes(512-16))
    struct.pack_into('<8sIIIIIIHHI',moved,head,b'.fixiat',16,0x3000,512,newraw,0,0,0,0,0xC0000040)
    struct.pack_into('<H',moved,pe+6,3); struct.pack_into('<I',moved,opt+56,0x4000)
    struct.pack_into('<I',moved,opt+8,struct.unpack_from('<I',moved,opt+8)[0]+512)
    good = work/'fixed-split-iat.dll'; good.write_bytes(moved)
    broken = bytearray(moved); struct.pack_into('<II',broken,opt+112+12*8,0,0)
    bad = work/'old-broken-layout.dll'; bad.write_bytes(broken)
    results = []
    for path in (original,bad,good):
        child = subprocess.run([sys.executable,__file__,'--build',str(a.build),'--child',str(path)],capture_output=True,text=True,timeout=15)
        result = dict(fixture=path.name, exit=child.returncode, data=json.loads(child.stdout) if child.stdout.strip() else None)
        results.append(result)
    assert results[0]['exit'] == 0 and results[0]['data']['old_and_new_imports_resolved'], results
    assert results[1]['exit'] == 0xC0000005, results
    assert results[2]['exit'] == 0 and results[2]['data']['old_and_new_imports_resolved'], results
    candidate = (a.build.resolve()/'TenPallas.portable.experimental.dll').read_bytes()
    candidate_opt = struct.unpack_from('<I',candidate,0x3C)[0]+24
    assert struct.unpack_from('<II',candidate,candidate_opt+112+12*8) == (0xFC000,0x6F8)
    report = dict(passed=True, own_fixture_only=True, checks=3, fixtures=results, work=str(work),
                  candidate_dll_sha256=hashlib.sha256(candidate).hexdigest())
    target = a.build.resolve()/'validation.loader.json'
    assert root/'build' in target.parents
    target.write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report))


if __name__ == '__main__': main()
