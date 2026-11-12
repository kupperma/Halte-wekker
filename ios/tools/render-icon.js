const {chromium}=require('playwright');const fs=require('fs');
// node render-icon.js <folder>: with icon.js in <folder>, writes the app icon and the website sizes there.
(async()=>{const dir=process.argv[2];const b=await chromium.launch();const pg=await b.newPage();
await pg.addScriptTag({path:dir+'/icon.js'});
const out=await pg.evaluate(()=>{const r={};for(const s of [1024,512,192,180,32]){const c=document.createElement('canvas');c.width=c.height=s;drawIcon(c.getContext('2d'),s);r['icon-'+s]=c.toDataURL('image/png');}return r;});
for(const [n,d] of Object.entries(out)) fs.writeFileSync(`${dir}/${n}.png`,Buffer.from(d.split(',')[1],'base64'));
await b.close();})();
