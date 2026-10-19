kind: added

**Materials look like what they are** in the viewport and in snapshots, read from each material's
own data: concrete warm grey, steel blue-grey with a highlight of the sun, profiled sheeting light
metallic, glass tinted and see-through, timber and CLT warm brown, brick red-brown, blockwork buff,
terrain earth. Exposure-only buildings are drawn by their walls' construction. Each is restrained,
so the blast's field and the damage colouring read over it. Failed elements are rubble in a dark
grey, not the material darkened: tinted by brick or timber, rubble read as the heaviest damage's
dark red to someone with protanopia. Under simulated protanopia, deuteranopia and tritanopia, every
material stays at least ΔE 15 from each stage of damage and from its rubble, and the heaviest damage
at least ΔE 10 from rubble (`MaterialAppearanceTests`); a wall of each, rendered, reads nearest its
own colour (`MaterialRenderingTests`). The colours travel to a watched run's view as well, so a
Mac watching or sharing with another needs both on this version (worker protocol 13).
