# Yao et al. (2023): large slabs under explosion

Derived data from J. Yao, S. Li, P. Zhang, S. Deng and G. Zhou, *Dynamic Response and Damage
Characteristics of Large Reinforced Concrete Slabs under Explosion*, Applied Sciences 13, 12552
(2023), doi:10.3390/app132312552, under CC BY 4.0 (https://creativecommons.org/licenses/by/4.0/).

**Transcribed** into `yao2023.json`, from the paper's tables and text:
- the slab, its bars and supports;
- the four tests;
- the accelerations (Table 4);
- the 20 kg test's damage (Section 3.3).

**Read by eye**, off Figures 6b and 7b, to about ±0.03 mm and ±0.1 MPa:
- the three smaller tests' peak top-face pressures;
- the underside displacements.

**The paper's own numerical results** (LS-DYNA; the 5–40 kg series and the P–I curves) are not
measurements and are not used.

**Sensor directions.** The paper's "long side" and "short side" sensors sit 1 m from the centre
towards the supported long side and towards the free short side. That is our reading of its
Figure 3.

**The model's slab carries its weight.** It is settled under it before the blast, and its
displacements are read from there, as the sensors read from the slab resting on its supports.
Before 17 October 2026 it was compared without its weight (`--weightless`).

`TwoFaceSlabTests.yaoTests` (Sources/BlastModel/YaoSlabTests.swift) holds the same values for
`blastbench twoface --yao`. See docs/validation.md, "Yao's large slabs".
