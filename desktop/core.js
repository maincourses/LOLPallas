"use strict";

const fs = require("node:fs");
const path = require("node:path");
const os = require("node:os");
const crypto = require("node:crypto");
const {execFileSync} = require("node:child_process");
const {pathToFileURL} = require("node:url");

const STOCK_DLL = "97ba57fd47a393a3a4bbfa684d0f03d10cf04344fbd99cb2d2e8626675be9c94";
const WORKING_DLL = "5407dfa6a92640b216f5fba143a5baf63ec68e46a108fc664356df3a037bf3e2";
const PORTABLE_DLL = "58bfd7feaf836fb91f41d41ddcffbd15fb938bab42c2ea2db8072ef00dee3acd";
const STOCK_LOADER = "e17f8ce7ca6936a5984af16bb2751f305b3f72f556d0c7d2ad31c2c9ee70d119";
const WORKING_LOADER = "803870e3fda683443471e835699b065293724dc7e0f3289d0093fc84c8e30935";
// Only certificate bytes may vary automatically. Matching a few patch-site
// bytes is not enough to establish that a new WeGame code build is compatible.
const LOADER_PROFILES = [
  {name:"stock",hash:STOCK_LOADER,code:"4b85c43ddf101ab165cdcb5e5d68426f8b3378d53fd965eb8b0524d720955eb1"},
  {name:"working",hash:WORKING_LOADER,code:"d5926bce1ff51eba32790607df029a5ae1aa0d7fa79c3642bbf062dfdf17b883"}
];
const DLL_PROFILES = [
  {name:"stock",hash:STOCK_DLL,code:"5709c18d88b00a09c8f29b13bc6c0de48de21e916b7ea09e848063002afa26c2"},
  {name:"working",hash:WORKING_DLL,code:"e3079679d555a53b38d3579de3871637258f8a80b06f0e23c03acdc11fa31c11"}
];
const PORTABLE_DLL_CODE = "c013a05d3362423752cb6e37909886c6eb86f07ea5f87d324aad5b2df61ffbbb";
const ORIGINAL_URL = "https://www.wegame.com.cn/api/v1/wegame.pallas.game.LolAide/GetShoutMessage";
const URL_OFFSET = 5498824;
const EXECUTABLE_EDITS = [
  [1682669, "c8", "00"], [1684660, "4b", "48"], [1684770, "02", "01"],
  [1685062, "e8a6290400", "83c4049090"]
];
const encoder = new TextEncoder();

function sha(data) { return crypto.createHash("sha256").update(data).digest("hex"); }
function assert(condition, reason) { if (!condition) throw new Error(reason); }
function certificateRange(bytes) {
  assert(Buffer.isBuffer(bytes) && bytes.length >= 512 && bytes.toString("ascii",0,2)==="MZ", "无效 PE 文件");
  const pe=bytes.readUInt32LE(0x3c);
  assert(pe>=64 && pe+24<=bytes.length && bytes.toString("binary",pe,pe+4)==="PE\0\0", "无效 PE 头");
  const optional=pe+24, optionalSize=bytes.readUInt16LE(pe+20);
  const magic=bytes.readUInt16LE(optional);
  assert(magic===0x10b || magic===0x20b, "不支持的 PE 格式");
  const directory=optional+(magic===0x20b?112:96)+8*4;
  assert(directory+8<=optional+optionalSize && directory+8<=bytes.length, "PE 证书目录缺失");
  const offset=bytes.readUInt32LE(directory), size=bytes.readUInt32LE(directory+4);
  assert(offset>=512 && size>=8 && offset%8===0 && offset+size===bytes.length, "PE 证书布局与已验证版本不同");
  return {offset,size};
}
function codeFingerprint(bytes) {
  const {offset,size}=certificateRange(bytes);
  const copy=Buffer.from(bytes);
  copy.fill(0,offset,offset+size);
  return {hash:sha(copy),offset,size};
}
function classifySource(bytes,profiles) {
  const full=sha(bytes);
  let profile=profiles.find(item=>item.hash===full);
  if(profile)return {...profile,certificateOnly:false};
  let fingerprint;
  try {fingerprint=codeFingerprint(bytes);} catch {return null;}
  profile=profiles.find(item=>item.code===fingerprint.hash);
  return profile?{...profile,certificateOnly:true}:null;
}
function isPortableDll(bytes) {
  if(sha(bytes)===PORTABLE_DLL)return true;
  try{return codeFingerprint(bytes).hash===PORTABLE_DLL_CODE;}catch{return false;}
}
function samePath(a,b){return typeof a==="string"&&typeof b==="string"&&
  path.resolve(a).toLowerCase()===path.resolve(b).toLowerCase();}
