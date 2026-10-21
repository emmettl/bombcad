kind: fixed

**A corrupt, cut-short or mismatched learned field model's weights file is refused with a message,
and the estimate stays the surrogate's.** Before, a `.bcfw` file named by `BOMBCAD_FIELD_MODEL` or
the setting whose header gave a negative or overflowing tensor size stopped the app, and one whose
tensors did not fit its width and depth reached the GPU. The file's tensors are now checked against
the U-Net its header describes ([learned models](../../learned-models.md#in-the-apps-quick-estimate-21-october-2026)).
The released file, checked by its SHA-256, reads as before.
