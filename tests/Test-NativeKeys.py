"""Own-process C receiver tests and byte-exact native-key rollback checks.
Never load a Tencent module or access a game. No real keyboard/message input.
"""
import argparse
import ctypes as c
import importlib.util
import json
from pathlib import Path
import struct
import subprocess
import sys

a=argparse.ArgumentParser(description=__doc__)
a.add_argument('--build',type=Path,required=True)
a.add_argument('--child',action='store_true'); a.add_argument('--real-io',action='store_true')
args=a.parse_args(); root=Path(__file__).resolve().parents[1]
spec=importlib.util.spec_from_file_location('nativekeys',root/'tools/native/PallasNativeKeys.py')
m=importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
build=args.build.resolve(); obj=(build/'nativekeys20.obj').read_bytes()
checks=0
def check(ok,label='fixture check'):
    global checks
    if not ok: raise AssertionError(label)
    checks+=1

def static_tests():
    old=(root/'engine/assets/TenPallas.original.dll').read_bytes()
    candidate=(build/'TenPallas.nativekeys.experimental.dll').read_bytes()
    manifest=json.loads((build/'manifest.json').read_text())
    result,info=m.patch(old,obj); check(result==candidate and info==manifest['native'],'reproducible')
    before=(root/'build/portable-v3-r2/TenPallas.portable.experimental.dll').read_bytes()
    plan=json.loads((build/'portable-fixed-to-native20.json').read_text())
    check(m.p.expand(before,plan)==candidate,'upgrade delta')
    known=(root/'build/local-library-v1/TenPallas.library.experimental.dll').read_bytes()
    check(m.t.sha256(known)=='beb422999a6e8e7f87d93937d9010b15dcaaacce237fd7b11c280d5cf88cca10')
    pe=m.t.PE64(candidate); kp=m.t.PE64(known)
    start=0x1800424C4; n=0x42599-0x424C4
    cb=bytearray(candidate[pe.offset(start,n):pe.offset(start,n)+n])
    prior=bytearray(known[kp.offset(start,n):kp.offset(start,n)+n])
    # Only the nonempty-sender guard target is relocated; every key instruction
    # is byte-identical to the user-confirmed native twenty-key version.
    at=m.t.BODY_VA+0x2C-start; cb[at:at+5]=prior[at:at+5]
    check(cb==prior,'entire native keyboard callback preserved')
    for va,raw in ((m.t.HELPER_VA,m.t.NORMALIZER),(m.t.EVENT_HELPER_VA,m.t.EVENT_NORMALIZER)):
        check(candidate[pe.offset(va,len(raw)):pe.offset(va,len(raw))+len(raw)]==raw,'native helper')
    baseline,_=m.t.patch_copy(old); original_pe=m.t.PE64(baseline)
    text=original_pe.sections[0]; allowed=set()
    for hook in info['hooks']: allowed.update(range(hook['file_offset'],hook['file_offset']+5))
    check(len(info['hooks'])==2 and all(h['va']!='0x1800424c4' for h in info['hooks']))
    check(all(candidate[i]==baseline[i] or i in allowed for i in range(text['raw'],text['raw']+text['raw_size'])))
    opt=struct.unpack_from('<I',old,0x3C)[0]+24
    check(candidate[opt+112+96:opt+112+104]==old[opt+112+96:opt+112+104],'old IAT preserved')
    check(info['sections'][1]['size']==74576 and manifest['capacity_bytes']==65536,'capacity/layout unchanged')
    for section in pe.sections:
        flags=struct.unpack_from('<I',candidate,section['header']+36)[0]
        check(not(flags&0x80000000 and flags&0x20000000),'no RWX')
    for bad in (dict(m.example(),count=19),dict(m.example(),bind0='Ctrl+Alt+Q')):
        try: m.artifacts(bad)
        except ValueError: check(True)
        else: check(False,'unsupported key mode accepted')

