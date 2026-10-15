#!/usr/bin/env python3
"""Only our disposable images and direct child PID may be detached/killed."""
import argparse,subprocess,tempfile,pathlib,os,time,json,errno,plistlib,shutil
ROOT=pathlib.Path(__file__).resolve().parents[1]
def main():
 p=argparse.ArgumentParser();p.add_argument('--probe',required=True);p.add_argument('--output',required=True);a=p.parse_args()
 probe=pathlib.Path(a.probe).resolve();out=pathlib.Path(a.output).absolute()
 if '..' in out.parts or out.resolve()!=out or not out.is_relative_to(ROOT/'Artifacts'):raise ValueError('Fresh Artifacts output required')
 out.mkdir(parents=True,exist_ok=False);rows=[];logs=[];attached=False;device=None;child=None
 def run(*args,timeout=45):
  r=subprocess.run(list(map(str,args)),capture_output=True,timeout=timeout);logs.append({'command':list(map(str,args)),'exit':r.returncode,'stdout':r.stdout.decode(errors='replace'),'stderr':r.stderr.decode(errors='replace')})
  if r.returncode:raise RuntimeError(logs[-1])
  return r.stdout
 def check(name,detail=''):rows.append({'name':name,'passed':True,'detail':detail});print('PASS '+name,flush=True)
 temp=pathlib.Path(tempfile.mkdtemp(prefix='jhcut-owned-storage-')).resolve()
 try:
  mount=temp/'mount';mount.mkdir();image=temp/'Fault.sparseimage'
  run('hdiutil','create','-size','128m','-fs','APFS','-volname','JHCutOwnedFault','-type','SPARSE',image)
  def attach():
   nonlocal attached,device
   value=plistlib.loads(run('hdiutil','attach',image,'-nobrowse','-mountpoint',mount,'-plist'))
   device=value['system-entities'][0]['dev-entry'];attached=True
   assert device.startswith('/dev/disk')
   assert any(pathlib.Path(e.get('mount-point','/missing')).resolve()==mount for e in value['system-entities'])
  def detach():
   nonlocal attached
   run('hdiutil','detach',device);attached=False
  try:
   attach();full=mount/'full';full.mkdir();run(probe,'seed',full)
   filler=mount/'fill'
   with filler.open('wb',buffering=0) as f:
    try:
     while True:f.write(b'\xa5'*65536)
    except OSError as e:
     if e.errno!=errno.ENOSPC:raise
   with filler.open('ab',buffering=0) as f:
    try:
     while True:f.write(b'\xa5'*4096)
    except OSError as e:
     if e.errno!=errno.ENOSPC:raise
   check('real ENOSPC last-good preservation',run(probe,'full',full).decode().strip());filler.unlink()
   for phase in ['backupStaged','documentStaged','documentCommitted','recovery-previousStaged','recovery-currentStaged','recovery-currentCommitted']:
    case=mount/phase;case.mkdir();run(probe,'seed',case)
    child=subprocess.Popen([str(probe),'crash',str(case),phase],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    deadline=time.monotonic()+15
    while not (case/'barrier').exists():
     if child.poll() is not None:raise RuntimeError('Crash child terminated before barrier '+str(child.communicate()))
     if time.monotonic()>deadline:raise RuntimeError('Crash barrier observation timeout')
     time.sleep(.01)
    assert (case/'barrier').read_text()==phase
    child.kill();stdout,stderr=child.communicate(timeout=10);assert child.returncode==-9;child=None
    check('SIGKILL at '+phase,run(probe,'verify',case,phase,out).decode().strip())
   reconnect=mount/'reconnect';reconnect.mkdir();run(probe,'seed',reconnect);run(probe,'prepare-media',reconnect,out)
   detach();check('owned volume detached',run(probe,'offline',reconnect,out).decode().strip())
   attach();check('owned volume remounted export',run(probe,'resumed',reconnect,out).decode().strip())
  finally:
   if child is not None and child.poll() is None:child.kill();child.communicate(timeout=10)
   if attached:detach()
  exfat_cases=out/'ExFATFixture';exfat_cases.mkdir();exfat_out=out/'ExFAT';exfat_out.mkdir()
  check('owned ExFAT fixture filesystem',run(probe,'filesystem',exfat_cases).decode().strip())
  try:
   for phase in ['documentStaged','documentCommitted','recovery-currentStaged']:
    case=exfat_cases/phase;case.mkdir();run(probe,'seed',case)
    child=subprocess.Popen([str(probe),'crash',str(case),phase],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
    deadline=time.monotonic()+15
    while not (case/'barrier').exists():
     if child.poll() is not None:raise RuntimeError('ExFAT child terminated before barrier '+str(child.communicate()))
     if time.monotonic()>deadline:raise RuntimeError('ExFAT barrier observation timeout')
     time.sleep(.01)
    assert (case/'barrier').read_text()==phase
    child.kill();child.communicate(timeout=10);assert child.returncode==-9;child=None
    check('ExFAT SIGKILL at '+phase,run(probe,'verify',case,phase,exfat_out).decode().strip())
  finally:
   if child is not None and child.poll() is None:child.kill();child.communicate(timeout=10)
 finally:
  (out/'commands.json').write_text(json.dumps(logs,ensure_ascii=False,indent=2))
  if not attached:shutil.rmtree(temp)
 (out/'checks.json').write_text(json.dumps(rows,ensure_ascii=False,indent=2));(out/'commands.json').write_text(json.dumps(logs,ensure_ascii=False,indent=2))
 print(f'STORAGE_FAULTS_RESULT checks={len(rows)} failures=0')
if __name__=='__main__':main()
