"""Deploy one native-reader stage once, under the existing shared PC lock."""
import argparse
import hashlib
import json
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
import uuid

HERE = Path(__file__).resolve().parent
ROOT = Path('/Volumes/StudioData/bombcad/experiments/2026-10-22-native-pressure-cross-replay')


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('stage', choices=['own', 'cross'])
    args = parser.parse_args()
    stage = args.stage
    assert json.loads((ROOT / 'metal-own-gate.json').read_text())['status'] == 'pass'
    if stage == 'cross':
        prior = json.loads((ROOT / 'cuda-own/receipt.json').read_text())
        assert prior['status'] == 'complete-all-outcomes' and prior['ownInputGatePass']
    staging = json.loads((ROOT / 'cuda-staging.json').read_text())
    for path, digest in staging['pins'].items():
        assert sha(path) == digest, path
    destination = ROOT / ('cuda-' + stage)
    assert not destination.exists()
    receipt_path = ROOT / ('cuda-' + stage + '-remote.json')
    assert not receipt_path.exists(), 'Observe existing stage; never duplicate it'
    pack = ROOT / 'remote-input'
    remote = 'bombcad-cuda/native-pressure-replay/jobs/' + uuid.uuid4().hex
    report = dict(status='deploying', stage=stage, remote=remote, host='bombcad-pc')
    def save():
        receipt_path.write_text(json.dumps(report, indent=2) + '\n')
    save()
    shutil.copyfile(__file__, ROOT / 'analysis' / ('run_cuda-' + stage + '.py'))
    subprocess.run(['ssh', '-o', 'BatchMode=yes', 'bombcad-pc',
        'python3 -c ' + shlex.quote('from pathlib import Path; (Path.home()/' + repr(remote) + ').mkdir(parents=True,exist_ok=False)')], check=True)
    subprocess.run(['scp', '-q', '-r', str(pack), 'bombcad-pc:' + remote + '/remote-input'], check=True)
    config = dict(remote=remote, stage=stage)
    script = """import json,os,pathlib,signal,subprocess
c=CONFIG
base=pathlib.Path.home()/c['remote'];root=base/'remote-input'
command=[str(pathlib.Path.home()/'bombcad-ml/venv/bin/python'),'-B',str(root/'worker/cuda_replay.py'),
 str(root),str(root/(c['stage']+'.json')),'--lock',str(pathlib.Path.home()/'bombcad-ml/lock'),'--stage',c['stage']]
with (base/'remote.log').open('xb') as log:
 p=subprocess.Popen(command,stdout=log,stderr=subprocess.STDOUT,start_new_session=True)
 boot=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()
 birth=pathlib.Path(f'/proc/{p.pid}/stat').read_text().split()[21]
 receipt=dict(status='running',pid=p.pid,boot=boot,birthTicks=birth,command=command)
 (base/'controller.json').write_text(json.dumps(receipt,indent=2)+'\\n')
 def same():
  return pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip()==boot and pathlib.Path(f'/proc/{p.pid}/stat').read_text().split()[21]==birth and pathlib.Path(f'/proc/{p.pid}/cmdline').read_bytes().rstrip(b'\\0').split(b'\\0')==[x.encode() for x in command]
 try:code=p.wait(timeout=5400)
 except subprocess.TimeoutExpired:
  assert same()
  os.killpg(p.pid,signal.SIGTERM)
  try:code=p.wait(timeout=10)
  except subprocess.TimeoutExpired:
   assert same();os.killpg(p.pid,signal.SIGKILL);code=p.wait()
  receipt['timedOut']=True
 receipt.update(status='terminal',returncode=code)
 (base/'controller.json').write_text(json.dumps(receipt,indent=2)+'\\n')
print(json.dumps(receipt))
raise SystemExit(code)
""".replace('CONFIG', repr(config))
    command = ['ssh', '-o', 'BatchMode=yes', 'bombcad-pc', 'python3 -c ' + shlex.quote(script)]
    report.update(status='running', command=command)
    save()
    with (ROOT / ('cuda-' + stage + '-ssh.log')).open('xb') as log:
        process = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        report['localSSHPID'] = process.pid
        save()
        code = process.wait()
    report.update(status='terminal', returncode=code)
    save()
    for name in ['controller.json', 'remote.log']:
        subprocess.run(['scp', '-q', 'bombcad-pc:' + remote + '/' + name,
                        str(ROOT / ('cuda-' + stage + '-' + name))], check=True)
    if code:
        print((ROOT / ('cuda-' + stage + '-remote.log')).read_text())
        raise SystemExit(code)
    subprocess.run(['scp', '-q', '-r', 'bombcad-pc:' + remote + '/remote-input/out-' + stage, str(destination)], check=True)
    for path, digest in staging['pins'].items():
        assert sha(path) == digest, path
    print((destination / 'receipt.json').read_text())


if __name__ == '__main__':
    main()
