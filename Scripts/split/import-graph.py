#!/usr/bin/env python3
"""Map Sources/BlastCore for the BlastModel split and classify each file; see
Scripts/split/blastcore_graph.py for the rules.

    python3 Scripts/split/import-graph.py            # print the counts
    python3 Scripts/split/import-graph.py --write    # write Scripts/split/classification.json
    python3 Scripts/split/import-graph.py --check    # fail if classification.json is stale
"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from blastcore_graph import main  # noqa: E402

if __name__ == "__main__":
    sys.exit(main())
