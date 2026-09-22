#!/usr/bin/env python3
"""Reproducible, additive CC0 collection. Sources are pinned; never replaces existing assets.
Run from any directory. curl downloads to private partial files; only reviewed source hashes
are accepted. Audio lengths come from macOS afinfo, not website labels. No looping/trimming.
"""
import hashlib, json, pathlib, re, struct, subprocess, urllib.parse, zipfile
ROOT = pathlib.Path(__file__).resolve().parents[1]
LIB = ROOT/'Resources/Library'
CACHE = ROOT/'Build/asset-expansion'
CC0 = 'https://creativecommons.org/publicdomain/zero/1.0/'
CONFIG = json.loads((ROOT/'Scripts/expand-library.sources.json').read_text())
CACHE.mkdir(parents=True, exist_ok=True)
def sha(data): return hashlib.sha256(data).hexdigest()
def fetch(item, name):
    path = CACHE/name
    if not path.exists():
        partial = path.with_suffix(path.suffix+'.partial')
        subprocess.run(['curl','-fsSL','--retry','2','--max-time','120','--max-filesize','100000000',item['downloadURL'],'-o',str(partial)],check=True)
        if sha(partial.read_bytes()) != item['sourceSHA256']: raise RuntimeError('Unreviewed source: '+name)
        partial.replace(path)
    if sha(path.read_bytes()) != item['sourceSHA256']: raise RuntimeError('Source checksum mismatch: '+name)
    return path

def record(item, filename, data, category, name, tags, original, author, **extra):
    target = LIB/filename; target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(data)
    return dict(id='expansion-'+item['slug']+'-'+pathlib.Path(filename).stem, name=name,category=category,relativePath=filename,
        author=author, sourceURL=item['sourceURL'], license='CC0-1.0', licenseURL=CC0,sha256=sha(data),
        tags=tags+['외부 수집','CC0'],origin='downloaded',originalFilename=original,downloadURL=item['downloadURL'],
        sourceSHA256=extra.pop('sourceSHA256',item['sourceSHA256']),fileBytes=len(data),**extra)

def evidence(item, author, note):
    path=LIB/'Licenses'/('Expansion-'+item['slug']+'.txt')
    path.write_text(f"Author: {author}\nSource: {item['sourceURL']}\nDownload: {item['downloadURL']}\nSource archive/file SHA256: {item['sourceSHA256']}\nLicense: CC0 1.0\nLicense URL: {CC0}\nReviewed: 2026-09-20\n{note}\n")

assets=[]
for item in CONFIG['music']:
    source=fetch(item,item['cacheName']);out=source
    if source.suffix.lower()=='.ogg':
        out=CACHE/(item['slug']+'-decoded.wav')
        subprocess.run(['/usr/bin/afconvert',str(source),str(out),'-f','WAVE','-d','LEI16'],check=True)
    info=subprocess.check_output(['/usr/bin/afinfo',str(out)],text=True)
    duration=float(re.search(r'estimated duration:\s+([\d.]+)',info)[1])
    if not 120<=duration<=180:raise RuntimeError('Music outside requested 2–3 minute range: '+item['slug'])
    filename='Audio/Music/Expansion/'+item['slug']+out.suffix.lower()
    assets.append(record(item,filename,out.read_bytes(),'music',item['name'],item['tags']+['2~3분'],
        urllib.parse.unquote(pathlib.Path(urllib.parse.urlparse(item['downloadURL']).path).name),item['author'],duration=duration))
    evidence(item,item['author'],'Whole original track. No looping, stretching, or trimming. OGG decoded to PCM WAV when required.')
    print('Music',item['slug'],round(duration,3),flush=True)

