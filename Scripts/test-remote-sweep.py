"""Tests of remote-sweep.py's cases and comparison: python3 Scripts/test-remote-sweep.py"""

import importlib.util
import json
import os
import tempfile
import unittest
from unittest.mock import patch
import shutil
import shlex
import subprocess
import sys
import signal
import time
from pathlib import Path

here = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("remote_sweep", os.path.join(here, "remote-sweep.py"))
sweep = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sweep)


class CaseTests(unittest.TestCase):
    def test_local_sweeps_keep_unflattened_inputs_with_equal_basenames(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder)
            inputs = []
            for name in ("a", "b"):
                p = base / name / "input.json"; p.parent.mkdir(); p.write_text("{}"); inputs.append(str(p))
            request = base / "sweep.json"
            sweep.atomic_json(request, dict(name="same", inputs=inputs, cases=[dict(name="one", args=[])]))
            with patch.object(sweep, "build", return_value="fake"), patch.object(sweep, "run_cases", return_value=([], 0)):
                self.assertEqual(sweep.run(["--here", str(request), "--results", str(base / "local")]), 0)
            with patch.object(sweep.runner, "reachable") as reached:
                with self.assertRaises(ValueError): sweep.run(["fake", str(request), "--results", str(base / "remote")])
                reached.assert_not_called()

    def test_inputs_repo_and_out_are_taken_to_the_hosts_copies(self):
        args = ["protect", "--osm", "{repo}/Fixtures/a.osm", "--inputs", "/data/in/protect.json",
                "--confirm", "/data/loads", "--out", "{out}/plans.json", "--centre", "1,2"]
        mapped = sweep.localize(args, ["/data/in/", "/data/loads"], "/home/x/src", "/home/x/runs/a", "/home/x/inputs/s")
        self.assertEqual(mapped, [
            "protect", "--osm", "/home/x/src/Fixtures/a.osm", "--inputs", "/home/x/inputs/s/in/protect.json",
            "--confirm", "/home/x/inputs/s/loads", "--out", "/home/x/runs/a/plans.json", "--centre", "1,2"])
        # Here, the inputs stay where they are.
        self.assertEqual(sweep.localize(["/data/loads"], ["/data/loads"], "/r", "/o", None), ["/data/loads"])


