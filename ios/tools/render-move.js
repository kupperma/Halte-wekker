const {chromium}=require('playwright');const fs=require('fs');
(async()=>{const S=process.argv[2],mode=process.argv[3]||'peek';
const b=await chromium.launch({args:['--use-gl=swiftshader','--enable-webgl','--ignore-gpu-blocklist']});
const pg=await b.newPage({viewport:{width:540,height:1170}});pg.on('pageerror',e=>console.log('PAGE ERROR',e.message));
await pg.goto('file://'+S+'/stage/stage.html');await pg.waitForFunction(()=>window.ready,null,{timeout:60000});await pg.evaluate(()=>document.fonts.ready);await pg.waitForTimeout(600);
console.log(JSON.stringify(await pg.evaluate(()=>window.posterRect())));
if(mode==='peek'){for(const u of [0,.35,.7,1]){const d=await pg.evaluate(([u])=>window.renderMove(u,0),[u]);fs.writeFileSync(`${S}/stage/peek-${u}.jpg`,Buffer.from(d.split(',')[1],'base64'));}}
else{const n=+process.argv[4]||48;for(const [name,mix] of [['out',0],['home',1]]){fs.mkdirSync(`${S}/stage/${name}`,{recursive:true});
  for(let i=0;i<n;i++){const d=await pg.evaluate(([u,m])=>window.renderMove(u,m),[i/(n-1),mix]);fs.writeFileSync(`${S}/stage/${name}/f${String(i).padStart(3,'0')}.jpg`,Buffer.from(d.split(',')[1],'base64'));}
  console.log(name,'done');}}
await b.close();})();