function validateText(text, label) {
  assert(typeof text === "string" && text.trim().length > 0, `${label}不能为空`);
  assert(!/[\x00-\x1f\x7f]/.test(text), `${label}不能包含换行或控制字符`);
  assert(!/[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/u.test(text), `${label}包含无效 Unicode`);
}
function validateScheme(input) {
  assert(input && typeof input === "object" && !Array.isArray(input), "文案结构无效");
  const {title, key, messages} = input;
  validateText(title, "方案名称");
  assert(key === 1, "当前便携版只支持已验证的 ~ 面板键");
  assert(Array.isArray(messages) && messages.length >= 20 && messages.length <= 80, "消息需为 20～80 条");
  messages.forEach((text, index) => validateText(text, `第 ${index + 1} 条`));
  const scheme = {title, key, messages: [...messages]};
  const {library} = compile(scheme, true);
  assert(library.length <= 65536, "整套文案超过 65,536 字节");
  return scheme;
}
function fnv(bytes) {
  let hash = 2166136261;
  for (const byte of bytes) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
  return hash >>> 0;
}
function preview(text) {
  if (text.length <= 32) return text;
  let n = 32;
  if (/^[\uD800-\uDBFF]$/.test(text[n - 1])) n -= 1;
  return text.slice(0, n) + "…";
}
function compile(scheme, skipValidation = false) {
  if (!skipValidation) scheme = validateScheme(scheme);
  const full = {};
  for (let i = 0; i < 80; i++) full[String(i)] = scheme.messages[i] || "";
  full.title = scheme.title; full.key = 1;
  const library = encoder.encode(JSON.stringify(full));
  assert(library.length <= 65536, "整套文案超过 65,536 字节");
  const token = `${library.length.toString(16).toUpperCase().padStart(8,"0")}:${fnv(library).toString(16).toUpperCase().padStart(8,"0")}`;
  const previewFields = {};
  for (let i = 0; i < 20; i++) previewFields[String(i)] = i < 10 ? preview(scheme.messages[i]) : "";
  previewFields.title = preview(scheme.title); previewFields.key = 1;
  // Integer-like property names always serialize before ordinary properties in
  // JavaScript. The native reader requires this marker at byte zero of the JSON;
  // constructing one JSON field explicitly prevents numeric keys moving first.
  const encodeBootstrap = () => encoder.encode(`{"_lps_local_v1":${JSON.stringify(token)},${JSON.stringify(previewFields).slice(1)}`);
  let short = encodeBootstrap();
  if (short.length > 2046) {
    for (let i = 0; i < 10; i++) previewFields[String(i)] = "";
    short = encodeBootstrap();
  }
  assert(short.length <= 2046, "原生预览数据超出 2046 字节");
  const response = encoder.encode(JSON.stringify({result:{error_code:0}, shout_message:Buffer.from(short).toString("base64")}));
  return {library:Buffer.from(library), response:Buffer.from(response), libraryBytes:library.length,
    groupCount:Math.ceil(scheme.messages.length / 10)};
}
function defaultScheme() {
  const seeds = ["注意地图，小心敌方支援。", "敌人消失，请注意安全。", "先补给，稍后回来。", "准备团战，请靠近队友。",
    "先撤退，等技能冷却。", "注意站位，优先保护后排。", "稳住发育，等下一波机会。", "可以尝试推进。",
    "打得漂亮，谢谢配合！", "注意小龙时间。", "先做视野再行动。", "我来处理兵线。", "这里可能有埋伏。",
    "稍等，我马上到。", "先别追，保护目标。", "注意对方关键技能。", "我们集合推进。", "先守塔，保持阵型。",
    "回家补给后再来。", "这一波打得不错。"];
  return {title:"我的快捷喊话",key:1,messages:seeds};
}
function fromLegacy(value) {
  assert(value && typeof value === "object" && value.key === 1, "旧文案格式不兼容");
  const messages = [];
  for (let i = 0; i < 80; i++) {
    assert(typeof value[String(i)] === "string", `旧文案缺少第 ${i + 1} 条`);
    messages.push(value[String(i)]);
  }
  while (messages.length > 20 && messages[messages.length - 1] === "") messages.pop();
  return validateScheme({title:value.title,key:1,messages});
}
function applyDeltaBytes(source,plan) {
  assert(plan.format === 1 && source.length === plan.sourceSize, "组件布局与补丁来源不匹配");
  const result = Buffer.alloc(plan.targetSize);
  source.copy(result, 0, 0, Math.min(source.length, result.length));
  let end = 0;
  for (const [offset, encoded] of plan.edits) {
    const bytes = Buffer.from(encoded, "base64");
    assert(Number.isSafeInteger(offset) && offset >= end && bytes.length && offset + bytes.length <= result.length,
      "补丁数据损坏");
    bytes.copy(result, offset); end = offset + bytes.length;
  }
  return result;
}
function expandDelta(source,plan) {
  assert(sha(source)===plan.sourceSha256,"组件版本与补丁来源不匹配");
  const result=applyDeltaBytes(source,plan);
  assert(sha(result)===plan.targetSha256,"补丁生成后哈希不一致");
  return result;
}
function expandCompatibleDelta(source,plan) {
  const profile=classifySource(source,DLL_PROFILES);
  assert(profile && profile.hash===plan.sourceSha256,"DLL 代码版本与补丁来源不匹配");
  if(!profile.certificateOnly)return expandDelta(source,plan);
  const sourceCertificate=certificateRange(source);
  const result=applyDeltaBytes(source,plan);
  const targetCertificate=certificateRange(result);
  assert(sourceCertificate.size===targetCertificate.size,"DLL 证书长度不同，需单独适配");
  source.copy(result,targetCertificate.offset,sourceCertificate.offset,sourceCertificate.offset+sourceCertificate.size);
  assert(codeFingerprint(result).hash===PORTABLE_DLL_CODE,"DLL 补丁后代码校验失败");
  return result;
}
function patchLoader(source, responsePath) {
  const profile=classifySource(source,LOADER_PROFILES);
  assert(profile,"不支持此版 pallas.exe 的代码布局；未改动文件");
  const resolved=path.resolve(responsePath);
  assert(/^[A-Za-z]:\\/.test(resolved),"只支持本地磁盘中的文案路径");
  const url = pathToFileURL(resolved).href;
  assert(Buffer.byteLength(url,"ascii") <= 75, "当前用户路径过长，无法放入此版 Pallas 的 75 字节网址槽位");
  const result = Buffer.from(source);
  if (profile.name === "stock") {
    for (const [offset, before, after] of EXECUTABLE_EDITS) {
      const original = Buffer.from(before,"hex"), replacement = Buffer.from(after,"hex");
      assert(result.subarray(offset,offset+original.length).equals(original), "启动器指令不匹配");
      replacement.copy(result,offset);
    }
    assert(result.toString("ascii", URL_OFFSET, URL_OFFSET+75) === ORIGINAL_URL, "启动器原网址不匹配");
  } else {
    assert(result.toString("ascii",URL_OFFSET,URL_OFFSET+8) === "file:///", "旧版启动器网址不匹配");
  }
  result.fill(0,URL_OFFSET,URL_OFFSET+76);
  result.write(url,URL_OFFSET,"ascii");
  return result;
}
function dataPaths(root = (process.defaultApp ? process.env.LPS_TEST_DATA_ROOT : null) ||
  process.env.LOCALAPPDATA || path.join(os.homedir(),"AppData","Local")) {
  const data = path.join(root,"LPS");
  return {data, draft:path.join(data,"messages.json"), library:path.join(data,"library.json"),
    response:path.join(data,"r.json"), state:path.join(data,"install.json"), backups:path.join(data,"backups")};
}
function jsonFile(file) { return JSON.parse(fs.readFileSync(file,"utf8").replace(/^\uFEFF/,"")); }
function atomicWrite(file, bytes) {
  fs.mkdirSync(path.dirname(file),{recursive:true});
  const temp = `${file}.${crypto.randomUUID()}.tmp`;
  try { fs.writeFileSync(temp,bytes,{flag:"wx"}); fs.renameSync(temp,file); }
  finally { if (fs.existsSync(temp)) fs.unlinkSync(temp); }
}
function readDraft(paths = dataPaths()) {
  if (fs.existsSync(paths.draft)) {
    const scheme = validateScheme(jsonFile(paths.draft));
    return {scheme, revision:sha(fs.readFileSync(paths.draft)), source:"draft"};
  }
  for (const file of [
    paths.library,
    path.join(path.dirname(paths.data),"LOLPallasPortable","Editor","banks10-messages.json"),
    path.join(path.dirname(paths.data),"PallasCustomShout","library20-v1.json")]) {
    if (fs.existsSync(file)) {
      try { return {scheme:fromLegacy(jsonFile(file)),revision:"",source:"legacy-import"}; }
      catch { /* Another/older format: leave it untouched and offer default. */ }
    }
  }
  return {scheme:defaultScheme(),revision:"",source:"default"};
}
function saveDraft(scheme, expectedRevision, paths = dataPaths()) {
  scheme = validateScheme(scheme);
  const current = fs.existsSync(paths.draft) ? sha(fs.readFileSync(paths.draft)) : "";
  assert(current === expectedRevision, "草稿已被其他窗口修改，请重新读取后再保存");
  const bytes = Buffer.from(JSON.stringify(scheme,null,2),"utf8");
  atomicWrite(paths.draft,bytes);
  return {scheme,revision:sha(bytes),source:"draft"};
}
function pathsForWeGame(root) {
  assert(typeof root === "string" && root.trim(), "请先选择 WeGame 安装目录");
  const resolved = path.resolve(root);
  assert(!resolved.startsWith("\\"), "不支持网络共享中的 WeGame");
  return {root:resolved, loader:path.join(resolved,"apps","Pallas","pallas.exe"),
    dll:path.join(resolved,"apps","Pallas","tp_deps","TenPallas.dll")};
}
function assertNoLinks(target) {
  let cursor=path.resolve(target);
  while(true){
    if(fs.existsSync(cursor))assert(!fs.lstatSync(cursor).isSymbolicLink(),`拒绝链接/重定向路径：${cursor}`);
    const parent=path.dirname(cursor);if(parent===cursor)break;cursor=parent;
  }
}
function findWeGame(saved = "") {
  const candidates = [saved, path.join(process.env["ProgramFiles(x86)"] || "C:\\Program Files (x86)","WeGame"),
    path.join(process.env.ProgramFiles || "C:\\Program Files","WeGame")];
  for (const drive of ["C","D","E","F","G"]) {
    candidates.push(`${drive}:\\Program Files (x86)\\WeGame`,`${drive}:\\Program Files\\WeGame`,
      `${drive}:\\WeGame`);
  }
  for (const folder of candidates) {
    try { const p=pathsForWeGame(folder); if (fs.existsSync(p.loader) && fs.existsSync(p.dll)) return p.root; }
    catch { /* Continue. */ }
  }
  return "";
}
function inspect(root, paths = dataPaths()) {
  const p = pathsForWeGame(root);
  assert(fs.existsSync(p.loader) && fs.existsSync(p.dll), "所选目录不是 WeGame 安装目录（应包含 apps\\Pallas）");
  const loaderBytes=fs.readFileSync(p.loader),dllBytes=fs.readFileSync(p.dll);
  const loaderHash=sha(loaderBytes), dllHash=sha(dllBytes);
  const loaderProfile=classifySource(loaderBytes,LOADER_PROFILES);
  const dllProfile=classifySource(dllBytes,DLL_PROFILES);
  const state=fs.existsSync(paths.state) ? jsonFile(paths.state) : null;
  const own=state && samePath(state.root,p.root) && state.loaderSha256===loaderHash && state.dllSha256===dllHash &&
    typeof state.backup==="string" && samePath(path.dirname(state.backup),paths.backups) &&
    fs.existsSync(path.join(state.backup,"manifest.json"));
  let status="unsupported";
  if (own && isPortableDll(dllBytes)) status="installed";
  else if (loaderProfile && dllProfile) status="ready";
  return {status,root:p.root,loaderHash,dllHash,backup:own?state.backup:null,
    loaderProfile:loaderProfile?.name||null,dllProfile:dllProfile?.name||null,
    certificateOnly:!!(loaderProfile?.certificateOnly||dllProfile?.certificateOnly),
    message:status==="installed"?"便携组件已安装":status==="ready"?
      (loaderProfile.certificateOnly||dllProfile.certificateOnly?"代码匹配，仅签名数据不同；可备份并应用":"版本匹配，可备份并应用"):
      "代码或 PE 布局与已验证版本不同；未写入。请提供新版组件进行单独适配"};
}
function assertStopped() {
  const output = execFileSync("tasklist",["/FO","CSV","/NH"],{encoding:"utf8",windowsHide:true});
  const blocked = ["wegame.exe","tgp_daemon.exe","pallas.exe","league of legends.exe","leagueclient.exe","leagueclientux.exe"];
  const names = [...output.matchAll(/^"([^"]+)"/gm)].map(match=>match[1].toLowerCase());
  const running = blocked.filter(name=>names.includes(name));
  assert(running.length===0,`请先结束对局并彻底退出 WeGame：${running.join(", ")}`);
}
function readDelta(name) {
  const plan=jsonFile(path.join(__dirname,"assets",`dll-${name}.json`));
  assert(plan.targetSha256===PORTABLE_DLL,"补丁目标哈希不正确");
  return plan;
}
function backupEntries(entries, paths) {
  const folder=path.join(paths.backups,`${new Date().toISOString().replace(/[:.]/g,"-")}-${crypto.randomUUID()}`);
  fs.mkdirSync(folder,{recursive:true});
  const manifest=[];
  for (let i=0;i<entries.length;i++) {
    const [name,file] = entries[i];
    const existed=fs.existsSync(file);
    const bytes=existed?fs.readFileSync(file):null;
    if (existed) fs.writeFileSync(path.join(folder,`${i}.bak`),bytes,{flag:"wx"});
    manifest.push({name,file,existed,sha256:bytes?sha(bytes):null,backup:existed?`${i}.bak`:null});
  }
  fs.writeFileSync(path.join(folder,"manifest.json"),JSON.stringify({version:1,entries:manifest},null,2),{flag:"wx"});
  return {folder,manifest};
}
function restoreEntries(backup) {
  for (let i=backup.manifest.length-1;i>=0;i--) {
    const entry=backup.manifest[i];
    if (entry.existed) {
      const bytes=fs.readFileSync(path.join(backup.folder,entry.backup));
      assert(sha(bytes)===entry.sha256,"备份已损坏，停止恢复");
      atomicWrite(entry.file,bytes);
    } else if (fs.existsSync(entry.file)) fs.unlinkSync(entry.file);
  }
}
function apply(root, scheme, paths = dataPaths(), options={}) {
  scheme=validateScheme(scheme);
  if (!options.skipProcessCheck) assertStopped();
  const before=inspect(root,paths);
  assert(before.status!=="unsupported",before.message);
  const p=pathsForWeGame(root), output=compile(scheme);
  for(const location of [p.loader,p.dll,paths.data,paths.library,paths.response,paths.state,paths.backups])
    assertNoLinks(location);
  const oldLoader=fs.readFileSync(p.loader),oldDll=fs.readFileSync(p.dll);
  const newLoader=before.status==="installed"?oldLoader:patchLoader(oldLoader,paths.response);
  const newDll=before.status==="installed"?oldDll:expandCompatibleDelta(oldDll,readDelta(before.dllProfile));
  assert(isPortableDll(newDll),"DLL 补丁验证失败");
  const changes=[["loader",p.loader],["dll",p.dll],["library",paths.library],["response",paths.response],
    ["state",paths.state]];
  const backup=backupEntries(changes,paths);
  assert(sha(fs.readFileSync(p.loader))===sha(oldLoader) && sha(fs.readFileSync(p.dll))===sha(oldDll),
    "备份时 WeGame 组件发生变化，已停止写入");
  const state={version:1,root:p.root,loaderSha256:sha(newLoader),dllSha256:sha(newDll),
    backup:before.status==="installed"?before.backup:backup.folder,lastApplyBackup:backup.folder,
    appliedAt:new Date().toISOString(),messageCount:scheme.messages.length,
    librarySha256:sha(output.library),responseSha256:sha(output.response)};
  try {
    if (before.status!=="installed") { atomicWrite(p.loader,newLoader); atomicWrite(p.dll,newDll); }
    atomicWrite(paths.library,output.library);
    atomicWrite(paths.response,output.response);
    atomicWrite(paths.state,Buffer.from(JSON.stringify(state,null,2)));
    assert(sha(fs.readFileSync(p.loader))===state.loaderSha256 && sha(fs.readFileSync(p.dll))===state.dllSha256 &&
      sha(fs.readFileSync(paths.library))===state.librarySha256 && sha(fs.readFileSync(paths.response))===state.responseSha256,
    "写入后校验失败");
    return {status:"installed",backup:backup.folder,messageCount:scheme.messages.length,groupCount:output.groupCount,
      libraryBytes:output.libraryBytes,gameVerified:false};
  } catch (error) {
    try { restoreEntries(backup); }
    catch (restoreError) { throw new Error(`应用失败，自动恢复也失败：${error.message}；请从 ${backup.folder} 手动恢复：${restoreError.message}`); }
    throw new Error(`应用失败，已从备份恢复：${error.message}`);
  }
}
function restore(root, paths = dataPaths(), options={}) {
  if (!options.skipProcessCheck) assertStopped();
  const before=inspect(root,paths);
  assert(before.status==="installed","只有本工具安装且哈希匹配的组件才允许一键还原");
  const backupPath=before.backup;
  assert(backupPath && samePath(path.dirname(backupPath),paths.backups),"还原备份路径无效");
  for(const location of [paths.data,paths.backups,backupPath,pathsForWeGame(root).loader,pathsForWeGame(root).dll])
    assertNoLinks(location);
  const record=jsonFile(path.join(backupPath,"manifest.json"));
  assert(record.version===1 && Array.isArray(record.entries) && record.entries.length===5,"备份清单无效");
  const original={folder:backupPath,manifest:record.entries};
  const expected=[["loader",pathsForWeGame(root).loader],["dll",pathsForWeGame(root).dll],
    ["library",paths.library],["response",paths.response],["state",paths.state]];
  record.entries.forEach((entry,index)=>{
    assert(entry.name===expected[index][0] && samePath(entry.file,expected[index][1]) &&
      entry.backup===(entry.existed?`${index}.bak`:null) &&
      (entry.existed? /^[a-f0-9]{64}$/.test(entry.sha256):entry.sha256===null),
    "备份清单目标或哈希无效");
  });
  const safety=backupEntries([["loader",record.entries[0].file],["dll",record.entries[1].file],
    ["library",paths.library],["response",paths.response],["state",paths.state]],paths);
  try { restoreEntries(original); return {status:"restored",safetyBackup:safety.folder}; }
  catch(error) { restoreEntries(safety); throw new Error(`还原失败，当前安装已恢复：${error.message}`); }
}
module.exports={sha,validateScheme,compile,defaultScheme,fromLegacy,expandDelta,patchLoader,dataPaths,
  readDraft,saveDraft,pathsForWeGame,findWeGame,inspect,apply,restore,STOCK_DLL,WORKING_DLL,PORTABLE_DLL,
  STOCK_LOADER,WORKING_LOADER};
