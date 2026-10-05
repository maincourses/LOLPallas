"use strict";

const $=id=>document.getElementById(id);
const keys=["1","2","3","4","5","6","7","8","9","0"];
const state={scheme:null,group:0,selected:0,query:"",dirty:false,busy:false,revision:"",source:"",
  root:"",install:null};
let toastTimer;

function errorText(error){return error?.message || String(error);}
function toast(text,error=false){
  const box=$("toast");box.textContent=text;box.classList.toggle("error",error);box.classList.add("show");
  clearTimeout(toastTimer);toastTimer=setTimeout(()=>box.classList.remove("show"),error?9000:4000);
}
function count(){return state.scheme.messages.length;}
function groups(){return Math.ceil(count()/10);}
function label(index){return `第 ${Math.floor(index/10)+1} 组 · 第 ${index%10+1} 条`;}
function libraryBytes(){
  const data={};for(let i=0;i<80;i++)data[String(i)]=state.scheme.messages[i]||"";
  data.title=state.scheme.title;data.key=1;
  return new TextEncoder().encode(JSON.stringify(data)).length;
}
function problem(){
  if(!state.scheme)return "文案尚未加载";
  if(!state.scheme.title.trim()||/[\x00-\x1f\x7f]/.test(state.scheme.title))return "方案名称不能为空或含控制字符";
  if(count()<20||count()>80)return "消息必须为 20～80 条";
  for(let i=0;i<count();i++){
    const text=state.scheme.messages[i];
    if(typeof text!=="string"||!text.trim()||/[\x00-\x1f\x7f]/.test(text))return `第 ${i+1} 条不能为空或含换行`;
  }
  if(libraryBytes()>65536)return "整套文案超过 65,536 字节";
  return "";
}
function renderBanks(){
  const nav=$("banks");nav.replaceChildren();
  $("bankSummary").textContent=`${groups()} 组 · 每组 10 条`;
  for(let bank=0;bank<groups();bank++){
    const button=document.createElement("button");button.type="button";
    button.className=`bank-button${state.group===bank&&!state.query?" active":""}`;
    button.setAttribute("aria-current",state.group===bank&&!state.query?"true":"false");
    const number=document.createElement("span");number.className="bank-number";number.textContent=String(bank+1).padStart(2,"0");
    const name=document.createElement("span");name.className="bank-name";name.textContent=`第 ${bank+1} 组`;
    const range=document.createElement("span");range.className="bank-range";
    range.textContent=`${bank*10+1}–${Math.min(count(),bank*10+10)}`;
    button.append(number,name,range);
    button.addEventListener("click",()=>{
      state.group=bank;state.query="";$("search").value="";state.selected=bank*10;render();
    });
    nav.append(button);
  }
}
function renderList(){
  const list=$("messageList");list.replaceChildren();
  const matches=[];
  for(let i=0;i<count();i++){
    if(state.query){if(state.scheme.messages[i].toLocaleLowerCase().includes(state.query.toLocaleLowerCase())||
      String(i+1).includes(state.query))matches.push(i);}
    else if(Math.floor(i/10)===state.group)matches.push(i);
  }
  $("listTitle").textContent=state.query?"搜索结果":`第 ${state.group+1} 组`;
  $("listCount").textContent=`${matches.length} 条`;
  if(!matches.length){const empty=document.createElement("div");empty.className="empty-result";
    empty.textContent="没有找到匹配的文案";list.append(empty);}
  for(const i of matches){
    const row=document.createElement("button");row.type="button";
    row.className=`message-row${i===state.selected?" active":""}`;
    row.setAttribute("role","option");row.setAttribute("aria-selected",String(i===state.selected));row.title=label(i);
    const key=document.createElement("span");key.className="row-key";key.textContent=keys[i%10];
    const preview=document.createElement("span");preview.className="row-text";preview.textContent=state.scheme.messages[i];
    const length=document.createElement("span");length.className="row-length";length.textContent=`${state.scheme.messages[i].length} 字`;
    row.append(key,preview,length);
    row.addEventListener("click",()=>{state.selected=i;renderList();renderEditor();});list.append(row);
  }
}
function renderEditor(){
  const i=state.selected;
  $("editTitle").textContent=label(i);$("keyChip").textContent=`~ + ${keys[i%10]}`;
  $("messageBody").value=state.scheme.messages[i];
  $("charCount").textContent=`${state.scheme.messages[i].length} 个 UTF-16 单位`;
  $("deleteMessage").disabled=state.busy||count()<=20;
}
function renderInstall(){
  $("weGameRoot").textContent=state.root||"尚未选择 WeGame 安装目录";
  $("weGameRoot").title=state.root;
  $("installStatus").textContent=state.install?.message||"请先选择安装目录";
  $("installStatus").classList.toggle("bad",!state.install||!["ready","installed"].includes(state.install.status));
  $("restoreComponents").disabled=state.busy||state.install?.status!=="installed";
}
function renderMeta(){
  const issue=problem(),bytes=libraryBytes();
  $("librarySize").textContent=`${bytes.toLocaleString()} / 65,536 字节${state.dirty?" · 估算":""}`;
  $("capacityMeter").style.width=`${Math.min(100,bytes/65536*100)}%`;
  $("capacityMeter").classList.toggle("danger",Boolean(issue));
  $("dirtyDot").className=`dirty-dot${issue?" error":state.dirty?" dirty":""}`;
  $("saveState").textContent=issue||(state.dirty?"有未保存修改":"草稿已保存 / 可继续编辑");
  $("detailState").textContent=issue?"修正后才能保存":`${count()} 条 · ${groups()} 组 · 保存草稿不影响当前对局`;
  $("sourceBadge").textContent=state.source==="legacy-import"?"已导入旧版文案":
    state.source==="default"?"新方案 · 初始 20 条":"本地草稿";
  $("saveDraft").disabled=state.busy||Boolean(issue);
  $("saveApply").disabled=state.busy||Boolean(issue)||!["ready","installed"].includes(state.install?.status);
  $("schemeTitle").disabled=state.busy;$("messageBody").disabled=state.busy;
  $("addMessage").disabled=state.busy||count()>=80;
  $("addHint").textContent=`${count()} / 80 条`;
  $("deleteMessage").disabled=state.busy||count()<=20;
  $("chooseRoot").disabled=state.busy;$("autoDetect").disabled=state.busy;
  renderInstall();
}
function render(){
  if(!state.scheme)return;
  state.selected=Math.min(state.selected,count()-1);state.group=Math.min(state.group,groups()-1);
  renderBanks();renderList();renderEditor();$("schemeTitle").value=state.scheme.title;renderMeta();
}
function setBusy(value){state.busy=value;if(state.scheme)renderMeta();}
async function save(){
  const issue=problem();if(issue)throw new Error(issue);
  const result=await window.lps.save(state.scheme,state.revision);
  state.revision=result.revision;state.source="draft";state.dirty=false;renderMeta();
  toast("草稿已保存。当前对局不会自动更新。");
  return result;
}
async function refreshInstall(){
  if(!state.root)return;
  try{state.install=await window.lps.inspect(state.root);}catch(error){state.install={status:"error",message:errorText(error)};}
  renderMeta();
}
$("search").addEventListener("input",event=>{
  state.query=event.target.value.trim();if(state.scheme){renderBanks();renderList();}
});
$("schemeTitle").addEventListener("input",event=>{
  if(!state.scheme)return;state.scheme.title=event.target.value;state.dirty=true;renderMeta();
});
$("messageBody").addEventListener("input",event=>{
  if(!state.scheme)return;
  state.scheme.messages[state.selected]=event.target.value;state.dirty=true;
  $("charCount").textContent=`${event.target.value.length} 个 UTF-16 单位`;
  renderList();renderMeta();
});
$("addMessage").addEventListener("click",()=>{
  if(state.busy||count()>=80)return;
  const next=count();state.scheme.messages.push(`新消息 ${next+1}`);
  state.selected=next;state.group=Math.floor(next/10);state.query="";$("search").value="";
  state.dirty=true;render();$("messageBody").focus();$("messageBody").select();
});
$("deleteMessage").addEventListener("click",()=>{
  if(state.busy||count()<=20)return;
  const index=state.selected;
  if(!window.confirm(`删除第 ${index+1} 条？后续消息会顺序前移，键位也会随之变化。`))return;
  state.scheme.messages.splice(index,1);state.selected=Math.min(index,count()-1);
  state.group=Math.floor(state.selected/10);state.query="";$("search").value="";
  state.dirty=true;render();toast("已删除。保存前仍可关闭工作台放弃修改。");
});
$("chooseRoot").addEventListener("click",async()=>{
  try{const result=await window.lps.choose();if(!result)return;
    state.root=result.root;state.install=result.install;renderMeta();}
  catch(error){toast(errorText(error),true);}
});
$("autoDetect").addEventListener("click",async()=>{
  try{const result=await window.lps.detect();state.root=result.root;state.install=result.install;renderMeta();}
  catch(error){toast(errorText(error),true);}
});
$("saveDraft").addEventListener("click",async()=>{
  setBusy(true);try{await save();}catch(error){toast(errorText(error),true);}finally{setBusy(false);}
});
$("saveApply").addEventListener("click",()=>{
  if(problem())return toast(problem(),true);$("applyDialog").showModal();
});
$("cancelApply").addEventListener("click",()=>$("applyDialog").close());
$("confirmApply").addEventListener("click",async()=>{
  $("applyDialog").close();setBusy(true);
  try{
    await save();
    const result=await window.lps.apply(state.root,state.scheme);
    await refreshInstall();
    toast(`已应用 ${result.messageCount} 条、${result.groupCount} 组。备份：${result.backup}。请重启 WeGame 并进入新的一局。`);
  }catch(error){toast(errorText(error),true);}finally{setBusy(false);}
});
$("restoreComponents").addEventListener("click",async()=>{
  if(!window.confirm("还原到首次安装本工具前的组件与文案？当前已应用文案会先另存安全备份。请确保游戏与 WeGame 均已退出。"))return;
  setBusy(true);
  try{const result=await window.lps.restore(state.root);await refreshInstall();
    toast(`已还原，操作前的安全备份：${result.safetyBackup}`);}
  catch(error){toast(errorText(error),true);}finally{setBusy(false);}
});
$("closeServer").addEventListener("click",()=>{
  if(state.dirty&&!window.confirm("还有未保存修改。仍要退出？"))return;
  state.dirty=false;window.lps.quit();
});
window.addEventListener("beforeunload",event=>{if(state.dirty){event.preventDefault();event.returnValue="";}});
window.addEventListener("keydown",event=>{
  if((event.ctrlKey||event.metaKey)&&event.key.toLowerCase()==="s"){
    event.preventDefault();if(!state.busy&&state.scheme)$("saveDraft").click();
  }
});
window.lps.load().then(result=>{
  state.scheme=result.scheme;state.revision=result.revision;state.source=result.source;
  state.root=result.root;state.install=result.install;render();
  if(result.source==="legacy-import")toast("已读取原有 80 条文案；保存草稿后再应用，原文件未被修改。");
}).catch(error=>{
  $("saveState").textContent="读取失败";$("detailState").textContent=errorText(error);toast(errorText(error),true);
});
