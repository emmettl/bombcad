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


def plenty():
    return {"allRunners": [], "pressure": 1, "freePercent": 77, "load": 3.0, "cores": 10}


class LaneTests(unittest.TestCase):
    settings = dict(remote.DEFAULTS)

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = self.directory.name
        self.lock = os.path.join(self.root, "lock")

    def held_by_parent(self, lane, mem, what="parent's check"):
        """Lane `lane` held by this test's parent process (alive, and not this one)."""
        path = os.path.join(self.root, "lanes", str(lane))
        os.makedirs(path)
        remote.write_owner(path, {"pid": os.getppid(), "since": 9e12, "what": what, "mem": mem})

    def test_the_first_lane_takes_the_lock_and_lets_it_go(self):
        self.assertEqual(remote.take_lane(self.root, self.settings, "mine", 7, facts=plenty), (1, None))
        self.assertEqual(remote.lock_owner(self.lock)["what"], "mine")
        self.assertEqual(remote.lane_folder(self.root, 1), os.path.join(self.root, "check"))
        remote.leave_lane(self.root, self.settings, 1)
        self.assertIsNone(remote.lock_owner(self.lock))
        self.assertEqual(remote.lane_owners(self.root, 2), {})

    def test_a_second_lane_beside_a_declared_job_and_the_lock_handed_on(self):
        self.assertEqual(remote.take_lane(self.root, self.settings, "mine", 7, facts=plenty), (1, None))
        # The parent's job joins in lane 2 (written as take_lane would), then this one ends first.
        self.held_by_parent(2, 7)
        remote.leave_lane(self.root, self.settings, 1)
        owner = remote.lock_owner(self.lock)
        self.assertEqual((owner["pid"], owner["what"]), (os.getppid(), "parent's check"))
        # A new job takes the free lane, beside the parent's, while the lock stays the parent's.
        self.assertEqual(remote.take_lane(self.root, self.settings, "next", 7, facts=plenty), (1, None))
        self.assertEqual(remote.lock_owner(self.lock)["pid"], os.getppid())
        self.assertEqual(remote.lane_folder(self.root, 2), os.path.join(self.root, "check-2"))
        remote.leave_lane(self.root, self.settings, 1)
        self.assertEqual(remote.lock_owner(self.lock)["pid"], os.getppid())

    def test_no_second_lane_when_it_is_not_safe(self):
        self.held_by_parent(1, 7)
        os.makedirs(self.lock)
        remote.write_owner(self.lock, {"pid": os.getppid(), "since": 9e12, "what": "parent's check", "mem": 7})
        for mem, facts, words in [
            (None, plenty, "declares no memory"),
            (8, plenty, "more than a lane's 7"),
            (7, lambda: dict(plenty(), allRunners=["Developer/actions-runner"]), "a CI runner there has a job"),
            (7, lambda: dict(plenty(), freePercent=30), "30% of its memory is free"),
            (7, lambda: dict(plenty(), pressure=2), "pressure is not normal"),
            (7, lambda: dict(plenty(), load=25.0), "its load is 25.0"),
        ]:
            with self.subTest(words=words):
                lane, why = remote.take_lane(self.root, self.settings, "mine", mem, facts=facts)
                self.assertIsNone(lane)
                self.assertIn(words, why)
        self.assertEqual(sorted(remote.lane_owners(self.root, 2)), [1])

    def test_never_beside_a_job_outside_the_lanes(self):
        # A worker (RemoteGate) or an older remote.py holds the lock with no lane: the Mac is taken.
        os.makedirs(self.lock)
        remote.write_owner(self.lock, {"pid": os.getppid(), "since": 9e12, "what": "BombCAD worker"})
        lane, why = remote.take_lane(self.root, self.settings, "mine", 7, facts=plenty)
        self.assertIsNone(lane)
        self.assertIn("BombCAD worker", why)
        # Nor beside a lane whose lock a worker took after the lane's holder was killed outright.
        self.held_by_parent(1, 7)
        remote.write_owner(self.lock, {"pid": os.getpid(), "since": 9e12, "what": "BombCAD worker"})
        lane, why = remote.take_lane(self.root, self.settings, "mine", 7, facts=plenty)
        self.assertIsNone(lane)
        self.assertIn("BombCAD worker", why)
        state = {"lock": {"pid": os.getpid(), "what": "BombCAD worker"},
                 "lanes": [{"lane": 1, "pid": os.getppid(), "what": "a", "mem": 7}], "runners": [], "quiet": False}
        self.assertIn("BombCAD worker", remote.unavailable(dict(state, **plenty()), self.settings, 7))

    def test_a_jobs_memory_is_its_whole_tree(self):
        table = "  10     1  1024\n  11    10  2048\n  12    11  4096\n  13     1  8192\n bad line\n"
        self.assertEqual(remote.tree_memory(10, table), (1024 + 2048 + 4096) * 1024)
        self.assertEqual(remote.tree_memory(99, table), 0)

    def test_the_lanes_sum_and_count_are_capped(self):
        owners = {1: {"what": "a", "mem": 7}}
        self.assertIsNone(remote.second_lane_refusal(owners, plenty(), self.settings, 7))
        self.assertIn("would declare 15 GB", remote.second_lane_refusal({1: {"what": "a", "mem": 8}}, plenty(),
                                                                        self.settings, 7))
        self.assertIn("all 2 lanes", remote.second_lane_refusal({1: owners[1], 2: owners[1]}, plenty(),
                                                                self.settings, 1))
        one = dict(self.settings, lanes=1)
        self.assertIn("all 1 lanes", remote.second_lane_refusal(owners, plenty(), one, 7))


if __name__ == "__main__":
    unittest.main()
