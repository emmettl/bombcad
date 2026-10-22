"""Retain pre-dispatch SDK mismatch and explicitly restore captured linker context."""
import re
import shutil
import subprocess

from prepare import HERE, ROOT, SDK, load, save, sha


def main():
    for name, digest in load(ROOT / 'preparation.json')['pins'].items(): assert sha(name) == digest, name
    old = load(ROOT / 'compile.json')
    assert old['returncode'] == 0 and old['linkedMinOS'] == '15.0' and old['linkedSDK'] == '27.0'
    assert not list(ROOT.glob('metal-*/receipt.json')), 'Pre-dispatch repair only'
    retained = ROOT / 'preflight-attempt-1'; retained.mkdir(exist_ok=False)
    for name in ['compile.json', 'compile.log', 'linked-sdk.txt', 'runtime/replay']:
        source = ROOT / name
        shutil.move(source, retained / source.name)
    shutil.copyfile(HERE / 'compile_sdk15.py', ROOT / 'analysis/compile_sdk15.py')
    compiler = old['command'][0]
    binary = ROOT / 'runtime/replay'
    command = [compiler, '-O', '-warnings-as-errors', '-target', 'arm64-apple-macosx15.0',
        '-sdk', str(SDK), '-module-cache-path', str(ROOT.with_name(ROOT.name + '-module-cache')),
        '-Xlinker', '-platform_version', '-Xlinker', 'macos', '-Xlinker', '15.0', '-Xlinker', '15.0',
        str(ROOT / 'analysis/replay.swift'), '-o', str(binary)]
    with (ROOT / 'compile.log').open('xb') as f:
        p = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT)
    report = dict(returncode=p.returncode, command=command, compilerSHA256=sha(compiler),
        sourceSHA256=sha(ROOT / 'analysis/replay.swift'), retainedPreflight=str(retained),
        sourceAudit='Original frozen harness and Metal source unchanged; explicit linked minOS/SDK15')
    if p.returncode == 0:
        linked = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
        (ROOT / 'linked-sdk.txt').write_text(linked)
        version = re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([\d.]+)\s+sdk ([\d.]+)', linked)
        assert version is not None
        report.update(linkedMinOS=version[1], linkedSDK=version[2], binarySHA256=sha(binary))
    save(ROOT / 'compile.json', report)
    assert p.returncode == 0, (ROOT / 'compile.log').read_text()
    assert report['linkedMinOS'] == report['linkedSDK'] == '15.0'
    print('Frozen harness warning-free; explicit linked minOS/SDK15.0')


if __name__ == '__main__': main()
