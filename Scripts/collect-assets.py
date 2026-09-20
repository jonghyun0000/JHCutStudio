#!/usr/bin/env python3
"""Collect the reviewed CC0 sources. Network is used only by this explicitly invoked build-time script."""
import concurrent.futures, hashlib, html, json, pathlib, re, subprocess, sys, urllib.request, zipfile
ROOT = pathlib.Path(__file__).resolve().parent.parent
LIB = ROOT / 'Resources/Library'
CACHE = ROOT / 'Build/asset-collection'
LOCK = ROOT / 'Scripts/collect-assets.lock.json'
CC0 = 'https://creativecommons.org/publicdomain/zero/1.0/'
KENNEY_PAGE = 'https://kenney.nl/assets/interface-sounds'
KENNEY_ZIP = 'https://kenney.nl/media/pages/assets/interface-sounds/fa43c1dd4d-1677589452/kenney_interface-sounds.zip'
MUSIC = [
 ('bossa-nova','카페 보사노바 · 8비트', 'Joth','https://opengameart.org/sites/default/files/8bit%20Bossa.mp3',['카페','보사노바','차분함','칩튠']),
 ('a-new-day','새로운 하루 · 밝은 모험','SpiderDave','https://opengameart.org/sites/default/files/49_0.ogg',['밝음','모험','일상','소개']),
 ('electronic','전자 리듬 · Techno 5','Alex McCulloch (Pro Sensory)','https://opengameart.org/sites/default/files/Techno_5_0.mp3',['전자음악','테크','몽타주']),
 ('at-the-end-of-hope','희망의 끝 · 잔잔한 피아노','Emma_MA','https://opengameart.org/sites/default/files/at%20the%20end%20of%20hope_0.mp3',['피아노','감성','회상','엔딩']),
 ('dream-2-ambience','꿈의 공간 · 앰비언스','TokyoGeisha','https://opengameart.org/sites/default/files/Dream%202%20%28Ambience%29_0.mp3',['몽환','앰비언트','공간','긴장']),
 ('liquid-flame','빛의 흐름 · 일렉트로 하우스','Of Far Different Nature','https://opengameart.org/sites/default/files/Of%20Far%20Different%20Nature%20-%20Liquid%20Flame%20%28CC0%29.mp3',['하우스','몽환','전자음악','에너지']),
 ('pure-raceway','질주 · 밝은 신스','MintoDog','https://opengameart.org/sites/default/files/pure_raceway_bpm160.mp3',['신스','경쾌함','스포츠','질주']),
 ('dance-field','댄스 필드 · 레트로 리듬','Centurion_of_war','https://opengameart.org/sites/default/files/dance_field_2_1.mp3',['댄스','레트로','경쾌함','칩튠']),
]
KOREAN = {'back':'뒤로 이동','bong':'둥 울림','click':'버튼 클릭','close':'닫기','confirmation':'확인 알림','drop':'툭 내려놓기','error':'오류 알림','glass':'맑은 유리음','glitch':'디지털 글리치','maximize':'확대','minimize':'축소','mouseclick':'마우스 클릭','open':'열기','pluck':'통통 튕김','question':'질문 알림','rollover':'선택 이동','scratch':'긁기','scroll':'스크롤','select':'선택','switch':'전환','tick':'짧은 틱','toggle':'토글'}
lock = json.loads(LOCK.read_text()) if LOCK.exists() else {}
refresh = '--refresh-lock' in sys.argv
observed = {}
def sha(data): return hashlib.sha256(data).hexdigest()
def fetch(url, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    data = target.read_bytes() if target.exists() else urllib.request.urlopen(urllib.request.Request(url,headers={'User-Agent':'JHCutStudio-AssetCollector/1.0'}),timeout=60).read()
    digest = sha(data)
    if url in lock and lock[url] != digest and not refresh: raise RuntimeError('Source checksum changed; review before updating lock: '+url)
    if not lock and not refresh: raise RuntimeError('Initial source collection requires --refresh-lock after reviewing sources')
    observed[url] = digest
    target.write_bytes(data)
    return data

def music_one(item):
    slug,name,author,url,tags=item
    page='https://opengameart.org/content/'+slug
    page_text=urllib.request.urlopen(page,timeout=45).read().decode()
    if 'creativecommons.org/publicdomain/zero/1.0' not in page_text: raise RuntimeError('CC0 license missing from author page '+page)
    # Store a factual evidence record rather than bundling unrelated site comments/previews.
    (LIB/'Licenses'/('OGA-'+slug+'.txt')).write_text('Title: '+slug+'\nAuthor: '+author+'\nSource: '+page+'\nLicense: CC0 1.0\nLicense URL: '+CC0+'\nDownload: '+url+'\nReviewed: 2026-09-20\nNo preview images or unrelated page assets are redistributed.\n')
    ext=pathlib.Path(urllib.request.url2pathname(urllib.parse.urlparse(url).path)).suffix
    downloaded=CACHE/(slug+ext); original=fetch(url,downloaded)
    relative='Audio/Music/'+slug+('.wav' if ext=='.ogg' else ext)
    destination=LIB/relative; destination.parent.mkdir(parents=True,exist_ok=True)
    if ext=='.ogg': subprocess.run(['/usr/bin/afconvert',str(downloaded),str(destination),'-f','WAVE','-d','LEI16'],check=True)
    else: destination.write_bytes(original)
    return dict(id='oga-'+slug,name=name,category='music',relativePath=relative,author=author,sourceURL=page,license='CC0-1.0',licenseURL=CC0,sha256=sha(destination.read_bytes()),tags=tags+['외부 수집','CC0'],origin='downloaded',originalFilename=urllib.parse.unquote(pathlib.Path(urllib.parse.urlparse(url).path).name),downloadURL=url,sourceSHA256=sha(original),fileBytes=destination.stat().st_size)

for folder in ['Audio/SFX/Kenney','Audio/Music','Graphics','Licenses']:(LIB/folder).mkdir(parents=True,exist_ok=True)
CACHE.mkdir(parents=True,exist_ok=True)
archive=CACHE/'kenney_interface-sounds.zip'; archive_data=fetch(KENNEY_ZIP,archive)
assets=[]
with zipfile.ZipFile(archive) as z:
    (LIB/'Licenses/Kenney-Interface-Sounds.txt').write_bytes(z.read('License.txt'))
    entries=sorted(n for n in z.namelist() if n.lower().endswith('.ogg'))
    if len(entries)!=100: raise RuntimeError('Kenney source package no longer contains exactly 100 OGG sounds')
    for entry in entries:
        name=pathlib.Path(entry).stem
        original=z.read(entry); temporary=CACHE/'kenney-original'/pathlib.Path(entry).name;temporary.parent.mkdir(exist_ok=True);temporary.write_bytes(original)
        relative='Audio/SFX/Kenney/'+name+'.wav'; destination=LIB/relative
        subprocess.run(['/usr/bin/afconvert',str(temporary),str(destination),'-f','WAVE','-d','LEI16'],check=True)
        group=name.rsplit('_',1)[0]; number=name.rsplit('_',1)[-1]
        assets.append(dict(id='kenney-'+name,name=KOREAN.get(group,group)+' '+number,category='sfx',relativePath=relative,author='Kenney',sourceURL=KENNEY_PAGE,license='CC0-1.0',licenseURL=CC0,sha256=sha(destination.read_bytes()),tags=['효과음','인터페이스',KOREAN.get(group,group),'Kenney','외부 수집'],origin='downloaded',originalFilename=entry,downloadURL=KENNEY_ZIP,sourceSHA256=sha(original),fileBytes=destination.stat().st_size))
with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
    for asset in pool.map(music_one,MUSIC):assets.append(asset);print('Collected',asset['id'],asset['fileBytes'])
# CC0 legal code is itself a public legal tool; retain full local text for offline review.
license_url='https://creativecommons.org/publicdomain/zero/1.0/legalcode.en'
license_data=urllib.request.urlopen(urllib.request.Request(license_url,headers={'User-Agent':'Mozilla/5.0'}),timeout=30).read();(LIB/'Licenses/CC0-1.0.html').write_bytes(license_data)
(CACHE/'downloaded-assets.json').write_text(json.dumps(assets,ensure_ascii=False,indent=2))
if refresh:
    lock.update(observed);LOCK.write_text(json.dumps(lock,indent=2,sort_keys=True)+'\n')
print('Collected',len(assets),'assets; PCM WAV conversion uses native macOS afconvert; sources unchanged.')