class SnapshotTests(unittest.TestCase):
    @unittest.skipUnless(shutil.which("rsync"), "rsync is required for source reuse")
    def test_source_reuse_preserves_basis_bytes_modes_and_cache_independence(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder) / "host"; local = Path(folder) / "local"; local.mkdir()
            (local / "large.bin").write_bytes(bytes(range(256)) * 4096)
            (local / "edit.txt").write_text("A"); (local / "mode.txt").write_text("mode")
            for p in local.iterdir(): os.utime(p, (1700000000, 1700000000))
            old = root / "staging" / ("a" * 32); (old / "src").mkdir(parents=True)
            subprocess.run(["rsync", "-a", str(local) + "/", str(old / "src") + "/"], check=True)
            original = sweep.tree_manifest(old / "src", sweep.EXCLUDED)
            sweep.atomic_json(old / "manifest.json", dict(src=original))
            sweep.atomic_json(old / "completion.json", dict(invocation=old.name, exitCode=0))
            self.assertEqual(sweep.source_basis(root), old.name)
            (local / "edit.txt").write_text("B")
            os.utime(local / "edit.txt", (1700000000, 1700000000))
            (local / "mode.txt").chmod(0o700)
            new = root / "staging" / ("b" * 32); (new / "src").mkdir(parents=True)
            sweep.atomic_json(new / "manifest.json", dict(src=sweep.tree_manifest(local)))
            self.assertEqual(sweep.prepare_source_basis(new.name, root), old.name)
            subprocess.run(["rsync", "-a", "--checksum", "--link-dest=../basis",
                            str(local) + "/", str(new / "src") + "/"], check=True)
            self.assertEqual(sweep.tree_manifest(new / "src"), sweep.tree_manifest(local))
            self.assertEqual(sweep.tree_manifest(old / "src"), original)
            self.assertEqual((old / "src/large.bin").stat().st_ino, (new / "src/large.bin").stat().st_ino)
            for name in ("edit.txt", "mode.txt"):
                self.assertNotEqual((old / "src" / name).stat().st_ino, (new / "src" / name).stat().st_ino)
            cache = root / "src"; cache.mkdir()
            subprocess.run(["rsync", "-a", "--checksum", str(new / "src") + "/", str(cache) + "/"], check=True)
            (cache / "large.bin").write_bytes(b"mutable build output")
            self.assertEqual(sweep.tree_manifest(old / "src"), original)
            self.assertEqual(sweep.tree_manifest(new / "src"), sweep.tree_manifest(local))
            # A basis removed after selection can be ignored by rsync or fail closed;
            # a successful transfer must still have the complete requested identity.
            shutil.rmtree(old)
            missing = root / "staging" / ("c" * 32); (missing / "src").mkdir(parents=True)
            result = subprocess.run(["rsync", "-a", "--checksum", "--link-dest=../../%s/src" % old.name,
                                     str(local) + "/", str(missing / "src") + "/"], capture_output=True)
            if result.returncode == 0:
                self.assertEqual(sweep.tree_manifest(missing / "src"), sweep.tree_manifest(local))
            self.assertIsNone(sweep.source_basis(root))  # uncompleted destinations are ineligible
            # Exercise removal inside the actual basis preparation, after selection
            # but before the first link. The private empty view safely falls back.
            sweep.atomic_json(new / "completion.json", dict(invocation=new.name, exitCode=0))
            raced = root / "staging" / ("d" * 32); (raced / "src").mkdir(parents=True)
            sweep.atomic_json(raced / "manifest.json", dict(src=sweep.tree_manifest(local)))
            original_link = os.link; removed = []
            def remove_basis_then_link(source, target):
                if not removed:
                    shutil.rmtree(new / "src"); removed.append(True)
                return original_link(source, target)
            with patch.object(sweep.os, "link", side_effect=remove_basis_then_link):
                self.assertEqual(sweep.prepare_source_basis(raced.name, root), new.name)
            self.assertTrue(removed)
            subprocess.run(["rsync", "-a", "--checksum", "--link-dest=../basis",
                            str(local) + "/", str(raced / "src") + "/"], check=True)
            self.assertEqual(sweep.tree_manifest(raced / "src"), sweep.tree_manifest(local))

    def test_source_basis_rejects_corruption_wrong_identity_and_mutable_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); (root / "src").mkdir(); (root / "src/value").write_text("cache")
            self.assertIsNone(sweep.source_basis(root))
            stage = root / "staging" / ("a" * 32); (stage / "src").mkdir(parents=True)
            (stage / "src/value").write_text("A")
            sweep.atomic_json(stage / "manifest.json", dict(src=sweep.tree_manifest(stage / "src")))
            sweep.atomic_json(stage / "completion.json", dict(invocation="b" * 32, exitCode=0))
            self.assertIsNone(sweep.source_basis(root))
            sweep.atomic_json(stage / "completion.json", dict(invocation=stage.name, exitCode=0))
            self.assertEqual(sweep.source_basis(root), stage.name)
            (stage / "src/value").write_text("B")
            self.assertIsNone(sweep.source_basis(root))
            (stage / "src/value").write_text("A")
            for malformed in (None, [], False, {"invocation": stage.name, "exitCode": False}):
                sweep.atomic_json(stage / "completion.json", malformed)
                self.assertIsNone(sweep.source_basis(root))

    @unittest.skipUnless(shutil.which("rsync"), "rsync is required for host activation")
    def test_activation_copies_same_size_same_mtime_edits_and_keeps_build_cache(self):
        with tempfile.TemporaryDirectory() as folder:
            home = Path(folder); options = dict(invocation="a" * 32, wait=0)
            stage = home / sweep.invocation_path(options["invocation"])
            for name in ("src", "tools", "inputs"): (stage / name).mkdir(parents=True)
            cache = home / sweep.ROOT / "src"; cache.mkdir()
            (stage / "src/value.txt").write_text("B"); (cache / "value.txt").write_text("A")
            for p in (stage / "src/value.txt", cache / "value.txt"): os.utime(p, (1700000000, 1700000000))
            (cache / ".build").mkdir(); (cache / ".build/keep").write_text("cache")
            sweep.atomic_json(stage / "request.json", options)
            sweep.atomic_json(stage / "manifest.json", dict(src=sweep.tree_manifest(stage / "src", sweep.EXCLUDED),
                                                             tools={}, inputs={}, request=options))
            expand = os.path.expanduser
            with patch.object(sweep.os.path, "expanduser", side_effect=lambda p: folder if p == "~" else expand(p)):
                repo, _ = sweep.activate_snapshot(options)
            self.assertEqual(Path(repo, "value.txt").read_text(), "B")
            self.assertEqual((cache / ".build/keep").read_text(), "cache")

    def test_staging_during_an_active_build_cannot_change_it_or_its_results(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder); source = base / "local"; host = base / "host"
            source.mkdir(); host.mkdir(); (source / "value.txt").write_text("A")
            data = base / "input.txt"; data.write_text("A")
            a = dict(kind="run", invocation="a" * 32, host="fake", cores=1, wait=0,
                     sweep=dict(name="same-name", inputs=[str(data)], cases=[dict(name="one", args=[])]))
            b = dict(a, invocation="b" * 32)
            original_run = subprocess.run
            original_expand = os.path.expanduser
            transfers = []

            def remote(command_host, command, **kwargs):
                self.assertEqual(command_host, "fake")
                return original_run(["sh", "-c", command], cwd=host, capture_output=True)

            def copy(command, **kwargs):
                if command[0] != "rsync":
                    if command[-1].startswith("cat > "):
                        target = host / command[-1][6:]
                        target.write_bytes(kwargs["input"])
                        return subprocess.CompletedProcess(command, 0)
                    return original_run(command, **kwargs)
                transfers.append(command)
                sources = []; i = 1
                while i < len(command) - 1:
                    item = command[i]
                    if item in ("-e", "--exclude"):
                        i += 2; continue
                    if not item.startswith("-"): sources.append(item)
                    i += 1
                destination = command[-1]
                target = host / destination.split(":", 1)[1] if ":" in destination else Path(destination)
                target.mkdir(parents=True, exist_ok=True)
                if "--delete" in command:
                    for child in target.iterdir():
                        if child.name not in sweep.EXCLUDED:
                            shutil.rmtree(child) if child.is_dir() else child.unlink()
                for name in sources:
                    path = Path(name)
                    if path.is_dir():
                        into = target if name.endswith("/") else target / path.name
                        shutil.copytree(path, into, dirs_exist_ok=True, symlinks=True,
                                        ignore=shutil.ignore_patterns(*sweep.EXCLUDED) if "--exclude" in command else None)
                    else:
                        shutil.copy2(path, target / path.name)
                return subprocess.CompletedProcess(command, 0)

            built = []

            def build(repo, cores, log):
                identity = (Path(repo) / "value.txt").read_text(); built.append(identity)
                if identity == "A":
                    (source / "value.txt").write_text("B"); data.write_text("B")
                    self.assertEqual(sweep.send_worktree("fake", lambda _: None, b), 0)
                    self.assertEqual((Path(repo) / "value.txt").read_text(), "A")
                    self.assertEqual(sweep.serve_run(b), sweep.TAKEN)
                    self.assertEqual((Path(repo) / "value.txt").read_text(), "A")
                    # Future local edits must not enter the retained B snapshot on resume.
                    (source / "value.txt").write_text("C"); data.write_text("C")
                return "fake-binary"

            def cases(plan, repo, binary, out, inputs, cores, log):
                identity = (Path(repo) / "value.txt").read_text()
                self.assertEqual((Path(inputs) / "input.txt").read_text(), identity)
                (Path(out) / "identity.txt").write_text(identity)
                return [dict(case="one", exitCode=0)], 0

            with patch.object(sweep, "REPO", str(source)), patch.object(sweep.runner, "ssh", side_effect=remote), \
                    patch.object(sweep.subprocess, "run", side_effect=copy), \
                    patch.object(sweep.os.path, "expanduser", side_effect=lambda p: str(host) if p == "~" else original_expand(p)), \
                    patch.object(sweep, "build", side_effect=build), patch.object(sweep, "run_cases", side_effect=cases):
                self.assertEqual(sweep.send_worktree("fake", lambda _: None, a), 0)
                self.assertEqual(sweep.serve_run(a), 0)
                first = host / sweep.invocation_path(a["invocation"]) / "results/identity.txt"
                self.assertEqual(first.read_text(), "A")
                self.assertEqual(sweep.serve_run(b), 0)
                self.assertEqual(first.read_text(), "A")
                self.assertEqual(sweep.serve_run(a), 0)  # Recovery reuses completion, not current C or cache B.
                self.assertEqual(built, ["A", "B"])
                self.assertTrue(all("staging/" in cmd[-1] for cmd in transfers if ":" in cmd[-1]))
                stage = host / sweep.invocation_path(a["invocation"])
                (stage / "results/identity.txt").write_text("tampered")
                with self.assertRaisesRegex(ValueError, "results changed"):
                    sweep.serve_run(a)
                (stage / "results/identity.txt").write_text("A")
                (stage / "inputs/input.txt").write_text("tampered")
                with self.assertRaisesRegex(ValueError, "snapshot changed"):
                    sweep.serve_run(a)
                self.assertEqual(built, ["A", "B"])
                (stage / "inputs/input.txt").write_text("A")
                request = json.loads((stage / "request.json").read_text()); request["cores"] = 99
                sweep.atomic_json(stage / "request.json", request)
                with self.assertRaisesRegex(ValueError, "request changed"):
                    sweep.serve_run(a)

    def test_manifest_rejects_modified_inputs_and_external_links(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); tree = root / "tree"; tree.mkdir()
            (tree / "file").write_text("before"); before = sweep.tree_manifest(tree)
            (tree / "file").write_text("after"); self.assertNotEqual(before, sweep.tree_manifest(tree))
            (tree / "internal").symlink_to("file")
            self.assertEqual(sweep.tree_manifest(tree)["internal"], {"link": "file"})
            (tree / "external").symlink_to(root / "outside")
            with self.assertRaises((ValueError, FileNotFoundError)): sweep.tree_manifest(tree)
            with self.assertRaises(ValueError): sweep.input_manifest([str(tree), str(tree)])
            with self.assertRaises(ValueError): sweep.input_manifest([str(tree / "..")])
            with self.assertRaises(ValueError): sweep.invocation_path("../active")

    def test_source_exclusions_never_hide_declared_input_or_result_payloads(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("dist", ".build", "__pycache__"):
                (root / name).mkdir(); (root / name / "record").write_text("declared payload")
            self.assertEqual(sweep.tree_manifest(root, sweep.EXCLUDED), {})
            inputs = sweep.input_manifest([str(root)])
            results = sweep.tree_manifest(root)
            for name in ("dist", ".build", "__pycache__"):
                self.assertIn(root.name + "/" + name + "/record", inputs)
                self.assertIn(name + "/record", results)
            self.assertIn("dist/record", sweep.input_manifest([str(root / "dist")]))

    def test_wait_uses_a_bounded_monotonic_deadline(self):
        with patch.object(sweep, "ownership_guard", return_value=sweep.contextlib.nullcontext()), \
                patch.object(sweep, "sweep_owner", return_value=dict(pid=321, what="held")), \
                patch.object(sweep.runner, "boot_id", return_value="boot"), \
                patch.object(sweep.runner, "acquire") as acquire, \
                patch.object(sweep.time, "monotonic", side_effect=[0, 0, .5, 1, 1.5, 2]), \
                patch.object(sweep.time, "sleep") as sleep:
            self.assertIsNone(sweep.take_lock(dict(wait=2, invocation="a" * 32), "waiting"))
            self.assertEqual([c.args[0] for c in sleep.call_args_list], [1.5, .5])
            acquire.assert_not_called()

    def test_taken_test_lane_cannot_activate_or_release_another_owner(self):
        with patch.object(sweep, "take_lock", return_value=None), \
                patch.object(sweep, "activate_snapshot") as activate, patch.object(sweep, "release_sweep") as release:
            self.assertEqual(sweep.serve_test(dict(suites=["One"])), sweep.TAKEN)
            activate.assert_not_called(); release.assert_not_called()

    def test_interrupted_or_completed_test_invocation_does_not_rebuild(self):
        with tempfile.TemporaryDirectory() as folder:
            stage = Path(folder)
            with patch.object(sweep, "take_lock", return_value="owned"), \
                    patch.object(sweep, "release_sweep") as release, \
                    patch.object(sweep, "verify_snapshot", return_value=(folder, {})), \
                    patch.object(sweep, "activate_snapshot") as activate:
                (stage / "started.json").write_text("{}")
                options = dict(suites=["One"], invocation="d" * 32)
                self.assertEqual(sweep.serve_test(options), 1)
                sweep.atomic_json(stage / "completion.json", dict(invocation=options["invocation"], exitCode=0))
                self.assertEqual(sweep.serve_test(options), 0)
                activate.assert_not_called(); self.assertEqual(release.call_count, 2)

    def test_resume_refuses_an_existing_destination_before_worker_dispatch(self):
        with tempfile.TemporaryDirectory() as folder:
            options = dict(kind="run", invocation="e" * 32, host="fake", sweep=dict(name="same"))
            Path(folder, "same-fake").mkdir()
            read = subprocess.CompletedProcess([], 0, json.dumps(options).encode())
            with patch.object(sweep.runner, "ssh", return_value=read), patch.object(sweep, "remote_worker") as worker:
                self.assertEqual(sweep.resume(["fake", options["invocation"], "--results", folder]), 2)
                worker.assert_not_called()

    def test_completion_cannot_be_reused_for_a_different_invocation(self):
        with tempfile.TemporaryDirectory() as folder:
            sweep.atomic_json(Path(folder, "completion.json"), dict(invocation="f" * 32, exitCode=0))
            with self.assertRaises(ValueError): sweep.completed_code(dict(invocation="e" * 32), folder)

    def test_reserved_metadata_names_refuse_before_transfer_or_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            source = Path(folder) / "sweep.json"
            for name in ("..", "sweep.json", "retrieval.json"):
                sweep.atomic_json(source, dict(name="safe", cases=[dict(name=name, args=[])]))
                with patch.object(sweep.runner, "ssh") as ssh:
                    with self.assertRaises(ValueError): sweep.run(["fake", str(source), "--results", folder])
                    ssh.assert_not_called()
            options = dict(invocation="c" * 32)
            receipt = json.dumps(dict(invocation=options["invocation"], exitCode=0,
                                     results={"retrieval.json": {"directory": True}})).encode()
            with patch.object(sweep.runner, "ssh", return_value=subprocess.CompletedProcess([], 0, receipt)):
                with self.assertRaises(ValueError): sweep.retrieve("fake", options, folder + "/out", 0, lambda _: None)
                self.assertFalse(Path(folder, "out").exists())

    def test_term_drains_only_the_workers_group_before_unlocking(self):
        with tempfile.TemporaryDirectory() as folder:
            lock = Path(folder) / "lock"
            code = f"""import importlib.util,sys,subprocess,os,json
s=importlib.util.spec_from_file_location('sweep', {sweep.__file__!r}); m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.prepare_worker(); os.mkdir({str(lock)!r})
m.atomic_json({str(lock / 'owner')!r},dict(pid=os.getpid(),pgid=os.getpgrp(),boot='test'))
p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)'])
print(p.pid,flush=True)
try: p.wait()
finally: m.release_sweep({str(lock)!r})
"""
            worker = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE, text=True, start_new_session=True)
            try:
                int(worker.stdout.readline())
                os.kill(worker.pid, signal.SIGTERM)
                worker.wait(timeout=8)
                self.assertEqual(sweep.group_members(worker.pid), [])
                self.assertFalse(lock.exists())
            finally:
                try: os.killpg(worker.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                worker.wait(timeout=5); worker.stdout.close()

    def test_retrieval_never_uses_the_shared_sweep_name_and_copy_failure_is_failure(self):
        with tempfile.TemporaryDirectory() as folder:
            options = dict(invocation="c" * 32)
            receipt = json.dumps(dict(invocation=options["invocation"], exitCode=0, results={})).encode()
            with patch.object(sweep.runner, "ssh", return_value=subprocess.CompletedProcess([], 0, receipt)), \
                    patch.object(sweep.subprocess, "run", return_value=subprocess.CompletedProcess([], 23)) as run:
                self.assertEqual(sweep.retrieve("fake", options, folder + "/out", 0, lambda _: None), 23)
                self.assertIn("staging/" + "c" * 32 + "/results/", run.call_args.args[0][-2])
                with self.assertRaises(FileExistsError):
                    sweep.retrieve("fake", options, folder + "/out", 0, lambda _: None)

    def test_retrieval_refusal_is_not_overridden_and_missing_bytes_do_not_pass(self):
        with tempfile.TemporaryDirectory() as folder:
            options = dict(invocation="c" * 32)
            receipt = json.dumps(dict(invocation=options["invocation"], exitCode=0,
                                     results={"missing": {"sha256": "bad", "mode": 420}})).encode()
            with patch.object(sweep.runner, "ssh", return_value=subprocess.CompletedProcess([], 0, receipt)), \
                    patch.object(sweep.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)) as copied:
                self.assertEqual(sweep.retrieve("fake", options, folder + "/refused", 1, lambda _: None), 1)
                copied.assert_not_called(); self.assertFalse(Path(folder, "refused").exists())
                self.assertEqual(sweep.retrieve("fake", options, folder + "/missing", 0, lambda _: None), 1)
                self.assertFalse(json.loads(Path(folder, "missing/retrieval.json").read_text())["filesVerified"])

    def test_disconnect_recovery_requires_the_receipted_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            base = Path(folder); template = base / "template"; template.mkdir()
            (template / "result.json").write_text('{"value":7}')
            options = dict(invocation="c" * 32)
            receipt = json.dumps(dict(invocation=options["invocation"], exitCode=0,
                                     results=sweep.tree_manifest(template))).encode()
            def copy(command, **kwargs):
                shutil.copy2(template / "result.json", Path(command[-1]) / "result.json")
                return subprocess.CompletedProcess(command, 0)
            with patch.object(sweep.runner, "ssh", return_value=subprocess.CompletedProcess([], 0, receipt)), \
                    patch.object(sweep.subprocess, "run", side_effect=copy):
                self.assertEqual(sweep.retrieve("fake", options, str(base / "recovered"), 255, lambda _: None), 0)
                self.assertTrue(json.loads((base / "recovered/retrieval.json").read_text())["filesVerified"])

    def test_orphaned_live_child_retains_ownership_after_worker_death(self):
        with tempfile.TemporaryDirectory() as folder:
            lock = Path(folder) / "lock"; lock.mkdir()
            script = "import subprocess,sys,time,os; p=subprocess.Popen([sys.executable,'-c','import time; time.sleep(60)']); print(p.pid,flush=True); time.sleep(60)"
            worker = subprocess.Popen([sys.executable, "-c", script], stdout=subprocess.PIPE, text=True, start_new_session=True)
            try:
                child = int(worker.stdout.readline())
                sweep.atomic_json(lock / "owner", dict(pid=worker.pid, pgid=worker.pid, boot="test", what="owned"))
                os.kill(worker.pid, signal.SIGKILL); worker.wait(timeout=5)
                self.assertEqual(sweep.sweep_owner(str(lock), "test")["pid"], worker.pid)
                self.assertTrue(lock.exists())
                os.killpg(worker.pid, signal.SIGKILL)
                deadline = time.monotonic() + 5
                while sweep.group_members(worker.pid) and time.monotonic() < deadline: time.sleep(.01)
                self.assertIsNone(sweep.sweep_owner(str(lock), "test"))
                self.assertFalse(lock.exists())
            finally:
                try: os.killpg(worker.pid, signal.SIGKILL)
                except ProcessLookupError: pass
                worker.wait(timeout=5); worker.stdout.close()

    def test_two_real_controllers_reclaim_a_stale_lease_with_only_one_winner(self):
        with tempfile.TemporaryDirectory() as folder:
            for trial in range(3):
                root = Path(folder) / str(trial); lock = root / "lock"; lock.mkdir(parents=True)
                sweep.atomic_json(lock / "owner", dict(pid=2_000_000_000, boot=sweep.runner.boot_id(), what="stale"))
                gate = root / "go"; workers = []
                try:
                    for ident in ["a" * 32, "b" * 32]:
                        code = f'''import importlib.util,sys,time,json
from pathlib import Path
s=importlib.util.spec_from_file_location('sweep',{sweep.__file__!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.ROOT={str(root)!r};m.prepare_worker();print('READY',flush=True)
while not Path({str(gate)!r}).exists():time.sleep(.005)
lease=m.take_lock(dict(wait=0,invocation={ident!r}),'synthetic race')
print('RESULT:'+json.dumps(0 if lease else 75),flush=True)
if lease:
 sys.stdin.readline();m.release_sweep(lease)
'''
                        worker = subprocess.Popen([sys.executable, "-c", code], stdout=subprocess.PIPE,
                                                  stdin=subprocess.PIPE, text=True, start_new_session=True)
                        workers.append(worker); self.assertEqual(worker.stdout.readline().strip(), "READY")
                    gate.write_text("go")
                    results = []
                    for worker in workers:
                        while True:
                            line = worker.stdout.readline()
                            if line.startswith("RESULT:"):
                                results.append(json.loads(line[7:])); break
                            if not line: self.fail("controller exited before reporting ownership")
                    self.assertEqual(sorted(results), [0, 75])
                finally:
                    for worker in workers:
                        worker.stdin.close()
                    for worker in workers:
                        try: worker.wait(timeout=5)
                        except subprocess.TimeoutExpired:
                            os.killpg(worker.pid, signal.SIGKILL); worker.wait(timeout=5)
                        worker.stdout.close()

    def test_zero_wait_does_not_block_behind_a_paused_transition_owner(self):
        with tempfile.TemporaryDirectory() as folder:
            lock = str(Path(folder) / "lock")
            code = f'''import importlib.util
s=importlib.util.spec_from_file_location('sweep',{sweep.__file__!r});m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
m.ROOT={folder!r};m.prepare_worker()
lease=m.take_lock(dict(wait=0,invocation='a'*32),'contender')
print('TAKEN',lease is None)
'''
            with sweep.ownership_guard(lock):
                result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True,
                                        start_new_session=True, timeout=5)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("TAKEN True", result.stdout)
                self.assertFalse(Path(lock).exists())


