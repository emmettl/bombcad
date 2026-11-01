kind: added

**A live drag:** with a quick estimate on screen, dragging the charge can colour Beirut's 14,169
buildings at 40–50 frames a second on a Mac Studio (20–25 ms a frame, against 0.6–0.8 s), under
Quick Estimate's new **Drag preview: Learned response (GPU)**. Small networks, trained on BombCAD's
own SDOF and chance code run over Beirut's district, stand in for each component's SDOF and the
chances' draws, and the sight lines and loads are worked out on the GPU. Against the full estimate
it is as close as the CPU's preview on every measure, the glass closer: blown out within 0.1 on
96.8–96.9% of sides (85.8% before), the walls' and roofs' chances on 98.8–100.0% of buildings, the
damage colour the same for 99.5%. Off by default, the CPU's preview kept as **SDOF and draws
(CPU)**; letting go still makes the full estimate. A district built otherwise than Beirut's map
buildings, or the learned field model, keeps the CPU's preview
([the live drag's learned response](../../learned-models.md#the-live-drags-learned-response-1-november-2026)).
