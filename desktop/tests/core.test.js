"use strict";
const test=require("node:test");
const assert=require("node:assert/strict");
const fs=require("node:fs");
const os=require("node:os");
const path=require("node:path");
const core=require("../core");

const root=path.resolve(__dirname,"../..");
const dllStock=fs.readFileSync(path.join(root,"engine","assets","TenPallas.original.dll"));
const exeStock=fs.readFileSync(path.join(process.env.LOCALAPPDATA,"PallasCustomShout","LocalSchemeExperiment","pallas.original.exe"));

test("20/21/80 messages fill banks without truncation",()=>{
  const base=core.defaultScheme();
  assert.equal(base.messages.length,20);
  for(const count of [20,21,29,30,31,80]){
    const scheme={...base,messages:Array.from({length:count},(_,i)=>`第 ${i+1} 条中文消息`)};
    const out=core.compile(scheme);
    const library=JSON.parse(out.library.toString("utf8"));
    assert.equal(out.groupCount,Math.ceil(count/10));
    assert.equal(library[String(count-1)],`第 ${count} 条中文消息`);
    if(count<80)assert.equal(library[String(count)],"");
    assert.equal(Object.keys(library).length,82);
    const envelope=JSON.parse(out.response.toString("utf8"));
    const bootstrap=JSON.parse(Buffer.from(envelope.shout_message,"base64").toString("utf8"));
    assert.equal(bootstrap._lps_local_v1,`${out.library.length.toString(16).toUpperCase().padStart(8,"0")}:${hash(out.library).toString(16).toUpperCase().padStart(8,"0")}`);
  }
});
function hash(bytes){let h=2166136261;for(const b of bytes)h=Math.imul(h^b,16777619)>>>0;return h;}

test("invalid data is rejected without silent clipping",()=>{
  const scheme=core.defaultScheme();
  assert.throws(()=>core.validateScheme({...scheme,messages:scheme.messages.slice(0,19)}),/20～80/);
  assert.throws(()=>core.validateScheme({...scheme,messages:[...scheme.messages,"x\ny"]}),/换行/);
  assert.throws(()=>core.validateScheme({...scheme,messages:[...scheme.messages,"中".repeat(24000)]}),/65,536/);
});

test("pinned binary delta and loader edits reconstruct reproducibly",()=>{
  const plan=JSON.parse(fs.readFileSync(path.join(root,"desktop","assets","dll-stock.json")));
  const candidate=core.expandDelta(dllStock,plan);
  assert.equal(core.sha(candidate),core.PORTABLE_DLL);
  const old=fs.readFileSync(path.join(root,"build","legacy-eight-banks-ten-20261005","TenPallas.banks10.experimental.dll"));
  const upgraded=core.expandDelta(old,JSON.parse(fs.readFileSync(path.join(root,"desktop","assets","dll-working.json"))));
  assert.ok(upgraded.equals(candidate));
  const legacyResponse=path.join(process.env.LOCALAPPDATA,"PallasCustomShout","local-response.json");
  const loader=core.patchLoader(exeStock,legacyResponse);
  assert.equal(core.sha(loader),core.WORKING_LOADER);
  const chinese=core.patchLoader(exeStock,"C:\\Users\\张三\\AppData\\Local\\LPS\\r.json");
  assert.ok(chinese.toString("ascii",5498824,5498900).includes("%E5%BC%A0"));
  assert.throws(()=>core.expandDelta(Buffer.alloc(10),plan),/版本/);
});

test("mock installation, text update and exact restore are isolated",()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),"LPS-"));
  try{
    const wegame=path.join(temp,"WeGame");
    const app=path.join(wegame,"apps","Pallas");
    const deps=path.join(app,"tp_deps");fs.mkdirSync(deps,{recursive:true});
    const loader=path.join(app,"pallas.exe"),dll=path.join(deps,"TenPallas.dll");
    fs.writeFileSync(loader,exeStock);fs.writeFileSync(dll,dllStock);
    const paths=core.dataPaths(temp);
    const original=core.defaultScheme();
    const first=core.apply(wegame,original,paths,{skipProcessCheck:true});
    assert.equal(first.messageCount,20);
    assert.equal(core.inspect(wegame,paths).status,"installed");
    const added={...original,messages:[...original.messages,"新增第21条"]};
    const second=core.apply(wegame,added,paths,{skipProcessCheck:true});
    assert.equal(second.groupCount,3);
    assert.equal(JSON.parse(fs.readFileSync(paths.library,"utf8"))["20"],"新增第21条");
    core.restore(wegame,paths,{skipProcessCheck:true});
    assert.ok(fs.readFileSync(loader).equals(exeStock));
    assert.ok(fs.readFileSync(dll).equals(dllStock));
  }finally{
    assert.ok(temp.startsWith(os.tmpdir()+path.sep)&&path.basename(temp).startsWith("LPS-"));
    fs.rmSync(temp,{recursive:true,force:true});
  }
});

test("existing verified 80-message install upgrades and restores without changing legacy texts",()=>{
  const temp=fs.mkdtempSync(path.join(os.tmpdir(),"LPS-"));
  try{
    const wegame=path.join(temp,"WeGame"),app=path.join(wegame,"apps","Pallas");
    const deps=path.join(app,"tp_deps");fs.mkdirSync(deps,{recursive:true});
    const oldLoader=core.patchLoader(exeStock,path.join(process.env.LOCALAPPDATA,"PallasCustomShout","local-response.json"));
    const oldDll=fs.readFileSync(path.join(root,"build","legacy-eight-banks-ten-20261005","TenPallas.banks10.experimental.dll"));
    const loader=path.join(app,"pallas.exe"),dll=path.join(deps,"TenPallas.dll");
    fs.writeFileSync(loader,oldLoader);fs.writeFileSync(dll,oldDll);
    const oldTexts=fs.readFileSync(path.join(process.env.LOCALAPPDATA,"PallasCustomShout","library20-v1.json"));
    const scheme=core.fromLegacy(JSON.parse(oldTexts));
    const paths=core.dataPaths(temp);
    const result=core.apply(wegame,scheme,paths,{skipProcessCheck:true});
    assert.equal(result.messageCount,80);
    assert.equal(JSON.parse(fs.readFileSync(paths.library,"utf8"))["79"],scheme.messages[79]);
    core.restore(wegame,paths,{skipProcessCheck:true});
    assert.ok(fs.readFileSync(loader).equals(oldLoader));
    assert.ok(fs.readFileSync(dll).equals(oldDll));
    assert.ok(fs.readFileSync(path.join(process.env.LOCALAPPDATA,"PallasCustomShout","library20-v1.json")).equals(oldTexts));
  }finally{
    assert.ok(temp.startsWith(os.tmpdir()+path.sep)&&path.basename(temp).startsWith("LPS-"));
    fs.rmSync(temp,{recursive:true,force:true});
  }
});
