"""check-test-deadlines on made-up test sources: each kind of wall-clock bound it exists to catch
(among them those that failed on a loaded Studio on 19 and 20 October 2026: a stall test's 20 times
its limit, a three-minute network limit, a 0.5 s wait for Metal to let a buffer go), what it must
let through (lower bounds, strings, comments, generics, polls on a condition), and the allow-list."""

import importlib.util
import io
from contextlib import redirect_stdout
from pathlib import Path
import tempfile
import textwrap
import unittest

SPEC = importlib.util.spec_from_file_location(
    "check_test_deadlines", Path(__file__).with_name("check-test-deadlines.py"))
check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(check)


def kinds(source, path="Tests/BombCADTests/Made.swift"):
    """The kinds of finding in `source`, by line."""
    return [(f.line, f.kind) for f in check.check_file(path, textwrap.dedent(source).lstrip("\n"))]


class Tree:
    """A made-up repository: `files` maps paths to sources."""

    def __init__(self, files):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        for path, text in files.items():
            target = self.root / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(textwrap.dedent(text).lstrip("\n"), encoding="utf-8")

    def run(self, allow=""):
        return check.check(self.root, textwrap.dedent(allow))

    def main(self, allow=""):
        (self.root / "allow.txt").write_text(textwrap.dedent(allow), encoding="utf-8")
        out = io.StringIO()
        with redirect_stdout(out):
            code = check.main(["--root", str(self.root), "--allow", str(self.root / "allow.txt")])
        return code, out.getvalue()


class ElapsedBounds(unittest.TestCase):
    def test_direct_upper_bounds(self):
        self.assertEqual(kinds("""
            #expect(ContinuousClock.now - start < limit / 2)
            #expect(Date().timeIntervalSince(clock) <= 5)
            #expect(start.duration(to: .now) < .seconds(3))
            guard 4 > Date().timeIntervalSince(began) else { return }
            return ContinuousClock.now - start < limit * 20
        """), [(1, "elapsed-bound"), (2, "elapsed-bound"), (3, "elapsed-bound"), (4, "elapsed-bound"),
               (5, "elapsed-bound")])

    def test_through_a_name(self):
        self.assertEqual(kinds("""
            let waited = (said.time ?? .distantFuture).timeIntervalSince(began.time ?? .distantPast)
            #expect(waited < 4, "The watchdog waited \\(waited) s.")
            var elapsed = ContinuousClock.now - started
            elapsed = ContinuousClock.now - started
            #expect(elapsed.components.seconds < 10)
        """), [(2, "elapsed-bound"), (5, "elapsed-bound")])

    def test_through_a_function_returning_a_tuple(self):
        # NearbyDeadlineGapTests, 19 October 2026.
        self.assertEqual(kinds("""
            private func timedOut(_ body: () async throws -> Void) async -> (reason: String?, took: Duration) {
                let start = ContinuousClock.now
                do {
                    try await body()
                } catch {
                    return (nil, ContinuousClock.now - start)
                }
                return (nil, ContinuousClock.now - start)
            }

            func test() async {
                let (reason, took) = await timedOut { try await channel.start(within: limit) }
                #expect(took >= limit && took < limit * 20)
                #expect(reason != nil)
            }
        """), [(13, "elapsed-bound")])

    def test_lower_bounds_and_other_comparisons_pass(self):
        self.assertEqual(kinds("""
            let (reason, took) = await timedOut { try await channel.start(within: limit) }
            #expect(took >= limit)
            #expect(limit <= ContinuousClock.now - start)
            let held = Locked<[DispatchWorkItem]>([])
            #expect(model.time < target + 2 * model.stats.timeStep)
            while model.time < 0.3 * model.duration { try await Task.sleep(for: .milliseconds(2)) }
            print("Laid out in \\(laid.duration(to: .now)) < budget")
            // #expect(ContinuousClock.now - start < limit)
            /* #expect(Date().timeIntervalSince(clock) < 5) */
            clock.now += .microseconds(2500)
        """), [])

    def test_a_multiline_string_is_not_code(self):
        self.assertEqual(kinds('''
            let text = """
                #expect(ContinuousClock.now - start < limit)
                \\(a ?? "") ContinuousClock.now + .seconds(5)
                """
            #expect(text.count > 0)
        '''), [])


