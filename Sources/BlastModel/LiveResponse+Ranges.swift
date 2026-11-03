// The live response's training ranges: each input's 0.1% and 99.9% points over the rows
// the built-in weights were trained on (emmettl/bombcad-work#118). Written by
// `Scripts/ml/corpus.py ranges` from protective-live/thrown-data, ref-corpus/pack-e;
// run it again whenever the built-in weights change. The live drag leaves to the CPU's preview
// what lies outside them (`LiveResponse.TrainingRanges`), and LiveResponseRangeTests checks the
// built-in scenes against them.
// swift-format-ignore-file

extension LiveResponse.TrainingRanges {
    /// The built-in weights' ranges (`forBuiltInWeights`).
    public static let builtIn = LiveResponse.TrainingRanges(
        weightsSHA256: "0a012b68ca174adeba16d5632b7ae957d01968902bce74664dab2f0dd1e6dc87",
        thrownSHA256: "a00a08621c37ef1291d7808b3bacc8e3ef6503624dd4e06893c78e9c682d74bd",
        networks: [
            "component": Network(
                names: [
                    "log10Peak", "log10Impulse", "rise", "walls.kind0", "walls.kind1", "walls.kind2",
                    "walls.kind3", "walls.kind4", "walls.thickness", "roof.kind0", "roof.kind1",
                    "roof.kind2", "roof.kind3", "roof.kind4", "roof.thickness", "bars", "glass.mm",
                    "glass.plain", "glass0", "glass1", "glass2", "glass3", "glass4", "glass5", "glass6",
                    "glass7", "glass8", "glass9", "glass10", "glass11", "glass12", "facadePane.x",
                    "facadePane.y", "facadePane.set", "spare", "kind.facade", "kind.wall", "kind.slab",
                    "kind.roof", "kind.pane", "span.short", "span.long", "oneWaySpan", "oneWay",
                    "freestanding", "edge0", "edge1", "edge2", "edge3", "axisZ", "panelHeight", "above",
                    "below"
                ],
                low: [
                    0.706035, -0.616187, 0, 0, 0, 0, 0, 0, 0.032, 0, 0, 0, 0, 0, 0.0851139, 0.150913, 6, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1.2, 1.5, 1, 0, 0, 0, 0, 0, 0, 2, 4, 0, 0, 0, 0,
                    0, 0, 0, 0, 2, 0, 0
                ],
                high: [
                    6.22605, 4.74977, 0.85, 1, 1, 1, 1, 1, 0.343446, 1, 0, 0, 1, 1, 0.319605, 0.898922, 12,
                    1, 1, 1, 1, 12, 1.52, 22, 1, 1, 8, 1, 1, 1, 1.55, 1.2, 1.5, 1, 0, 1, 0, 0, 1, 0, 6, 6, 0,
                    0, 0, 0, 0, 1, 0, 1, 4, 84, 73.8001
                ]
            ),
            "side": Network(
                names: [
                    "strip0.load0", "strip0.load1", "strip0.load2", "strip0.load3", "strip0.load4",
                    "strip0.load5", "strip0.share", "strip0.lnDistance", "strip0.present", "strip1.load0",
                    "strip1.load1", "strip1.load2", "strip1.load3", "strip1.load4", "strip1.load5",
                    "strip1.share", "strip1.lnDistance", "strip1.present", "strip2.load0", "strip2.load1",
                    "strip2.load2", "strip2.load3", "strip2.load4", "strip2.load5", "strip2.share",
                    "strip2.lnDistance", "strip2.present", "strip3.load0", "strip3.load1", "strip3.load2",
                    "strip3.load3", "strip3.load4", "strip3.load5", "strip3.share", "strip3.lnDistance",
                    "strip3.present", "log10Area", "yieldLogSD", "scatter.peak", "scatter.impulse",
                    "scatter.correlation", "glazing.mix0", "glazing.mix1", "glazing.mix2", "glazing.mix3",
                    "glazing.glass0", "glazing.glass1", "glazing.glass2", "glazing.glass3", "glazing.glass4",
                    "glazing.glass5", "glazing.glass6", "glazing.glass7", "glazing.glass8", "glazing.glass9",
                    "glazing.glass10", "glazing.glass11", "glazing.glass12", "glazing.glass13"
                ],
                low: [
                    1.41572, 0.359519, 0, 0.315891, 0.118445, 0, 0.285714, 0.112285, 1, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.20412, 0, 0.19, 0.11, 0.36,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0
                ],
                high: [
                    5.80531, 4.4252, 0.818866, 1.06182, 0.991158, 0, 1, 6.17435, 1, 4.73179, 3.87745,
                    0.776279, 0.778678, 0.876808, 0, 0.5, 6.09379, 1, 4.42734, 3.70181, 0.664751, 0.671491,
                    0.685301, 0, 0.333333, 5.7966, 1, 4.0908, 3.42492, 0.481138, 0.6268, 0.634939, 0, 0.28,
                    5.03842, 1, 3.78161, 0.667849, 0.41, 0.26, 0.51, 1, 1, 1, 1, 1, 1, 1, 12, 1.52, 22, 1, 1,
                    8, 1, 1, 1, 1.55, 0
                ]
            ),
            "building": Network(
                names: [
                    "wall0.load0", "wall0.load1", "wall0.load2", "wall0.load3", "wall0.load4", "wall0.load5",
                    "wall0.lnZ", "wall0.present", "wall0.scatter.peak", "wall0.scatter.impulse",
                    "wall0.scatter.correlation", "wall0.facing0", "wall0.facing1", "wall0.facing2",
                    "wall0.facing3", "wall0.facing4", "wall0.facing5", "wall0.kind.facade",
                    "wall0.kind.wall", "wall0.kind.slab", "wall0.kind.roof", "wall0.kind.pane",
                    "wall0.span.short", "wall0.span.long", "wall0.oneWaySpan", "wall0.oneWay",
                    "wall0.freestanding", "wall0.edge0", "wall0.edge1", "wall0.edge2", "wall0.edge3",
                    "wall0.axisZ", "wall0.panelHeight", "wall0.above", "wall0.below", "wall1.load0",
                    "wall1.load1", "wall1.load2", "wall1.load3", "wall1.load4", "wall1.load5", "wall1.lnZ",
                    "wall1.present", "wall1.scatter.peak", "wall1.scatter.impulse",
                    "wall1.scatter.correlation", "wall1.facing0", "wall1.facing1", "wall1.facing2",
                    "wall1.facing3", "wall1.facing4", "wall1.facing5", "wall1.kind.facade",
                    "wall1.kind.wall", "wall1.kind.slab", "wall1.kind.roof", "wall1.kind.pane",
                    "wall1.span.short", "wall1.span.long", "wall1.oneWaySpan", "wall1.oneWay",
                    "wall1.freestanding", "wall1.edge0", "wall1.edge1", "wall1.edge2", "wall1.edge3",
                    "wall1.axisZ", "wall1.panelHeight", "wall1.above", "wall1.below", "wall2.load0",
                    "wall2.load1", "wall2.load2", "wall2.load3", "wall2.load4", "wall2.load5", "wall2.lnZ",
                    "wall2.present", "wall2.scatter.peak", "wall2.scatter.impulse",
                    "wall2.scatter.correlation", "wall2.facing0", "wall2.facing1", "wall2.facing2",
                    "wall2.facing3", "wall2.facing4", "wall2.facing5", "wall2.kind.facade",
                    "wall2.kind.wall", "wall2.kind.slab", "wall2.kind.roof", "wall2.kind.pane",
                    "wall2.span.short", "wall2.span.long", "wall2.oneWaySpan", "wall2.oneWay",
                    "wall2.freestanding", "wall2.edge0", "wall2.edge1", "wall2.edge2", "wall2.edge3",
                    "wall2.axisZ", "wall2.panelHeight", "wall2.above", "wall2.below", "wall3.load0",
                    "wall3.load1", "wall3.load2", "wall3.load3", "wall3.load4", "wall3.load5", "wall3.lnZ",
                    "wall3.present", "wall3.scatter.peak", "wall3.scatter.impulse",
                    "wall3.scatter.correlation", "wall3.facing0", "wall3.facing1", "wall3.facing2",
                    "wall3.facing3", "wall3.facing4", "wall3.facing5", "wall3.kind.facade",
                    "wall3.kind.wall", "wall3.kind.slab", "wall3.kind.roof", "wall3.kind.pane",
                    "wall3.span.short", "wall3.span.long", "wall3.oneWaySpan", "wall3.oneWay",
                    "wall3.freestanding", "wall3.edge0", "wall3.edge1", "wall3.edge2", "wall3.edge3",
                    "wall3.axisZ", "wall3.panelHeight", "wall3.above", "wall3.below", "wall4.load0",
                    "wall4.load1", "wall4.load2", "wall4.load3", "wall4.load4", "wall4.load5", "wall4.lnZ",
                    "wall4.present", "wall4.scatter.peak", "wall4.scatter.impulse",
                    "wall4.scatter.correlation", "wall4.facing0", "wall4.facing1", "wall4.facing2",
                    "wall4.facing3", "wall4.facing4", "wall4.facing5", "wall4.kind.facade",
                    "wall4.kind.wall", "wall4.kind.slab", "wall4.kind.roof", "wall4.kind.pane",
                    "wall4.span.short", "wall4.span.long", "wall4.oneWaySpan", "wall4.oneWay",
                    "wall4.freestanding", "wall4.edge0", "wall4.edge1", "wall4.edge2", "wall4.edge3",
                    "wall4.axisZ", "wall4.panelHeight", "wall4.above", "wall4.below", "wall5.load0",
                    "wall5.load1", "wall5.load2", "wall5.load3", "wall5.load4", "wall5.load5", "wall5.lnZ",
                    "wall5.present", "wall5.scatter.peak", "wall5.scatter.impulse",
                    "wall5.scatter.correlation", "wall5.facing0", "wall5.facing1", "wall5.facing2",
                    "wall5.facing3", "wall5.facing4", "wall5.facing5", "wall5.kind.facade",
                    "wall5.kind.wall", "wall5.kind.slab", "wall5.kind.roof", "wall5.kind.pane",
                    "wall5.span.short", "wall5.span.long", "wall5.oneWaySpan", "wall5.oneWay",
                    "wall5.freestanding", "wall5.edge0", "wall5.edge1", "wall5.edge2", "wall5.edge3",
                    "wall5.axisZ", "wall5.panelHeight", "wall5.above", "wall5.below", "wall6.load0",
                    "wall6.load1", "wall6.load2", "wall6.load3", "wall6.load4", "wall6.load5", "wall6.lnZ",
                    "wall6.present", "wall6.scatter.peak", "wall6.scatter.impulse",
                    "wall6.scatter.correlation", "wall6.facing0", "wall6.facing1", "wall6.facing2",
                    "wall6.facing3", "wall6.facing4", "wall6.facing5", "wall6.kind.facade",
                    "wall6.kind.wall", "wall6.kind.slab", "wall6.kind.roof", "wall6.kind.pane",
                    "wall6.span.short", "wall6.span.long", "wall6.oneWaySpan", "wall6.oneWay",
                    "wall6.freestanding", "wall6.edge0", "wall6.edge1", "wall6.edge2", "wall6.edge3",
                    "wall6.axisZ", "wall6.panelHeight", "wall6.above", "wall6.below", "wall7.load0",
                    "wall7.load1", "wall7.load2", "wall7.load3", "wall7.load4", "wall7.load5", "wall7.lnZ",
                    "wall7.present", "wall7.scatter.peak", "wall7.scatter.impulse",
                    "wall7.scatter.correlation", "wall7.facing0", "wall7.facing1", "wall7.facing2",
                    "wall7.facing3", "wall7.facing4", "wall7.facing5", "wall7.kind.facade",
                    "wall7.kind.wall", "wall7.kind.slab", "wall7.kind.roof", "wall7.kind.pane",
                    "wall7.span.short", "wall7.span.long", "wall7.oneWaySpan", "wall7.oneWay",
                    "wall7.freestanding", "wall7.edge0", "wall7.edge1", "wall7.edge2", "wall7.edge3",
                    "wall7.axisZ", "wall7.panelHeight", "wall7.above", "wall7.below", "roof.load0",
                    "roof.load1", "roof.load2", "roof.load3", "roof.load4", "roof.load5", "roof.lnZ",
                    "roof.present", "roof.scatter.peak", "roof.scatter.impulse", "roof.scatter.correlation",
                    "roof.facing0", "roof.facing1", "roof.facing2", "roof.facing3", "roof.facing4",
                    "roof.facing5", "roof.kind.facade", "roof.kind.wall", "roof.kind.slab", "roof.kind.roof",
                    "roof.kind.pane", "roof.span.short", "roof.span.long", "roof.oneWaySpan", "roof.oneWay",
                    "roof.freestanding", "roof.edge0", "roof.edge1", "roof.edge2", "roof.edge3",
                    "roof.axisZ", "roof.panelHeight", "roof.above", "roof.below", "yieldLogSD",
                    "walls.kind0", "walls.kind1", "walls.kind2", "walls.kind3", "walls.kind4",
                    "walls.thickness", "roof.kind0", "roof.kind1", "roof.kind2", "roof.kind3", "roof.kind4",
                    "roof.thickness", "bars", "glass.mm", "glass.plain", "glass0", "glass1", "glass2",
                    "glass3", "glass4", "glass5", "glass6", "glass7", "glass8", "glass9", "glass10",
                    "glass11", "glass12", "facadePane.x", "facadePane.y", "facadePane.set", "spare"
                ],
                low: [
                    1.50479, 0.333582, 0, 0.314015, 0.0962668, 0, -0.245565, 1, 0.19, 0.11, 0.36, 0, 0, 0, 0,
                    0, 0, 1, 0, 0, 0, 0, 2, 4, 0, 0, 0, 0, 0, 0, 0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, -0.0464828,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0.457365, -0.87798, 0, 0.441994, 0.293769, 0, -0.0400119, 1, 0.19, 0.11, 0.36, 0, 0, 0,
                    0, 0, 1, 0, 0, 0, 1, 0, 4, 4, 0, 0, 0, 0, 0, 0, 0, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0.032,
                    0, 0, 0, 0, 0, 0.0851139, 0.150913, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 1.2,
                    1.5, 1, 0
                ],
                high: [
                    6.48659, 4.84295, 0.9, 1.08993, 1.02701, 0, 6.16885, 1, 0.41, 0.26, 0.51, 1, 1, 1, 1, 0,
                    0, 1, 0, 0, 0, 0, 3, 6, 0, 0, 0, 0, 0, 1, 0, 0, 3, 84.1, 24, 5.88782, 4.42835, 0.9,
                    0.977749, 0.958596, 0, 6.16922, 1, 0.41, 0.26, 0.51, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 3,
                    6, 0, 0, 0, 0, 0, 1, 0, 0, 3, 84.1, 24, 5.54752, 4.27869, 0.9, 1.00462, 0.946098, 0,
                    6.16721, 1, 0.41, 0.26, 0.51, 1, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 3, 6, 0, 0, 0, 0, 0, 1, 0,
                    0, 3, 84.1, 24, 5.4266, 4.24588, 0.9, 1.01416, 0.942964, 0, 6.1567, 1, 0.41, 0.26, 0.51,
                    1, 1, 1, 1, 0, 0, 1, 0, 0, 0, 0, 3, 6, 0, 0, 0, 0, 0, 1, 0, 0, 3, 84, 24, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 6.05514, 4.2951, 0.530416, 1.75464, 1.86203,
                    0, 6.16965, 1, 0.41, 0.26, 0.51, 0, 0, 0, 0, 0, 1, 0, 0, 0, 1, 0, 6, 6, 0, 0, 0, 0, 0, 0,
                    0, 1, 4, 2, 84.2, 0.667849, 1, 1, 1, 1, 1, 0.343254, 1, 0, 0, 1, 1, 0.319605, 0.898922,
                    12, 1, 1, 1, 1, 12, 1.52, 22, 1, 1, 8, 1, 1, 1, 1.55, 1.2, 1.5, 1, 0
                ]
            ),
            "thrown": Network(
                names: [
                    "strip0.load0", "strip0.load1", "strip0.load2", "strip0.load3", "strip0.load4",
                    "strip0.load5", "strip0.share", "strip0.lnDistance", "strip0.present", "strip1.load0",
                    "strip1.load1", "strip1.load2", "strip1.load3", "strip1.load4", "strip1.load5",
                    "strip1.share", "strip1.lnDistance", "strip1.present", "strip2.load0", "strip2.load1",
                    "strip2.load2", "strip2.load3", "strip2.load4", "strip2.load5", "strip2.share",
                    "strip2.lnDistance", "strip2.present", "strip3.load0", "strip3.load1", "strip3.load2",
                    "strip3.load3", "strip3.load4", "strip3.load5", "strip3.share", "strip3.lnDistance",
                    "strip3.present", "log10Area", "yieldLogSD", "scatter.peak", "scatter.impulse",
                    "scatter.correlation", "glazing.mix0", "glazing.mix1", "glazing.mix2", "glazing.mix3",
                    "glazing.glass0", "glazing.glass1", "glazing.glass2", "glazing.glass3", "glazing.glass4",
                    "glazing.glass5", "glazing.glass6", "glazing.glass7", "glazing.glass8", "glazing.glass9",
                    "glazing.glass10", "glazing.glass11", "glazing.glass12", "glazing.glass13"
                ],
                low: [
                    1.45256, 0.484657, 0, 0.29563, 0.0795503, 0, 0.333333, -0.554007, 1, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1.20412, 0, 0.19, 0.11, 0.36,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0
                ],
                high: [
                    6.58714, 4.83725, 0.832309, 1.10082, 0.993972, 0, 1, 6.06735, 1, 4.77137, 3.91159,
                    0.760072, 0.7478, 0.78082, 0, 0.5, 5.96199, 1, 4.33254, 3.6384, 0.585651, 0.649408,
                    0.643402, 0, 0.307692, 5.57481, 1, 3.91927, 3.25855, 0.349495, 0.564285, 0.613317, 0,
                    0.2, 4.03997, 1, 3.65128, 0.667849, 0.41, 0.26, 0.51, 1, 1, 1, 1, 1, 1, 1, 12, 1.52, 22,
                    1, 1, 8, 1, 1, 1, 1.55, 0
                ]
            ),
        ])
}
