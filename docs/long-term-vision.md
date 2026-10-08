# BombCAD long term vision

**All explosions great and small.**

BombCAD's long-term ambition is to make explosions and their interaction with the world
explorable across scales, from kilogram-scale events in rooms and around individual
structures to kiloton-scale events across landscapes and urban environments. The appeal is
being able to change a scene, observe the consequences and understand why they change.

This is a product direction, with an open research horizon. It is not a claim that the
current models cover that range, a delivery schedule or a replacement for the existing
[roadmap](roadmap.md). Improving the evidence behind the present models remains the
immediate priority.

## The experience

A user should be able to construct or import an environment, choose a supported event,
run it and inspect what happens through space and time. Geometry, materials and scale
should be meaningful parts of that exploration. The results should explain physical
interactions as well as produce an engaging visual sequence.

At small scales, the useful detail might be a pressure wave entering an opening, reflecting
inside a room or loading a wall. At the scale of a building, it might be the relationship
between the surrounding flow, connections and structural response. Across a neighbourhood
or landscape, the useful questions change to the distribution of exposure, shielding,
terrain interaction and widespread effects.

The interface should support that change in emphasis. Increasing scale should reveal
different questions and appropriate representations, rather than suggest that enlarging
one charge automatically produces a credible model of every kind of explosion.

## A broad subject

The proposition extends beyond weapons. Conventional explosions, accidental events and
idealised scientific examples all offer ways to explore pressure waves, confinement,
reflection, material response and the influence of the environment.

Nuclear effects belong to the long-term horizon because they introduce important physical
effects that a conventional blast simulation does not establish. Fireball evolution,
radiant thermal exposure and ground interaction are central areas of interest. Prompt
radiation and fallout would be additional subjects if the scope eventually included a
broader account of nuclear hazards.

No single effect is universally dominant. The useful model depends on the event, the
environment and the question. A thermal exposure study and a study of structural collapse
need different detail and different evidence.

## What would distinguish BombCAD

Tools already illustrate explosions and weapons effects at geographic scales.
[Grid/84](https://grid84.app/), for example, presents strategic scenarios with detonations,
fires and plumes, supported by [research dossiers](https://grid84.app/dossier/). Broad yield
coverage alone is therefore insufficient as a claim of uniqueness.

BombCAD's opportunity is to connect editable three-dimensional environments with spatial
simulation and clear explanations of local interactions. A user could explore how a
street, an opening, a wall or a terrain feature changes an outcome, and inspect the
physical quantities behind the image.

Native Metal solvers provide scope for substantial computation on local hardware. That
capacity can support richer models and larger scenes, but computational power alone does
not establish accuracy. The distinction should be demonstrated through the experience and
the evidence, rather than inferred from a comparison between native and browser delivery.

## Detail appropriate to the question

Large scenes cannot depend on resolving every building at the detail required for an
individual structural study. The long-term experience should accommodate detailed local
studies and simpler representations across a wider environment, with their assumptions
visible to the user.

Reusable building representations are a possible general direction. Detailed studies could
inform simplified descriptions of mechanical response or changes in geometry. For exposure
studies, building envelopes, openings and surface properties may be more relevant than
individual reinforcement bars.

Those representations would need evidence for their intended use. Buildings influence their
neighbours through shielding and changes to the surrounding flow, so a collection of
independent building results cannot simply be added together. Agreement for one isolated
building would not establish agreement for a neighbourhood.

The objective is to spend detail where it changes the answer, while keeping the cost of
exploration practical. The user should understand what detail was retained, what was
approximated and how that affects the conclusions.

## New physical scope

The present [air model](air-blast-model.md) includes options for hot-gas thermodynamics.
These affect the relationship between gas energy and pressure; they do not establish
coverage of radiant flash heating or thermal damage.

The larger-scale vision would require distinct treatment of physical subjects such as
fireball behaviour, thermal exposure, material heating and subsequent fire. A visibility or
shadow calculation is only part of an exposure assessment, and exposure alone does not
establish ignition or eventual structural failure.

Ground interaction is another distinct subject. The current reflecting ground boundary
does not represent crater formation, ground shock or displaced soil. These topics require
their own models and validation rather than an extension of the existing ground display.

These are statements of research scope. Specific formulations, numerical methods and
implementation commitments belong in separate proposals once the intended questions and
available evidence are clear.

Most of these effects can run apart from the blast, on other hardware or after it, because they
happen on different time scales or act on the blast only weakly; the early fireball, the crater
near a charge and detailed structures cannot. [Distributed computing](distributed-computing.md#the-long-term-visions-effects)
sorts them.

## Credibility as a product feature

BombCAD should make the standing of a result as accessible as the result itself. Users
should be able to distinguish measured agreement, mathematical verification, an approximation
and an illustrative output. Model assumptions, resolution sensitivity and unsupported
effects should remain attached to the scene and its exported results.

A compelling animation can help someone understand an event, but visual plausibility
cannot substitute for validation. Enlarging a scene can multiply existing uncertainties
as readily as it can reveal new interactions.

The current [validation record](validation.md) and [roadmap](roadmap.md) provide the starting
point. The long-term ambition should strengthen that practice: each expansion in physical
scope needs evidence relevant to the claims it makes. Educational exploration and
engineering decision support carry different expectations; the present project does not
establish suitability for judging the safety of real structures.

## What success would look like

The vision succeeds when users can explore explosions across substantially different
scales within one coherent environment and learn something meaningful at each scale.

- Changing geometry produces explainable differences in supported results.
- The level of detail matches the question and available computational resources.
- Larger scenes remain practical to construct, run and inspect.
- Comparisons and exports preserve the model assumptions and evidential standing.
- New physical effects enter the product with explicit scope and relevant validation.

“All explosions great and small” expresses the ambition. Delivering it means building an
environment in which the physics, the experience and the evidence grow together.
