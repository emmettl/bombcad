# Postprocessing follow-up: compare both fixed model outputs

The completed 432-case written-order summary has the same aggregate Float32
mismatch count as the earlier independent model. Equal counts do not establish
array identity. Before inferring anything from that coincidence, compare all
432 newly saved written32/written64 flux arrays against their corresponding
independent separate32/stored64 arrays. Verify archived hashes, shapes and dtypes;
report bit differences and maximum absolute differences per case/component and
for the whole corpus. Keep every mismatch and failure. No GPU/PDE rerun, model
selection or numerical intervention. This is separately versioned postprocessing,
not part of the frozen producing driver or a claim that either model matches
GPU intermediates. Float64 comparisons use their actual UInt64 words, not
rounded Float32 compatibility. Mathematical rearrangements can agree in the
recorded operating range without agreeing for arbitrary states.
