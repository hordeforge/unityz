# ADR 0001 - Read the mesh channel dimension byte as two nibbles

**Date:** 2026-10-28

## Status

Accepted.

## Context

A Mesh's `m_VertexData.m_Channels` entry is four bytes: `stream`, `offset`,
`format`, `dimension`. The type tree names `dimension` a plain `UInt8` in every
shipped release from 2019.4 to 2023.2, so the reader took it whole. That breaks
on the streamed decoration meshes of 7 Days to Die (found on `2022.3.62f2` and
Raft's `2021.3.45f2`): their Float16 normal channel carries `0x34`.

Reading `0x34` as a component count makes that channel `4 * 2` bytes wide only
by accident of the high bits, so the derived stride is 116 instead of 32 and
the exporter refuses the mesh, even though `m_StreamData` names a `.resS` range
of exactly `vertex_count * 32` bytes.

The alternatives were:

- Keep the raw byte and refuse the mesh (the status quo - most of the
  container's meshes never exported).
- Mask the byte to its low nibble with no explanation (a hunch dressed as a
  rule).
- Treat the high nibble as the dimension, as Unity's own UnityDataTools
  analyzer does for its `VertexSize` statistic ("The dimension can be padded.
  In that case, the real dimension is encoded in the top nibble").

## Decision

The byte is two nibbles: the low one is the number of components stored per
vertex, which is what the stride and the next channel's offset account for; the
high one is the number of components that carry data, written only when Unity
padded the attribute so the next one stays 4-byte aligned. `MeshChannel` keeps
both (`dimension`, `real_dimension`) and every layout calculation uses
`dimension`.

The evidence that the low nibble is the stored count, not the top one: on
22,948 meshes across three 7 Days to Die bundles and Raft, `vertex_count`
times the low-nibble stride equals the vertex buffer size exactly, and on
`cinderBlock01_LOD0` the 552 vertices decode as unit-length half-float normals
with a zero fourth component, perpendicular half-float tangents whose fourth
component is +-1, and UVs inside `[0, 1]` - with 4 stored normal components,
not 3.

## Consequences

Every streamed decoration mesh exports with positions, normals, and UV0. The
padded normal is written as `VEC3` and its padding component is dropped, which
matches what the component means.

The top nibble is trusted only when it is nonzero; a hypothetical byte with a
zero low nibble and a nonzero top nibble is treated as an absent channel,
because no observed file has one. A future file that does, or a high nibble
other than the `3` seen on Float16 normals, would be the smallest thing to
look at before widening this rule - the exporter already reports an unusable
layout loudly rather than writing a silently wrong stride.
