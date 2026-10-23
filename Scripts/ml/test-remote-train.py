"""remote-train.py's arguments, lock, dataset hash, free-space check and retention, without another machine."""

import contextlib
import datetime
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest
import unittest.mock

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


GB = 1e9
DAY = 86400


def disk(free, size, windows=False, images=None):
    entry = {"path": "/mnt/c" if windows else "/home/x", "label": "C:" if windows else "~",
             "freeBytes": free, "sizeBytes": size}
    if windows:
        entry.update(windows=True, diskImages=images or {})
    return entry


class SpaceTests(unittest.TestCase):
    def test_the_floor_is_50_gb_or_15_percent_of_a_smaller_disk(self):
        self.assertEqual(remote_train.floor_for(1000 * GB, {}), 50 * GB)
        self.assertAlmostEqual(remote_train.floor_for(100 * GB, {}), 15 * GB)
        self.assertEqual(remote_train.floor_for(1000 * GB, {"BOMBCAD_HOST_MIN_FREE_GB": "20"}), 20 * GB)
        self.assertAlmostEqual(remote_train.floor_for(100 * GB, {"BOMBCAD_HOST_MIN_FREE_PERCENT": "5"}), 5 * GB)

    def test_a_send_that_would_leave_too_little_is_refused(self):
        self.assertIsNone(remote_train.space_refusal([disk(800 * GB, 1000 * GB)], 10 * GB, {}))
        self.assertIsNone(remote_train.space_refusal(None, 10 * GB, {}))  # A host that can't say
        refusal = remote_train.space_refusal([disk(55 * GB, 1000 * GB)], 10 * GB, {})
        self.assertIn("would leave 45.0 GB", refusal)
        self.assertNotIn("Optimize-VHD", refusal)
        # The Windows drive under WSL's disk image counts, whatever WSL's own df says.
        refusal = remote_train.space_refusal(
            [disk(796 * GB, 1007 * GB), disk(29 * GB, 998 * GB, windows=True, images={"/mnt/c/x/ext4.vhdx": 175 * GB})],
            0, {})
        self.assertIn("C: has 29.0 GB free", refusal)
        self.assertIn("/mnt/c/x/ext4.vhdx 175.0 GB", refusal)
        self.assertIn("wsl --shutdown", refusal)
        self.assertIn("Optimize-VHD", refusal)
        self.assertNotIn("~ has", refusal)
        self.assertIsNone(remote_train.space_refusal([disk(29 * GB, 998 * GB, windows=True)], 0,
                                                     {"BOMBCAD_HOST_MIN_FREE_GB": "10"}))

    def test_the_disks_a_send_lands_on(self):
        with tempfile.TemporaryDirectory() as folder:
            (here,) = remote_train.space_here(home=folder, wsl=False)
            self.assertEqual(here["path"], folder)
            self.assertGreater(here["freeBytes"], 0)
            self.assertGreaterEqual(here["sizeBytes"], here["freeBytes"])
            self.assertNotIn("windows", here)
            # Inside WSL, the drive holding its disk image too, with the images on it.
            drive = os.path.join(folder, "c")
            image = Path(drive, "Users", "u", "AppData", "Local", "wsl", "{guid}", "ext4.vhdx")
            image.parent.mkdir(parents=True)
            image.write_bytes(b"x" * 1000)
            self.assertEqual(len(remote_train.space_here(home=folder, windows=drive, wsl=True)), 1)  # not a mount
            real = os.path.ismount
            with unittest.mock.patch.object(remote_train.os.path, "ismount", side_effect=lambda p: p == drive or real(p)):
                home, windows = remote_train.space_here(home=folder, windows=drive, wsl=True)
            self.assertTrue(windows["windows"])
            self.assertEqual(windows["diskImages"], {str(image): 1000})
            self.assertIn("WSL", home["label"])


class RetentionTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = os.path.join(self.directory.name, "bombcad-ml")
        self.now = 1_800_000_000.0

    def dataset(self, name, used_days_ago, complete=True):
        path = os.path.join(self.root, "datasets", name)
        os.makedirs(path)
        Path(path, "runs.npy").write_bytes(b"data")
        if complete:
            Path(path, ".complete").touch()
            os.utime(os.path.join(path, ".complete"), (self.now - 30 * DAY,) * 2)
            Path(path, ".last-used").write_text("")
            os.utime(os.path.join(path, ".last-used"), (self.now - used_days_ago * DAY,) * 2)
        os.utime(path, (self.now - used_days_ago * DAY,) * 2)
        return path

    def job(self, name, days_ago, collected):
        path = os.path.join(self.root, "jobs", name)
        os.makedirs(os.path.join(path, "out"))
        if collected:
            Path(path, ".collected").write_text("{}")
        os.utime(path, (self.now - days_ago * DAY,) * 2)
        return path

    def plan(self, in_use=(), **keep):
        remove, keep_list = remote_train.prune_plan(self.root, now=self.now, in_use=lambda paths: {
            p for p in paths if p in in_use}, **keep)
        return {p: why for p, why in remove}, {p: why for p, why in keep_list}

    def test_datasets_beyond_the_last_used_go_unless_in_use(self):
        newest, second, old, older = (self.dataset(n, d) for n, d in (("a-1", 1), ("b-2", 2), ("c-3", 5), ("d-4", 9)))
        remove, keep = self.plan(in_use=(older,))
        self.assertEqual(set(remove), {old})
        self.assertEqual(keep[newest], keep[second])
        self.assertEqual(keep[older], "in use")
        remove, _ = self.plan(keep_datasets=3)
        self.assertEqual(set(remove), {older})

    def test_last_use_not_age_orders_datasets(self):
        made_long_ago = self.dataset("x-1", 1)
        os.utime(os.path.join(made_long_ago, ".complete"), (self.now - 100 * DAY,) * 2)
        self.dataset("y-2", 2)
        self.dataset("z-3", 3)
        remove, keep = self.plan()
        self.assertIn(made_long_ago, keep)
        self.assertEqual([os.path.basename(p) for p in remove], ["z-3"])

    def test_a_dataset_being_sent_stays_a_day(self):
        sending = self.dataset("new-1.partial", 0.5, complete=False)
        abandoned = self.dataset("old-2.partial", 3, complete=False)
        renamed = self.dataset("half-3", 3, complete=False)  # never marked complete
        remove, keep = self.plan()
        self.assertEqual(set(remove), {abandoned, renamed})
        self.assertEqual(keep[sending], "being sent")

    def test_jobs_go_once_collected_and_not_among_the_newest(self):
        recent = [self.job("j%d" % k, k, collected=True) for k in range(3)]
        old_collected = self.job("old-collected", 10, collected=True)
        old_uncollected = self.job("old-uncollected", 11, collected=False)
        running = self.job("old-running", 12, collected=True)
        remove, keep = self.plan(in_use=(running,))
        self.assertEqual(set(remove), {old_collected})
        self.assertEqual(keep[old_uncollected], "results not collected")
        self.assertEqual(keep[running], "in use")
        for path in recent:
            self.assertIn(path, keep)
        remove, _ = self.plan(in_use=(running,), keep_jobs=0)
        self.assertEqual(set(remove), set(recent) | {old_collected})

    def test_marking_old_jobs_collected_does_not_make_them_new(self):
        old = [self.job("old%d" % k, 10 + k, collected=False) for k in range(2)]
        for path in old:
            Path(path, "log.txt").write_text("ran")
            os.utime(os.path.join(path, "log.txt"), (self.now - 10 * DAY,) * 2)
        recent = [self.job("new%d" % k, k, collected=False) for k in range(3)]
        for path in old:
            Path(path, ".collected").write_text("{}")  # the folder's time is now
        remove, keep = self.plan()
        self.assertEqual(set(remove), set(old))
        # A job named collected by the Studio (its results there whole) counts as one marked.
        for path in old:
            os.remove(os.path.join(path, ".collected"))
        remove, _ = remote_train.prune_plan(self.root, now=self.now, in_use=lambda paths: set(),
                                            collected={"old0"})
        self.assertEqual([p for p, _ in remove], [old[0]])
        self.assertTrue(all(p in keep for p in recent))

    def test_nothing_but_datasets_and_jobs_is_looked_at(self):
        for name in ("venv", "experiments", "lock"):
            os.makedirs(os.path.join(self.root, name, "x"))
        os.makedirs(os.path.join(self.root, "datasets"))
        os.symlink(os.path.join(self.root, "venv"), os.path.join(self.root, "datasets", "linked-1"))
        remove, keep = self.plan(keep_datasets=1)
        self.assertEqual(remove, {})
        self.assertEqual(keep, {})

    def test_a_process_naming_a_folder_uses_it(self):
        path = self.dataset("live-5f3a9c1e", 1)
        other = self.dataset("idle-5f3a9c1e", 1)
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "--data", path])
        try:
            deadline = time.monotonic() + 10
            while not remote_train.processes_using([path]) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(remote_train.processes_using([path, other]), {path})
        finally:
            child.kill()
            child.wait()
        # A job waiting for the lock names its dataset only by the folder's name.
        child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)", "serve-run",
                                  json.dumps({"dataset": "idle-5f3a9c1e"})])
        try:
            deadline = time.monotonic() + 10
            while not remote_train.processes_using([other]) and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertEqual(remote_train.processes_using([path, other]), {other})
        finally:
            child.kill()
            child.wait()

    def serve_prune(self, **options):
        output = io.StringIO()
        with unittest.mock.patch.dict(os.environ, HOME=self.directory.name), contextlib.redirect_stdout(output):
            self.assertEqual(remote_train.serve_prune(dict({"lock": "bombcad-ml/lock"}, **options)), 0)
        return json.loads(output.getvalue().strip().splitlines()[-1])

    def test_the_hosts_prune_waits_for_the_lock_and_marks_collected_jobs(self):
        self.now = time.time()
        for k in range(4):
            self.dataset("ds%d-5f3a9c1e" % k, k)
        for k in range(4):
            self.job("job%d-5f3a9c1e" % k, k, collected=k > 0)
        lock = os.path.join(self.root, "lock")
        # A job holds the lock (a live process: this one's parent): nothing goes, but the job just
        # collected is marked.
        self.assertTrue(remote_train.acquire(lock, "remote-train job0-5f3a9c1e", boot=remote_train.boot_id(), pid=os.getppid()))
        report = self.serve_prune(collected="job0-5f3a9c1e", keepDatasets=2, keepJobs=1)
        self.assertEqual(report["held"], "remote-train job0-5f3a9c1e")
        self.assertEqual(report["removed"], [])
        self.assertTrue(os.path.exists(os.path.join(self.root, "jobs", "job0-5f3a9c1e", ".collected")))
        self.assertEqual(len(os.listdir(os.path.join(self.root, "datasets"))), 4)
        os.remove(os.path.join(lock, "owner"))
        os.rmdir(lock)
        dry = self.serve_prune(keepDatasets=2, keepJobs=1, dryRun=True)
        self.assertEqual(len(dry["removed"]), 5)
        self.assertEqual(len(os.listdir(os.path.join(self.root, "datasets"))), 4)
        report = self.serve_prune(keepDatasets=2, keepJobs=1)
        self.assertTrue(report["pruned"])
        self.assertEqual(sorted(os.listdir(os.path.join(self.root, "datasets"))), ["ds0-5f3a9c1e", "ds1-5f3a9c1e"])
        self.assertEqual(os.listdir(os.path.join(self.root, "jobs")), ["job0-5f3a9c1e"])
        self.assertGreater(report["freedBytes"], 0)
        self.assertFalse(os.path.exists(lock))  # let go again
        self.assertTrue(report["space"])

    def test_results_count_as_collected_only_when_whole(self):
        with tempfile.TemporaryDirectory() as results:
            self.assertFalse(remote_train.collected(results))
            os.makedirs(os.path.join(results, "out"))
            Path(results, "job.json").write_text(json.dumps({"resultsCopied": False}))
            Path(results, "status.json").write_text("{}")
            self.assertFalse(remote_train.collected(results))
            Path(results, "job.json").write_text(json.dumps({"resultsCopied": True}))
            self.assertTrue(remote_train.collected(results))
            Path(results, "status.json").write_text("{half")
            self.assertFalse(remote_train.collected(results))

    def test_keep_counts(self):
        plan = remote_train.parse(["bombcad-pc", "d", "s.py", "--keep-datasets", "4", "--keep-jobs", "0"], now=NOW)
        self.assertEqual((plan["keepDatasets"], plan["keepJobs"]), (4, 0))
        plan = remote_train.parse(["bombcad-pc", "d", "s.py"], now=NOW)
        self.assertEqual((plan["keepDatasets"], plan["keepJobs"]), (2, 3))
        for bad in (["--keep-datasets", "0"], ["--keep-jobs", "-1"], ["--keep-datasets", "two"]):
            with self.assertRaises(ValueError):
                remote_train.parse(["bombcad-pc", "d", "s.py"] + bad, now=NOW)


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