DAY = 86400


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / "bombcad-sweeps"
        self.now = time.time()
        self.count = 0

    def stage(self, days_ago, kind="test", state="completed", exit_code=0, retrieved=False, source=None):
        self.count += 1
        name = "%032x" % self.count
        path = self.root / "staging" / name
        (path / "inputs").mkdir(parents=True)
        if kind:
            sweep.atomic_json(path / "request.json", dict(kind=kind, invocation=name))
        if state in ("started", "completed"):
            sweep.atomic_json(path / "started.json", {})
        if state == "completed":
            sweep.atomic_json(path / "completion.json", dict(invocation=name, exitCode=exit_code))
        if retrieved:
            sweep.atomic_json(path / "retrieved.json", {})
        if source is not None:
            (path / "src").mkdir()
            for file, text in source.items():
                (path / "src" / file).write_text(text)
            sweep.atomic_json(path / "manifest.json", dict(src=sweep.tree_manifest(path / "src", sweep.EXCLUDED)))
        self.age(name, days_ago)
        return name

    def age(self, name, days_ago):
        path = self.root / "staging" / name
        for item in [path] + [path / receipt for receipt in sweep.RECEIPTS if (path / receipt).exists()]:
            os.utime(item, (self.now - days_ago * DAY,) * 2)

    def test_the_newest_the_basis_the_pending_and_the_unretrieved_stay(self):
        newest = [self.stage(0.1 * k) for k in range(4)]
        basis = self.stage(5, source={"a.swift": "same"})
        failed_source = self.stage(1, exit_code=1, source={"a.swift": "broken"})
        old_tests = [self.stage(3 + k) for k in range(3)]
        staged_recent = self.stage(1, kind=None, state="staged")
        staged_old = self.stage(3, kind=None, state="staged")
        interrupted_recent = self.stage(1, state="started")
        interrupted_old = self.stage(4, state="started")
        run_waiting = self.stage(6, kind="run")
        run_retrieved = self.stage(6, kind="run", retrieved=True)
        run_forgotten = self.stage(20, kind="run")
        current = self.stage(30)
        (self.root / "staging" / ".lane-probe-1").write_text("")
        (self.root / "staging" / "not-a-stage").mkdir()
        os.symlink(self.root / "staging" / basis, self.root / "staging" / ("f" * 32))
        remove, kept = sweep.stage_plan(self.root, current=current, now=self.now)
        remove, kept = dict(remove), dict(kept)
        self.assertEqual(set(remove), {failed_source, *old_tests, staged_old, interrupted_old, run_retrieved,
                                       run_forgotten})
        for name in newest:
            self.assertEqual(kept[name], "one of the newest 4")
        self.assertEqual(kept[basis], "the source basis")
        self.assertEqual(kept[current], "this invocation")
        self.assertEqual(kept[staged_recent], "staged, never started, recent")
        self.assertEqual(kept[interrupted_recent], "interrupted, recent")
        self.assertEqual(kept[run_waiting], "run results not yet retrieved")
        self.assertIn("over 14 days", remove[run_forgotten])
        self.assertEqual(len(kept) + len(remove), 17)  # the probe file, other names and links untouched

    def test_a_prune_keeps_source_reuse_working(self):
        # Emmettl/bombcad-work#70 links a new stage's unchanged files to the basis's: removing the
        # stages around it must leave the basis whole, and stages linked to removed ones intact.
        basis = self.stage(5, source={"a.swift": "one", "b.swift": "two"})
        older = self.stage(9, source={"a.swift": "one", "b.swift": "old"})
        linked = self.root / "staging" / basis / "src" / "c.swift"
        os.link(self.root / "staging" / older / "src" / "b.swift", linked)
        sweep.atomic_json(self.root / "staging" / basis / "manifest.json",
                          dict(src=sweep.tree_manifest(self.root / "staging" / basis / "src", sweep.EXCLUDED)))
        self.age(basis, 5)
        for k in range(4):
            self.stage(0.1 * k, exit_code=1)  # newer, but failing: none is a basis
        report = sweep.prune_staging(self.root, keep=2)
        self.assertEqual({entry["stage"] for entry in report["removed"]}, {"%032x" % 5, "%032x" % 6, older})
        self.assertFalse((self.root / "staging" / older).exists())
        self.assertTrue((self.root / "staging" / basis).exists())
        self.assertEqual(linked.read_text(), "old")
        self.assertEqual(sweep.source_basis(self.root), basis)
        self.assertEqual(len(report["kept"]), 3)
        self.assertEqual(len(report["removed"]), 3)

    def test_a_stage_emptied_by_hand_is_not_made_new(self):
        old = self.stage(5, kind=None, state="staged", source={"a.swift": "x"})
        for k in range(4):
            self.stage(1 + 0.1 * k)
        shutil.rmtree(self.root / "staging" / old / "src")  # the folder's time is now, its receipts' not
        remove, _ = sweep.stage_plan(self.root, now=self.now)
        self.assertEqual(dict(remove), {old: "staged, never started, over 2 days old"})

    def test_a_dry_run_removes_nothing(self):
        for k in range(6):
            self.stage(3 + k)
        report = sweep.prune_staging(self.root, dry_run=True)
        self.assertEqual(len(report["removed"]), 2)
        self.assertEqual(len(list((self.root / "staging").iterdir())), 6)
        report = sweep.prune_staging(self.root)
        self.assertEqual(len(list((self.root / "staging").iterdir())), 4)

    def test_the_worker_prunes_only_its_own_hosts_staging(self):
        for k in range(6):
            self.stage(3 + k)
        with patch.object(sweep, "prune_staging") as pruned:
            sweep.prune_after("owned", "a" * 32)  # not a lock path: a test's stand-in
            pruned.assert_not_called()
        sweep.prune_after(str(self.root / "lock"), "%032x" % 6)
        names = sorted(p.name for p in (self.root / "staging").iterdir())
        self.assertEqual(names, ["%032x" % k for k in (1, 2, 3, 4, 6)])
        with patch.object(sweep, "stage_plan", side_effect=OSError("disk gone")):
            sweep.prune_after(str(self.root / "lock"), None)  # said, never raised

    def test_the_serving_prune_takes_the_lock_and_gives_it_back(self):
        for k in range(6):
            self.stage(3 + k)
        expand = os.path.expanduser
        output = __import__("io").StringIO()
        with patch.object(sweep.os.path, "expanduser",
                          side_effect=lambda p: self.directory.name if p == "~" else expand(p)), \
                __import__("contextlib").redirect_stdout(output):
            self.assertEqual(sweep.serve_prune({}), 0)
            report = json.loads(output.getvalue().strip().splitlines()[-1])
            self.assertEqual(len(report["removed"]), 2)
            self.assertFalse((self.root / "lock").exists())
            lock = sweep.take_lock(dict(invocation="b" * 32, wait=0), "a lane run")
            self.assertEqual(sweep.serve_prune({}), sweep.TAKEN)
            sweep.runner.release(lock)
        self.assertEqual(len(list((self.root / "staging").iterdir())), 4)


