# Digitising Keys's debris histograms

Reads the longitudinal debris histograms of Keys's 2016 thesis (see
`Fixtures/Keys2016/README.md`) into `Fixtures/Keys2016/debris.json`. Needs numpy only (Pillow
is not installed here; `ppm.py` reads the images pdfimages writes) and poppler's `pdfimages`.

```
F=Richard_Keys_FINAL_e_thesis_for_e_prints.pdf
for p in 134 142 149 152 155 168 183 211 233; do pdfimages -f $p -l $p "$F" pages/q$p; done
python3 run_digitise.py pages ../../Fixtures/Keys2016/debris.json
```

`digitise.py` finds each bar's top over the middle half of its bin: up from the x axis to the
first white gap taller than 3% of the frame (so a legend over a short bar is skipped), or, for
MW1, whose "unknown" boxes are open, down from the top except under its legend. Each figure's
frame is set by hand in `run_digitise.py`; `lines.py`, `axes.py` and `ticks.py` print an image's
long lines and tick marks to set and check it.
