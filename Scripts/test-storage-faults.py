#!/usr/bin/env python3
"""Real ENOSPC and SIGKILL tests on our own disposable disk image. Never detaches the user's T7."""
import subprocess, tempfile, pathlib, os, time, json, shutil
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'Artifacts/Upgrade-0.5/Storage';out.mkdir(parents=True,exist_ok=True)
probe=root/'Build/UpgradeStage/StorageFaultProbe'
results=[]
with tempfile.TemporaryDirectory(prefix='jhcut-storage-') as temp:
 temp=pathlib.Path(temp);image=temp/'Fault.sparseimage';mount=temp/'mount';mount.mkdir()
 def run(*args):
  result=subprocess.run(list(map(str,args)),capture_output=True,text=True)
  if result.returncode:raise RuntimeError(f"{args[0]} failed ({result.returncode}): {result.stdout}\n{result.stderr}")
  return result.stdout
 run('hdiutil','create','-size','128m','-fs','APFS','-volname','JHCutFaultTest','-type','SPARSE',image)
 run('hdiutil','attach',image,'-nobrowse','-mountpoint',mount)
 try:
  run(probe,'seed',mount)
  with open(mount/'fill','wb',buffering=0) as f:
   try:
    while True:f.write(b'\xa5'*65536)
   except OSError as e:
    if e.errno != 28:raise
  # Consume small remaining data blocks too.
  with open(mount/'fill','ab',buffering=0) as f:
   try:
    while True:f.write(b'\xa5'*4096)
   except OSError as e:
    if e.errno != 28:raise
  result=run(probe,'full',mount);results.append({'test':'real-enospc','passed':True,'detail':result.strip()})
  (mount/'fill').unlink()
  child=subprocess.Popen([str(probe),'crash',str(mount)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
  for _ in range(1000):
   if (mount/'writing').exists():break
   if child.poll() is not None:raise RuntimeError('Crash fixture exited before kill')
   time.sleep(.005)
  time.sleep(.01);child.kill();child.wait()
  result=run(probe,'verify',mount);results.append({'test':'sigkill-during-save','passed':True,'detail':result.strip()})
  fixture=root/'Artifacts/Upgrade-0.5/Features-Final/fixtures/장면 1/같은 이름 영상.mp4'
  shutil.copy2(fixture,mount/'clip.mp4')
  run(probe,'prepare-media',mount,out)
  run('hdiutil','detach',mount)
  result=run(probe,'offline',mount,out);results.append({'test':'disposable-volume-detached','passed':True,'detail':result.strip()})
  run('hdiutil','attach',image,'-nobrowse','-mountpoint',mount)
  result=run(probe,'resumed',mount,out);results.append({'test':'remount-and-export','passed':True,'detail':result.strip()})
 finally:
  if os.path.ismount(mount):run('hdiutil','detach',mount)
(out/'checks.json').write_text(json.dumps(results,ensure_ascii=False,indent=2))
print(json.dumps(results,ensure_ascii=False,indent=2))
