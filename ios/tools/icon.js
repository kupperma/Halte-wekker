// The Haltewekker icon ("Night line"): one line of the metro map on map paper, with the yellow glow of your route,
// bending up like the Berlin map to your stop: a big white station with the alarm bell in it, ringing.
function drawIcon(x,S){x.save();x.scale(S/1024,S/1024);

  x.fillStyle='#f6f3ea';x.fillRect(0,0,1024,1024);let sd=3;const rnd=()=>{sd=(sd*16807)%2147483647;return sd/2147483647;};
  for(let i=0;i<2600;i++){x.fillStyle=`rgba(80,70,50,${rnd()*.07})`;x.fillRect(rnd()*1024,rnd()*1024,2,2);}
  const SX=620,SY=400,path=()=>{x.beginPath();x.moveTo(-60,820);x.lineTo(300,820);x.lineTo(SX,500);x.lineTo(SX,SY);};
  x.lineCap='butt';x.lineJoin='round';
  x.strokeStyle='rgba(244,197,66,.55)';x.lineWidth=230;path();x.stroke();             // the yellow glow of "your route"
  x.strokeStyle='#1d2c5a';x.lineWidth=120;path();x.stroke();
  // two stops on the way (ticks, like the Berlin map)
  x.strokeStyle='#1d2c5a';x.lineWidth=34;x.lineCap='butt';const q=Math.SQRT1_2;
  [[150,820,0,1],[420,700,q,q],[520,600,q,q]].forEach(([a,b,dx,dy])=>{x.beginPath();x.moveTo(a,b);x.lineTo(a+dx*100,b+dy*100);x.stroke();});
  // your stop: a big white station with a thick ring and the alarm bell in it, ringing
  x.save();x.shadowColor='rgba(0,0,0,.18)';x.shadowBlur=24;x.shadowOffsetY=10;x.fillStyle='#fff';x.beginPath();x.arc(SX,SY,160,0,7);x.fill();x.restore();
  x.strokeStyle='#1d2c5a';x.lineWidth=46;x.beginPath();x.arc(SX,SY,137,0,7);x.stroke();
  x.fillStyle='#e8762c';x.beginPath();x.moveTo(SX-62,SY+44);x.quadraticCurveTo(SX-58,SY-70,SX,SY-76);x.quadraticCurveTo(SX+58,SY-70,SX+62,SY+44);x.lineTo(SX+80,SY+66);x.lineTo(SX-80,SY+66);x.closePath();x.fill();
  x.beginPath();x.arc(SX,SY+86,24,0,7);x.fill();x.beginPath();x.arc(SX,SY-84,14,0,7);x.fill();
  x.strokeStyle='#e8762c';x.lineWidth=22;x.lineCap='round';
  [[1.13,1.33],[-.33,-.13]].forEach(([a0,a1])=>{x.beginPath();x.arc(SX,SY,214,a0*Math.PI,a1*Math.PI);x.stroke();});
  [[1.17,1.29],[-.29,-.17]].forEach(([a0,a1])=>{x.beginPath();x.arc(SX,SY,262,a0*Math.PI,a1*Math.PI);x.stroke();});
  x.restore();}
if(typeof module!=='undefined') module.exports=drawIcon;
