kind: added

**Protective design scoped, with a working prototype (not yet in the app).** A design for finding the
cheapest set of glazing, wall and stand-off changes that meets a hazard target, with a survey of the
public criteria it builds on: UFC 4-010-01's stand-offs, GSA and ASTM F1642 glazing conditions, and
UFC 3-340-02 and PDC-TR 06-08 response limits. A Python prototype in `Scripts/protective/` searches
toy districts on the reference Kingery–Bulmash and SDOF models. On its four scenarios, an exact search
and annealing agree, and stand-off comes first in every cheapest plan. The prototype also shows what
BombCAD must improve before the search can run on its loads: shielding and close-in loads, which set the
price, and film and retrofits as constructions. Those are the staged plan's next steps
([protective design](../../protective-design.md)).