class SpaceTests(unittest.TestCase):
    SHORT = [dict(path="/home/x", label="~", freeBytes=900e9, sizeBytes=1000e9),
             dict(path="/mnt/c", label="C:", freeBytes=29e9, sizeBytes=998e9, windows=True, diskImages={})]

    def test_a_short_host_is_not_a_lane_and_gets_nothing(self):
        self.assertIn(sweep.NOSPACE, sweep.LANE_DOWN)
        with patch.object(sweep.runner, "host_space", return_value=self.SHORT), \
                patch.object(sweep, "send_worktree") as send, patch.object(sweep, "remote_worker") as worker:
            with tempfile.TemporaryFile(mode="w+") as stream:
                self.assertEqual(sweep.test("fake", ["One"], stream=stream), sweep.NOSPACE)
                stream.seek(0)
                self.assertIn("C: has 29.0 GB free", stream.read())
            send.assert_not_called(); worker.assert_not_called()
        ok = subprocess.CompletedProcess([], 0, b"ok\n")
        with patch.object(sweep.runner, "reachable", return_value=None), \
                patch.object(sweep.runner, "ssh", return_value=ok), \
                patch.object(sweep.runner, "host_space", return_value=self.SHORT):
            self.assertIn("short of space", sweep.lane_ready("fake"))

    def test_a_sweep_is_refused_before_anything_is_sent(self):
        with tempfile.TemporaryDirectory() as folder:
            request = Path(folder) / "sweep.json"
            sweep.atomic_json(request, dict(name="s", cases=[dict(name="one", args=[])]))
            with patch.object(sweep.runner, "reachable", return_value=None), \
                    patch.object(sweep.runner, "host_space", return_value=self.SHORT), \
                    patch.object(sweep, "send_worktree") as send:
                self.assertEqual(sweep.run(["fake", str(request), "--results", folder]), sweep.NOSPACE)
                send.assert_not_called()

    def test_the_send_is_counted_whole(self):
        with tempfile.TemporaryDirectory() as folder:
            data = Path(folder) / "inputs"; data.mkdir(); (data / "a.json").write_bytes(b"x" * 1000)
            (Path(folder) / "b.json").write_bytes(b"y" * 10)
            source = Path(folder) / "repo"; (source / ".build").mkdir(parents=True)
            (source / ".build" / "huge").write_bytes(b"z" * 5000); (source / "Package.swift").write_bytes(b"p" * 7)
            with patch.object(sweep, "REPO", str(source)):
                self.assertEqual(sweep.sending_bytes([str(data) + "/", str(Path(folder) / "b.json")]), 1017)


