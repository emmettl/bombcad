kind: added

`field-export --trace-clock-inputs` can save bounded native timestep inputs and controls for
Metal/CUDA comparisons. It preserves the producer shaders and requires pressure tracing;
these diagnostic records do not change dataset admission.
