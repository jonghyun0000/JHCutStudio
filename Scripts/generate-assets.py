#!/usr/bin/env python3
"""Generate original, explicitly labeled procedural editing assets, then native-decode every bundled asset."""
import array, hashlib, json, math, pathlib, random, subprocess, wave, os
ROOT=pathlib.Path(__file__).resolve().parent.parent
LIB=ROOT/'Resources/Library'; CACHE=ROOT/'Build/asset-collection'
CC0='https://creativecommons.org/publicdomain/zero/1.0/'
RATE=44100
assets=[]
def write_audio(slug,name,seconds,tags,events,bpm=None):
    samples=int(seconds*RATE); stereo=array.array('f',[0])*(samples*2)
    rng=random.Random(slug)
    for start,duration,freq,amp,kind,pan in events:
        n=int(duration*RATE);first=int(start*RATE)
        for i in range(n):
            if first+i>=samples:break
            t=i/RATE;u=i/max(1,n-1)
            if kind=='pad': envelope=min(1,t/.2)*min(1,(duration-t)/.4);value=(math.sin(2*math.pi*freq*t)+.17*math.sin(2*math.pi*freq*2*t))*envelope
            elif kind=='bell': value=(math.sin(2*math.pi*freq*t)+.35*math.sin(2*math.pi*freq*2.01*t)+.15*math.sin(2*math.pi*freq*3.98*t))*math.exp(-6*u)*min(1,t/.004)
            elif kind=='pluck': value=(math.sin(2*math.pi*freq*t)+.2*math.sin(2*math.pi*freq*2*t))*math.exp(-8*u)*min(1,t/.004)
            elif kind=='kick': value=math.sin(2*math.pi*(45*t+freq*(1-math.exp(-30*t))/30))*math.exp(-18*t)
            elif kind=='noise': value=(rng.random()*2-1)*math.sin(math.pi*u)**2
            elif kind=='hat': value=(rng.random()*2-1)*math.exp(-25*u)*min(1,t/.001)
            elif kind=='rise': value=math.sin(2*math.pi*(freq*t+freq*2*t*t/duration))*math.sin(math.pi*u)**2
            else:value=math.sin(2*math.pi*freq*t)*math.exp(-6*u)*min(1,t/.003)
            value*=amp
            stereo[2*(first+i)]+=value*math.sqrt((1-pan)/2)
            stereo[2*(first+i)+1]+=value*math.sqrt((1+pan)/2)
    peak=max(abs(v) for v in stereo) or 1
    gain=min(1,.82/peak)
    pcm=array.array('h')
    for i,value in enumerate(stereo):
        frame=i//2;fade=min(1,frame/(RATE*.015),max(0,(samples-frame)/(RATE*.06)))
        pcm.append(round(max(-1,min(1,value*gain*fade))*32767))
    category='music' if bpm else 'sfx';rel='Audio/Original/'+slug+'.wav';p=LIB/rel;p.parent.mkdir(parents=True,exist_ok=True)
    with wave.open(str(p),'wb') as f:f.setnchannels(2);f.setsampwidth(2);f.setframerate(RATE);f.writeframes(pcm.tobytes())
    item=dict(id='original-'+slug,name=name,category=category,relativePath=rel,author='JH CUT Studio · 로컬 절차 생성',sourceURL='local:Scripts/generate-assets.py',license='CC0-1.0',licenseURL=CC0,sha256=hashlib.sha256(p.read_bytes()).hexdigest(),tags=tags+['직접 제작','합성음'],duration=seconds,origin='original',fileBytes=p.stat().st_size)
    if bpm:item['bpm']=bpm
    assets.append(item)