class CompareTests(unittest.TestCase):
    def test_numbers_within_the_tolerance_agree_and_beyond_it_do_not(self):
        self.assertEqual(sweep.same_json({"a": [1.0, 2.0]}, {"a": [1.0, 2.0 * (1 + 1e-12)]}, 1e-9), [])
        self.assertEqual(len(sweep.same_json({"a": 1.0}, {"a": 1.1}, 1e-9)), 1)
        self.assertEqual(len(sweep.same_json({"a": 1}, {"b": 1}, 1e-9)), 1)

    def test_two_sweeps_compare_file_by_file_times_left_out(self):
        with tempfile.TemporaryDirectory() as folder:
            for side, (plans, log) in {"a": ({"cost": 10.0}, "Chances in 25.7 s\n204 sides"),
                                       "b": ({"cost": 10.0}, "Chances in 9.1 s\n204 sides")}.items():
                os.makedirs(os.path.join(folder, side, "one"))
                json.dump({"cases": [{"case": "one"}]}, open(os.path.join(folder, side, "sweep.json"), "w"))
                json.dump(plans, open(os.path.join(folder, side, "one", "plans.json"), "w"))
                open(os.path.join(folder, side, "one", "log.txt"), "w").write(log)
            self.assertEqual(sweep.compare([os.path.join(folder, "a"), os.path.join(folder, "b")]), 0)
            open(os.path.join(folder, "b", "one", "log.txt"), "w").write("Chances in 9.1 s\n205 sides")
            self.assertEqual(sweep.compare([os.path.join(folder, "a"), os.path.join(folder, "b")]), 1)


if __name__ == "__main__":
    unittest.main()
