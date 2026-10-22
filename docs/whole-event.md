# Whole-event simulation

The aim ([emmettl/bombcad-work#36](https://github.com/emmettl/bombcad-work/issues/36)) is to carry
a building through the blast, its progressive collapse, the rubble pile and the dust cloud in one
coupled run, as at Ronan Point or Oklahoma City, and to give the collapse a standing of its own.
This page records the first step: the [large-panel block](large-panel-flats.md) under its street
charge, run past its collapse towards 10 s with failed concrete as rubble particles and the air
kept awake, measured as it goes, to find what gives out first: the contact, the time step, the
memory or the energy.

**In short (22 October 2026):** the energy gives out first. A joint between parts on a node whose
concrete had turned to rubble rang beyond the step and blew the run up at 0.62 s; that is fixed.
With it fixed, the run reaches 3.4 s, but from about 1.5 s the energy budget no longer closes: by
3.36 s the forces the work trace does not see (the air, contact, the joints and the ground) have
put 52 MJ into the body against the blast's 2, and at 3.40 s nodes holding only their bars' few
grams blow up. On the three-storey block failed elements opposite the charge blow up at 0.6 s,
with rubble or without. The contact table, the step and the memory are nowhere near their
limits. And the collapse is not earned: hourglass control does 54–61% of all the elements' work
through it.

![The street charge with rubble and the air awake, 2 s: the east bay's floors folding down off their flank wall](whole-event-2000ms.png)

## The run

```bash
blastbench wholeevent [--storeys 12] [--mass 500] [--dx 0.25] [--time 10] [--every 0.05]
                      [--budget 80] [--checkpoint-every 0.5] [--frames 1,2,4,6,8,10]
                      [--awake] [--no-rubble] [--dir …] [--continue] [--watch 20] [--inspect <checkpoint>]
                      [--erode-crushed-bare] [--release-bare-hourglass]
```

The street preset (500 kg of TNT 8 m from the east flank wall, 670,560 solid elements of 87.5 mm,
air on 1.19 million cells of 0.25 m), with:
- **rubble particles** on (`StructureModel.rubbleParticles`, an option): failed concrete becomes
  a particle keeping its mass, pushed by the air and in contact with everything;
- **the air kept awake** (`--awake`: no sleep), as a dust cloud would need; by default the air
  sleeps as the recommended settings have it;
- **pieces of at most `--budget` minutes**: a checkpoint at the next 64-step boundary, and
  `--continue` carries on from it, the same to the bit (checked on the three-storey block, the
  resumed run's rows equal to the straight run's in every column);
- **a census at each sample** (`StructureSolver.census()`, read from the buffers between
  batches, so the run is the same with it or without it): nodes listed for contact, moved, and
  pushed; the contact table's entries holding more than its 8 slots and the nodes so left out,
  for nodes and for particles; the fastest node and particle; kinetic energy, the particles'
  internal energy and the work gravity has done; and the elements' work by mechanism from the
  work trace (`tracesWork`, started after the settle under self-weight). What those leave is the
  **net external work**, the work of everything the trace does not count: the air, the joints
  between parts, contact and the ground. While the blast loads the building it is the blast's
  work less what the joints and contact have taken; after, it should only fall.
- `--inspect <checkpoint>` lists the fastest nodes of a saved state with their mass and the
  elements round them; `--watch 20` does it at each sample with a node faster than 20 m/s, and a
  run that goes unstable does it as it stops.

Each sample's row goes to `phases.csv` in the run's folder (on StudioData,
`whole-event/run12-pairfix/`), with the frames.

## What gave out first

### 1. A joint on a node whose concrete had turned to rubble (fixed)

The first run went to NaN at **0.617 s**: a node of the east flank wall at the joint under the
second storey reached 18,363 m/s, the kinetic energy jumped from 0.09 to 0.70 MJ within 55 steps,
and the air's step went to zero. The node had 2.8 g of mass: its elements had all failed, their
concrete gone into particles, and it kept only its bars' share. Its joint pair
(`Anchorage.betweenParts`) was still as stiff as when set up for the whole node, whose mass was a
hundred times more, so its frequency was ten times what the step allows. The same had thrown
nodes at the joints' rows along the ground at 300–540 m/s from 0.2 s on.

The fix: with rubble, a pair bears in proportion to the reduced mass its two nodes have left
(`structurePairs`), which keeps its frequency where the step was set for it, and it lets go with
the concrete. Without rubble the kernel is built as before. Resumed from the checkpoint at
0.611 s, the run passed 0.75 s with its kinetic energy steady; run afresh, nothing went faster
than 12 m/s before 0.4 s, where 300–540 m/s had. The test
"A joint between parts eases as the concrete at it turns to rubble" (`RubbleParticleTests`)
fails without the fix (a node at 23 m/s from rest at 0.1) and passes with it.

### 2. The energy budget (not fixed)

With the joint fixed, by phase (on the Studio, shared with other work; wall and GPU seconds per
second simulated; the structure's step 10.14 µs throughout):

| Phase | Wall s/s | GPU s/s | Air step | Failed (all rubble) | Nodes listed / pushed | Fastest node |
|---|---|---|---|---|---|---|
| 0–0.05 s, the blast | 606 | 598 | 103 µs | 679 | 773,700 / 512 | 12 m/s |
| 0.1–0.5 s | 655 | 648 | 114 µs | 1,416 | 774,000 / 1,413 | 119 m/s, once |
| 0.5–1 s, the east bay starts down | 984 | 942 | 119 µs | 2,510 | 774,400 / 2,498 | 33 m/s |
| 1–1.5 s | 1,164 | 1,147 | 126 µs | 3,781 | 775,300 / 2,996 | 21 m/s |
| 1.5–2 s | 847 | 833 | 138 µs | 5,405 | 776,700 / 3,421 | 31 m/s |
| 2–2.5 s | 792 | 781 | 147 µs | 9,992 | 779,100 / 7,209 | 249 m/s |
| 2.5–3 s | 1,167 | 1,152 | 147 µs | 16,092 | 782,100 / 10,852 | 249 m/s |
| 3–3.36 s | 1,443 | 1,408 | 147 µs | 39,359 | 793,900 / 27,120 | 903 m/s |
| 3.40 s | | | 0 | 42,823 | | 3 × 10⁸ m/s: blown up |

The energy, in MJ (gravity's is the work it has done since the settle):

| t (s) | Kinetic | Gravity's work | Elements' work | of which hourglass | fracture | bars | Net external work |
|---|---|---|---|---|---|---|---|
| 0.05 | 0.36 | −0.05 | 1.13 | 0.63 (56%) | 0.20 | 0.13 | 1.54 |
| 0.46 | 0.21 | 0.57 | 2.23 | 1.27 (57%) | 0.36 | 0.27 | 1.87 |
| 0.96 | 0.25 | 1.86 | 3.58 | 2.14 (60%) | 0.60 | 0.42 | 1.97 |
| 1.45 | 0.76 | 3.50 | 5.09 | 3.10 (61%) | 0.83 | 0.58 | 2.35 |
| 1.96 | 2.87 | 6.68 | 7.56 | 4.56 (60%) | 1.10 | 0.74 | 3.76 |
| 2.46 | 7.30 | 14.07 | 14.48 | 8.33 (58%) | 1.99 | 1.16 | 8.32 |
| 2.95 | 20.04 | 33.15 | 34.70 | 19.53 (56%) | 3.27 | 2.08 | 22.19 |
| 3.36 | 22.41 | 54.80 | 78.48 | 42.16 (54%) | 7.00 | 4.36 | 51.81 |

The net external work is the blast's 1.5 MJ by 50 ms, rises to 2.0 MJ by 1 s as the air keeps
loading the walls, and should then only fall, as contact, the joints' friction and the ground take
their share. It rises instead, slowly to 1.5 s, then doubling every half second: by 3.36 s
something the trace does not count has put about 50 MJ into the body, nearly as much as gravity
has. Either energy is being made, or the trace is counting work that was not done (the
elements' "elastic" channels, uncracked concrete's own stresses, read 24.5 MJ at 3.36 s, more
than ten times what the pile could store). Each accounts for the other: kinetic energy 22.4 MJ
equals gravity's 54.8 less the elements' 78.5 plus 46 from outside. The particles' internal
energy, the motion about their centres of the nodes they were made from, jumped from 0.6 to
5.7 MJ between 2.95 and 3.36 s: elements already ringing when they turned to rubble. At 3.40 s
the run went to NaN through nodes holding their bars' 0.5–7 g, some still on bare elements (bars
alone), the rest with every element round them gone.

**On the three-storey block** (167,640 elements; `--storeys 3`), which is a quarter of the cost,
the same kind of event comes at 0.58 s, with the air asleep or awake: a cluster of the east flank
wall's bars-only nodes, a metre up, thrown at 1.9–3.7 km/s within one batch, 5 MJ into the
particles' internal energy. It is not the air's push on loose nodes (holding such a node to its
own mass as steel changed nothing, to the bit) nor the joint. Of the options for crushed bare
elements, `erodesCrushedBare` changed nothing and `releasesCrushedBareHourglass` put it off to
0.68 s and cut it to 1.6 MJ: bare elements' hourglass control is in it, but is not all of it.
**Without rubble it is worse, not better:** the same nodes, holding their whole concrete
(0.8–1.6 kg), go at 0.62 s, and the kinetic energy jumps from 0.12 to 307 MJ, two hundred times
the blast's 1.4, with nodes at 14 km/s. They are the flank wall's elements straight opposite the
charge, at its height, the first to fail. So this wall is the model's, after failure, and not the
rubble's: rubble's light nodes only add ways to reach it. The street preset's runs to 4 s without
rubble ([large-panel flats](large-panel-flats.md#a-street-charge)) had no energy budget; they may
have carried such events unseen.

**Where the extra work comes from**, sampled at 20 batch ends from 2.05 to 2.44 s on the twelve
storeys (resumed from the 2 s checkpoint with the census's power columns): the net external work
grew at 9.5 MW, while contact put in 1.3 MW on average and the joints between parts 0.85 MW,
both of which should take energy out, not put it in. Instantaneous samples of ringing forces are
noisy, but both lean positive throughout. The other 7 MW is in the air, the ground or the trace's
own count, which the census cannot yet tell apart.

### Contact, the step and the memory: not near a limit

- **Contact.** Of the 1.07 million nodes, 774,000–795,000 are listed for contact (not buried in
  intact solid) and 512–27,000 pushed. The contact table never held more than its 8 slots in an
  entry, for nodes or for particles: no node was left out of contact at any sample. Its cost
  shows in the time per second simulated rising from 600–650 s to 1,400 s as failures went from
  700 to 39,000; at 3.4 s 6% of the elements were rubble.
- **The step.** The structure's step is fixed by its elements, 10.14 µs, from start to end; the
  air's, kept awake, grows from 103 to 147 µs (10 to 15 substeps a step). Asleep it would be
  41 substeps. Nothing in a collapse shortens it, and nothing checks it either: a flattened or
  bars-only element is held to a step set for whole concrete, which is the kind of thing that
  blew up above.
- **Memory.** 1.9–2.8 GB of process footprint and 1.20–1.22 GB on the GPU, flat: rubble keeps a
  slot for every element from the start, and the air is uniform. Checkpoints are 320–360 MB.
- **The time to 10 s.** At 800–1,450 s per second simulated, 10 s would take 2.5–4 hours on the
  Studio: two or three pieces of 80 minutes. Not a wall, once the energy holds.

## Is the collapse earned?

No. Limitation 1 is the gate the issue set ("collapse on a model that springs back is
unearned"), and the run shows why it holds here:
- **Hourglass control does most of the work.** Through the whole collapse, 54–61% of all the
  elements' work is hourglass control's, from five sixths of it at its cap (where it dissipates)
  in the blast to half as the bay falls; fracture does 9–18% and the bars 6–12%. With two elements through each panel and floor, an
  element's own bending is a third of the whole even elastically, and once cracked it is held at
  the cap that counts the bars' strength as spread through the element. The cracked-element
  study (emmettl/bombcad-work#20, [concrete model](concrete-model.md)) found the struck beams'
  agreement leaning on exactly this, and lowered their standing to low; an element that bends in
  its cracked concrete without it was stopped. So the hinges along which the floors fold here,
  and the energy they take, are the stabilisation's, not the concrete's.
- **A finer mesh is out of reach.** Four elements through the 175 mm panels is 44 mm elements:
  eight times the elements and half the step, sixteen times the cost, some 4–6 hours per second
  simulated on the Studio.
- **The budget does not close** (above), so even the illustrative collapse after about 1.5 s is
  carried on energy the model has made or miscounted.

The collapse stays **illustrative** ([standing](standing.md#collapse)), and the whole-event
run is not ready to be offered: it would show a pile and a cloud on a collapse whose dissipation
is the mesh's.

## Dust: what it would take

Nothing is built for dust. What it would need, from what the model has:
- **Where it comes from.** Crushing and fracture make fines in proportion to the new surface,
  so in proportion to the fracture and crushing work the trace already separates by element; and
  rubble landing makes more, in proportion to the impact energy contact takes out. A source per
  element per substep: fines mass = (fracture + crushing work) / an energy per kilogram of fines,
  and a share of each particle's impact loss. Both coefficients need data: dust sampled from a
  collapse or a demolition (to find, for data-wanted).
- **Carried by the air.** The air already carries two species alongside its state for
  afterburning, the detonation products and the oxygen, advected by the same fluxes. Dust is one
  or two more, a mass density per size class, with a settling velocity (Stokes: about 7 mm/s
  for 10 µm concrete, 0.6 m/s for 100 µm) added to its flux, and deposited on the ground and on
  the rubble where it reaches them.
- **Coupling.** Up to a few per cent by mass the dust rides the air passively. A collapse's
  cloud is denser: the falling floors push the air out at the base as a dusty gravity current,
  so its density enters the air's momentum and its weight the air's gravity (the well-balanced
  gravity option). The particles already push the air and take its push (`debrisAirForce`, the
  debris exchange); the dust adds the source and its inertia.
- **The air must stay awake** through the collapse, as here: asleep, the air is frozen and no
  cloud forms. That cost little: the awake air's step is 10–15 substeps.
- **Beyond the domain.** The cloud leaves a 31 m domain within seconds; the fireball's
  [cloud spread](fireball-rise.md) (a gravity current, then a Pasquill puff) is the hand-over
  once it does.
- **What it hides.** Optical depth from the dust's mass concentration and a mass extinction
  coefficient, marched as the fireball's volume is ([thermal radiation](thermal-radiation.md)).

```
 elements' fracture + crushing work ──┐
 particles' impact loss (contact) ────┴─► fines source ─► air cell's dust species ─► advected,
                                                                 │                     settling
                                    dust density in momentum ◄───┘                       │
                                    and gravity (dense cloud)              deposited ◄───┘
                                                                           on ground/rubble
                                    leaves the domain ─► cloud spread (gravity current, puff)
```

## Next

1. **Close the energy budget, on the three-storey block first** (a quarter of the cost, and its
   event at 0.6 s repeats: the same fastest node, to 0.1 m/s, on two builds). Find what blows up the failed
   elements opposite the charge without rubble (`--no-rubble --watch`, from its 0.5 s
   checkpoint, sampling every batch); then why contact and the joints lean positive, and what is
   left of the 7 MW (the air's work on the faces and the ground's would need counting too). With
   rubble, a candidate for the bars-only nodes: when a bare element's bars break, their mass goes
   with its particle, so that no node is left with a few grams.
2. **Then the 10 s run**, in pieces, with the residual held to a few per cent of gravity's work.
3. **Collapse earned** only after limitation 1's next attack, cracked concrete's stiffness and
   shear, which is not taken up.
4. **Dust** after that, as sketched.
