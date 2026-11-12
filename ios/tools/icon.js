// The Haltewekker icon: an "H" (for halte) drawn as a piece of the metro map: the blue line, the orange 306 and
// a yellow line between them, white interchanges, on the station's navy tiled wall with a pink neon border,
// a little grime, and the smiley sticker someone stuck on it.
function drawIcon(x,S,opt){opt=opt||{};const k=S/1024;x.save();x.scale(k,k);let sd=9;const rnd=()=>{sd=(sd*16807)%2147483647;return sd/2147483647;};
  // the wall
  const bg=x.createLinearGradient(0,0,0,1024);bg.addColorStop(0,'#243872');bg.addColorStop(1,'#121a3d');x.fillStyle=bg;x.fillRect(0,0,1024,1024);
  const T=128;for(let i=0;i<=8;i++){x.fillStyle='rgba(0,0,0,.22)';x.fillRect(i*T-3,0,6,1024);x.fillRect(0,i*T-3,1024,6);x.fillStyle='rgba(255,255,255,.05)';x.fillRect(i*T+3,0,3,1024);x.fillRect(0,i*T+3,1024,3);}
  for(let i=0;i<8;i++)for(let j=0;j<8;j++){x.fillStyle=`rgba(255,255,255,${rnd()*.035})`;x.fillRect(i*T+6,j*T+6,T-9,T-9);}
  // pink light from the neon on the wall
  const pg=x.createRadialGradient(512,512,250,512,512,640);pg.addColorStop(0,'rgba(255,61,158,0)');pg.addColorStop(1,'rgba(255,61,158,.16)');x.fillStyle=pg;x.fillRect(0,0,1024,1024);
  // the neon border
  const rr=(i,r)=>{x.beginPath();x.roundRect(i,i,1024-2*i,1024-2*i,r);};
  x.save();x.lineJoin='round';x.strokeStyle='#ff3d9e';x.shadowColor='#ff3d9e';x.shadowBlur=46;x.lineWidth=20;rr(84,150);x.stroke();x.shadowBlur=18;x.lineWidth=14;rr(84,150);x.stroke();
  x.shadowBlur=0;x.strokeStyle='#ffd6ec';x.lineWidth=6;rr(84,150);x.stroke();x.restore();
  // the H: two lines and the one between them, with a dark edge like on the map
  const L=330,R=694,TOP=268,BOT=756,MID=512,W=118;
  const seg=(x0,y0,x1,y1,c)=>{x.lineCap='round';x.strokeStyle='rgba(8,12,30,.9)';x.lineWidth=W+26;x.beginPath();x.moveTo(x0,y0);x.lineTo(x1,y1);x.stroke();x.strokeStyle=c;x.lineWidth=W;x.beginPath();x.moveTo(x0,y0);x.lineTo(x1,y1);x.stroke();};
  x.save();x.shadowColor='rgba(0,0,0,.45)';x.shadowBlur=30;x.shadowOffsetY=14;
  seg(L,MID,R,MID,'#F0D722');seg(L,TOP,L,BOT,'#3F86DC');seg(R,TOP,R,BOT,'#EC7A2E');x.restore();
  // a highlight down each line, like enamel
  x.lineCap='round';x.strokeStyle='rgba(255,255,255,.16)';x.lineWidth=20;[[L-30,TOP+10,L-30,BOT-10],[R-30,TOP+10,R-30,BOT-10]].forEach(([a,b,c,d])=>{x.beginPath();x.moveTo(a,b);x.lineTo(c,d);x.stroke();});
  // the two interchanges
  [[L,MID],[R,MID]].forEach(([a,b])=>{x.save();x.shadowColor='rgba(0,0,0,.4)';x.shadowBlur=18;x.shadowOffsetY=8;x.fillStyle='#fff';x.beginPath();x.arc(a,b,84,0,7);x.fill();x.restore();
    x.strokeStyle='#0c1430';x.lineWidth=24;x.beginPath();x.arc(a,b,72,0,7);x.stroke();});
  // grime: soft stains towards the edges, dust, a scuff
  for(let i=0;i<26;i++){const a=rnd()*6.283,d=380+rnd()*240,cx=512+Math.cos(a)*d,cy=512+Math.sin(a)*d,r=60+rnd()*140,g=x.createRadialGradient(cx,cy,0,cx,cy,r);g.addColorStop(0,`rgba(30,22,14,${.08+rnd()*.1})`);g.addColorStop(1,'rgba(30,22,14,0)');x.fillStyle=g;x.fillRect(cx-r,cy-r,2*r,2*r);}
  for(let i=0;i<1400;i++){x.fillStyle=`rgba(${rnd()<.5?'255,255,255':'20,14,8'},${rnd()*.09})`;const s=1+rnd()*3;x.fillRect(rnd()*1024,rnd()*1024,s,s);}
  for(let i=0;i<5;i++){x.strokeStyle=`rgba(255,255,255,${.05+rnd()*.06})`;x.lineWidth=2+rnd()*2;const sx=rnd()*1024,sy=rnd()*1024,a=rnd()*3;x.beginPath();x.moveTo(sx,sy);x.lineTo(sx+Math.cos(a)*140,sy+Math.sin(a)*140);x.stroke();}
  // the sticker, slapped on the corner over the neon
  if(!opt.noSticker){x.save();x.translate(836,196);x.rotate(.3);x.scale(.86,.86);x.shadowColor='rgba(0,0,0,.45)';x.shadowBlur=20;x.shadowOffsetY=8;x.fillStyle='#f4f1e8';x.beginPath();x.arc(0,0,104,0,7);x.fill();x.shadowColor='transparent';
    x.fillStyle='#f6d02e';x.beginPath();x.arc(0,0,92,0,7);x.fill();x.fillStyle='#1d1d1b';x.beginPath();x.arc(-26,-18,13,0,7);x.arc(26,-18,13,0,7);x.fill();
    x.lineWidth=14;x.lineCap='round';x.strokeStyle='#1d1d1b';x.beginPath();x.arc(0,4,48,.35,2.79);x.stroke();
    x.fillStyle='rgba(255,255,255,.22)';x.beginPath();x.ellipse(-40,-50,30,14,-.6,0,7);x.fill();x.restore();}
  // a soft vignette
  const vg=x.createRadialGradient(512,512,420,512,512,760);vg.addColorStop(0,'rgba(0,0,0,0)');vg.addColorStop(1,'rgba(0,0,0,.35)');x.fillStyle=vg;x.fillRect(0,0,1024,1024);
  x.restore();}
if(typeof module!=='undefined') module.exports=drawIcon;
