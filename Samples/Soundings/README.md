# Measured soundings

Two radiosonde soundings from Las Vegas, Nevada (WMO station 72388, the US National Weather
Service's office at 36.05° N, 115.18° W, 698 m above sea level), on one summer day, for the
[fireball's rise and cloud](../../docs/fireball-rise.md#a-measured-sounding):

| File | Launched | Local time | The air near the ground |
|---|---|---|---|
| `las-vegas-2024-06-15-12z.csv` | 15 June 2024, 11:09 UTC (the 12 UTC sounding) | 04:09 PDT | after a hot night: cooling at only about 3 K/km, stable, up to about 1.5 km |
| `las-vegas-2024-06-16-00z.csv` | 15 June 2024, 23:07 UTC (the 00 UTC sounding of the 16th) | 16:07 PDT | the afternoon: a mixed layer, cooling at about the dry adiabatic lapse rate, about 3 km deep |

**Source.** The University of Wyoming's upper-air archive,
[weather.uwyo.edu/upperair/sounding.shtml](https://weather.uwyo.edu/upperair/sounding.shtml),
station 72388, "Comma Separated Values" (`type=TEXT:CSV`, from the high-resolution BUFR
reports), fetched on 9 October 2026, for example:

```
https://weather.uwyo.edu/wsgi/sounding?datetime=2024-06-15%2012:00:00&id=72388&src=BUFR&type=TEXT:CSV
```

**Licence.** The observations are the US National Weather Service's, a work of the US federal
government, which has no copyright in the United States. The archive states no terms of its own.

**Trimmed.** The downloads have a row a second, some 5,800 rows and 540 kB each. These keep
Wyoming's header and columns unchanged and only some of the rows: the first, then the first at or
above every 100 m up to 5 km above the ground and every 250 m above that, up to 100 hPa (about
16.5 km above sea level), leaving out rows with a value missing. A full download reads the same
way.
