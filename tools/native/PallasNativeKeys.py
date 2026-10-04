"""Offline native-key rollback candidate. Never loads/installs Tencent modules."""
import argparse
import importlib.util
import json
from pathlib import Path
import subprocess

spec = importlib.util.spec_from_file_location('portable', Path(__file__).with_name('PallasPortable.py'))
p = importlib.util.module_from_spec(spec); spec.loader.exec_module(p)
t, lib, BASE = p.t, p.lib, p.BASE
FIXED_HASH = '52776e6b2d105df4cd0ff7ec8933e8170f7a404d1d6fd68288ca5c44af0cc0ad'

def patch(original, obj):
    return p.patch(original, obj, native_keys=True)

def check_scheme(scheme):
    if scheme.get('count') != 20: raise ValueError('Native key mode requires exactly twenty messages.')
    for i in range(20):
        expected = '~+' + (str((i + 1) % 10) if i < 10 else 'F' + str(i - 9))
        if p.binding(scheme.get('bind'+str(i)))[2] != expected:
            raise ValueError('Native key mode requires fixed ~+digits / ~+F1-F10 bindings.')

def artifacts(scheme):
    check_scheme(scheme)
    return p.artifacts(scheme)

def example():
    scheme = dict(version=2, title='Native twenty-key test', count=20)
    for i in range(20):
        scheme[str(i)] = 'Native key test ' + str(i+1)
        scheme['bind'+str(i)] = '~+' + (str((i+1)%10) if i < 10 else 'F'+str(i-9))
    return scheme

def main():
    a = argparse.ArgumentParser(description=__doc__)
    a.add_argument('--out-dir',type=Path,required=True)
    a.add_argument('--clang',type=Path,default=Path(r'D:\LLVM\bin\clang.exe'))
    args=a.parse_args(); root=Path(__file__).resolve().parents[2]; out=args.out_dir.resolve()
    if root/'build' not in out.parents or out.exists(): raise ValueError('Use a NEW build subdirectory.')
    original=(root/'engine/assets/TenPallas.original.dll').read_bytes()
    before=(root/'build/portable-v3-r2/TenPallas.portable.experimental.dll').read_bytes()
    if t.sha256(before)!=FIXED_HASH: raise ValueError('Pinned current component mismatch.')
    out.mkdir(); obj=out/'nativekeys20.obj'
    subprocess.run([str(args.clang),'--target=x86_64-pc-windows-msvc','-Os','-ffreestanding','-fno-builtin',
        '-fno-stack-protector','-fno-ident','-fno-addrsig','-funwind-tables','-g0','-c',
        str(Path(__file__).with_name('nativekeys20.c')),'-o',str(obj)],check=True,capture_output=True,text=True)
    candidate,native=patch(original,obj.read_bytes()); raw,_,canonical,metrics=artifacts(example())
    plan=t.compact(p.delta(before,candidate))
    t.write_new(out/'TenPallas.nativekeys.experimental.dll',candidate)
    t.write_new(out/'portable-fixed-to-native20.json',plan)
    t.write_new(out/'hotkeys-v3.bin',raw)
    report=dict(experiment='native-keys-64k-v1',candidate_dll_sha256=t.sha256(candidate),
        previous_dll_sha256=FIXED_HASH,delta_sha256=t.sha256(plan),native=native,metrics=metrics,
        keyboard_handler_restored=True,capacity_bytes=65536,maximum_messages=20,
        game_send_verified=False,installed=False,unsigned_experiment=True)
    t.write_new(out/'manifest.json',json.dumps(report,indent=2).encode())
    print(json.dumps(report))

if __name__=='__main__': main()
