import json,pathlib,subprocess
r=dict(scope='Read-only post-benchmark snapshot, taken during/after repository validation; not an independent QPC/UTC calibration',bootID=pathlib.Path('/proc/sys/kernel/random/boot_id').read_text().strip(),lockExists=pathlib.Path('bombcad-ml/lock').exists(),gpu=subprocess.check_output(['nvidia-smi','--query-gpu=utilization.gpu,memory.used','--format=csv,noheader'],text=True).strip())
for name,args in [('timesyncdActive',['systemctl','is-active','systemd-timesyncd']),('timesyncdEnabled',['systemctl','is-enabled','systemd-timesyncd'])]:
 p=subprocess.run(args,capture_output=True,text=True);r[name]=dict(returncode=p.returncode,stdout=p.stdout.strip())
p=subprocess.run(['/mnt/c/Windows/System32/wsl.exe','--system','--user','root','--exec','/usr/bin/chronyc','-n','tracking'],cwd='/mnt/c',capture_output=True,text=True,timeout=20);r['hostClockAgent']=dict(returncode=p.returncode,stdout=p.stdout,stderr=p.stderr)
print(json.dumps(r,indent=2))
