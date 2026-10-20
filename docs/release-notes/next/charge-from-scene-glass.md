kind: added

**Charge inference from the glass on the scene's own buildings (headless).** The charge's yield
and place can now be inferred from which building sides' glass broke. Each side is loaded by the
façade load surrogate from the place being weighed, with the shielding and facing that place gives
it, rather than by the free field. On a made-up district, against BombCAD's own runs on 4 m cells,
the glass alone held the true yield inside its 90% interval for all four charges, three of them
within 15%, where the arrivals alone read 1.6–2 times high. On 2 m cells it held two of four, and
says only "large" where nearly all glass breaks. A run of BombCAD near the estimate corrects the
surrogate's loads as it corrects the arrivals (`--passes`). With the arrivals, that finds all four
yields within 2% on 2 m cells; on the glass alone it does not help, as the glass places the charge
20–70 m off. `scenebench infer-charge-study --forward-damage`
([charge inference](../../charge-inference.md#damage-on-the-scenes-own-buildings)).

**In the app, the survey on the scene's own buildings.** Simulation ▸ Infer Charge from Arrivals…
offers **On this scene's buildings** under Broken glass, where the scene has buildings whose glass
the app judges. Each surveyed façade is put on the side of a building it lies on, and weighed by the
surrogate from the charge being searched. Illustrative, and circular on Beirut
([in the app](../../charge-inference.md#in-the-app)).