def note(midi):return 440*2**((midi-69)/12)
# Two original instrumental beds, with no sampled or third-party musical material.
for slug,name,bpm,bars,bright in [('soft-pulse','잔잔한 펄스 · 30초',96,12,False),('morning-plucks','가벼운 아침 · 32초',120,16,True)]:
 beat=60/bpm;length=bars*4*beat;events=[];chords=[[48,55,60,64],[45,52,57,60],[41,48,53,57],[43,50,55,59]]
 for bar in range(bars):
  chord=chords[bar%4]
  for pitch in chord:events.append((bar*4*beat,4*beat,note(pitch),.027 if bright else .035,'pad',0))
  for step in range(8):events.append(((bar*4+step*.5)*beat,beat*1.15,note(chord[step%4]+(24 if bright else 12)),.105 if bright else .055,'pluck',(-.35,.35)[step%2]))
  for quarter in range(4):
   events.append(((bar*4+quarter)*beat,.22,85,.12 if bright else .06,'kick',0))
   if bright:events.append(((bar*4+quarter+.5)*beat,.07,0,.025,'hat',.2))
 write_audio(slug,name,length,['배경음악','밝음' if bright else '차분함','광고','기악'],events,bpm)
SFX=[
 ('soft-whoosh','부드러운 전환 바람',.55,[(0,.5,0,.35,'noise',0)]),
 ('quick-whoosh','빠른 전환 바람',.22,[(0,.2,0,.4,'noise',0)]),
 ('warm-rise','따뜻한 상승음',1.2,[(0,1.1,240,.2,'rise',0)]),
 ('soft-impact','부드러운 강조 타격',.6,[(0,.35,120,.6,'kick',0),(.02,.18,0,.1,'noise',0)]),
 ('water-ripple','물결풍 전환',.8,[(0,.7,660,.3,'bell',-.3),(.12,.6,880,.2,'bell',.3)]),
 ('paper-flick','종이 넘김풍 합성음',.24,[(0,.11,0,.25,'noise',-.2),(.09,.12,0,.14,'noise',.2)]),
 ('gentle-bell','맑은 한 번 알림',1.3,[(0,1.2,880,.35,'bell',0)]),
 ('notification-pair','두 번 확인 알림',.9,[(0,.5,660,.3,'bell',-.1),(.2,.6,990,.3,'bell',.1)]),
 ('low-thump','낮은 임팩트',.6,[(0,.55,90,.7,'kick',0)]),
 ('sparkle-end','반짝이는 엔딩',1.3,[(0,.8,1046.5,.18,'bell',-.4),(.15,.8,1318.5,.18,'bell',0),(.3,.9,1568,.18,'bell',.4)]),
 ('soft-success','부드러운 성공 신호',.8,[(0,.55,523.25,.2,'pluck',-.2),(.15,.55,659.25,.2,'pluck',0),(.3,.48,783.99,.2,'pluck',.2)]),
 ('tiny-pop','작은 팝 강조',.18,[(0,.16,600,.35,'kick',0)])]
for slug,name,seconds,events in SFX:write_audio(slug,name,seconds,['전환' if '전환' in name else '강조','효과음'],events)
(CACHE/'original-audio.json').write_text(json.dumps(assets,ensure_ascii=False,indent=2))
(LIB/'Licenses/Originals.txt').write_text('JH CUT Studio original procedural assets\n\nThe original assets labeled origin=original were generated locally using the bundled Scripts/generate-assets.py and Scripts/generate-assets.swift source code. They contain no third-party audio samples, downloaded artwork, logos, font files or cloned voices. These generated assets are provided under CC0 1.0 Universal.\nhttps://creativecommons.org/publicdomain/zero/1.0/\n\nOriginal synthesis is separate from the collected author-created Kenney/OpenGameArt assets; no claim that the downloaded music was generated by this project is made.\n')
compiler='/Library/Developer/CommandLineTools/usr/bin/swiftc'
os.environ['DEVELOPER_DIR']='/Library/Developer/CommandLineTools'
subprocess.run([compiler,'-sdk','/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk','-swift-version','5','-target',os.uname().machine+'-apple-macos14.0','-parse-as-library',str(ROOT/'Services/AssetLibrary.swift'),str(ROOT/'Scripts/generate-assets.swift'),'-o',str(CACHE/'GenerateAssets')],check=True)
subprocess.run([str(CACHE/'GenerateAssets'),str(ROOT)],check=True)
