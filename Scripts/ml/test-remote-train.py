"""remote-train.py's arguments, lock and dataset hash, without another machine."""

import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("remote_train", Path(__file__).with_name("remote-train.py"))
remote_train = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remote_train)

NOW = datetime.datetime(2026, 10, 20, 9, 30, 5, tzinfo=datetime.timezone.utc)


class ArgumentTests(unittest.TestCase):
    def test_everything_after_args_goes_to_the_script(self):
        plan = remote_train.parse(["bombcad-pc", "data", "train.py", "--dry-run", "--args", "--epochs", "3",
                                   "--dry-run", "--job", "x"], now=NOW)
        self.assertEqual(plan["args"], ["--epochs", "3", "--dry-run", "--job", "x"])
        self.assertTrue(plan["dryRun"])
        self.assertEqual(plan["job"], "train-20261020-093005-bombcad-pc")

    def test_the_hosts_settings(self):
        pc = remote_train.parse(["bombcad-pc", "d", "s.py"], now=NOW)
        self.assertEqual(pc["settings"]["venv"], "bombcad-ml/venv")
        self.assertEqual(pc["settings"]["lock"], "bombcad-ml/lock")
        self.assertEqual(pc["timeout"], 24 * 3600)
        laptop = remote_train.parse(["bombcad-laptop", "d", "s.py"], now=NOW)
        self.assertEqual(laptop["timeout"], 2 * 3600)
        # The mini: its own python3, and the lock BombCAD's checks take there.
        mini = remote_train.parse(["scrimply-ci-tb", "d", "s.py"], now=NOW)
        self.assertIsNone(mini["settings"]["venv"])
        self.assertEqual(mini["settings"]["lock"], "bombcad-remote/lock")
        self.assertEqual(mini["timeout"], 1.5 * 3600)
        other = remote_train.parse(["elsewhere", "d", "s.py"], now=NOW)
        self.assertFalse(other["known"])
        self.assertEqual(other["settings"], remote_train.DEFAULT_HOST)

    def test_options_override_the_host(self):
        plan = remote_train.parse(["bombcad-pc", "d", "s.py", "--venv", "none", "--timeout", "90m", "--wait", "1.5h",
                                   "--job", "first-try", "--results", "/tmp/r"], now=NOW)
        self.assertIsNone(plan["settings"]["venv"])
        self.assertEqual(plan["timeout"], 5400)
        self.assertEqual(plan["wait"], 5400)
        self.assertEqual(plan["job"], "first-try")
        self.assertEqual(plan["results"], "/tmp/r")
        # The host table itself is not changed.
        self.assertEqual(remote_train.HOSTS["bombcad-pc"]["venv"], "bombcad-ml/venv")

    def test_refusals(self):
        for arguments in (["bombcad-pc", "d"], ["bombcad-pc", "d", "s.py", "--epochs", "3"],
                          ["bombcad-pc", "d", "s.py", "--job", "../escape"], ["bombcad-pc", "d", "s.py", "--job"],
                          ["bombcad-pc", "d", "s.py", "--timeout", "soon"]):
            with self.assertRaises(ValueError, msg=arguments):
                remote_train.parse(arguments, now=NOW)

    def test_durations(self):
        self.assertEqual(remote_train.duration("3600"), 3600)
        self.assertEqual(remote_train.duration("90m"), 5400)
        self.assertEqual(remote_train.duration("1.5h"), 5400)
        self.assertEqual(remote_train.duration("30s"), 30)

    def test_an_unreachable_host_fails_cleanly(self):
        with tempfile.TemporaryDirectory() as folder:
            script = os.path.join(folder, "s.py")
            Path(script).write_text("print(1)\n")
            os.makedirs(os.path.join(folder, "data"))
            result = subprocess.run(
                [sys.executable, "-I", str(Path(__file__).with_name("remote-train.py")), "no-such-host.invalid",
                 os.path.join(folder, "data"), script, "--dry-run"],
                capture_output=True, text=True, timeout=120, env=dict(os.environ, HOME=folder))
            self.assertEqual(result.returncode, remote_train.UNREACHABLE, result.stderr)
            self.assertIn("unreachable", result.stderr)


class DatasetTests(unittest.TestCase):
    def test_the_hash_follows_content_not_hidden_files(self):
        with tempfile.TemporaryDirectory() as folder:
            os.makedirs(os.path.join(folder, "runs", "a"))
            Path(folder, "runs", "a", "inputs.npy").write_bytes(b"one")
            Path(folder, "meta.json").write_text("{}")
            first = remote_train.content_hash(remote_train.manifest(folder))
            Path(folder, ".DS_Store").write_bytes(b"noise")
            self.assertEqual(remote_train.content_hash(remote_train.manifest(folder)), first)
            Path(folder, "runs", "a", "inputs.npy").write_bytes(b"two")
            self.assertNotEqual(remote_train.content_hash(remote_train.manifest(folder)), first)
            self.assertEqual([entry[0] for entry in remote_train.manifest(folder)], ["meta.json", "runs/a/inputs.npy"])

    def test_the_cache_is_used_only_for_unchanged_files(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder, "x.npy")
            path.write_bytes(b"abc")
            cache = {}
            first = remote_train.manifest(folder, cache)
            self.assertIn(str(path), cache)
            # A cached hash is believed while size and time match...
            cache[str(path)][2] = "f" * 64
            self.assertEqual(remote_train.manifest(folder, cache)[0][2], "f" * 64)
            # ...and recomputed when they don't.
            path.write_bytes(b"abcd")
            self.assertNotEqual(remote_train.manifest(folder, cache)[0][2], "f" * 64)
            self.assertEqual(first[0][1], 3)

    def test_the_hosts_folder_name(self):
        self.assertEqual(remote_train.dataset_name("/x/smoke/", "0123456789abcdef0123"), "smoke-0123456789abcdef")
        self.assertEqual(remote_train.dataset_name("/x/my data", "ab" * 32), "my-data-" + "ab" * 8)


class LockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.lock = os.path.join(self.directory.name, "bombcad-ml", "lock")

    def owner(self):
        with open(os.path.join(self.lock, "owner")) as handle:
            return json.load(handle)

    def test_one_holder_at_a_time(self):
        self.assertTrue(remote_train.acquire(self.lock, "job a", boot="b1"))
        self.assertEqual(self.owner()["what"], "job a")
        self.assertEqual(self.owner()["pid"], os.getpid())
        # Held by this live process: a second taker is refused.
        self.assertFalse(remote_train.acquire(self.lock, "job b", boot="b1"))
        self.assertEqual(remote_train.lock_owner(self.lock, "b1")["what"], "job a")
        self.assertTrue(remote_train.release(self.lock))
        self.assertFalse(os.path.exists(self.lock))
        self.assertTrue(remote_train.acquire(self.lock, "job b", boot="b1"))

    def test_a_dead_owner_is_taken_over(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        self.assertTrue(remote_train.acquire(self.lock, "gone", boot="b1", pid=child.pid))
        self.assertIsNone(remote_train.lock_owner(self.lock, "b1"))
        self.assertTrue(remote_train.acquire(self.lock, "next", boot="b1"))
        self.assertEqual(self.owner()["what"], "next")

    def test_an_earlier_boots_lock_is_stale(self):
        # Its pid may be anyone's now (this process's, here).
        self.assertTrue(remote_train.acquire(self.lock, "before the reboot", boot="old"))
        self.assertIsNotNone(remote_train.lock_owner(self.lock, "old"))
        self.assertIsNone(remote_train.lock_owner(self.lock, "new"))
        self.assertTrue(remote_train.acquire(self.lock, "after", boot="new"))
        self.assertEqual(self.owner()["boot"], "new")

    def test_age_counts_only_when_asked(self):
        self.assertTrue(remote_train.acquire(self.lock, "long job", boot="b1"))
        owner = self.owner()
        owner["since"] -= 7 * 3600
        Path(self.lock, "owner").write_text(json.dumps(owner))
        self.assertIsNotNone(remote_train.lock_owner(self.lock, "b1"))
        self.assertIsNone(remote_train.lock_owner(self.lock, "b1", stale_seconds=6 * 3600))

    def test_a_folder_without_an_owner_is_being_taken(self):
        os.makedirs(self.lock)
        self.assertEqual(remote_train.lock_owner(self.lock)["what"], "starting")

    def test_release_leaves_another_holders_lock(self):
        self.assertTrue(remote_train.acquire(self.lock, "mine", pid=os.getppid()))
        self.assertFalse(remote_train.release(self.lock))
        self.assertTrue(os.path.exists(self.lock))

    def test_scripts_remote_reads_the_same_owner(self):
        # Scripts/remote.py sees the mini's lock taken while a job holds it.
        spec = importlib.util.spec_from_file_location("remote", Path(__file__).parents[1] / "remote.py")
        remote = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(remote)
        self.assertTrue(remote_train.acquire(self.lock, "remote-train job", boot=remote_train.boot_id()))
        self.assertEqual(remote.lock_owner(self.lock)["what"], "remote-train job")


class RecordTests(unittest.TestCase):
    def test_job_record(self):
        with tempfile.TemporaryDirectory() as folder:
            script = Path(folder, "train.py")
            script.write_text("print('hi')\n")
            plan = remote_train.parse(["bombcad-pc", folder, str(script), "--args", "--epochs", "2"], now=NOW)
            entries = [("a.npy", 10, "x"), ("b.npy", 5, "y")]
            record = remote_train.job_record(
                plan, {"machine": "pc", "gpu": "NVIDIA GeForce RTX 3080 Ti, 12288 MiB", "python": "3.12.3"},
                entries, "h" * 64, "data-hhhh", True, 100.0, 160.0, 0, {"seconds": 55.0, "timedOut": False})
            self.assertEqual(record["gpu"], "NVIDIA GeForce RTX 3080 Ti, 12288 MiB")
            self.assertEqual(record["dataset"]["bytes"], 15)
            self.assertEqual(record["dataset"]["files"], 2)
            self.assertTrue(record["dataset"]["sent"])
            self.assertEqual(record["seconds"], 60.0)
            self.assertEqual(record["remoteSeconds"], 55.0)
            self.assertEqual(record["exitCode"], 0)
            self.assertEqual(record["args"], ["--epochs", "2"])
            self.assertEqual(len(record["script"]["sha256"]), 64)


if __name__ == "__main__":
    unittest.main()
