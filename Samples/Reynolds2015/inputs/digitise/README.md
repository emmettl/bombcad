# Digitising Figs 9 and 10

Run against the two figure images embedded in the thesis (pages 31 and 32 of the PDF, extracted
with `pdfimages -png`), which stay in the sealed folder with the thesis:

```bash
python trace.py fig-000.png '[151,869,145,623]' 55 55 1000 '[630,822,303,522]' '{"HSCV1/2":[0,60,5,1],"HSCV3":[128,178,3,1]}' > fig9-raw.json
python path.py fig9-raw.json 55 1000 54 '{"HSCV1/2":8,"HSCV3":4}' > fig9-path.json
python trace.py fig-003.png '[143,861,144,622]' 58.95 40 800 '[630,825,338,556]' '{"HSCV4":[0,60,5,1],"HSCV5":[88,140,5,1],"HSCV6":[165,215,5,1]}' > fig10-raw.json
python path.py fig10-raw.json 40 800 58 '{"HSCV4":8,"HSCV5":2,"HSCV6":2}' > fig10-path.json
```

The arguments are the plot frame in pixels (left, right, top, bottom, found from the frame
lines and tick marks), the axes' ranges (time, pressure, impulse), the legend box to leave
out, and per curve its grey-level range, erosion size and smallest marker. HSCV3, HSCV4,
HSCV5 and HSCV6 are `path.py`'s output. The overlapping HSCV1 and HSCV2 defeated it (their
impulse curves' markers are as large as the pressure markers), so that trace was picked by
hand from `fig9-black-candidates.txt`. The integrated traces are checked against the figures'
impulse curves in `../slabs.json`.
