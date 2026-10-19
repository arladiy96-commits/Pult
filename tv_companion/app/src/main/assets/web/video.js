/* Pult TV: local H.264 Annex-B -> fragmented MP4 for Safari ManagedMediaSource.
   No external CDN, libraries, transcoding or second MediaProjection capture. */
(() => {
  'use strict';
  const enc = s => new TextEncoder().encode(s);
  const u8 = (...v) => Uint8Array.from(v);
  const u16 = n => u8((n >>> 8) & 255, n & 255);
  const u32 = n => u8((n >>> 24) & 255, (n >>> 16) & 255, (n >>> 8) & 255, n & 255);
  const u64 = n => {
    const b = BigInt(n);
    return join(u32(Number((b >> 32n) & 0xffffffffn)), u32(Number(b & 0xffffffffn)));
  };
  const join = (...parts) => {
    const len = parts.reduce((s, p) => s + p.length, 0);
    const out = new Uint8Array(len);
    let at = 0;
    for (const p of parts) { out.set(p, at); at += p.length; }
    return out;
  };
  const box = (type, ...parts) => {
    const body = join(...parts);
    return join(u32(8 + body.length), enc(type), body);
  };
  const full = (type, version, flags, ...parts) => box(type, u8(version, (flags >>> 16) & 255, (flags >>> 8) & 255, flags & 255), ...parts);
  const zeros = n => new Uint8Array(n);
  const matrix = join(u32(0x10000),u32(0),u32(0),u32(0),u32(0x10000),u32(0),u32(0),u32(0),u32(0x40000000));
  function initSegment(width, height, sps, pps) {
    const avcC = box('avcC', join(u8(1,sps[1],sps[2],sps[3],255,225),u16(sps.length),sps,u8(1),u16(pps.length),pps));
    const avc1 = box('avc1',zeros(6),u16(1),zeros(16),u16(width),u16(height),
      u32(0x480000),u32(0x480000),u32(0),u16(1),zeros(32),u16(24),u16(65535),avcC);
    const stbl = box('stbl',full('stsd',0,0,u32(1),avc1),full('stts',0,0,u32(0)),
      full('stsc',0,0,u32(0)),full('stsz',0,0,u32(0),u32(0)),full('stco',0,0,u32(0)));
    const dinf = box('dinf',full('dref',0,0,u32(1),full('url ',0,1)));
    const minf = box('minf',full('vmhd',0,1,zeros(8)),dinf,stbl);
    const mdia = box('mdia',full('mdhd',0,0,u32(0),u32(0),u32(90000),u32(0),u16(0x55c4),u16(0)),
      full('hdlr',0,0,u32(0),enc('vide'),zeros(12),enc('VideoHandler\0')),minf);
    const trak = box('trak',full('tkhd',0,7,u32(0),u32(0),u32(1),u32(0),u32(0),zeros(8),
      u16(0),u16(0),u16(0),u16(0),matrix,u32(width*65536),u32(height*65536)),mdia);
    const moov = box('moov',full('mvhd',0,0,u32(0),u32(0),u32(90000),u32(0),u32(0x10000),
      u16(0x100),u16(0),zeros(8),matrix,zeros(24),u32(2)),trak,
      box('mvex',full('trex',0,0,u32(1),u32(1),u32(3000),u32(0),u32(0))));
    return join(box('ftyp',enc('isom'),u32(512),enc('isom'),enc('iso6'),enc('avc1'),enc('mp41')),moov);
  }
  function fragment(sequence, dts, duration, sample, isKey) {
    const sampleFlags = isKey ? 0x02000000 : 0x01010000;
    const traf = offset => box('traf',full('tfhd',0,0x020000,u32(1)),full('tfdt',1,0,u64(dts)),
      full('trun',0,0x000701,u32(1),u32(offset),u32(duration),u32(sample.length),u32(sampleFlags)));
    let moof = box('moof',full('mfhd',0,0,u32(sequence)),traf(0));
    moof = box('moof',full('mfhd',0,0,u32(sequence)),traf(moof.length+8));
    return join(moof,box('mdat',sample));
  }
  function nals(bytes) {
    const starts = [];
    for (let i = 0; i < bytes.length - 3; i++) {
      if (bytes[i] !== 0 || bytes[i+1] !== 0) continue;
      if (bytes[i+2] === 1) { starts.push([i,i+3]); i += 2; }
      else if (bytes[i+2] === 0 && bytes[i+3] === 1) { starts.push([i,i+4]); i += 3; }
    }
    const result = [];
    for (let i=0; i<starts.length; i++) {
      const from = starts[i][1];
      const until = i + 1 < starts.length ? starts[i+1][0] : bytes.length;
      if (until > from) result.push(bytes.subarray(from,until));
    }
    return result;
  }
  function sampleAVCC(bytes) {
    const nalList = nals(bytes);
    // Some Android encoders may emit length-prefixed access units.
    if (!nalList.length && bytes.length>4) {
      let i=0; const parts=[];
      while (i+4<=bytes.length) {
        const n = new DataView(bytes.buffer,bytes.byteOffset+i,4).getUint32(0);
        if (!n || i+4+n>bytes.length) return null;
        parts.push(bytes.subarray(i,i+4+n)); i+=4+n;
      }
      return i===bytes.length ? join(...parts) : null;
    }
    if (!nalList.length) return null;
    return join(...nalList.map(nal=>join(u32(nal.length),nal)));
  }

  class Playback {
    constructor(video, report) {
      this.video=video; this.report=report; this.controller=null; this.live=false;
      this.media=null; this.buffer=null; this.objectUrl=null;
      this.queue=[]; this.sps=null; this.pps=null; this.width=1280; this.height=720;
      this.seq=0; this.decodeTime=0; this.lastPts=null; this.configuring=null;
      this.lastData=0; this.ticker=null; this.streamId=0;
    }
    async start() {
      this.live=true;
      const id=++this.streamId;
      this.controller=new AbortController();
      this.ticker=setInterval(()=>{
        if (!this.live || id!==this.streamId) return;
        if (this.lastData && Date.now()-this.lastData>9000) this.controller?.abort();
      },3000);
      this.report('Получаем H.264 с приставки…');
      while (this.live && id===this.streamId) {
        let reader;
        try {
          const res=await fetch('/api/video',{signal:this.controller.signal,credentials:'same-origin',cache:'no-store'});
          if (!res.ok) {
            const msg=(await res.json().catch(()=>({}))).error || `Видео: HTTP ${res.status}`;
            this.report(msg); if (res.status===401 || res.status===409 || res.status===429) return;
            throw Error(msg);
          }
          if (!res.body?.getReader) throw Error('Safari не поддерживает потоковое чтение видео');
          this.width=Number(res.headers.get('X-Pult-Video-Width'))||1280;
          this.height=Number(res.headers.get('X-Pult-Video-Height'))||720;
          reader=res.body.getReader();
          let pending=new Uint8Array(0);
          this.lastData=Date.now();
          while (this.live && id===this.streamId) {
            const {value,done}=await reader.read();
            if (done) break;
            this.lastData=Date.now();
            pending=join(pending,value);
            while (pending.length>=16) {
              const dv=new DataView(pending.buffer,pending.byteOffset,pending.byteLength);
              const size=dv.getUint32(0);
              if (size<1 || size>2000000) throw Error('Неверный пакет видеопотока');
              if (pending.length < size+16) break;
              const pts=Number(dv.getBigUint64(4));
              const flags=dv.getUint32(12);
              const packet=pending.slice(16,16+size);
              pending=pending.slice(16+size);
              this.packet(pts,flags,packet);
            }
            if (pending.length>3000000) throw Error('Переполнен видеобуфер');
          }
        } catch (e) {
          if (!this.live || id!==this.streamId) break;
          this.report(`Видео: ${e.message || 'обрыв соединения'} · переподключение`);
        } finally { try { await reader?.cancel(); } catch (_) {} }
        if (!this.live || id!==this.streamId) break;
        await new Promise(r=>setTimeout(r,1400));
        this.resetMedia(); this.controller=new AbortController();
      }
    }
    packet(pts,flags,bytes) {
      if (flags&2) {
        const nalList=nals(bytes);
        for (const nal of nalList) {
          if ((nal[0]&31)===7) this.sps=nal.slice();
          if ((nal[0]&31)===8) this.pps=nal.slice();
        }
        if (!this.configuring && !this.buffer && this.sps && this.pps) {
          this.configuring=this.configure().catch(e=>{
            this.report(`Плеер: ${e.message}`);
            this.controller?.abort();
          });
        }
        return;
      }
      const sample=sampleAVCC(bytes);
      if (!sample) return;
      if (!(flags&1) && this.seq===0) return; // Begin only on IDR
      if (this.queue.length>32) {
        // Stalling source buffer => reconnect at new IDR, not random P-frames.
        this.report('Видео отстаёт · пересинхронизация…');
        this.controller?.abort();
        return;
      }
      let duration=3000;
      if (this.lastPts!==null && pts>this.lastPts) duration=Math.max(1500,Math.min(9000,Math.round((pts-this.lastPts)*0.09)));
      this.lastPts=pts;
      this.queue.push(fragment(++this.seq,this.decodeTime,duration,sample,!!(flags&1)));
      this.decodeTime+=duration;
      this.pump();
    }
    async configure() {
      if (!this.sps || !this.pps || this.sps.length<4) throw Error('Приставка не выдала параметры кодека');
      const Source=window.ManagedMediaSource || window.MediaSource;
      if (!Source) throw Error('Для видео нужен iOS 17.1+ с поддержкой Managed Media Source');
      const codec='avc1.'+Array.from(this.sps.slice(1,4)).map(v=>v.toString(16).padStart(2,'0')).join('').toUpperCase();
      const mime=`video/mp4; codecs="${codec}"`;
      if (typeof Source.isTypeSupported==='function' && !Source.isTypeSupported(mime)) throw Error(`Safari не поддерживает ${codec}`);
      const media=new Source(); this.media=media;
      this.video.disableRemotePlayback=true;
      this.objectUrl=URL.createObjectURL(media);
      this.video.src=this.objectUrl;
      await new Promise((resolve,reject)=>{
        if (media.readyState==='open') return resolve();
        const timer=setTimeout(()=>reject(Error('MediaSource не открылся')),8000);
        media.addEventListener('sourceopen',()=>{clearTimeout(timer);resolve();},{once:true});
      });
      if (!this.live || this.media!==media) return;
      this.buffer=media.addSourceBuffer(mime);
      this.buffer.mode='segments';
      this.buffer.addEventListener('updateend',()=>this.pump());
      this.queue.unshift(initSegment(this.width,this.height,this.sps,this.pps));
      this.report('Экран X96 · трансляция активна');
      this.video.play().catch(()=>this.report('Коснитесь экрана, чтобы запустить видео'));
      this.pump();
    }
    pump() {
      const b=this.buffer;
      if (!b || b.updating || !this.queue.length || this.media?.readyState!=='open') return;
      try {
        const v=this.video;
        if (b.buffered.length) {
          const end=b.buffered.end(b.buffered.length-1);
          const start=b.buffered.start(0);
          if (end-v.currentTime>0.6 && end>0.3) v.currentTime=Math.max(start,end-0.16);
          if (end-start>3.5 && start<v.currentTime-1.5) {
            b.remove(start,Math.max(start,v.currentTime-1.2));
            return;
          }
        }
        b.appendBuffer(this.queue.shift());
      } catch (e) {
        this.report(`Видеобуфер: ${e.message}`);
        this.controller?.abort();
      }
    }
    resetMedia() {
      this.queue=[];this.buffer=null;this.media=null;this.configuring=null;
      this.sps=null;this.pps=null;this.seq=0;this.decodeTime=0;this.lastPts=null;
      try {this.video.pause();this.video.removeAttribute('src');this.video.load();}catch(_){}
      if (this.objectUrl) URL.revokeObjectURL(this.objectUrl);
      this.objectUrl=null;
    }
    stop() {
      this.live=false;this.streamId++;
      this.controller?.abort();this.controller=null;
      if(this.ticker)clearInterval(this.ticker);this.ticker=null;
      this.resetMedia();
    }
  }
  let active=null;
  window.PultVideo={
    start(video,report) {active?.stop();active=new Playback(video,report);active.start();},
    stop() {active?.stop();active=null;},
  };
})();