class TimeLimits(unittest.TestCase):
    def test_shorter_than_the_targets_hang_limit(self):
        app = "Tests/BombCADTests/Made.swift"
        core = "Tests/BlastCoreTests/Made.swift"
        self.assertEqual(kinds("static var networkLimit: Self { .timeLimit(.minutes(3)) }", app),
                         [(1, "time-limit")])
        self.assertEqual(kinds("static var hangLimit: Self { .timeLimit(.minutes(10)) }", app), [])
        self.assertEqual(kinds('@Suite("Slow", .timeLimit(.minutes(30)))', core), [(1, "time-limit")])
        self.assertEqual(kinds('@Suite("Slow", .timeLimit(.minutes(120)))', core), [])
        self.assertEqual(kinds('@Suite("Slow", .timeLimit(.hours(2)))', core), [])
        self.assertEqual(kinds('@Test(.timeLimit(.seconds(90))) func a() {}', app), [(1, "time-limit")])
        self.assertEqual(kinds("@Test(.timeLimit(limit)) func a() {}", app), [(1, "time-limit")])

    def test_a_target_not_named_takes_the_smallest(self):
        self.assertEqual(kinds('@Suite(.timeLimit(.minutes(10)))', "Tests/NewTests/Made.swift"), [])
        self.assertEqual(kinds('@Suite(.timeLimit(.minutes(5)))', "Tests/NewTests/Made.swift"),
                         [(1, "time-limit")])


class Deadlines(unittest.TestCase):
    def test_deadlines_made_in_a_test(self):
        self.assertEqual(kinds("""
            let deadline = ContinuousClock.now + .seconds(30)
            done.wait(timeout: .now() + 5)
            let until = Date().addingTimeInterval(10)
            let then = Date(timeIntervalSinceNow: 10)
            try await Task.sleep(until: deadline, clock: .continuous)
        """), [(1, "deadline"), (2, "deadline"), (3, "deadline"), (4, "deadline"), (5, "deadline")])

    def test_a_driven_clock_is_not_one(self):
        self.assertEqual(kinds("""
            var now = ContinuousClock.now
            clock.now += .microseconds(2500)
        """), [])


class Sleeps(unittest.TestCase):
    def test_long_sleeps(self):
        self.assertEqual(kinds("""
            try await Task.sleep(for: .seconds(6))
            try await Task.sleep(for: .milliseconds(1100))
            Thread.sleep(forTimeInterval: 2)
            try await Task.sleep(for: .milliseconds(300))
            Thread.sleep(forTimeInterval: 0.05)
        """), [(1, "long-sleep"), (2, "long-sleep"), (3, "long-sleep")])

    def test_counted_waits(self):
        # SolverMemoryTests, 20 October 2026: half a second for Metal to let a buffer go.
        self.assertEqual(kinds("""
            for _ in 0..<50 where mask != nil { Thread.sleep(forTimeInterval: 0.01) }
            for _ in 0..<100 {
                try await Task.sleep(for: .milliseconds(10))
            }
        """), [(1, "bounded-wait"), (2, "bounded-wait")])

    def test_a_counted_loop_of_polls_waits_on_a_condition(self):
        self.assertEqual(kinds("""
            for _ in 0..<2 {
                while !model.experimentIsReady {
                    try await Task.sleep(for: .milliseconds(5))
                }
                model.run()
            }
            while mask != nil { Thread.sleep(forTimeInterval: 0.01) }
        """), [])


class AllowList(unittest.TestCase):
    SOURCE = {
        "Tests/BombCADTests/Waiting.swift": """
            extension Trait where Self == TimeLimitTrait {
                static var hangLimit: Self { .timeLimit(.minutes(10)) }
                static var networkLimit: Self { .timeLimit(.minutes(3)) }
            }
        """,
    }
    ENTRY = ("Tests/BombCADTests/Waiting.swift [time-limit] "
             "static var networkLimit: Self { .timeLimit(.minutes(3)) } => a reason")

    def test_an_entry_lets_its_finding_through(self):
        tree = Tree(self.SOURCE)
        findings, errors, files = tree.run()
        self.assertEqual([(f.path, f.line, f.kind) for f in findings],
                         [("Tests/BombCADTests/Waiting.swift", 3, "time-limit")])
        self.assertEqual((errors, files), ([], 1))
        self.assertEqual(tree.run(self.ENTRY)[:2], ([], []))

    def test_a_stale_entry_or_one_without_a_reason_fails(self):
        tree = Tree(self.SOURCE)
        stale = "Tests/BombCADTests/Waiting.swift [time-limit] static var gone: Self { .timeLimit(.minutes(1)) } => old"
        errors = tree.run(self.ENTRY + "\n" + stale)[1]
        self.assertEqual(len(errors), 1)
        self.assertIn("matches nothing", errors[0])
        self.assertIn("no reason", check.parse_allow(self.ENTRY.replace("a reason", ""))[1][0])
        self.assertIn("expected", check.parse_allow("just some words")[1][0])
        self.assertEqual(check.parse_allow("# a comment\n\n")[1], [])

    def test_main(self):
        tree = Tree(self.SOURCE)
        code, out = tree.main()
        self.assertEqual(code, 1)
        self.assertIn("Waiting.swift:3: time-limit: 3 minutes, shorter than the target's hang limit of 10 min", out)
        code, out = tree.main(self.ENTRY)
        self.assertEqual(code, 0)
        self.assertIn("No wall-clock bounds in 1 test files.", out)


if __name__ == "__main__":
    unittest.main()
