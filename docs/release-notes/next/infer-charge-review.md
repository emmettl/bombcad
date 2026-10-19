kind: fixed

**The charge inference's glass faces the right way, and a clock offset can no longer give it a
false answer.** GEER's façade layer gives each façade's way in degrees, which `infer-charge --glass`
took as radians, so it judged the wrong façades as facing the charge; the glass's yields move
(with BombCAD's exposure and the place held, 0.010 kt where it gave 0.025) and still sit far below
the arrivals' 0.5 kt ([charge inference](../../charge-inference.md#broken-glass)). A clock offset
that put an arrival before the explosion made a likelihood that was not a number, which the search
could settle on with intervals falsely narrow; such a charge is now impossible. Asking for no
steps no longer stops the program.
