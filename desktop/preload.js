"use strict";
const {contextBridge,ipcRenderer}=require("electron");
contextBridge.exposeInMainWorld("lps",Object.freeze({
  load:()=>ipcRenderer.invoke("lps:load"),
  save:(scheme,revision)=>ipcRenderer.invoke("lps:save",scheme,revision),
  choose:()=>ipcRenderer.invoke("lps:choose"),
  detect:()=>ipcRenderer.invoke("lps:detect"),
  inspect:root=>ipcRenderer.invoke("lps:inspect",root),
  apply:(root,scheme)=>ipcRenderer.invoke("lps:apply",root,scheme),
  restore:root=>ipcRenderer.invoke("lps:restore",root),
  quit:()=>ipcRenderer.invoke("lps:quit")
}));
