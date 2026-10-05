"use strict";
// Real Electron renderer and IPC smoke test through Chromium DevTools protocol.
// No game or WeGame files are written; test data lives in a fresh temp profile.
const fs=require("node:fs");
const os=require("node:os");
const path=require("node:path");
const {spawn}=require("node:child_process");
const {chromium}=require("playwright-core");

async function main(){
  const root=path.resolve(__dirname,"../..");
  const scratch=fs.mkdtempSync(path.join(os.tmpdir(),"LPS-UI-"));
  const port=19433;
  const electron=require("electron");
  const target=process.argv.includes("--asar")?path.join(root,"dist","win-unpacked","resources","app.asar"):".";
  const child=spawn(electron,[`--remote-debugging-port=${port}`,`--user-data-dir=${path.join(scratch,"electron-profile")}`,target],{
    cwd:root,env:{...process.env,LPS_TEST_DATA_ROOT:scratch},windowsHide:true,stdio:"ignore"});
  let browser;
  try{
    for(let attempt=0;attempt<60;attempt++){
      try{browser=await chromium.connectOverCDP(`http://127.0.0.1:${port}`,{timeout:1000});break;}
      catch{await new Promise(resolve=>setTimeout(resolve,250));}
    }
    if(!browser)throw new Error("Electron CDP did not start");
    const context=browser.contexts()[0];
    let page;
    for(let attempt=0;attempt<40;attempt++){
      page=context.pages().find(p=>p.url().endsWith("banks10.html"));
      if(page)break;await new Promise(resolve=>setTimeout(resolve,250));
    }
    if(!page)throw new Error("Editor page did not load");
    await page.locator("#saveState").filter({hasText:"草稿已保存"}).waitFor();
    if((await page.locator(".bank-button").count())!==2)throw new Error("Fresh profile must start with 2 groups");
    if((await page.locator("#addHint").innerText())!=="20 / 80 条")throw new Error("Fresh profile must have 20 messages");
    fs.mkdirSync(path.join(root,"build","qa"),{recursive:true});
    await page.screenshot({path:path.join(root,"build","qa","fresh-20.png"),fullPage:true});
    await page.locator("#addMessage").click();
    if((await page.locator("#addHint").innerText())!=="21 / 80 条")throw new Error("Add did not increment count");
    if((await page.locator(".bank-button").count())!==3)throw new Error("21st message did not create bank 3");
    if((await page.locator("#keyChip").innerText())!=="~ + 1")throw new Error("21st message key mapping incorrect");
    await page.locator("#messageBody").fill("第21条测试：真正进入下一组。");
    await page.screenshot({path:path.join(root,"build","qa","added-21.png"),fullPage:true});
    page.once("dialog",dialog=>dialog.accept());
    await page.locator("#deleteMessage").click();
    if((await page.locator("#addHint").innerText())!=="20 / 80 条")throw new Error("Delete did not decrement count");
    if((await page.locator(".bank-button").count())!==2)throw new Error("Empty bank was not removed");
    for(let i=0;i<60;i++)await page.locator("#addMessage").click();
    if((await page.locator("#addHint").innerText())!=="80 / 80 条")throw new Error("80-message upper bound failed");
    if(!(await page.locator("#addMessage").isDisabled()))throw new Error("Add must disable at 80");
    await page.locator("#saveDraft").click();
    await page.locator("#saveState").filter({hasText:"草稿已保存"}).waitFor();
    const draft=JSON.parse(fs.readFileSync(path.join(scratch,"LPS","messages.json"),"utf8"));
    if(draft.messages.length!==80)throw new Error("Saved draft is incomplete");
    console.log("Electron UI/IPC: 20 → 21 → 20 → 80, save draft OK");
  }finally{
    if(browser)await browser.close().catch(()=>{});
    child.kill();
    await new Promise(resolve=>setTimeout(resolve,400));
    if(scratch.startsWith(os.tmpdir()+path.sep)&&path.basename(scratch).startsWith("LPS-UI-"))
      fs.rmSync(scratch,{recursive:true,force:true});
  }
}
main().catch(error=>{console.error(error);process.exitCode=1;});
