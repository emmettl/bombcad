"""Exercise the remote check's policy without another Mac."""

import datetime
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("remote", Path(__file__).with_name("remote.py"))
remote = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(remote)


def machine(load=1.0, cores=10, gpu=0.0, lock=None, runners=(), quiet=False):
    return {"load": load, "cores": cores, "gpu": gpu, "gpuTop": [], "lock": lock, "runners": list(runners),
            "quiet": quiet}


class PolicyTests(unittest.TestCase):
    settings = dict(remote.DEFAULTS, remoteRatio=1.6)

    def test_quiet_window(self):
        at = lambda h, m: datetime.datetime(2026, 10, 11, h, m, tzinfo=datetime.timezone.utc)
        self.assertTrue(remote.in_quiet_window(["01:30-04:30"], at(2, 0)))
        self.assertFalse(remote.in_quiet_window(["01:30-04:30"], at(4, 30)))
        self.assertFalse(remote.in_quiet_window(["01:30-04:30"], at(1, 29)))
        # Across midnight.
        self.assertTrue(remote.in_quiet_window(["23:00-01:00"], at(0, 30)))
        self.assertFalse(remote.in_quiet_window(["23:00-01:00"], at(12, 0)))

    def test_busy_studio_sends_the_check_away(self):
        where, why = remote.choose(machine(load=48, cores=16, gpu=0.9), machine(load=2, cores=10), self.settings)
        self.assertEqual(where, "there", why)

    def test_quiet_studio_keeps_it(self):
        where, why = remote.choose(machine(load=4, cores=16, gpu=0.1), machine(load=2, cores=10), self.settings)
        self.assertEqual(where, "here", why)

    def test_a_held_or_busy_mini_is_never_chosen(self):
        busy = machine(load=60, cores=16, gpu=1.5)
        for other, words in [
            (machine(lock={"what": "make check from x"}), "another BombCAD job"),
            (machine(runners=["Developer/actions-runner"]), "runners are busy"),
            (machine(quiet=True), "nightly window"),
        ]:
            where, why = remote.choose(busy, other, self.settings)
            self.assertEqual(where, "here")
            self.assertIn(words, why)
        self.assertEqual(remote.choose(busy, None, self.settings)[0], "here")


class LockTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.lock = os.path.join(self.directory.name, "lock")

    def test_one_holder_at_a_time(self):
        self.assertTrue(remote.acquire(self.lock, "first"))
        self.assertFalse(remote.acquire(self.lock, "second"))
        self.assertEqual(remote.lock_owner(self.lock)["what"], "first")
        remote.release(self.lock)
        self.assertIsNone(remote.lock_owner(self.lock))
        self.assertTrue(remote.acquire(self.lock, "second"))

    def test_a_dead_holders_lock_is_taken(self):
        child = subprocess.Popen([sys.executable, "-c", "pass"])
        child.wait()
        os.mkdir(self.lock)
        with open(os.path.join(self.lock, "owner"), "w") as handle:
            json.dump({"pid": child.pid, "since": 0, "what": "gone"}, handle)
        self.assertIsNone(remote.lock_owner(self.lock))
        self.assertTrue(remote.acquire(self.lock, "next"))

    def test_another_processs_lock_is_not_released(self):
        os.mkdir(self.lock)
        with open(os.path.join(self.lock, "owner"), "w") as handle:
            json.dump({"pid": os.getppid(), "since": 9e12, "what": "parent"}, handle)
        remote.release(self.lock)
        self.assertTrue(os.path.isdir(self.lock))


if __name__ == "__main__":
    unittest.main()
