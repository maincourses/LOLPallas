"use strict";

const {app,BrowserWindow,ipcMain,dialog} = require("electron");
const fs=require("node:fs");
const path=require("node:path");
const core=require("./core");

let window=null;
const single=app.requestSingleInstanceLock();
if (!single) app.quit();
else {
  app.on("second-instance",()=>{ if(window){ if(window.isMinimized())window.restore(); window.focus(); } });
  app.whenReady().then(()=>{
    window=new BrowserWindow({width:1320,height:880,minWidth:900,minHeight:680,show:false,
      backgroundColor:"#e9eef2",title:"LoL 快捷喊话工作台",autoHideMenuBar:true,
      webPreferences:{preload:path.join(__dirname,"preload.js"),nodeIntegration:false,contextIsolation:true,sandbox:true}});
    window.webContents.setWindowOpenHandler(()=>({action:"deny"}));
    window.webContents.on("will-navigate",event=>event.preventDefault());
    window.loadFile(path.join(__dirname,"..","web","banks10.html"));
    window.once("ready-to-show",()=>window.show());
  });
  app.on("window-all-closed",()=>app.quit());
}

function own(event){ if(!window || event.sender!==window.webContents) throw new Error("调用来源无效"); }
function settingsFile(){return path.join(core.dataPaths().data,"settings.json");}
function readRoot(){
  try {const saved=JSON.parse(fs.readFileSync(settingsFile(),"utf8")); return core.findWeGame(saved.weGameRoot);}
  catch {return core.findWeGame();}
}
function saveRoot(root){
  const file=settingsFile(); fs.mkdirSync(path.dirname(file),{recursive:true});
  fs.writeFileSync(file,JSON.stringify({weGameRoot:root},null,2));
}
ipcMain.handle("lps:load",event=>{
  own(event);
  const draft=core.readDraft(); const root=readRoot();
  let install=null;
  if(root){try{install=core.inspect(root);}catch(error){install={status:"error",message:error.message};}}
  return {...draft,root,install,libraryBytes:core.compile(draft.scheme).libraryBytes};
});
ipcMain.handle("lps:save",(event,scheme,revision)=>{own(event);return core.saveDraft(scheme,revision);});
ipcMain.handle("lps:choose",async event=>{
  own(event);
  const result=await dialog.showOpenDialog(window,{title:"选择 WeGame 安装目录（包含 apps\\Pallas）",
    properties:["openDirectory"]});
  if(result.canceled)return null;
  const root=core.pathsForWeGame(result.filePaths[0]).root;
  const install=core.inspect(root);
  saveRoot(root);
  return {root,install};
});
ipcMain.handle("lps:detect",event=>{
  own(event);const root=core.findWeGame();
  if(!root)return {root:"",install:{status:"missing",message:"没有自动找到 WeGame，请手动选择安装目录"}};
  const install=core.inspect(root);saveRoot(root);return {root,install};
});
ipcMain.handle("lps:inspect",(event,root)=>{own(event);return core.inspect(root);});
ipcMain.handle("lps:apply",(event,root,scheme)=>{
  own(event);const result=core.apply(root,scheme);saveRoot(root);return result;
});
ipcMain.handle("lps:restore",(event,root)=>{own(event);return core.restore(root);});
ipcMain.handle("lps:quit",event=>{own(event);app.quit();});