def receiver_tests():
    k=c.WinDLL('kernel32',use_last_error=True); W=c.WINFUNCTYPE
    for name,params,result in (
        ('VirtualAlloc',[c.c_void_p,c.c_size_t,c.c_uint32,c.c_uint32],c.c_void_p),
        ('VirtualProtect',[c.c_void_p,c.c_size_t,c.c_uint32,c.c_void_p],c.c_int),
        ('VirtualFree',[c.c_void_p,c.c_size_t,c.c_uint32],c.c_int),
        ('FlushInstructionCache',[c.c_void_p,c.c_void_p,c.c_size_t],c.c_int),
        ('GetProcessHeap',[],c.c_void_p),('HeapAlloc',[c.c_void_p,c.c_uint32,c.c_size_t],c.c_void_p),
        ('HeapFree',[c.c_void_p,c.c_uint32,c.c_void_p],c.c_int),
        ('CreateFileW',[c.c_wchar_p,c.c_uint32,c.c_uint32,c.c_void_p,c.c_uint32,c.c_uint32,c.c_void_p],c.c_void_p),
        ('ReadFile',[c.c_void_p,c.c_void_p,c.c_uint32,c.c_void_p,c.c_void_p],c.c_int),
        ('CloseHandle',[c.c_void_p],c.c_int)):
        getattr(k,name).argtypes=params; getattr(k,name).restype=result
    base=k.VirtualAlloc(None,0x60000,0x3000,4)
    if not base: raise c.WinError(c.get_last_error())
    state=dict(file=b'',copied=None,sent=[],opens=0,closed=0)
    callbacks=[]; errors=[]; allocations=set()
    def wrap(kind,fn):
        def safe(*params):
            try: return fn(*params)
            except BaseException as e: errors.append(repr(e)); return 0
        cb=kind(safe); callbacks.append(cb); return c.cast(cb,c.c_void_p).value
    def folder(hwnd,csidl,token,flags,out):
        assert (hwnd,csidl,token,flags)==(None,0x1C,None,0)
        if state.get('folder_fail'): return -1
        value=c.create_unicode_buffer(r'C:\OwnFixture\Local'); c.memmove(out,value,c.sizeof(value)); return 0
    def create(path,*params):
        assert c.wstring_at(path)==r'C:\OwnFixture\Local\LOLPallasPortable\hotkeys.bin'
        state['opens']+=1
        if state.get('missing'): return 0xFFFFFFFFFFFFFFFF
        if args.real_io:
            return k.CreateFileW(str(build/'hotkeys-v3.bin'),*params)
        return 42
    def read(handle,dest,size,count,overlap):
        assert size==65537 and overlap is None
        if args.real_io:
            return k.ReadFile(handle,dest,size,count,overlap)
        value=bytes(state['file'][:size]); c.memmove(dest,value,len(value)); c.c_uint32.from_address(count).value=len(value)
        return int(not state.get('read_error'))
    def close(handle): state['closed']+=1; return k.CloseHandle(handle) if args.real_io else 1
    def alloc(heap,flags,size):
        assert size==4096 and flags==0
        if state.get('no_alloc'): return None
        value=k.HeapAlloc(heap,flags,size); allocations.add(value); return value
    def free(heap,flags,ptr): allocations.remove(ptr); return k.HeapFree(heap,flags,ptr)
    def copy(dest,src): state['copied']=c.string_at(src); return dest
    def send(src): state['sent'].append(c.string_at(src))
    api={
        '__imp_CreateFileW':wrap(W(c.c_void_p,c.c_void_p,c.c_uint32,c.c_uint32,c.c_void_p,c.c_uint32,c.c_uint32,c.c_void_p),create),
        '__imp_ReadFile':wrap(W(c.c_int,c.c_void_p,c.c_void_p,c.c_uint32,c.c_void_p,c.c_void_p),read),
        '__imp_CloseHandle':wrap(W(c.c_int,c.c_void_p),close),
        '__imp_SHGetFolderPathW':wrap(W(c.c_int,c.c_void_p,c.c_int,c.c_void_p,c.c_uint32,c.c_void_p),folder),
        '__imp_GetAsyncKeyState':wrap(W(c.c_short,c.c_int),lambda vk:0),
        '__imp_GetForegroundWindow':wrap(W(c.c_void_p),lambda:None),
        '__imp_GetProcessHeap':wrap(W(c.c_void_p),lambda:None if state.get('no_heap') else k.GetProcessHeap()),
        '__imp_HeapAlloc':wrap(W(c.c_void_p,c.c_void_p,c.c_uint32,c.c_size_t),alloc),
        '__imp_HeapFree':wrap(W(c.c_int,c.c_void_p,c.c_uint32,c.c_void_p),free)}
    external={}
    for i,(name,address) in enumerate(api.items()):
        slot=base+0x18000+8*i; c.c_uint64.from_address(slot).value=address; external[name]=slot
    for name,offset,target in (('copy_string',0x17000,wrap(W(c.c_void_p,c.c_void_p,c.c_void_p),copy)),
                               ('original_send',0x17020,wrap(W(None,c.c_void_p),send))):
        stub=b'\x48\xb8'+struct.pack('<Q',target)+b'\xff\xe0'; c.memmove(base+offset,stub,len(stub)); external[name]=base+offset
    code,data,exports,pdata=m.p.link_split(obj,base,0,0x20000,external)
    assert len(code)<0x10000 and len(data)<0x30000
    c.memmove(base,bytes(code),len(code)); c.memmove(base+0x20000,bytes(data),len(data))
    previous=c.c_uint32()
    for offset,size in ((0,0x10000),(0x17000,0x1000)):
        if not k.VirtualProtect(base+offset,size,0x20,c.byref(previous)): raise c.WinError(c.get_last_error())
    k.FlushInstructionCache(c.c_void_p(-1),base,0x60000)
    load=W(c.c_void_p,c.c_void_p,c.c_void_p)(exports['ReadLocalScheme'])
    guard=W(None,c.c_void_p)(exports['SendNonempty'])
    def run(raw,**flags):
        state.update(file=raw,copied=None,missing=False,read_error=False,folder_fail=False,no_heap=False,no_alloc=False)
        state.update(flags); cloud=c.create_string_buffer(b'Cloud ignored')
        check(load(0x2222,c.addressof(cloud))==0x2222)
        check(not allocations and not errors,'heap cleanup/callback errors: '+repr(errors))
        return json.loads(state['copied'])
    try:
        raw=(build/'hotkeys-v3.bin').read_bytes(); result=run(raw)
        check(result['0']=='Native key test 1' and result['19']=='Native key test 20' and result['key']==1)
        for flags in (dict(missing=True),dict(no_heap=True),dict(no_alloc=True),dict(folder_fail=True)):
            check('LOAD FAILED' in run(raw,**flags)['title'])
        if not args.real_io:
            worst=m.example()
            for i in range(20): worst[str(i)]='\u4e2d'*50
            big=m.artifacts(worst)[0]; result=run(big)
            check(result['19']=='\u4e2d'*50 and 2046<len(state['copied'])<4096,'all twenty native strings survive')
            worst['0']='\\"<> '*10; result=run(m.artifacts(worst)[0]); check(result['0']==worst['0'])
            corrupt=bytearray(raw); corrupt[-2]^=1; check('LOAD FAILED' in run(corrupt)['title'])
            check('LOAD FAILED' in run(raw,read_error=True)['title'])
            arbitrary=m.example(); arbitrary['bind19']='Ctrl+Alt+Q'
            check('LOAD FAILED' in run(m.p.artifacts(arbitrary)[0])['title'],'missing fixed slot fails closed')
            check('LOAD FAILED' in run(raw[:-1])['title'])
        guard(None); blank=c.create_string_buffer(b''); guard(c.addressof(blank)); check(not state['sent'])
        value=c.create_string_buffer(b'Own sender fixture'); guard(c.addressof(value)); check(state['sent']==[b'Own sender fixture'])
        check(state['closed']<=state['opens'] and not allocations)
    finally:
        for ptr in allocations: k.HeapFree(k.GetProcessHeap(),0,ptr)
        k.VirtualFree(base,0,0x8000)

if args.child:
    receiver_tests(); print(json.dumps(dict(passed=True,checks=checks,real_file_io=args.real_io,no_game_or_proprietary_dll_loaded=True)))
else:
    static_tests(); report=dict(passed=True,static_checks=checks,game_send_verified=False)
    for name,extra in (('receiver',[]),('receiver_file_io',['--real-io'])):
        child=subprocess.run([sys.executable,__file__,'--build',str(build),'--child']+extra,capture_output=True,text=True,timeout=30)
        if child.returncode: raise RuntimeError(child.stdout+child.stderr+' exit '+str(child.returncode))
        report[name]=json.loads(child.stdout)
    report['candidate_dll_sha256']=m.t.sha256((build/'TenPallas.nativekeys.experimental.dll').read_bytes())
    (build/'validation.nativekeys.json').write_text(json.dumps(report,indent=2),encoding='utf-8')
    print(json.dumps(report))