particle_names={'circle':'링','dirt':'먼지','fire':'불꽃','flame':'화염','flare':'플레어','light':'빛','magic':'마법 입자','muzzle':'섬광','scorch':'그을음','scratch':'스크래치','slash':'슬래시','smoke':'연기','spark':'스파크','star':'별','symbol':'심벌','trace':'빛 궤적','twirl':'회오리','window':'창문 빛'}
emotes={'alert':'알림','anger':'화남','bars':'신호','cash':'돈','circle':'동그라미','cloud':'구름','cross':'실패','dots1':'말줄임 1','dots2':'말줄임 2','dots3':'말줄임 3','drop':'물방울','drops':'땀방울','exclamation':'느낌표','exclamations':'놀람','faceAngry':'화난 얼굴','faceHappy':'행복한 얼굴','faceSad':'슬픈 얼굴','heart':'하트','heartBroken':'깨진 하트','hearts':'사랑','idea':'아이디어','laugh':'웃음','music':'음악','question':'질문','sleep':'졸음','sleeps':'잠','star':'별','stars':'반짝임','swirl':'혼란'}
for item in CONFIG['packs']:
    archive=fetch(item,item['slug']+'.zip')
    with zipfile.ZipFile(archive) as z:
        license_name=next(n for n in z.namelist() if n.lower().endswith('license.txt'))
        license_data=z.read(license_name)
        if b'CC0' not in license_data and b'Creative Commons Zero' not in license_data:raise RuntimeError('Unexpected pack license')
        (LIB/'Licenses'/('Kenney-'+item['slug']+'.txt')).write_bytes(license_data)
        count=0
        for entry in sorted(z.namelist()):
            if not entry.endswith('.png'):continue
            stem=pathlib.Path(entry).stem
            if item['slug']=='particle-pack':
                if not entry.startswith('PNG (Transparent)/') or entry.count('/')!=1:continue
                group=stem.rsplit('_',1)[0];name='입자 · '+particle_names.get(group,group)+' '+stem.rsplit('_',1)[-1]
                category='overlay';tags=['입자','빛','이펙트','투명 PNG',particle_names.get(group,group)]
            elif item['slug']=='emotes-pack':
                if not entry.startswith('PNG/Pixel/Style 1/') or stem=='emote__':continue
                label=emotes.get(stem.removeprefix('emote_'),stem);name='픽셀 반응 · '+label
                category='overlay';tags=['스티커','말풍선','픽셀 아트','레트로','작은 해상도',label]
            else:
                if not entry.startswith('PNG/Default/') or entry.count('/')!=2:continue
                name='반복 패턴 · '+stem.rsplit('_',1)[-1];category='texture';tags=['패턴','텍스처','기하학','타일']
            data=z.read(entry);width,height=struct.unpack('>II',data[16:24])
            assets.append(record(item,'Graphics/Expansion/'+item['slug']+'/'+stem+'.png',data,category,name,tags,entry,'Kenney',sourceSHA256=sha(data),width=width,height=height))
            count+=1
    evidence(item,'Kenney','Selected PNG files are subsequently converted to explicit 8-bit sRGB RGBA at original dimensions. Source file hashes are retained. Duplicate style/rotation variants omitted. Emotes are labeled pixel art at original resolution.')
    print('Graphics',item['slug'],count,flush=True)

manifest=LIB/'manifest.json';existing=json.loads(manifest.read_text());by_id={a['id']:a for a in existing}
for asset in assets:by_id[asset['id']]=asset
combined=list(by_id.values())
assert len({a['relativePath'] for a in combined})==len(combined)
temporary=manifest.with_suffix('.json.partial');temporary.write_text(json.dumps(combined,ensure_ascii=False,indent=2)+'\n');temporary.replace(manifest)
print('Added/updated',len(assets),'assets; library total',len(combined))
import os
environment = dict(os.environ, DEVELOPER_DIR=os.environ.get('JHCUT_DEVELOPER_DIR','/Library/Developer/CommandLineTools'))
subprocess.run(['/usr/bin/xcrun','swift',str(ROOT/'Scripts/normalize-library-images.swift'),str(LIB)],env=environment,check=True)
