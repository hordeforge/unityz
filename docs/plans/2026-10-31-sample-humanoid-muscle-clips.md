# Plan - sample Unity humanoid muscle clips

**Date:** 2026-10-31  
**Status:** Draft  
**Related:** the exported clip data (CHANGELOG 0.1.16, `AnimationClip` JSON)

## Outcome

`unityz` can turn a humanoid `AnimationClip`'s muscle data into a per-bone pose, so an importer
can build an animation instead of a bind pose. Done means: for a clip whose first frame is the
reference pose, the sampled pose matches the skeleton's bind pose within a stated tolerance, and a
run prints that comparison per clip.

## Scope and constraints

- In scope: the sampling itself (muscle values to bone local transforms), the mapping from a
  dense clip's curve index to a muscle, and where the rig's human description comes from.
- Out of scope: blending between clips, retargeting, root motion beyond the root muscle set, and
  anything the port needs to *play* the clip. Those belong to the importer's side.
- The data is already exported (`space: "muscle"`, `dense`, `constant`, `streamed`), so no bundle
  access is needed to develop this: a clip JSON and the character GLB are the fixtures.

## Decisions and unknowns

Known from the export and a real clip (`zombie.bundle`, `animation_9206265066114128525_headLeftB.json`):

- the clip lasts 1.3333333730697632 s, `start` 0, no curve keys at all;
- `dense`: **42 frames × 84 curves = 3528 samples**, sample rate 30, begin 0;
- `constant`: 46 values; `streamed`: 2 words and no curves, so the dense clip is the only motion;
- the curve count is **per clip, not per rig**: 376 clips in `zombie.bundle` range from 37 to 127
  dense curves, so the dense clip is a sparse set of the curves that actually move.

Known from the avatar export (`avatar_-7101528791746256914_ZAnimBaseAvatar.json`, 0.1.18):

- 52 human parts map a rig bone to a human name (`Hips` to `Hips`, `LeftArm` to `LeftUpperArm`),
  which is the bone map a sampler needs;
- **every muscle limit is zero and `m_Modified` is false**, so the per-muscle ranges are Unity's
  built-in `HumanTrait` tables, not something the file carries;
- `m_SkeletonHasParents` is **false** and every `m_ParentName` is empty, so the human
  description's skeleton has no hierarchy: the parents come from the rig itself, which the
  character GLB already carries;
- `scale` is 0.01, `has_translation_dof` and `has_extra_root` are false.

Partly settled for the curve layout (step 2, measured across **all 376** clips in
`zombie.bundle`):

- `m_MuscleClip.m_IndexArray` has **200 slots**, one per muscle curve, holding the curve's source
  or `-1`;
- **358 of 376** clips bind exactly **130** slots, always `7..136`; **13** also bind the root
  (`0..136`, 137 slots) and **5** bind none. So the mask is a property of the rig, not of the clip,
  and slots `0..6` are the root;
- on `leftArmB` the bound sources are `0..129`, exactly its 81 dense curves plus 49 constants, so a
  source below `dense.curves` is dense and the rest are constant. **That does not generalise**:
  bound equals dense-plus-constant for only 219 of the 376 clips, so the dense/constant split needs
  its own rule (likely `m_StreamedClip`, which is empty for these, plus `m_ValueArrayDelta`);
- a frame is `dense.samples[frame * curves + source]`, frame 0 included, dated by `start`/`stop`.

What that leaves for the layout is a ground-truth experiment rather than more inference, and the
first half of it is already proven on this host:

- the stock game's own Unity version (2022.3.62f2) is installed, and the editor loads a stock
  bundle with `AssetBundle.LoadFromFile`: `zombie.bundle` gives **340 assets and 376 humanoid
  clips**, each reporting its length, frame rate and `isHumanMotion`;
- the stock `Avatar` loads from the same bundle and its human description is readable in the
  editor, so the bone map a sampler needs is available from Unity too;
