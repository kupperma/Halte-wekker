const {chromium}=require('playwright');const fs=require('fs');
(async()=>{const dir=process.argv[2];const b=await chromium.launch();const pg=await b.newPage();
await pg.addScriptTag({path:dir+'/draw.js'});
const out=await pg.evaluate(()=>{const mk=(S,o)=>{const c=document.createElement('canvas');c.width=c.height=S;drawIcon(c.getContext('2d'),S,o);return c.toDataURL('image/png');};
  return {big:mk(1024),s512:mk(512),s192:mk(192),s180:mk(180),s32:mk(32,{noSticker:true})};});
for(const [n,d] of Object.entries(out)) fs.writeFileSync(`${dir}/${n}.png`,Buffer.from(d.split(',')[1],'base64'));
await b.close();})();
