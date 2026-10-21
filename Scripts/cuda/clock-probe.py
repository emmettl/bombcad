#!/usr/bin/env python3
"""Read-only paired Mac/WSL/Windows clock observations over persistent SSH.

No remote files, GPU work, or clock settings changes. Native Windows Stopwatch/UTC
are bracketed by WSL clock observations and a Mac request/ack interval. Zero-duration
samples retain IPC/network overhead rather than assuming it away. No clock is declared
an absolute reference by this tool.
"""
import argparse
import base64
import datetime
import json
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time

WINDOWS = r'''
$ErrorActionPreference = 'Stop'
[Console]::WriteLine('ready')
while ($null -ne ($line = [Console]::ReadLine())) {
    $ms = [int]$line
    $q0 = [Diagnostics.Stopwatch]::GetTimestamp()
    $u0 = [DateTime]::UtcNow.Ticks
    if ($ms -gt 0) { [Threading.Thread]::Sleep($ms) }
    $q1 = [Diagnostics.Stopwatch]::GetTimestamp()
    $u1 = [DateTime]::UtcNow.Ticks
    [Console]::WriteLine((@{qpcStart=$q0; qpcEnd=$q1; utcStart=$u0; utcEnd=$u1;
       qpcFrequency=[Diagnostics.Stopwatch]::Frequency;
       qpcSeconds=($q1-$q0)/[double][Diagnostics.Stopwatch]::Frequency;
       utcSeconds=($u1-$u0)/[double][TimeSpan]::TicksPerSecond} | ConvertTo-Json -Compress))
}
'''
REMOTE = r'''
import json,subprocess,sys,time,platform
from pathlib import Path
exe='/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe'
if not Path(exe).is_file(): raise RuntimeError('native Windows PowerShell unavailable')
proc=subprocess.Popen([exe,'-NoLogo','-NoProfile','-NonInteractive','-EncodedCommand',ENCODED],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
def clock():
 return {name:time.clock_gettime_ns(getattr(time,name))/1e9 for name in ('CLOCK_MONOTONIC','CLOCK_MONOTONIC_RAW','CLOCK_BOOTTIME','CLOCK_REALTIME')}
def request(ms):
 proc.stdin.write((str(ms)+'\n').encode());proc.stdin.flush()
 line=proc.stdout.readline()
 if not line: raise RuntimeError('Windows clock process ended')
 return json.loads(line)
try:
 if proc.stdout.readline().strip()!=b'ready':raise RuntimeError('Windows clock process did not start')
 source=Path('/sys/devices/system/clocksource/clocksource0/current_clocksource')
 print(json.dumps(dict(ready=True,platform=platform.platform(),clocksource=source.read_text().strip(),
  clocks={k:vars(time.get_clock_info(k)) for k in ('time','monotonic','perf_counter')})),flush=True)
 for line in sys.stdin:
  h=json.loads(line); start=clock()
  if h['target']=='windows':
   native=request(h['milliseconds'])
  elif h['target']=='wsl':
   first=request(0);time.sleep(h['milliseconds']/1000);last=request(0)
   native=dict(qpcSeconds=(last['qpcEnd']-first['qpcStart'])/first['qpcFrequency'],
    utcSeconds=(last['utcEnd']-first['utcStart'])/1e7,qpcFrequency=first['qpcFrequency'])
  else:raise ValueError('invalid target')
  end=clock()
  print(json.dumps(dict(wslSeconds={k:end[k]-start[k] for k in start},windows=native)),flush=True)
finally:
 if proc.poll() is None:
  proc.stdin.close()
  try:proc.wait(timeout=5)
  except subprocess.TimeoutExpired:proc.kill();proc.wait()
'''


def main():
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('host');p.add_argument('--out',type=Path,required=True)
    p.add_argument('--context',required=True)
    p.add_argument('--durations',default='0,1,5,15',help='seconds per target, maximum 15')
    p.add_argument('--repetitions',type=int,default=3)
    a=p.parse_args()
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_.-]*',a.host):p.error('use a configured SSH alias')
    try:durations=[float(x) for x in a.durations.split(',')]
    except ValueError:p.error('invalid durations')
    if not durations or any(not 0<=x<=15 for x in durations) or not 1<=a.repetitions<=5:p.error('duration/repetition bounds exceeded')
    if 2*sum(durations)*a.repetitions>180:p.error('requested sleep budget exceeds 180 seconds')
    if a.out.exists():p.error('output must be new')
    code='ENCODED='+repr(base64.b64encode(WINDOWS.encode('utf-16le')).decode())+'\n'+REMOTE
    proc=subprocess.Popen(['ssh','-T','-o','BatchMode=yes','-o','ConnectTimeout=10',a.host,
                           'python3 -u -c '+shlex.quote(code)],stdin=subprocess.PIPE,stdout=subprocess.PIPE)
    def deadline(*_):raise TimeoutError('paired clock probe exceeded 240 seconds')
    previous=signal.signal(signal.SIGALRM,deadline);signal.alarm(240)
    report={'status':'running','date':datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'host':a.host,'context':a.context,'scope':__doc__,
            'localClocks':{k:vars(time.get_clock_info(k)) for k in ('time','monotonic','perf_counter')},'rows':[]}
    def save():
        temp=a.out.with_name(a.out.name+'.tmp');temp.write_text(json.dumps(report,indent=2)+'\n');temp.replace(a.out)
    save()
    try:
        report['remote']=json.loads(proc.stdout.readline());assert report['remote']['ready']
        for seconds in durations:
            for repetition in range(a.repetitions):
                for target in ('windows','wsl'):
                    start=time.perf_counter();wall=time.time()
                    proc.stdin.write(json.dumps(dict(target=target,milliseconds=round(seconds*1000))).encode()+b'\n');proc.stdin.flush()
                    row=json.loads(proc.stdout.readline())
                    row.update(target=target,requestedSeconds=seconds,repetition=repetition,
                               macPerfCounterRoundTripSeconds=time.perf_counter()-start,
                               macWallRoundTripSeconds=time.time()-wall)
                    report['rows'].append(row);save()
                    print(target,seconds,repetition,row['macPerfCounterRoundTripSeconds'],row['wslSeconds']['CLOCK_MONOTONIC'],row['windows']['qpcSeconds'],flush=True)
        proc.stdin.close();proc.wait(timeout=10)
        if proc.returncode:raise RuntimeError('SSH clock probe failed')
        report['status']='complete';save()
    except BaseException as e:
        report['status']='failed';report['error']=repr(e);save();raise
    finally:
        signal.alarm(0);signal.signal(signal.SIGALRM,previous)
        if proc.poll() is None:proc.kill();proc.wait()


if __name__=='__main__':main()
