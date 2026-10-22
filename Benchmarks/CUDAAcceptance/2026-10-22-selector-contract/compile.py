"""Compile the frozen Swift harness in the original linked SDK15 context."""
import re
import subprocess

from prepare import ROOT, SDK, load, save, sha


def main():
    for name, digest in load(ROOT / 'preparation.json')['pins'].items(): assert sha(name) == digest, name
    compiler = '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc'
    binary = ROOT / 'runtime/replay'
    assert not binary.exists()
    command = [compiler, '-O', '-warnings-as-errors', '-target', 'arm64-apple-macosx15.0',
        '-sdk', str(SDK), '-module-cache-path', str(ROOT.with_name(ROOT.name + '-module-cache')),
        str(ROOT / 'analysis/replay.swift'), '-o', str(binary)]
    with (ROOT / 'compile.log').open('xb') as f:
        p = subprocess.run(command, stdout=f, stderr=subprocess.STDOUT)
    report = dict(returncode=p.returncode, command=command, compilerSHA256=sha(compiler))
    if p.returncode == 0:
        linked = subprocess.check_output(['/usr/bin/otool', '-l', str(binary)], text=True)
        (ROOT / 'linked-sdk.txt').write_text(linked)
        version = re.search(r'cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos ([\d.]+)\s+sdk ([\d.]+)', linked)
        assert version is not None
        report.update(linkedMinOS=version[1], linkedSDK=version[2], binarySHA256=sha(binary))
    save(ROOT / 'compile.json', report)
    assert p.returncode == 0, (ROOT / 'compile.log').read_text()
    assert report['linkedMinOS'] == report['linkedSDK'] == '15.0'
    print('Frozen harness warning-free; linked minOS/SDK15.0')


if __name__ == '__main__': main()
