#!/usr/bin/env python3
"""Report the nightly full check: what failed, and which commits since the last green one are
suspects.

    python3 Scripts/nightly-suspects.py --outcome success|failure --log full.log \
        --marker ~/bombcad-nightly/last-green-full [--summary "$GITHUB_STEP_SUMMARY"] [--repo .]

The marker file on the runner holds the commit of the last full check that passed; a pass
moves it to this commit. A failure lists the failing tests and build errors from the log, and
the commits after the marker, newest first, as the suspects.
"""
import argparse
import os
import re
import subprocess
import sys

LIMIT = 40


def failures(log):
    """The failing tests, the compiler's errors and make's failing target, in order, without
    repeats."""
    found = []
    patterns = [
        re.compile(r'✘ Test "(.+?)" (?:failed|recorded an issue)'),
        re.compile(r"(\S+\.swift:\d+:\d+: error: .*)"),
        re.compile(r"(make(?:\[\d+\])?: \*\*\* .*)"),
        re.compile(r"(FAIL(?:ED)?: .*)"),
    ]
    for line in log.splitlines():
        for pattern in patterns:
            match = pattern.search(line)
            if match and match.group(1) not in found:
                found.append(match.group(1))
    return found


def suspects(repo, green):
    """Commits after `green`, newest first, as "<short> <subject> (<author>)"; None if `green`
    is unknown or not an ancestor of HEAD."""
    if not green:
        return None
    ancestor = subprocess.run(["git", "-C", repo, "merge-base", "--is-ancestor", green, "HEAD"])
    if ancestor.returncode != 0:
        return None
    log = subprocess.run(
        ["git", "-C", repo, "log", "--no-merges", "--format=%h %s (%an)", "%s..HEAD" % green],
        capture_output=True, text=True, check=True).stdout
    return [line for line in log.splitlines() if line]


def report(outcome, log, green, head, commits):
    """The report as Markdown lines."""
    if outcome == "success":
        return ["### Full check: passed", "", "On %s, now the last green full check." % head[:10]]
    lines = ["### Full check: FAILED", ""]
    found = failures(log)
    if found:
        lines.append("**What failed** (%d):" % len(found))
        lines += ["- `%s`" % item.replace("`", "'") for item in found[:LIMIT]]
        if len(found) > LIMIT:
            lines.append("- … and %d more; see the log" % (len(found) - LIMIT))
    else:
        lines.append("Nothing failing named in the log; see it whole (a time-out, or a crash).")
    lines.append("")
    if commits is None:
        lines.append("**Suspects:** unknown: no green full check recorded on this runner%s." % (
            " (%s is not an ancestor of %s)" % (green[:10], head[:10]) if green else ""))
    elif not commits:
        lines.append("**Suspects:** none: nothing has changed since the last green check (%s), so "
                     "suspect the machine: another job on it, or a flaky test." % green[:10])
    else:
        lines.append("**Suspects:** the %d commits since the last green full check (%s), newest first:" % (
            len(commits), green[:10]))
        lines += ["- %s" % commit for commit in commits[:LIMIT]]
        if len(commits) > LIMIT:
            lines.append("- … and %d older" % (len(commits) - LIMIT))
    return lines


def main(arguments):
    parser = argparse.ArgumentParser()
    parser.add_argument("--outcome", required=True)
    parser.add_argument("--log", required=True)
    parser.add_argument("--marker", required=True)
    parser.add_argument("--summary")
    parser.add_argument("--repo", default=".")
    options = parser.parse_args(arguments)
    try:
        with open(options.log, errors="replace") as handle:
            log = handle.read()
    except OSError:
        log = ""
    try:
        with open(options.marker) as handle:
            green = handle.read().strip()
    except OSError:
        green = ""
    head = subprocess.run(["git", "-C", options.repo, "rev-parse", "HEAD"], capture_output=True,
                          text=True, check=True).stdout.strip()
    commits = None if options.outcome == "success" else suspects(options.repo, green)
    text = "\n".join(report(options.outcome, log, green, head, commits)) + "\n"
    print(text)
    if options.summary:
        with open(options.summary, "a") as handle:
            handle.write(text)
    if options.outcome == "success":
        os.makedirs(os.path.dirname(os.path.abspath(options.marker)), exist_ok=True)
        with open(options.marker, "w") as handle:
            handle.write(head + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
