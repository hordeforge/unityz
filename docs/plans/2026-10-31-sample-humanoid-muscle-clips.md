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
- the curve count is fixed per rig, so 84 curves is a property of this avatar, not of the clip.

Known from the avatar export (`avatar_-7101528791746256914_ZAnimBaseAvatar.json`, 0.1.18):

- 52 human parts map a rig bone to a human name (`Hips` to `Hips`, `LeftArm` to `LeftUpperArm`),
  which is the bone map a sampler needs;
- **every muscle limit is zero and `m_Modified` is false**, so the per-muscle ranges are Unity's
  built-in `HumanTrait` tables, not something the file carries;
- `m_SkeletonHasParents` is **false** and every `m_ParentName` is empty, so the human
  description's skeleton has no hierarchy: the parents come from the rig itself, which the
  character GLB already carries;
- `scale` is 0.01, `has_translation_dof` and `has_extra_root` are false.

Unknown, and each one blocks the solver:

- **Curve to muscle mapping.** Unity orders dense curves by muscle index, with several components
  per muscle; which order and how many components each muscle has must be established against a
  reference, not assumed from 84.
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
2. **Pin the curve layout.** For three clips whose first frame is the reference pose (an idle
   start, a T-pose start, a death start), record the first frame's 84 values. Values that are
   zero across all three are the muscles at rest; that fixes the mapping well enough to write it
   down, and it fails loudly if the assumption is wrong.
3. **Transcribe the muscle tables.** The per-muscle component count, axis order and range, from
   Unity's own tables, with the source revision recorded.
4. **Sample.** A function from clip data plus human description to a per-bone local transform,
   with the root muscle set handled separately.
5. **Acceptance.** Sample frame 0 of the reference-pose clips and compare with the character
   GLB's bind pose per bone; print the worst deviation per clip and fail above a stated bound.

## Verification

- step 1: the export prints the human map and says which fields were missing, on a real bundle.
- step 2: the three first frames agree on the same zero set, and the report names it.
- step 3: the transcribed ranges match UnityCsReference line for line, cited by revision.
- step 4 and 5: the acceptance run prints the worst per-bone deviation for the reference clips,
  and a clip that is not a reference pose produces a non-identity pose (so the check cannot pass
  by returning the bind pose).
