# Digitising the supplied sources

`make_fixtures.py DATA OUT` rebuilds `Fixtures/UFC-3-340-02`, `Fixtures/Schwer2015`,
`Fixtures/XuLu2016` and `Fixtures/Cooper1996` from the PDFs in DATA
(`$BOMBCAD_DATA/data/`). It needs numpy and Pillow (a venv:
`python3 -m venv v && v/bin/pip install numpy pillow`) and poppler's pdftocairo, pdftoppm,
pdfimages and pdftotext.

- `svgcurves.py`: stroked paths of a pdftocairo SVG page in page coordinates (vector charts).
- `vector_chart.py`: a vector chart mapped through its frame, checked against its gridlines.
- `vector_auto.py`: a vector log–log chart calibrated from its printed tick labels, curves named
  by the number at their ends.
- `trace.py`: raster tracing, by the line's own course (`follow`) or along anchor points
  (`guided`), and an overlay to check a trace by eye.
- `dots.py`: filled markers as solid blobs, and a skew-aware frame from four fitted edges.
- `colour_curves.py`: coloured curves on a raster chart, per column, with gridline calibration.
- The `*.json` files are the anchors and chart specifications used (pixel coordinates read by
  eye; they only steer the traces where lines cross).

Each fixture's README gives its method and error. Intermediate files are under
`$BOMBCAD_DATA/digitise-sources/`.
