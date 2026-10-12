# Reinforcement fixture

`reinforced-wall.ifc` is hand-written for BombCAD's tests (IFC2x3, millimetres), with no
third-party content. It has a concrete wall 4 m long, 3 m high and 200 mm thick. Its 12 mm bars are
nested in it (`IfcRelAggregates`): vertical bars at 200 mm in each face, 40 mm from the face to
their centres, and horizontal bars at 200 mm in one face, 52 mm in. There is also a roof slab whose
only reinforcement is a `Pset_ConcreteElementGeneral` (cover 25 mm, area ratio 1%).
