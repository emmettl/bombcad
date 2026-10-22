kind: fixed

**Structures past failure no longer blow up.** A concrete element crushed or sheared far past
failure could outrun the structure's fixed time step and ring unstably, throwing its corners at
kilometres a second within a millisecond. On the large-panel block, a wall's failed elements
opposite the charge put two hundred times the blast's energy into the building at 0.6 s. Such
elements are now removed, or left as their bars, as soon as they pass the step's reach. Bare
elements so distorted lose their hourglass control. Runs past failure, the whole-event runs
especially, no longer carry those events. Elements that never get that far are unchanged.