- the mechanism is `clip.SampleAnimation` on **the preview rig the bundle already ships**: four of
  its 1286 GameObjects carry an `Animator` whose avatar validates as human (`ZAnimBase`,
  `fall5mToLand`, `fall5mToBoost`, `fall5mToCatLandBoost`), so no rig has to be built at all. On
  `ZAnimBase`, `idle` samples to `Hips (-0.2071, 0.0708, 0.0296, 0.9753)` at t=0 and
  `(-0.1755, 0.1072, 0.0782, 0.9755)` at t=4.45. That oracle is now a tool in the consumer
  (`make clip-sample CLIP= idle TIMES=0,2.4` writes every human bone's local rotation and position);
- reading the **muscle values** directly does not work in batchmode: an `AnimationScriptPlayable`
  with an `IAnimationJob` and `MuscleHandle.GetMuscleHandles` runs and reports the clip time, but
  `AnimationHumanStream.GetMuscle` returns zero for every handle at every time, with the matching
  avatar and an instantiated, active rig. So the slot ordering has to be settled through bone
  rotations (the oracle above), not through muscle values.

The next experiment is therefore: pick a clip that moves one body part, sample it per bone with the
oracle, and match the dense curve that changes against the bone that moves. The probe scripts live
in the consumer's `work/` and are not committed.

Two numbers to carry into it, so the mapping is not assumed again:

- the avatar's `muscleFromBone` has a muscle on **95 of its 165** bone-and-axis pairs, and the
  muscle indices are not in bone order (`LeftUpperLeg` is `[23, 22, 21]`, `RightUpperLeg`
  `[31, 30, 29]`);
- a clip binds **130** slots but the rig has 95 muscles, so a slot is not a muscle: the extra 35
  has to come from somewhere (a fourth degree of freedom on some parts, or curves the muscle table
  does not name), and that is a thing to measure with the oracle, not to guess.

The method that settles it: for a set of clips that each move one body part, take the dense columns
whose values change over the clip, take the bones whose sampled rotation changes with the oracle,
and pair them up. Three or four such clips should be enough to name most of the slots, and the rest
can be confirmed by sampling a clip that moves everything at once.

Still unknown, and each blocks the solver:

- **Which muscle each slot is.** The 200 slots are in Unity's muscle order; the order and each
  slot's component role (rotation x/y/z, stretch, or a translation DoF) must be established, not
  assumed.
- **The muscle tables are native.** `HumanTrait.MuscleName`, `HumanTrait.GetMuscleDefaultMin` and
  `GetMuscleDefaultMax` are `extern` methods
  ([HumanTrait.bindings.cs](https://github.com/Unity-Technologies/UnityCsReference/blob/master/Modules/Animation/ScriptBindings/HumanTrait.bindings.cs)),
  so neither the order nor the ranges are in Unity's C# reference: the implementation lives in
  `Modules/Animation/HumanTrait.cpp`, which is not published.
  - The reproducible way to get them is a one-off dump from any Unity install: a script that
    prints `HumanTrait.MuscleName`, `GetMuscleDefaultMin(i)` and `GetMuscleDefaultMax(i)` for
    every i, committed as a table with the Unity version that produced it. That is a five-minute
    run and needs no reverse engineering, and it is exact where a transcription from another
    project would be a copy of someone else's table.
  - `unityz` cannot produce it (it reads files, not Unity APIs), so the dump belongs with the
    consumer or with the research corpus, not here.
- ~~Per-muscle ranges.~~ Measured: the avatar stores none (all limits zero, unmodified), so the
  ranges are Unity's built-in `HumanTrait` tables. They are public in UnityCsReference and have to
  be transcribed exactly, because a wrong range is a wrong pose.
- ~~Where the human description lives.~~ Measured: the Animator names its `Avatar`, and the
  `Avatar` carries the 52-part human map. Both are exported now.
- **The sampling math.** Unity converts the per-muscle values into a local rotation per bone,
  including the handedness and the "muscle is in avatar space" convention. The acceptance check
  below is what settles whether the transcription is right.

## Steps

1. **Export the rig's human description.** Read the `Avatar` (or the `Animator`'s) human
   description from a character container: the bone name per human body part, and the muscle
   limits if the file carries them. Report what is present and what is not, with the field names.
2. ~~Pin the curve layout.~~ **Done.** `m_IndexArray` plus the dense and constant clips give the
   rule above, and `index_array` is exported beside them.
3. **Transcribe the muscle tables.** The per-muscle component count, axis order and range, from
   Unity's own tables, with the source revision recorded.
4. **Sample.** A function from clip data plus human description to a per-bone local transform,
   with the root muscle set handled separately.
5. **Acceptance.** Sample frame 0 of the reference-pose clips and compare with the character
   GLB's bind pose per bone; print the worst deviation per clip and fail above a stated bound.

## Verification

- step 1: the export prints the human map and says which fields were missing, on a real bundle.
- step 2: measured on `leftArmB`: 200 slots, 130 bound, 0..129, 81 dense plus 49 constant, and the
  arithmetic closes exactly.
- step 3: the transcribed ranges match UnityCsReference line for line, cited by revision.
- step 4 and 5: the acceptance run prints the worst per-bone deviation for the reference clips,
  and a clip that is not a reference pose produces a non-identity pose (so the check cannot pass
  by returning the bind pose).
