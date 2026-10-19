(() => {
  'use strict';
  const $=id=>document.getElementById(id);
  const pages=['login','remote','apps','keyboard','mouse','screen'];
  let active='login', paired=false, busy=false, healthTimer, toastTimer;
  let scrollQueued=0, scrollBusy=false, mouseX=0, mouseY=0, mouseActive=false;
  let dragState=false, longTimer=null, mouseMoveTimer=null, mousePendingX=0,mousePendingY=0,mouseSending=false;
  const pointers=new Map();
  function toast(message) {const el=$('toast');el.textContent=message;el.classList.remove('hidden');clearTimeout(toastTimer);toastTimer=setTimeout(()=>el.classList.add('hidden'),2600);}
  function status(connected,message) {const el=$('statusBadge');el.classList.toggle('online',connected);el.classList.toggle('offline',!connected);$('statusLabel').textContent=message || (connected?'X96 · в сети':'Нет связи');}
  async function fetchJSON(path,options={}) {
    const controller=new AbortController();const timeout=setTimeout(()=>controller.abort(),5000);
    try {
      const result=await fetch(path,{credentials:'same-origin',cache:'no-store',...options,signal:controller.signal});
      const data=await result.json().catch(()=>({ok:false,error:'Плохой ответ приставки'}));
      if(result.status===401 && path!='/api/pair') { paired=false;show('login');status(false,'Нужен PIN'); }
      if(!result.ok||data.ok!==true) throw Error(data.error||`HTTP ${result.status}`);
      return data;
    } finally {clearTimeout(timeout);}
  }
  async function send(cmd,values={},quiet=false){
    if(!paired) return null;
    try {
      const result=await fetchJSON('/api/command',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({cmd,...values})});
      status(true,'X96 · в сети'); return result;
    } catch(e) {if(!quiet){toast(e.message);status(false,'Ошибка команды');}return null;}
  }
  const key=code=>send('key',{code:Number(code)});
  function show(page) {
    if(page!=='screen') window.PultVideo?.stop();
    if(page==='mouse' && active!=='mouse') resetMouse();
    active=page;
    pages.forEach(p=>$(p+'Page').classList.toggle('hidden',p!==page));
    if(page==='screen') startVideo();
    if(page==='apps') loadApps();
    if(page!=='mouse') flushMouse();
  }
  async function checkHealth() {
    try {const info=await fetchJSON('/api/status');paired=info.paired;status(info.paired,info.paired?'X96 · в сети':'Введите PIN');
      if(!paired && active!=='login')show('login');
      else if(paired && active==='login')show('remote');
      if(active==='screen'&&!info.sharing)$('videoInfo').textContent='На приставке включите трансляцию экрана';
    }catch(e){status(false,'Нет связи с приставкой');}
  }
  $('hostName').textContent=location.host;
  $('pairForm').addEventListener('submit',async e=>{
    e.preventDefault();if(busy)return;
    const pin=$('pin').value.trim();if(!/^\d{6}$/.test(pin))return;
    busy=true;const button=e.submitter;button.disabled=true;$('loginError').textContent='';
    try {await fetchJSON('/api/pair',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({pin})});
      paired=true;$('pin').value='';status(true,'X96 · в сети');show('remote');
    }catch(err){$('loginError').textContent=err.message;}
    finally{busy=false;button.disabled=false;}
  });
  $('logout').addEventListener('click',async()=>{try{await fetchJSON('/api/logout',{method:'POST',headers:{'Content-Type':'application/json'},body:'{}'});}catch(_){}paired=false;show('login');status(false,'Нужен PIN');});
  document.querySelectorAll('[data-key]').forEach(b=>b.addEventListener('click',()=>key(b.dataset.key)));
  document.querySelectorAll('[data-cmd]').forEach(b=>b.addEventListener('click',()=>{
    const cmd=b.dataset.cmd;
    if(cmd==='scroll-up')send('screen_swipe',{x1:.5,y1:.3,x2:.5,y2:.82,duration:250});
    else if(cmd==='scroll-down')send('screen_swipe',{x1:.5,y1:.8,x2:.5,y2:.23,duration:250});
    else send(cmd);
  }));
  document.querySelectorAll('[data-action]').forEach(b=>b.addEventListener('click',()=>{
    const v=b.dataset.action;
    if(v==='refresh-apps')loadApps();else if(v==='refresh-video'){window.PultVideo?.stop();startVideo();}else show(v);
  }));
  async function loadApps(){const root=$('appsGrid');root.textContent='Загрузка…';const response=await send('apps');root.textContent='';
    if(!response){root.textContent='Не удалось загрузить приложения';return;}
    const apps=(response.apps||[]).slice().sort((a,b)=>String(a.name||'').localeCompare(String(b.name||''),'ru'));
    if(!apps.length){root.textContent='Список пуст';return;}
    for(const app of apps){const button=document.createElement('button');button.className='app-entry';button.textContent=app.name||app.package||'Приложение';
      button.addEventListener('click',async()=>{const result=await send('launch',{package:app.package});if(result)show('remote');});root.append(button);}
  }
  $('textForm').addEventListener('submit',async e=>{e.preventDefault();const field=$('textField');if(!field.value)return;
    if(await send('text',{text:field.value})){field.value='';toast('Текст отправлен');}
  });
  $('deleteKey').addEventListener('click',()=>send('delete'));

  // Fullscreen touchpad: pointer capture prevents accidental browser swipes.
  function resetMouse(){pointers.clear();mousePendingX=0;mousePendingY=0;dragState=false;clearTimeout(longTimer);}
  function move(dx,dy) {mousePendingX+=dx;mousePendingY+=dy;
    if(!mouseMoveTimer)mouseMoveTimer=setTimeout(flushMouse,38);
  }
  async function flushMouse() {
    clearTimeout(mouseMoveTimer);mouseMoveTimer=null;
    if(mouseSending || !paired || (!mousePendingX && !mousePendingY))return;
    const dx=Math.max(-250,Math.min(250,mousePendingX));const dy=Math.max(-250,Math.min(250,mousePendingY));
    mousePendingX-=dx;mousePendingY-=dy;
    mouseSending=true;await send(dragState?'drag_move':'move',{dx,dy},true);mouseSending=false;
    if(mousePendingX || mousePendingY)mouseMoveTimer=setTimeout(flushMouse,16);
  }
  function scroll(dy){scrollQueued=Math.max(-12,Math.min(12,scrollQueued+dy));pumpScroll();}
  async function pumpScroll(){if(scrollBusy||!paired||Math.abs(scrollQueued)<.1)return;scrollBusy=true;
    try{while(paired&&Math.abs(scrollQueued)>=.1){const dy=Math.min(3,Math.max(-3,scrollQueued));scrollQueued-=dy;await send('scroll',{dy},true);}}
    finally{scrollBusy=false;}
  }
  const touchpad=$('touchpad');
  touchpad.addEventListener('pointerdown',e=>{
    e.preventDefault();touchpad.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId,{x:e.clientX,y:e.clientY,startX:e.clientX,startY:e.clientY,at:Date.now(),travel:0});
    if(pointers.size===1){clearTimeout(longTimer);const id=e.pointerId;
      longTimer=setTimeout(async()=>{if(pointers.size!==1||!pointers.has(id))return;const p=pointers.get(id);if(p.travel<15){dragState=true;await send('drag_start',{},true);}},650);
    }else clearTimeout(longTimer);
  });
  touchpad.addEventListener('pointermove',e=>{
    const p=pointers.get(e.pointerId);if(!p)return;
    e.preventDefault();const dx=e.clientX-p.x,dy=e.clientY-p.y;p.travel+=Math.hypot(dx,dy);p.x=e.clientX;p.y=e.clientY;
    if(p.travel>12)clearTimeout(longTimer);
    if(pointers.size>=2){scroll(-dy/36);}else if(!dragState){move(dx*1.6,dy*1.6);}else{move(dx*1.6,dy*1.6);}
  });
  function endPointer(e){const p=pointers.get(e.pointerId);if(!p)return;e.preventDefault();
    clearTimeout(longTimer);pointers.delete(e.pointerId);
    if(dragState){if(pointers.size===0){
      (async()=>{
        while(mouseSending) await new Promise(r=>setTimeout(r,20));
        while(mousePendingX||mousePendingY){await flushMouse();while(mouseSending)await new Promise(r=>setTimeout(r,20));}
        await send('drag_end',{},true);dragState=false;
      })();
    }return;}
    if(pointers.size===0&&p.travel<12&&Date.now()-p.at<500)send('tap');
  }
  touchpad.addEventListener('pointerup',endPointer);touchpad.addEventListener('pointercancel',endPointer);
  touchpad.addEventListener('contextmenu',e=>e.preventDefault());
  $('scrollStrip').addEventListener('touchstart',e=>e.preventDefault(),{passive:false});
  let stripLast=null;
  $('scrollStrip').addEventListener('pointerdown',e=>{e.preventDefault();e.currentTarget.setPointerCapture(e.pointerId);stripLast=e.clientY;});
  $('scrollStrip').addEventListener('pointermove',e=>{if(stripLast==null)return;e.preventDefault();let delta=e.clientY-stripLast;stripLast=e.clientY;scroll(delta/23);});
  ['pointerup','pointercancel'].forEach(evt=>$('scrollStrip').addEventListener(evt,()=>stripLast=null));

  // Screen touch gestures: immediate list scrolling and accurate normalized taps.
  const area=$('videoTouchArea'), video=$('tvVideo');
  let gesture=null;
  function normalize(x,y){const box=area.getBoundingClientRect(),w=video.videoWidth||1280,h=video.videoHeight||720;
    const scale=video.classList.contains('fill')?Math.max(box.width/w,box.height/h):Math.min(box.width/w,box.height/h);
    const drawW=w*scale,drawH=h*scale;
    return {x:Math.max(0,Math.min(1,(x-box.left-(box.width-drawW)/2)/drawW)),
      y:Math.max(0,Math.min(1,(y-box.top-(box.height-drawH)/2)/drawH))};
  }
  area.addEventListener('pointerdown',e=>{e.preventDefault();area.setPointerCapture(e.pointerId);
    const p=normalize(e.clientX,e.clientY);gesture={id:e.pointerId,x:p.x,y:p.y,dx:p.x,dy:p.y,lastX:e.clientX,lastY:e.clientY,dist:0,scroll:0,scrolled:false,at:Date.now()};
    clearTimeout(longTimer);longTimer=setTimeout(()=>{if(gesture&&gesture.dist<14){send('screen_long',{x:gesture.x,y:gesture.y},true);gesture.scrolled=true;}},750);
  });
  area.addEventListener('pointermove',e=>{const g=gesture;if(!g||g.id!==e.pointerId)return;e.preventDefault();
    const travelY=e.clientY-g.lastY;g.dist+=Math.hypot(e.clientX-g.lastX,travelY);g.lastX=e.clientX;g.lastY=e.clientY;
    const p=normalize(e.clientX,e.clientY);g.dx=p.x;g.dy=p.y;
    if(g.dist>15)clearTimeout(longTimer);
    if(Math.abs(g.dy-g.y)>Math.abs(g.dx-g.x)*1.4&&Math.abs(g.dy-g.y)>.04){
      g.scroll+=travelY;
      if(Math.abs(g.scroll)>85){send('screen_scroll',{x:p.x,y:p.y,dy:g.scroll<0?1:-1},true);g.scroll=0;g.scrolled=true;}
    }
  });
  function endScreen(e){const g=gesture;if(!g||g.id!==e.pointerId)return;e.preventDefault();clearTimeout(longTimer);gesture=null;
    if(g.scrolled)return;
    if(g.dist<14){send('screen_tap',{x:g.x,y:g.y});return;}
    send('screen_swipe',{x1:g.x,y1:g.y,x2:g.dx,y2:g.dy,duration:Math.max(100,Math.min(900,Date.now()-g.at))});
  }
  area.addEventListener('pointerup',endScreen);area.addEventListener('pointercancel',endScreen);
  area.addEventListener('contextmenu',e=>e.preventDefault());
  function startVideo(){window.PultVideo?.start(video,text=>$('videoInfo').textContent=text);}
  $('videoFit').addEventListener('click',()=>{video.classList.toggle('fill');toast(video.classList.contains('fill')?'Видео на весь экран':'Без обрезки');});
  $('toggleVideoUi').addEventListener('click',()=>{
    const hidden=document.querySelector('.video-toolbar').classList.toggle('controls-hidden');
    document.querySelector('.screen-bottom').classList.toggle('hidden',hidden);
    document.querySelectorAll('.video-toolbar button').forEach(b=>{if(b.id!=='toggleVideoUi')b.classList.toggle('hidden',hidden);});
    $('toggleVideoUi').textContent=hidden?'+':'×';
  });
  document.addEventListener('visibilitychange',()=>{if(!document.hidden){checkHealth();if(active==='screen')startVideo();}else if(active==='screen')window.PultVideo?.stop();});
  window.addEventListener('pageshow',()=>checkHealth());
  window.addEventListener('online',()=>checkHealth());
  healthTimer=setInterval(()=>{if(!document.hidden)checkHealth();},6000);
  // All pages are hidden in HTML. The initial 'login' state alone does not make it visible.
  // Render a page before the first asynchronous status response arrives.
  show('login');
  checkHealth();
})();
