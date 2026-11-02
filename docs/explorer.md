# The explorer: a blast for someone who knows nothing about blast

Design note, stage 1 of emmettl/bombcad-work#114, 2 November 2026. It is for the user's review and
nothing here is built yet. The user's direction of 1 November: "an engaging interactive
experience — for a non specialist to be able to get an intuition about what happens", on live
models that give good enough numbers at reasonable frame rates. The solver is the referee and is
not part of the experience.

The explorer is a front onto what is already live on main: the
[live drag](learned-models.md#the-live-drags-learned-response-1-november-2026), the
[live wave and its learned refinement](live-wave.md#adopted-as-the-default-2-november-2026), the
[instant what-ifs](learned-models.md#instant-what-ifs-2-november-2026), the
[fire after the blast](fire-spread.md#the-app-stage-3-31-october-2026), the
[people in the scene](people-in-the-scene.md#where-to-see-it) and the
[safety rings](hazards.md#where-to-see-them). Each of these already gives its
[standing](standing.md#the-four-levels). Today they sit among some forty sidebar sections built for
an engineer. The fire section alone has about thirty controls. The explorer puts five of them in
order and says in plain words what each shows.

## 1. The flow

**First launch.** The app opens on the explorer, not on the Run sidebar. The window shows three
scene cards over a still of each, with one line beneath:

- **A street.** A high street of shops and flats, three to five storeys, brick and concrete.
- **A square.** A town square ringed by blocks, with a glass office on one side.
- **Beirut's port, 2020.** The city around the port as it stood, from map data.

Under the cards: "Everything here is a quick estimate that answers as you move things. Each layer
says how sure it is." The full app is one click away (View ▸ Workbench, and back by View ▸
Explore).

**Placing the charge.** The scene opens from a high, oblique camera. The prompt reads "Click where
the charge goes". For the keyboard there is a picker of named places, such as "In the middle of the
square" or "By the kerb outside the bank". Size is a row of four steps with the slider beneath. The
charge can be dragged at any time, and every layer follows it.

**Watching it play out.** Once the charge is placed, the wave plays by itself, slowed so that it
lasts about five seconds whatever the scene (a square's wave is over in well under a second,
Beirut's in 12 s). Captions are tied to the wave's own times: the charge goes off, the front leaves
the square, the first shadow forms. The view then keeps each place's strongest push, as the live
wave does now.

**The layers, in order.** A strip under the view steps through **Wave → Glass → Walls → People →
Fire**, one at a time (each can also be turned on by itself). Each step shows its colours, a legend
in words, one or two sentences on what is happening, and a "How sure?" line. A disclosure, "Why?",
holds the full standing as the sidebar gives it now. The safety rings can be laid over any step.

**Afterwards: try something.** Cards offer the comparisons in section 2. Letting go of a drag or a
slider brings the full estimate in behind the preview, with "Refining…" and its progress. It takes
about 26 s on Beirut and seconds on the made-up scenes.

**What it leaves out, and says so.** There is no fireball, no collapse and no dust. Collapse and
its dust come only from whole-event solver runs, and the app offers none of those
([dust adopted](whole-event.md#adopted-the-dust-1-november-2026)). A line at the end of the strip
reads "Not shown: the fireball, buildings coming down and their dust. These need the full
simulation."

## 2. The comparisons that build intuition

Each comparison works by pinning, then changing one thing. **Pin** keeps the present picture. The
view then colours each building better, the same or worse than the pinned picture, and a line of
words gives the change.

| Comparison | What the user does | Existing control | What is shown |
|---|---|---|---|
| **Twice the charge** | "Double it" (×2), or the size slider | TNT slider, live through the learned response (25–32 ms a frame) | The distance out to which windows break, before and after, with a faint ring at the old distance. "Twice the charge breaks windows about a quarter further out, not twice as far." Blast distances scale with the cube root of the charge: ×2 gives ×1.26, ×10 gives ×2.2. |
| **Behind a building** | Drag the charge from the open square to behind a block | Place Charge and the drag; the live wave's shadows | The wave's shadow, and the windows behind the block that survive. "The block takes the brunt: behind it the push is weaker, and fewer windows break." |
| **Glass with film** | Glass ▸ "Filmed" (and "Laminated") | What if ▸ Glass | The windows blown in, before and after, and the people hurt by glass, relative. "Film holds the broken glass together, so fewer pieces fly into rooms." |
| **Brick or concrete** | Walls ▸ "Unreinforced masonry" | What if ▸ Walls | Walls damaged, before and after. |
| **Night or day** | Time ▸ night, working day, evening | People's time of day | Where the people hurt are, relative. |
| **Wind, or a wooden town** | The wind slider, or "If it were built of wood" | Fire's wind; the timber contrast | How far fire could carry. On Beirut, from 20 fires at random, it barely carries: 92 buildings by 12 hours. Built of wood, about 4,000 catch. |

The people comparison reuses **Pin as Baseline**, its change worked out draw by draw, for example
"−38% hurt against the pinned baseline". The pin and the better-or-worse colouring generalise that
baseline to the other layers.

## 3. The words

These are draft on-screen sentences in British English, written plainly and without alarm. Each
"How sure?" line comes from the layer's standing, and the figures are drawn from `ValidationTables`
so that they stay in step with the record. The four levels become:

| Standing | Plain words |
|---|---|
| Compared with measurement | "Checked against measurements from real tests." |
| Verified against theory | "Checked against textbook solutions, not real events." |
| Approximation | "A recognised method; how close it comes here is not known exactly." |
| Illustrative | "A sketch to show the idea, not a prediction." |

**The wave.** "The charge pushes the air outwards in a thin wall of high pressure, faster than
sound. Colours show how hard it pushes: yellow is strongest. Buildings in the way cast a shadow,
and behind them the push is weaker." *How sure:* "A sketch. Against our detailed simulations of
Beirut, it was within a quarter of their strength at about 19 places in 20 in the open and 7 in 10
behind buildings." (The refined wave: 96% and 70% within ×1.25.)

**The glass.** "Windows are the first thing to go, and the furthest out. Near the charge most are
blown in. Further away some crack and some hold." Legend: "None broken · Some broken · Blown in".
*How sure:* "An approximation. This quick look matches our detailed simulation for 7 to 9 building
sides in 10. At Beirut, that simulation broke glass about as far out as observers reported."
(68–89% of sides; the full run's edge was 1.1–2.2 km, against Rigby's 1.86 km.)

**The walls.** "Most walls stand. Close to the charge, weaker walls can crack or be pushed in.
Brick suffers more than reinforced concrete." *How sure:* "A rough sketch. It agrees with our
detailed simulation for only a third to a half of the damaged walls. To know a particular
building, run the full simulation." (29–51% of concrete, 45–56% of stone.)

**The people.** "Most people hurt by a blast are indoors, hurt by flying glass. Colours show where
people are most likely to be hurt, as a share of those inside." *How sure:* "A sketch. At Beirut,
this kind of estimate put the people hurt at about the right distances from the port, but counted
four to twelve times too many. So it shows where, and how much a change helps, never how many."

**The fire.** "A blast can start fires, and broken windows let them spread from one building to the
next. We start fires in the buildings nearest the blast and show how far they could travel over the
next 12 hours. Concrete and stone rarely carry a fire. Wood does, and wind carries sparks."
*How sure:* "A sketch, built from a fire-spread model made for New Zealand's fire service. Nobody
knows which buildings catch first. At Beirut no fire spread through the city, and the model agrees."

**The safety rings.** "These rings show how far safety rules keep the public back from a charge of
this size. They are rules, not predictions of damage." The injury rings before a run: "In the open,
eardrums can be hurt inside the amber ring." *How sure:* "A recognised method, largely from tests
on animals."

**After a drag.** "Refining… the full estimate takes about half a minute." When done: "Refined."

## 4. What's reused and what's new

| Piece | Reused | New | Rough size |
|---|---|---|---|
| Explore mode shell | `SimulationModel` as it stands | `ExplorerView`, which takes the sidebar's place: scene cards, layer strip, comparison cards | 600–800 lines of SwiftUI |
| Scenes | New District's `DistrictLayout`; the made-up district generator (`Scripts/ml/make_district.py`) | Two small fixtures (street, square), tens of kB each; Beirut's inputs, cropped (see question 2); a loader | 200 lines and fixtures |
| Placing and dragging | Place Charge; `SimulationModel+ChargeDrag`; the learned response | Named places for the keyboard; charge size steps | 100 lines |
| Wave | `LiveWave`, the refinement, the GPU pass, `LiveWaveControls` (play, speed) | A simpler bar; captions from the field's own times (BlastModel, Linux-tested) | 300 lines |
| Glass, walls | Quick estimate, learned response, Colour by, what-ifs | Plain legends; a **reach** figure (the distance out to which half the sides have some glass broken, from the chances by distance band; BlastModel) | 250 lines |
| People | `OccupantInjury`, Pin as Baseline, Colour by People Hurt | Words; relative figures only | 100 lines |
| Fire | `FireSpread.layer`, through its existing API | Explorer defaults: seeds near the charge, the scene's usual wind, 12 h | 100 lines, none in `SimulationModel+Fire.swift` |
| Rings | K24/K40 and the surface-burst injury references | Words | 50 lines |
| Words | Every layer's `standing`, `ValidationTables` | `ExplorerWords` in BlastModel: each sentence above, figures filled from the tables, tested on Linux | 300 lines |
| Pin and compare | People's baseline | Better/same/worse colouring for glass, walls and fire; the change in words | 350 lines |
| Checks | `AccessibilityTreeTests`, `AccessibilityLabelTests`, InterfaceReview captures | `InterfaceReviewExplorerTests`; tree states for each step | 300 lines |

In all, about 2,500 lines and two small fixtures. No new model is needed for stage 2.

## 5. Frame-rate budget

Figures were measured on the Studio (M4 Max) and come from the linked docs. A frame at 30 fps is
33 ms.

| Step | What runs | Measured | 30 fps? |
|---|---|---|---|
| Looking around, Beirut at 1800 × 1200 | The scene's ray march plus the wave pass | 19.3 ms GPU (13–28); the wave pass cannot be measured against it | Yes |
| Playing or scrubbing the wave | Time only, no recompute, every 15 ms | As above | Yes |
| Dragging: colours (glass, walls, damage) | Learned response: GPU loads and networks | 21–25 ms median; first frame 64–73 ms; 35–60 ms with a GPU run beside it | Yes, on a Studio not heavily shared |
| Dragging: the wave follows | Paths, KB and the refinement on 8 m cells | Beirut 81–82 ms per recompute. In the app, placed to shown took 158–388 ms (stage 1, loaded): **3–6 updates a second**. The made-up 20-building district took 6 ms | **No** on Beirut; yes on small scenes |
| Charge size slider | Learned response | 25–32 ms | Yes |
| Picking a what-if | Laying it on, then one frame | 40–60 ms, then the full estimate | Fine: a choice, not a slider |
| Fire's wind slider | 40 preview draws on the CPU | 41 ms (49–62 at load 100): **about 20 fps** | **No** |
| Dragging with the fire shown | A colours frame, then 40 fire draws | About 25 + 41 = 66 ms: **about 15 fps** (the sum of measured parts; not timed together) | **No** |
| Dragging with people shown | 10 glass draws, 40 of the assumptions | Not measured | To measure |
| Letting go | Full estimate; fire's 200 draws | About 26 s on Beirut through New District (a minute on all 14,169 buildings); fire 0.05 s | Not live, shown as "Refining…" |

Where it falls short:

- **The wave while dragging on Beirut.** Dragging on cells twice as coarse is already the default.
  A Beirut cropped to 1.5 km has about a third of the cells, which would put a recompute near 30 ms
  (an estimate, not measured). The colours keep up in any case.
- **The fire while anything moves.** Twenty draws would take about 21 ms. Another agent is changing
  the fire's preview now, and the explorer should take what that lands.
- **The GPU is shared.** A colours frame's 11 ms of GPU comes on top of the scene's 19 ms, so 30 ms
  together is close to the limit at 1800 × 1200.
- **Nothing has been measured on the M2 Air.** Stage 2 should time the square there.

## 6. Accessibility

This follows the [offscreen pass of 1 November](native-interface-review.md#offscreen-accessibility-pass-1-november-2026):

- **VoiceOver.** The 3D view's description summarises the explorer, for example "A square; 500 kg
  in the middle; windows broken on 34 of 60 buildings, out to 120 m; showing the glass". Each
  layer's sentence and its "How sure?" line are read as text. The captions are announced once when
  the wave ends, not on every frame. Every slider reads its title and the value shown ("Charge,
  500 kilograms"). Each control has one name and never a hidden title beside a label. Each legend
  reads as one element, its range in words.
- **Keyboard.** Every step is reachable without the pointer. The charge goes in by named place and
  is nudged by keys (shortcuts to be chosen so as not to clash with the camera's ⌥⌘ arrows). The
  layer strip, the comparison cards and Pin are buttons in reading order, and the view stays out of
  the Tab loop, as now. Escape leaves a card and Return acts.
- **Colour is never the only carrier.** Each layer's figure is also in words, and the
  better-or-worse colouring is also a count ("12 fewer buildings with glass blown in"). It should be
  checked under Color Filters, as the materials were.
- **Reduce Motion.** The wave steps through five stills instead of playing.
- **Tests.** `AccessibilityTreeTests` should gain the explorer's states, one per step and one per
  comparison. `AccessibilityLabelTests` holds the sources. VoiceOver on a real screen stays the
  user's check, added to the existing checklist.

## 7. Open questions for the user

1. **Where it lives.** The recommendation is an Explore mode in the same app, which the first launch
   opens, with the workbench a menu item away. The other choices are a separate window or a
   separate app target. One app keeps a single build, the same scenes and the same referee.
2. **Beirut's port as a scene.** It needs map, height and terrain data (68 MB in all,
   OpenStreetMap under ODbL, GHSL under CC BY, Copernicus GLO-30), and the live wave's refinement
   needs 15.7 MB of weights. The recommendation is to build the street and the square into the app
   and to fetch Beirut, cropped to 1.5 km, as a release asset. A single prompt would cover both
   downloads, asking first as the weights' download does. A short, factual opening line would
   say that this was a real disaster in which more than 200 people died, and that the figures here
   are a model's.
3. **People in the explorer.** Their counts read 4 to 12 times Beirut's record. The recommendation
   is to show where people are hurt and how much a change helps, as relative figures, and never a
   count or a share of people. Leaving people out of the explorer altogether is the other choice.
4. **Naming the charge's size.** The recommendation is kilograms and tonnes of TNT, in four steps
   (50 kg, 500 kg, 5 t and 500 t, the last about Beirut's estimated size), with the slider for
   anything between. Weapons and vehicles would not be named.
5. **The shortfalls in frame rate.** The recommendation is to accept the wave's 3–6 updates a
   second on all of Beirut, or to crop the explorer's Beirut to 1.5 km. For the fire, the
   recommendation is 20 preview draws while anything moves, after the other agent's change lands.

## 8. Proposed stage 2: the square, end to end

1. **The scene.** A seeded made-up square, a new style in `Scripts/ml/make_district.py`: 80–150 buildings, blocks of four
   to six storeys, a brick terrace, a glass office. Bundled, and laid out by `DistrictLayout` at
   open. Judge the learned response on it against the full estimate (`scenebench drag-time
   --agreement`), held out, with the solver as referee.
2. **The words and the reach.** `ExplorerWords` and the reach figure in BlastModel, with Linux
   tests that each sentence's figures are the tables'.
3. **The mode.** `ExplorerView` holds the scene card, placing by click or named place, the size
   steps, the wave's play with its captions, and the layer strip with each layer's words and "How
   sure?".
4. **The comparisons.** Pin and compare, with twice the charge, behind a building and glass with
   film.
5. **Accessibility and captures.** `InterfaceReviewExplorerTests` in light and dark, and the tree's
   new states.
6. **Frame times.** Measure each step of section 5 on the square on the Studio (and the Air if the
   user builds there), and record them in this doc.
7. **Release note and stop.** Add a fragment, then stop for the user's review with the captures.
   The street and Beirut follow as stage 3.
