"use strict";
const fs=require("node:fs");
const path=require("node:path");
const sharp=require("sharp");
const pngToIco=require("png-to-ico").default;
const root=path.resolve(__dirname,"..");
async function main(){
  const source=path.join(root,"desktop","assets","icon.svg");
  const png=path.join(root,"build","icon-256.png");
  const ico=path.join(root,"desktop","assets","icon.ico");
  fs.mkdirSync(path.dirname(png),{recursive:true});
  await sharp(source).resize(256,256).png().toFile(png);
  fs.writeFileSync(ico,await pngToIco(png));
  console.log(`Created ${ico}`);
}
main().catch(error=>{console.error(error);process.exitCode=1;});
