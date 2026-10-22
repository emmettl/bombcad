"""Run one declared native Metal stage under the ordinary shared GPU lease."""
import argparse
import os
import signal
import subprocess

from prepare import ROOT, save, sha


def main():
    p = argparse.ArgumentParser()
    p.add_argument('stage', choices=['own', 'cross'])
    stage = p.parse_args().stage
    receipt = ROOT / ('metal-' + stage + '-process.json')
    assert not receipt.exists(), 'Observe existing stage rather than duplicating it'
    command = [os.path.expanduser('~/.local/bin/gpu-slot'), '--mem', '1',
               str(ROOT / 'runtime/replay'), str(ROOT), stage]
    with (ROOT / ('metal-' + stage + '.log')).open('xb') as log:
        proc = subprocess.Popen(command, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        state = dict(status='running', pid=proc.pid, command=command,
            binarySHA256=sha(ROOT / 'runtime/replay'))
        save(receipt, state)
        try:
            code = proc.wait(timeout=5400)
        except subprocess.TimeoutExpired:
            # This exact unreaped Popen child owns the process group; never signal a PID pattern.
            if proc.poll() is None:
                os.killpg(proc.pid, signal.SIGTERM)
            code = proc.wait(timeout=10)
            state['timedOut'] = True
        state.update(status='terminal', returncode=code)
        save(receipt, state)
    print('Metal', stage, 'terminal', code)
    if code:
        print((ROOT / ('metal-' + stage + '.log')).read_text())
    raise SystemExit(code)


if __name__ == '__main__':
    main()
