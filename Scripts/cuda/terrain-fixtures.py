#!/usr/bin/env python3
"""Write two made-up DEMs for synthetic-neighbourhood.geojson CUDA acceptance.

The rasters cover the sample centre (0.00045,51.50028); they contain no surveyed data.
Use with field-export --radius 48 --dx 2 --height 32 --mass 10 --until .08
--above 1 --first-phase --dem <output>/slope.asc (or hill.asc).
"""
import argparse
import math
from pathlib import Path


def write(folder):
    folder = Path(folder)
    folder.mkdir(parents=True, exist_ok=True)
    for kind in ('slope', 'hill'):
        n, step, x0, y0 = 61, .00005, -.00105, 51.49878
        lines = [f'ncols {n}', f'nrows {n}', f'xllcorner {x0}', f'yllcorner {y0}',
                 f'cellsize {step}', 'NODATA_value -9999']
        for row in reversed(range(n)):
            values = []
            for col in range(n):
                x = (x0 + (col + .5) * step - .00045) * 69300
                y = (y0 + (row + .5) * step - 51.50028) * 111320
                z = (10 + .13*x + .07*y if kind == 'slope' else
                     10 + 9*math.exp(-((x-12)**2 + (y+9)**2)/500))
                values.append(str(z))
            lines.append(' '.join(values))
        (folder / (kind + '.asc')).write_text('\n'.join(lines) + '\n')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('output', type=Path)
    write(parser.parse_args().output)
