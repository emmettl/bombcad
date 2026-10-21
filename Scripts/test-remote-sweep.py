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
