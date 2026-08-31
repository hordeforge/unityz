//! Typed views over the generic value tree for the common Unity classes.
//!
//! UnityPy exposes a typed class per Unity class ID; here we provide the
//! subset needed by extraction and editing, as accessors over
//! [`value.Value`]. Fields are read by name, so files with stripped or
//! renamed fields degrade to defaults instead of failing.

const std = @import("std");
const value = @import("value.zig");

/// Class name for a Unity class ID, mirroring UnityPy's `ClassIDType`
/// enum (the full runtime + editor table). `null` for IDs the enum does
/// not define, e.g. 100 (unassigned) and 238 (NavMeshData).
pub fn className(class_id: i32) ?[]const u8 {
    const names = [_]struct { id: i32, name: []const u8 }{
        .{ .id = 0, .name = "Object" },
        .{ .id = 1, .name = "GameObject" },
        .{ .id = 2, .name = "Component" },
        .{ .id = 3, .name = "LevelGameManager" },
        .{ .id = 4, .name = "Transform" },
        .{ .id = 5, .name = "TimeManager" },
        .{ .id = 6, .name = "GlobalGameManager" },
        .{ .id = 8, .name = "Behaviour" },
        .{ .id = 9, .name = "GameManager" },
        .{ .id = 11, .name = "AudioManager" },
        .{ .id = 12, .name = "ParticleAnimator" },
        .{ .id = 13, .name = "InputManager" },
        .{ .id = 15, .name = "EllipsoidParticleEmitter" },
        .{ .id = 17, .name = "Pipeline" },
        .{ .id = 18, .name = "EditorExtension" },
        .{ .id = 19, .name = "Physics2DSettings" },
        .{ .id = 20, .name = "Camera" },
        .{ .id = 21, .name = "Material" },
        .{ .id = 23, .name = "MeshRenderer" },
        .{ .id = 25, .name = "Renderer" },
        .{ .id = 26, .name = "ParticleRenderer" },
        .{ .id = 27, .name = "Texture" },
        .{ .id = 28, .name = "Texture2D" },
        .{ .id = 29, .name = "OcclusionCullingSettings" },
        .{ .id = 30, .name = "GraphicsSettings" },
        .{ .id = 33, .name = "MeshFilter" },
        .{ .id = 41, .name = "OcclusionPortal" },
        .{ .id = 43, .name = "Mesh" },
        .{ .id = 45, .name = "Skybox" },
        .{ .id = 47, .name = "QualitySettings" },
        .{ .id = 48, .name = "Shader" },
        .{ .id = 49, .name = "TextAsset" },
        .{ .id = 50, .name = "Rigidbody2D" },
        .{ .id = 51, .name = "Physics2DManager" },
        .{ .id = 53, .name = "Collider2D" },
        .{ .id = 54, .name = "Rigidbody" },
        .{ .id = 55, .name = "PhysicsManager" },
        .{ .id = 56, .name = "Collider" },
        .{ .id = 57, .name = "Joint" },
        .{ .id = 58, .name = "CircleCollider2D" },
        .{ .id = 59, .name = "HingeJoint" },
        .{ .id = 60, .name = "PolygonCollider2D" },
        .{ .id = 61, .name = "BoxCollider2D" },
        .{ .id = 62, .name = "PhysicsMaterial2D" },
        .{ .id = 64, .name = "MeshCollider" },
        .{ .id = 65, .name = "BoxCollider" },
        .{ .id = 66, .name = "CompositeCollider2D" },
        .{ .id = 68, .name = "EdgeCollider2D" },
        .{ .id = 70, .name = "CapsuleCollider2D" },
        .{ .id = 72, .name = "ComputeShader" },
        .{ .id = 74, .name = "AnimationClip" },
        .{ .id = 75, .name = "ConstantForce" },
        .{ .id = 76, .name = "WorldParticleCollider" },
        .{ .id = 78, .name = "TagManager" },
        .{ .id = 81, .name = "AudioListener" },
        .{ .id = 82, .name = "AudioSource" },
        .{ .id = 83, .name = "AudioClip" },
        .{ .id = 84, .name = "RenderTexture" },
        .{ .id = 86, .name = "CustomRenderTexture" },
        .{ .id = 87, .name = "MeshParticleEmitter" },
        .{ .id = 88, .name = "ParticleEmitter" },
        .{ .id = 89, .name = "Cubemap" },
        .{ .id = 90, .name = "Avatar" },
        .{ .id = 91, .name = "AnimatorController" },
        .{ .id = 92, .name = "GUILayer" },
        .{ .id = 93, .name = "RuntimeAnimatorController" },
        .{ .id = 94, .name = "ScriptMapper" },
        .{ .id = 95, .name = "Animator" },
        .{ .id = 96, .name = "TrailRenderer" },
        .{ .id = 98, .name = "DelayedCallManager" },
        .{ .id = 102, .name = "TextMesh" },
        .{ .id = 104, .name = "RenderSettings" },
        .{ .id = 108, .name = "Light" },
        .{ .id = 109, .name = "CGProgram" },
        .{ .id = 110, .name = "BaseAnimationTrack" },
        .{ .id = 111, .name = "Animation" },
        .{ .id = 114, .name = "MonoBehaviour" },
        .{ .id = 115, .name = "MonoScript" },
        .{ .id = 116, .name = "MonoManager" },
        .{ .id = 117, .name = "Texture3D" },
        .{ .id = 118, .name = "NewAnimationTrack" },
        .{ .id = 119, .name = "Projector" },
        .{ .id = 120, .name = "LineRenderer" },
        .{ .id = 121, .name = "Flare" },
        .{ .id = 122, .name = "Halo" },
        .{ .id = 123, .name = "LensFlare" },
        .{ .id = 124, .name = "FlareLayer" },
        .{ .id = 125, .name = "HaloLayer" },
        .{ .id = 126, .name = "NavMeshProjectSettings" },
        .{ .id = 127, .name = "HaloManager" },
        .{ .id = 128, .name = "Font" },
        .{ .id = 129, .name = "PlayerSettings" },
        .{ .id = 130, .name = "NamedObject" },
        .{ .id = 131, .name = "GUITexture" },
        .{ .id = 132, .name = "GUIText" },
        .{ .id = 133, .name = "GUIElement" },
        .{ .id = 134, .name = "PhysicMaterial" },
        .{ .id = 135, .name = "SphereCollider" },
        .{ .id = 136, .name = "CapsuleCollider" },
        .{ .id = 137, .name = "SkinnedMeshRenderer" },
        .{ .id = 138, .name = "FixedJoint" },
        .{ .id = 140, .name = "RaycastCollider" },
        .{ .id = 141, .name = "BuildSettings" },
        .{ .id = 142, .name = "AssetBundle" },
        .{ .id = 143, .name = "CharacterController" },
        .{ .id = 144, .name = "CharacterJoint" },
        .{ .id = 145, .name = "SpringJoint" },
        .{ .id = 146, .name = "WheelCollider" },
        .{ .id = 147, .name = "ResourceManager" },
        .{ .id = 148, .name = "NetworkView" },
        .{ .id = 149, .name = "NetworkManager" },
        .{ .id = 150, .name = "PreloadData" },
        .{ .id = 152, .name = "MovieTexture" },
        .{ .id = 153, .name = "ConfigurableJoint" },
        .{ .id = 154, .name = "TerrainCollider" },
        .{ .id = 155, .name = "MasterServerInterface" },
        .{ .id = 156, .name = "TerrainData" },
        .{ .id = 157, .name = "LightmapSettings" },
        .{ .id = 158, .name = "WebCamTexture" },
        .{ .id = 159, .name = "EditorSettings" },
        .{ .id = 160, .name = "InteractiveCloth" },
        .{ .id = 161, .name = "ClothRenderer" },
        .{ .id = 162, .name = "EditorUserSettings" },
        .{ .id = 163, .name = "SkinnedCloth" },
        .{ .id = 164, .name = "AudioReverbFilter" },
        .{ .id = 165, .name = "AudioHighPassFilter" },
        .{ .id = 166, .name = "AudioChorusFilter" },
        .{ .id = 167, .name = "AudioReverbZone" },
        .{ .id = 168, .name = "AudioEchoFilter" },
        .{ .id = 169, .name = "AudioLowPassFilter" },
        .{ .id = 170, .name = "AudioDistortionFilter" },
        .{ .id = 171, .name = "SparseTexture" },
        .{ .id = 180, .name = "AudioBehaviour" },
        .{ .id = 181, .name = "AudioFilter" },
        .{ .id = 182, .name = "WindZone" },
        .{ .id = 183, .name = "Cloth" },
        .{ .id = 184, .name = "SubstanceArchive" },
        .{ .id = 185, .name = "ProceduralMaterial" },
        .{ .id = 186, .name = "ProceduralTexture" },
        .{ .id = 187, .name = "Texture2DArray" },
        .{ .id = 188, .name = "CubemapArray" },
        .{ .id = 191, .name = "OffMeshLink" },
        .{ .id = 192, .name = "OcclusionArea" },
        .{ .id = 193, .name = "Tree" },
        .{ .id = 194, .name = "NavMeshObsolete" },
        .{ .id = 195, .name = "NavMeshAgent" },
        .{ .id = 196, .name = "NavMeshSettings" },
        .{ .id = 197, .name = "LightProbesLegacy" },
        .{ .id = 198, .name = "ParticleSystem" },
        .{ .id = 199, .name = "ParticleSystemRenderer" },
        .{ .id = 200, .name = "ShaderVariantCollection" },
        .{ .id = 205, .name = "LODGroup" },
        .{ .id = 206, .name = "BlendTree" },
        .{ .id = 207, .name = "Motion" },
        .{ .id = 208, .name = "NavMeshObstacle" },
        .{ .id = 210, .name = "SortingGroup" },
        .{ .id = 212, .name = "SpriteRenderer" },
        .{ .id = 213, .name = "Sprite" },
        .{ .id = 214, .name = "CachedSpriteAtlas" },
        .{ .id = 215, .name = "ReflectionProbe" },
        .{ .id = 216, .name = "ReflectionProbes" },
        .{ .id = 218, .name = "Terrain" },
        .{ .id = 220, .name = "LightProbeGroup" },
        .{ .id = 221, .name = "AnimatorOverrideController" },
        .{ .id = 222, .name = "CanvasRenderer" },
        .{ .id = 223, .name = "Canvas" },
        .{ .id = 224, .name = "RectTransform" },
        .{ .id = 225, .name = "CanvasGroup" },
        .{ .id = 226, .name = "BillboardAsset" },
        .{ .id = 227, .name = "BillboardRenderer" },
        .{ .id = 228, .name = "SpeedTreeWindAsset" },
        .{ .id = 229, .name = "AnchoredJoint2D" },
        .{ .id = 230, .name = "Joint2D" },
        .{ .id = 231, .name = "SpringJoint2D" },
        .{ .id = 232, .name = "DistanceJoint2D" },
        .{ .id = 233, .name = "HingeJoint2D" },
        .{ .id = 234, .name = "SliderJoint2D" },
        .{ .id = 235, .name = "WheelJoint2D" },
        .{ .id = 236, .name = "ClusterInputManager" },
        .{ .id = 237, .name = "BaseVideoTexture" },
        .{ .id = 238, .name = "NavMeshData" },
        .{ .id = 240, .name = "AudioMixer" },
        .{ .id = 241, .name = "AudioMixerController" },
        .{ .id = 243, .name = "AudioMixerGroupController" },
        .{ .id = 244, .name = "AudioMixerEffectController" },
        .{ .id = 245, .name = "AudioMixerSnapshotController" },
        .{ .id = 246, .name = "PhysicsUpdateBehaviour2D" },
        .{ .id = 247, .name = "ConstantForce2D" },
        .{ .id = 248, .name = "Effector2D" },
        .{ .id = 249, .name = "AreaEffector2D" },
        .{ .id = 250, .name = "PointEffector2D" },
        .{ .id = 251, .name = "PlatformEffector2D" },
        .{ .id = 252, .name = "SurfaceEffector2D" },
        .{ .id = 253, .name = "BuoyancyEffector2D" },
        .{ .id = 254, .name = "RelativeJoint2D" },
        .{ .id = 255, .name = "FixedJoint2D" },
        .{ .id = 256, .name = "FrictionJoint2D" },
        .{ .id = 257, .name = "TargetJoint2D" },
        .{ .id = 258, .name = "LightProbes" },
        .{ .id = 259, .name = "LightProbeProxyVolume" },
        .{ .id = 271, .name = "SampleClip" },
        .{ .id = 272, .name = "AudioMixerSnapshot" },
        .{ .id = 273, .name = "AudioMixerGroup" },
        .{ .id = 280, .name = "NScreenBridge" },
        .{ .id = 290, .name = "AssetBundleManifest" },
        .{ .id = 292, .name = "UnityAdsManager" },
        .{ .id = 300, .name = "RuntimeInitializeOnLoadManager" },
        .{ .id = 301, .name = "CloudWebServicesManager" },
        .{ .id = 303, .name = "UnityAnalyticsManager" },
        .{ .id = 304, .name = "CrashReportManager" },
        .{ .id = 305, .name = "PerformanceReportingManager" },
        .{ .id = 310, .name = "UnityConnectSettings" },
        .{ .id = 319, .name = "AvatarMask" },
        .{ .id = 320, .name = "PlayableDirector" },
        .{ .id = 328, .name = "VideoPlayer" },
        .{ .id = 329, .name = "VideoClip" },
        .{ .id = 330, .name = "ParticleSystemForceField" },
        .{ .id = 331, .name = "SpriteMask" },
        .{ .id = 362, .name = "WorldAnchor" },
        .{ .id = 363, .name = "OcclusionCullingData" },
        .{ .id = 1000, .name = "SmallestEditorClassID" },
        .{ .id = 1001, .name = "PrefabInstance" },
        .{ .id = 1002, .name = "EditorExtensionImpl" },
        .{ .id = 1003, .name = "AssetImporter" },
        .{ .id = 1004, .name = "AssetDatabaseV1" },
        .{ .id = 1005, .name = "Mesh3DSImporter" },
        .{ .id = 1006, .name = "TextureImporter" },
        .{ .id = 1007, .name = "ShaderImporter" },
        .{ .id = 1008, .name = "ComputeShaderImporter" },
        .{ .id = 1020, .name = "AudioImporter" },
        .{ .id = 1026, .name = "HierarchyState" },
        .{ .id = 1027, .name = "GUIDSerializer" },
        .{ .id = 1028, .name = "AssetMetaData" },
        .{ .id = 1029, .name = "DefaultAsset" },
        .{ .id = 1030, .name = "DefaultImporter" },
        .{ .id = 1031, .name = "TextScriptImporter" },
        .{ .id = 1032, .name = "SceneAsset" },
        .{ .id = 1034, .name = "NativeFormatImporter" },
        .{ .id = 1035, .name = "MonoImporter" },
        .{ .id = 1037, .name = "AssetServerCache" },
        .{ .id = 1038, .name = "LibraryAssetImporter" },
        .{ .id = 1040, .name = "ModelImporter" },
        .{ .id = 1041, .name = "FBXImporter" },
        .{ .id = 1042, .name = "TrueTypeFontImporter" },
        .{ .id = 1044, .name = "MovieImporter" },
        .{ .id = 1045, .name = "EditorBuildSettings" },
        .{ .id = 1046, .name = "DDSImporter" },
        .{ .id = 1048, .name = "InspectorExpandedState" },
        .{ .id = 1049, .name = "AnnotationManager" },
        .{ .id = 1050, .name = "PluginImporter" },
        .{ .id = 1051, .name = "EditorUserBuildSettings" },
        .{ .id = 1052, .name = "PVRImporter" },
        .{ .id = 1053, .name = "ASTCImporter" },
        .{ .id = 1054, .name = "KTXImporter" },
    };
    for (names) |n| {
        if (n.id == class_id) return n.name;
    }
    return null;
}

/// Finds a named field in a `.obj` value, or null.
pub fn fieldOf(v: value.Value, name: []const u8) ?value.Value {
    return switch (v) {
        .obj => |fields| blk: {
            for (fields) |f| {
                if (std.mem.eql(u8, f.name, name)) break :blk f.value;
            }
            break :blk null;
        },
        else => null,
    };
}

pub fn intField(v: value.Value, name: []const u8) ?i64 {
    const f = fieldOf(v, name) orelse return null;
    return f.asInt();
}

/// Narrows an untrusted type-tree integer to `T`, yielding 0 when it does
/// not fit. Field values come from the file, so a negative or oversized
/// integer must degrade to the default the same way a missing field does
/// rather than make `@intCast` illegal behaviour.
fn narrow(comptime T: type, v: i64) T {
    return std.math.cast(T, v) orelse 0;
}

pub fn boolField(v: value.Value, name: []const u8) ?bool {
    return switch (fieldOf(v, name) orelse return null) {
        .bool => |b| b,
        else => null,
    };
}

pub fn stringField(v: value.Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .string => |s| s,
        else => null,
    };
}

pub fn floatField(v: value.Value, name: []const u8) ?f64 {
    return switch (fieldOf(v, name) orelse return null) {
        .float => |f| f,
        else => null,
    };
}

pub fn bytesField(v: value.Value, name: []const u8) ?[]const u8 {
    return switch (fieldOf(v, name) orelse return null) {
        .bytes => |b| b,
        else => null,
    };
}

pub fn pptrField(v: value.Value, name: []const u8) ?value.PPtr {
    return switch (fieldOf(v, name) orelse return null) {
        .pptr => |p| p,
        .obj => |fields| blk: {
            // PPtrs with extra fields were read as objects.
            const file = intField(.{ .obj = fields }, "m_FileID") orelse break :blk null;
            const path = intField(.{ .obj = fields }, "m_PathID") orelse break :blk null;
            break :blk .{ .file_id = narrow(i32, file), .path_id = path };
        },
        else => null,
    };
}

/// A `Vector3f`/`Quaternionf`-style struct of floats.
pub fn vec3Field(v: value.Value, name: []const u8) ?[3]f32 {
    const f = fieldOf(v, name) orelse return null;
    var out: [3]f32 = .{ 0, 0, 0 };
    const comps = [_][]const u8{ "x", "y", "z" };
    for (0..3) |i| {
        const comp = comps[i];
        const c = fieldOf(f, comp) orelse continue;
        if (c != .float) return null;
        out[i] = @floatCast(c.float);
    }
    return out;
}

/// Reference to a streamed byte range, `StreamingInfo` in the tree:
/// `offset` (u32), `size` (u32), `path` (string).
pub const StreamingInfo = struct {
    offset: u32 = 0,
    size: u32 = 0,
    path: []const u8 = "",

    pub fn fromValue(v: value.Value) StreamingInfo {
        const f = fieldOf(v, "m_StreamData") orelse return .{};
        return .{
            .offset = narrow(u32, intField(f, "offset") orelse intField(f, "m_Offset") orelse 0),
            .size = narrow(u32, intField(f, "size") orelse intField(f, "m_Size") orelse 0),
            .path = stringField(f, "path") orelse stringField(f, "m_Path") orelse "",
        };
    }
};

pub const Texture2D = struct {
    width: u32 = 0,
    height: u32 = 0,
    format: i32 = 0,
    mip_count: u32 = 0,
    image_count: u32 = 0,
    complete_image_size: u32 = 0,
    is_readable: bool = false,
    /// Embedded pixel data (`m_ImageData`).
    image_data: []const u8 = &.{},
    /// Streamed pixel data range (`m_StreamData`); when `path` is empty the
    /// data lives in this serialized file at `data_offset + offset`.
    stream: StreamingInfo = .{},

    pub fn fromValue(v: value.Value) Texture2D {
        return .{
            .width = narrow(u32, intField(v, "m_Width") orelse 0),
            .height = narrow(u32, intField(v, "m_Height") orelse 0),
            .format = narrow(i32, intField(v, "m_TextureFormat") orelse 0),
            .mip_count = narrow(u32, intField(v, "m_MipCount") orelse 1),
            .image_count = narrow(u32, intField(v, "m_ImageCount") orelse 1),
            .complete_image_size = narrow(u32, intField(v, "m_CompleteImageSize") orelse 0),
            .is_readable = boolField(v, "m_IsReadable") orelse false,
            // The pixel payload is named "image data" in modern type trees
            // (2021.2+) and "m_ImageData" in older ones; accept both.
            .image_data = bytesField(v, "image data") orelse bytesField(v, "m_ImageData") orelse &.{},
            .stream = StreamingInfo.fromValue(v),
        };
    }
};

pub const TextAsset = struct {
    name: []const u8 = "",
    script: []const u8 = &.{},

    pub fn fromValue(v: value.Value) TextAsset {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .script = bytesField(v, "m_Script") orelse &.{},
        };
    }
};

/// Unity AudioClip: metadata plus streamed audio data. When
/// `resource.path` is set the bytes live in a sibling `.resS`/`.resource`
/// sidecar (often an FSB5 bank); otherwise `audio_data` holds them.
pub const AudioClip = struct {
    name: []const u8 = "",
    channels: u32 = 0,
    frequency: u32 = 0,
    bits_per_sample: u32 = 0,
    compression_format: i32 = 0,
    audio_data: []const u8 = &.{},
    /// Streamed data range (`m_Resource`): `path` is the sidecar source,
    /// `offset`/`size` the clip's slice within it.
    resource: StreamingInfo = .{},

    pub fn fromValue(v: value.Value) AudioClip {
        const f = fieldOf(v, "m_Resource") orelse return .{};
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .channels = narrow(u32, intField(v, "m_Channels") orelse 0),
            .frequency = narrow(u32, intField(v, "m_Frequency") orelse 0),
            .bits_per_sample = narrow(u32, intField(v, "m_BitsPerSample") orelse 0),
            .compression_format = narrow(i32, intField(v, "m_CompressionFormat") orelse 0),
            .audio_data = bytesField(v, "m_AudioData") orelse &.{},
            .resource = .{
                .offset = narrow(u32, intField(f, "m_Offset") orelse 0),
                .size = narrow(u32, intField(f, "m_Size") orelse 0),
                .path = stringField(f, "m_Source") orelse "",
            },
        };
    }
};

pub const GameObject = struct {
    name: []const u8 = "",
    layer: i64 = 0,
    is_active: bool = true,
    tag: []const u8 = "",
    /// PPtrs to Component objects.
    components: []const value.PPtr = &.{},

    pub fn fromValue(v: value.Value) GameObject {
        var self = GameObject{
            .name = stringField(v, "m_Name") orelse "",
            .layer = intField(v, "m_Layer") orelse 0,
            .is_active = boolField(v, "m_IsActive") orelse true,
            .tag = stringField(v, "m_TagString") orelse "",
        };
        const comps = fieldOf(v, "m_Components") orelse return self;
        const arr = switch (comps) {
            .array => |a| a,
            else => return self,
        };
        var list: std.ArrayList(value.PPtr) = .empty;
        for (arr) |item| {
            if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item } } }, "x")) |p| {
                list.append(std.heap.page_allocator, p) catch {};
            }
        }
        self.components = list.toOwnedSlice(std.heap.page_allocator) catch &.{};
        return self;
    }
};

pub const Transform = struct {
    local_position: [3]f32 = .{ 0, 0, 0 },
    local_rotation: [4]f32 = .{ 0, 0, 0, 1 },
    local_scale: [3]f32 = .{ 1, 1, 1 },
    game_object: ?value.PPtr = null,
    father: ?value.PPtr = null,

    pub fn fromValue(v: value.Value) Transform {
        var self = Transform{};
        if (vec3Field(v, "m_LocalPosition")) |p| self.local_position = p;
        if (vec3Field(v, "m_LocalScale")) |s| self.local_scale = s;
        if (fieldOf(v, "m_LocalRotation")) |q| {
            if (q == .obj) {
                const comps = [_][]const u8{ "x", "y", "z", "w" };
                for (comps, 0..) |c, i| {
                    if (fieldOf(q, c)) |f| {
                        if (f == .float) self.local_rotation[i] = @floatCast(f.float);
                    }
                }
            }
        }
        self.game_object = pptrField(v, "m_GameObject");
        self.father = pptrField(v, "m_Father");
        return self;
    }
};

pub const Sprite = struct {
    name: []const u8 = "",
    texture: ?value.PPtr = null,
    alpha_texture: ?value.PPtr = null,
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    pixels_to_units: f32 = 100,
    width: u32 = 0,
    height: u32 = 0,
    /// SpriteRenderData.settingsRaw bitfield (see helpers below).
    settings_raw: u32 = 0,

    /// bit 0: sprite is atlas-packed.
    pub fn isPacked(self: *const Sprite) bool {
        return self.settings_raw & 1 != 0;
    }

    /// bit 1: 0 = kSPMTight (mesh/polygon), 1 = kSPMRectangle (plain crop).
    pub fn isTight(self: *const Sprite) bool {
        return (self.settings_raw >> 1) & 1 == 0;
    }

    /// bits 2-5: SpritePackingRotation (0 none, 1 flipH, 2 flipV, 3 rot180,
    /// 4 rot90), matching UnityPy's SpriteSettings.
    pub fn packingRotation(self: *const Sprite) u32 {
        return (self.settings_raw >> 2) & 0xf;
    }

    /// Fills `out[4]` with x/y/width/height from a Rectf-shaped value.
    fn readRect(r: value.Value, out: *[4]f32) void {
        if (r != .obj) return;
        const comps = [_][]const u8{ "x", "y", "width", "height" };
        for (comps, 0..) |c, i| {
            if (fieldOf(r, c)) |f| {
                if (f == .float) out[i] = @floatCast(f.float);
            }
        }
    }

    pub fn fromValue(v: value.Value) Sprite {
        const ptu: f32 = blk: {
            const f = fieldOf(v, "m_PixelsToUnits") orelse break :blk 100;
            break :blk @floatCast(f.asFloat() orelse 100);
        };
        var self = Sprite{
            .name = stringField(v, "m_Name") orelse "",
            .texture = pptrField(v, "m_Texture"),
            .alpha_texture = pptrField(v, "m_AlphaTexture"),
            .pixels_to_units = ptu,
        };
        if (intField(v, "m_Width")) |w| self.width = narrow(u32, w);
        if (intField(v, "m_Height")) |h| self.height = narrow(u32, h);
        if (fieldOf(v, "m_Rect")) |r| readRect(r, &self.rect);
        // Modern sprites carry the render data in m_RD (texture + rect);
        // it takes precedence over the legacy top-level fields.
        if (fieldOf(v, "m_RD")) |rd| {
            if (pptrField(rd, "texture")) |t| self.texture = t;
            if (pptrField(rd, "alphaTexture")) |at| self.alpha_texture = at;
            if (fieldOf(rd, "textureRect")) |r| readRect(r, &self.rect);
            if (intField(rd, "settingsRaw")) |sr| {
                self.settings_raw = @truncate(@as(u64, @bitCast(sr)));
            }
        }
        return self;
    }

    /// Crops the sprite's rect out of a decoded RGBA texture and flips it
    /// vertically, matching UnityPy's sprite export (the rect's y is
    /// measured from the texture's top; Unity displays it bottom-up).
    /// Returns RGBA8 pixels of size `width x height`.
    pub fn spriteRgba(
        self: *const Sprite,
        allocator: std.mem.Allocator,
        tex_rgba: []const u8,
        tex_w: u32,
        tex_h: u32,
    ) ![]u8 {
        return spriteRgbaRect(allocator, self.rect, tex_rgba, tex_w, tex_h);
    }

    /// Crops an arbitrary rect (e.g. the atlas's copy for packed sprites)
    /// out of a decoded RGBA texture. Rounds the box the way Pillow's
    /// Image.crop does - floor on x/y, ceil on x+w/y+h - so sprite sizes
    /// match UnityPy byte-for-byte, and clamps to the texture bounds, then
    /// flips the rows vertically (UnityPy flips the final sprite image).
    pub fn spriteRgbaRect(
        allocator: std.mem.Allocator,
        rect: [4]f32,
        tex_rgba: []const u8,
        tex_w: u32,
        tex_h: u32,
    ) ![]u8 {
        const crop = try cropRectNoFlip(allocator, rect, tex_rgba, tex_w, tex_h);
        return flipRows(allocator, crop.data, crop.w, crop.h);
    }

    /// A cropped box: `data` is `w x h` RGBA8, top-origin (not flipped).
    pub const Crop = struct {
        data: []u8,
        w: usize,
        h: usize,
    };

    /// Crops `rect` out of `tex_rgba` WITHOUT flipping rows, returning the
    /// top-origin box, sized/rounded exactly like UnityPy/Pillow.
    pub fn cropRectNoFlip(
        allocator: std.mem.Allocator,
        rect: [4]f32,
        tex_rgba: []const u8,
        tex_w: u32,
        tex_h: u32,
    ) !Crop {
        const tw: usize = tex_w;
        const th: usize = tex_h;
        const rx_f = @floor(rect[0]);
        const ry_f = @floor(rect[1]);
        const r1_f = @ceil(rect[0] + rect[2]);
        const r2_f = @ceil(rect[1] + rect[3]);
        const tw_f: f32 = @floatFromInt(tw);
        const th_f: f32 = @floatFromInt(th);
        // Stated in the positive so a NaN rect fails it: `rect` is
        // file-supplied, and @intFromFloat on a NaN or on an extent past the
        // usize range is illegal behavior, not a clamp. The upper end is
        // clamped in the float domain instead of rejected, since the box is
        // clipped to the texture bounds below anyway.
        if (!(rx_f >= 0 and ry_f >= 0 and r1_f > rx_f and r2_f > ry_f)) return error.RectOutsideTexture;
        if (!(rx_f <= tw_f and ry_f <= th_f)) return error.RectOutsideTexture;
        const rx: usize = @intFromFloat(rx_f);
        const ry: usize = @intFromFloat(ry_f);
        var rw: usize = @as(usize, @intFromFloat(@min(r1_f, tw_f))) - rx;
        var rh: usize = @as(usize, @intFromFloat(@min(r2_f, th_f))) - ry;
        if (rx >= tw or ry >= th) return error.RectOutsideTexture;
        rw = @min(rw, tw - rx); // PIL clamps to the image bounds
        rh = @min(rh, th - ry);
        if (tex_rgba.len < tw * th * 4) return error.SizeMismatch;

        const out = try allocator.alloc(u8, rw * rh * 4);
        for (0..rh) |row| {
            const src_row = ry + row; // top-origin, no flip
            const src = tex_rgba[(src_row * tw + rx) * 4 ..][0 .. rw * 4];
            @memcpy(out[row * rw * 4 ..][0 .. rw * 4], src);
        }
        return .{ .data = out, .w = rw, .h = rh };
    }

    fn flipRows(allocator: std.mem.Allocator, rgba: []const u8, w: usize, h: usize) ![]u8 {
        const out = try allocator.alloc(u8, rgba.len);
        for (0..h) |row| {
            const src = rgba[(h - 1 - row) * w * 4 ..][0 .. w * 4];
            @memcpy(out[row * w * 4 ..][0 .. w * 4], src);
        }
        return out;
    }
};

/// Merges a packed sprite's separate alpha texture into the main RGBA
/// image: RGB from `main_rgba`, alpha from the alpha texture's R channel
/// (UnityPy: Image.merge("RGBA", (*main.split()[:3], alpha.split()[0]))).
/// Both images are `w x h` RGBA8.
pub fn mergeAlphaTexture(
    allocator: std.mem.Allocator,
    main_rgba: []const u8,
    alpha_rgba: []const u8,
    w: u32,
    h: u32,
) ![]u8 {
    const n: usize = @as(usize, w) * @as(usize, h);
    if (main_rgba.len < n * 4 or alpha_rgba.len < n * 4) return error.SizeMismatch;
    const out = try allocator.alloc(u8, n * 4);
    for (0..n) |i| {
        out[i * 4 + 0] = main_rgba[i * 4 + 0];
        out[i * 4 + 1] = main_rgba[i * 4 + 1];
        out[i * 4 + 2] = main_rgba[i * 4 + 2];
        out[i * 4 + 3] = alpha_rgba[i * 4 + 0]; // alpha texture's R channel
    }
    return out;
}

/// Upper bound on a rendered sprite edge in pixels. Only a sanity limit: it
/// keeps the file-derived extent inside the range where converting it to a
/// `usize` is defined.
const max_sprite_dim: f32 = 65536;

/// A sprite's tight/polygon mesh: 3D positions, optional per-vertex UVs,
/// and triangle indices (grouped by submesh in the source blob).
pub const SpriteMesh = struct {
    positions: []const [3]f32,
    uvs: []const [2]f32, // length == positions.len, or empty
    triangles: []const u32,
};

/// Reads the sprite triangle index list from the render data's index buffer
/// (bytes of u16) or one of the integer-array fields Unity writes.
pub fn readSpriteTriangles(arena: std.mem.Allocator, rd: value.Value) ?[]const u32 {
    if (bytesField(rd, "m_IndexBuffer")) |buf| {
        if (buf.len >= 6) {
            const n = buf.len / 2;
            const tris = arena.alloc(u32, n) catch return null;
            for (0..n) |i| tris[i] = std.mem.readInt(u16, buf[i * 2 ..][0..2], .little);
            return tris;
        }
    }
    for ([_][]const u8{ "m_IndexBuffer", "indices", "triangles" }) |name| {
        const f = fieldOf(rd, name) orelse continue;
        if (f == .array and f.array.len > 0) {
            const n = f.array.len;
            const tris = arena.alloc(u32, n) catch return null;
            for (f.array, 0..) |x, i| tris[i] = @intCast(x.asInt() orelse @as(i64, 0));
            return tris;
        }
    }
    return null;
}

/// A rotated/transposed RGBA image: `data` is `w x h`.
pub const Rotated = struct {
    data: []u8,
    w: u32,
    h: u32,
};

/// Applies a `SpritePackingRotation` (0 none, 1 flipH, 2 flipV, 3 rotate180,
/// 4 rotate90) to a top-origin RGBA image, matching UnityPy's transpose for
/// packed sprites. Rotation 4 rotates 90° clockwise (PIL ROTATE_270).
pub fn rotateSprite(
    allocator: std.mem.Allocator,
    rgba: []const u8,
    w: u32,
    h: u32,
    rotation: u32,
) !Rotated {
    const wi = @as(usize, w);
    const hi = @as(usize, h);
    switch (rotation) {
        0 => return .{ .data = try allocator.dupe(u8, rgba), .w = w, .h = h },
        1 => { // FLIP_LEFT_RIGHT
            const out = try allocator.alloc(u8, rgba.len);
            for (0..hi) |r| {
                for (0..wi) |c| {
                    const dst = (r * wi + c) * 4;
                    const src = (r * wi + (wi - 1 - c)) * 4;
                    @memcpy(out[dst..][0..4], rgba[src..][0..4]);
                }
            }
            return .{ .data = out, .w = w, .h = h };
        },
        2 => { // FLIP_TOP_BOTTOM (reuse the vertical flip)
            const out = try allocator.alloc(u8, rgba.len);
            for (0..hi) |r| {
                const src = (hi - 1 - r) * wi * 4;
                @memcpy(out[r * wi * 4 ..][0 .. wi * 4], rgba[src..][0 .. wi * 4]);
            }
            return .{ .data = out, .w = w, .h = h };
        },
        3 => { // ROTATE_180
            const out = try allocator.alloc(u8, rgba.len);
            for (0..hi) |r| {
                for (0..wi) |c| {
                    const dst = (r * wi + c) * 4;
                    const src = ((hi - 1 - r) * wi + (wi - 1 - c)) * 4;
                    @memcpy(out[dst..][0..4], rgba[src..][0..4]);
                }
            }
            return .{ .data = out, .w = w, .h = h };
        },
        4 => { // ROTATE_270 (90° clockwise): w and h swap
            const nw = h;
            const nh = w;
            const out = try allocator.alloc(u8, @as(usize, nw) * @as(usize, nh) * 4);
            for (0..nh) |r| {
                for (0..nw) |c| {
                    // new(r, c) = old(old_y = h-1-c, old_x = r)
                    const src = ((hi - 1 - c) * wi + r) * 4;
                    const dst = (r * nw + c) * 4;
                    @memcpy(out[dst..][0..4], rgba[src..][0..4]);
                }
            }
            return .{ .data = out, .w = nw, .h = nh };
        },
        else => return .{ .data = try allocator.dupe(u8, rgba), .w = w, .h = h },
    }
}

/// Point-in-triangle test (inclusive of edges), matching a non-anti-aliased
/// polygon fill like PIL's `draw.polygon(..., fill=1)`.
fn pointInTri(px: f32, py: f32, ax: f32, ay: f32, bx: f32, by: f32, cx: f32, cy: f32) bool {
    const s1 = (bx - ax) * (py - ay) - (by - ay) * (px - ax);
    const s2 = (cx - bx) * (py - by) - (cy - by) * (px - bx);
    const s3 = (ax - cx) * (py - cy) - (ay - cy) * (px - cx);
    const has_neg = s1 < 0 or s2 < 0 or s3 < 0;
    const has_pos = s1 > 0 or s2 > 0 or s3 > 0;
    return !(has_pos and has_neg);
}

/// Masks a `w x h` top-origin crop with the sprite's polygon, zeroing pixels
/// outside the mesh triangles. The mesh is projected to 2D on x/y (UnityPy
/// drops the constant axis), normalized by its min, and scaled by
/// `pixels_to_units`, so the polygon aligns with the crop extent.
pub fn maskSprite(
    allocator: std.mem.Allocator,
    mesh: SpriteMesh,
    pixels_to_units: f32,
    crop: []const u8,
    w: u32,
    h: u32,
) ![]u8 {
    const cw = @as(usize, w);
    const ch = @as(usize, h);
    if (crop.len < cw * ch * 4) return error.SizeMismatch;
    if (mesh.positions.len == 0 or mesh.triangles.len == 0) return error.NoMesh;
    const ptu = pixels_to_units;

    var min_x: f32 = mesh.positions[0][0];
    var min_y: f32 = mesh.positions[0][1];
    for (mesh.positions) |p| {
        if (p[0] < min_x) min_x = p[0];
        if (p[1] < min_y) min_y = p[1];
    }

    const out = try allocator.alloc(u8, cw * ch * 4);
    const tri_count = mesh.triangles.len / 3;
    for (0..ch) |r| {
        for (0..cw) |c| {
            const px: f32 = @as(f32, @floatFromInt(c)) + 0.5;
            const py: f32 = @as(f32, @floatFromInt(r)) + 0.5;
            var inside = false;
            for (0..tri_count) |t| {
                const ia = mesh.triangles[t * 3];
                const ib = mesh.triangles[t * 3 + 1];
                const ic = mesh.triangles[t * 3 + 2];
                if (ia >= mesh.positions.len or ib >= mesh.positions.len or ic >= mesh.positions.len) continue;
                const p0 = mesh.positions[ia];
                const p1 = mesh.positions[ib];
                const p2 = mesh.positions[ic];
                const ax = (p0[0] - min_x) * ptu;
                const ay = (p0[1] - min_y) * ptu;
                const bx = (p1[0] - min_x) * ptu;
                const by = (p1[1] - min_y) * ptu;
                const cx = (p2[0] - min_x) * ptu;
                const cy = (p2[1] - min_y) * ptu;
                if (pointInTri(px, py, ax, ay, bx, by, cx, cy)) {
                    inside = true;
                    break;
                }
            }
            if (inside) {
                @memcpy(out[(r * cw + c) * 4 ..][0..4], crop[(r * cw + c) * 4 ..][0..4]);
            } else {
                @memset(out[(r * cw + c) * 4 ..][0..4], 0);
            }
        }
    }
    return out;
}

/// Unpacked texture-mapped triangle copy. Fills `sprite` with the triangle's
/// pixels sampled from the full texture: for each destination pixel we compute
/// barycentric weights against the destination triangle and apply them to the
/// source (UV) triangle's vertices, then round to the nearest source pixel.
/// Renders into `sprite` (RGBA8, `sw x sh`), pixels untouched by a triangle
/// stay `(0,0,0,0)` (matching UnityPy's render_sprite_mesh blank canvas).
fn paintTriangle(
    sprite: []u8,
    sw: usize,
    sh: usize,
    src: []const u8,
    src_w: usize,
    src_h: usize,
    dp0: [2]f32,
    dp1: [2]f32,
    dp2: [2]f32,
    sp0: [2]f32,
    sp1: [2]f32,
    sp2: [2]f32,
) void {
    // Clamp the bounding box in the float domain: `dp` derives from
    // file-supplied positions times `m_PixelsToUnits`, so it can be
    // negative, NaN, or huge, and @intFromFloat outside the destination
    // range is illegal behavior. (@min/@max drop NaN, so a NaN corner
    // collapses to the sw/sh end and the loop body never runs.)
    const sw_f: f32 = @floatFromInt(sw);
    const sh_f: f32 = @floatFromInt(sh);
    const min_x: usize = @intFromFloat(@floor(std.math.clamp(@min(@min(dp0[0], dp1[0]), dp2[0]), 0, sw_f)));
    const max_x: usize = @intFromFloat(@ceil(std.math.clamp(@max(@max(dp0[0], dp1[0]), dp2[0]), 0, sw_f)));
    const min_y: usize = @intFromFloat(@floor(std.math.clamp(@min(@min(dp0[1], dp1[1]), dp2[1]), 0, sh_f)));
    const max_y: usize = @intFromFloat(@ceil(std.math.clamp(@max(@max(dp0[1], dp1[1]), dp2[1]), 0, sh_f)));
    const src_w_f: f32 = @floatFromInt(src_w);
    const src_h_f: f32 = @floatFromInt(src_h);
    const area = (dp1[0] - dp0[0]) * (dp2[1] - dp0[1]) - (dp2[0] - dp0[0]) * (dp1[1] - dp0[1]);
    if (area == 0) return; // degenerate
    // Barycentric weights (share a common area sign); interior for either
    // winding is "all >= 0" or "all <= 0".
    for (min_y..max_y) |r| {
        for (min_x..max_x) |c| {
            const px: f32 = @as(f32, @floatFromInt(c)) + 0.5;
            const py: f32 = @as(f32, @floatFromInt(r)) + 0.5;
            const l0 = ((dp1[0] - dp0[0]) * (py - dp0[1]) - (dp1[1] - dp0[1]) * (px - dp0[0])) / area; // weight of C
            const l1 = ((dp2[0] - dp1[0]) * (py - dp1[1]) - (dp2[1] - dp1[1]) * (px - dp1[0])) / area; // weight of A
            const l2 = ((dp0[0] - dp2[0]) * (py - dp2[1]) - (dp0[1] - dp2[1]) * (px - dp2[0])) / area; // weight of B
            const inside = (l0 >= 0 and l1 >= 0 and l2 >= 0) or (l0 <= 0 and l1 <= 0 and l2 <= 0);
            if (inside) {
                // u = wA*sp0 + wB*sp1 + wC*sp2 ; here wA=l1, wB=l2, wC=l0
                const u = l1 * sp0[0] + l2 * sp1[0] + l0 * sp2[0];
                const vv = l1 * sp0[1] + l2 * sp1[1] + l0 * sp2[1];
                // nearest-neighbour: the texel containing the sampled point
                // Clamp both ends before the conversion: `sp` derives from
                // file-supplied UVs, so u/vv can be Inf or huge, and
                // @intFromFloat outside the usize range is illegal behavior
                // rather than something clampUsize can still catch. @max
                // first (not std.math.clamp, which puts a NaN on the upper
                // bound) keeps a NaN UV sampling texel 0 as before.
                const uf = @floor(@min(@max(u, 0), src_w_f));
                const vf = @floor(@min(@max(vv, 0), src_h_f));
                const sx = clampUsize(@intFromFloat(uf), src_w);
                const sy = clampUsize(@intFromFloat(vf), src_h);
                @memcpy(sprite[(r * sw + c) * 4 ..][0..4], src[(sy * src_w + sx) * 4 ..][0..4]);
            }
        }
    }
}

fn clampUsize(v: usize, limit: usize) usize {
    return if (v >= limit) limit - 1 else v;
}

/// Renders a tightly packed sprite mesh: maps the texture (sampled at the
/// mesh's UV coordinates) onto the polygon defined by the mesh positions,
/// producing a tightly cropped sprite. Matches UnityPy's render_sprite_mesh.
pub fn renderSpriteMesh(
    allocator: std.mem.Allocator,
    mesh: SpriteMesh,
    pixels_to_units: f32,
    tex_rgba: []const u8,
    tex_w: u32,
    tex_h: u32,
) !Rotated {
    const tw = @as(usize, tex_w);
    const th = @as(usize, tex_h);
    if (mesh.positions.len == 0 or mesh.triangles.len == 0 or mesh.uvs.len == 0) return error.NoMesh;
    if (tex_rgba.len < tw * th * 4) return error.SizeMismatch;
    if (mesh.uvs.len != mesh.positions.len) return error.BadMesh;

    // project to 2D on x/y (drop the constant axis)
    var min_x: f32 = mesh.positions[0][0];
    var min_y: f32 = mesh.positions[0][1];
    var max_x: f32 = mesh.positions[0][0];
    var max_y: f32 = mesh.positions[0][1];
    for (mesh.positions) |p| {
        if (p[0] < min_x) min_x = p[0];
        if (p[1] < min_y) min_y = p[1];
        if (p[0] > max_x) max_x = p[0];
        if (p[1] > max_y) max_y = p[1];
    }
    const ptu = pixels_to_units;
    // destination (absolute-pixel) and source (absolute-texel) per vertex
    const n = mesh.positions.len;
    const dw_f = @round((max_x - min_x) * ptu);
    const dh_f = @round((max_y - min_y) * ptu);
    // Reject before the conversion, not after: positions and
    // `m_PixelsToUnits` are file-supplied, and @intFromFloat on a negative,
    // NaN, or out-of-range extent is illegal behavior rather than a clamp.
    if (!(dw_f >= 0 and dw_f <= max_sprite_dim)) return error.BadMesh;
    if (!(dh_f >= 0 and dh_f <= max_sprite_dim)) return error.BadMesh;
    // guard against zero sizes
    const sprite_w = @max(@as(usize, @intFromFloat(dw_f)), 1);
    const sprite_h = @max(@as(usize, @intFromFloat(dh_f)), 1);
    const sprite = try allocator.alloc(u8, sprite_w * sprite_h * 4);
    @memset(sprite, 0);

    var dp: [][2]f32 = try allocator.alloc([2]f32, n);
    var sp: [][2]f32 = try allocator.alloc([2]f32, n);
    for (0..n) |i| {
        dp[i] = .{ (mesh.positions[i][0] - min_x) * ptu, (mesh.positions[i][1] - min_y) * ptu };
        sp[i] = .{ mesh.uvs[i][0] * @as(f32, @floatFromInt(tex_w)), mesh.uvs[i][1] * @as(f32, @floatFromInt(tex_h)) };
    }
    const tri_count = mesh.triangles.len / 3;
    for (0..tri_count) |t| {
        const va = mesh.triangles[t * 3];
        const vb = mesh.triangles[t * 3 + 1];
        const vc = mesh.triangles[t * 3 + 2];
        if (va >= n or vb >= n or vc >= n) continue;
        paintTriangle(sprite, sprite_w, sprite_h, tex_rgba, tw, th, dp[va], dp[vb], dp[vc], sp[va], sp[vb], sp[vc]);
    }
    return .{ .data = sprite, .w = @intCast(sprite_w), .h = @intCast(sprite_h) };
}

pub const Material = struct {
    name: []const u8 = "",
    shader: ?value.PPtr = null,

    pub fn fromValue(v: value.Value) Material {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .shader = pptrField(v, "m_Shader"),
        };
    }
};

pub const MonoBehaviour = struct {
    name: []const u8 = "",
    enabled: bool = true,
    script: ?value.PPtr = null,
    game_object: ?value.PPtr = null,
    /// Raw serialized script payload (the managed object graph) after the
    /// type-tree-described fields; exposed as bytes, not yet parsed.
    script_data: []const u8 = &.{},
    /// Resolved MonoScript identity when the caller supplies it.
    script_name: []const u8 = "",
    script_namespace: []const u8 = "",
    script_assembly: []const u8 = "",

    pub fn fromValue(v: value.Value) MonoBehaviour {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .enabled = boolField(v, "m_Enabled") orelse true,
            .script = pptrField(v, "m_Script"),
            .game_object = pptrField(v, "m_GameObject"),
        };
    }
};

/// MonoScript identity fields (class 115).
pub const MonoScript = struct {
    name: []const u8 = "",
    class_name: []const u8 = "",
    namespace: []const u8 = "",
    assembly: []const u8 = "",

    pub fn fromValue(v: value.Value) MonoScript {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .class_name = stringField(v, "m_ClassName") orelse "",
            .namespace = stringField(v, "m_Namespace") orelse "",
            .assembly = stringField(v, "m_AssemblyName") orelse "",
        };
    }

    /// Best available script name (`Namespace` when set, else the class
    /// name), with the trailing NUL Unity's string fields carry trimmed.
    pub fn fullName(self: MonoScript) []const u8 {
        const ns = std.mem.trimEnd(u8, self.namespace, "\x00");
        const cn = std.mem.trimEnd(u8, self.class_name, "\x00");
        return if (ns.len != 0) ns else cn;
    }
};

pub const AssetBundle = struct {
    name: []const u8 = "",

    pub fn fromValue(v: value.Value) AssetBundle {
        return .{ .name = stringField(v, "m_Name") orelse "" };
    }
};

/// One vertex channel layout entry (`Mesh.m_VertexData.m_Channels`).
pub const MeshChannel = struct {
    stream: u32 = 0,
    offset: u32 = 0,
    format: i32 = 0,
    dimension: u32 = 0,
};

/// Typed view over a Mesh object's serialized form.
///
/// The geometry lives in two opaque byte buffers decoded by `m_Channels`:
/// `vertex_data` holds `vertex_count` interleaved vertices (each channel at
/// `offset` with `format`/`dimension` components), and `index_buffer` holds
/// `m_IndexFormat`-sized indices. Channel formats follow Unity's
/// `VertexChannelFormat` enum (0 = Float32 ... 10 = UInt32Normalized).
pub const Mesh = struct {
    name: []const u8 = "",
    vertex_count: u32 = 0,
    index_format: i32 = 0,
    vertex_data: []const u8 = "",
    index_buffer: []const u8 = "",
    /// Fixed-size channel table (Unity writes at most 14); `channel_count`
    /// is the populated length.
    channels: [14]MeshChannel = [_]MeshChannel{.{}} ** 14,
    channel_count: usize = 0,

    pub fn channelSlice(self: *const Mesh) []const MeshChannel {
        return self.channels[0..self.channel_count];
    }

    /// The channel's layout, or null when absent (dimension 0) or when the
    /// data is not all in stream 0 (multi-stream layouts are rare and
    /// unsupported for export).
    pub fn channel(self: *const Mesh, index: usize) ?MeshChannel {
        if (index >= self.channel_count) return null;
        const c = self.channels[index];
        if (c.dimension == 0 or c.stream != 0) return null;
        return c;
    }

    /// Size in bytes of one component for a `VertexChannelFormat` value.
    pub fn formatSize(format: i32) ?usize {
        return switch (format) {
            0, 2, 4, 5, 10, 11 => 4,
            1, 6, 7, 9 => 2,
            3, 8 => 1,
            else => null,
        };
    }

    /// The interleaved vertex stride: the furthest byte any channel
    /// occupies, rounded up to 4.
    pub fn stride(self: *const Mesh) ?usize {
        var max_end: usize = 0;
        for (self.channelSlice()) |c| {
            if (c.dimension == 0) continue;
            if (c.stream != 0) return null;
            const fs = formatSize(c.format) orelse return null;
            // offset and dimension are raw u32s from the file; saturate
            // instead of wrapping so a bogus channel yields an impossibly
            // large stride (which the callers' size check then rejects)
            // rather than overflowing into a small one.
            max_end = @max(max_end, @as(usize, c.offset) +| fs *| @as(usize, c.dimension));
        }
        return (max_end +| 3) / 4 * 4;
    }

    pub fn fromValue(v: value.Value) Mesh {
        var m = Mesh{ .name = stringField(v, "m_Name") orelse "" };
        if (intField(v, "m_IndexFormat")) |f| m.index_format = narrow(i32, f);
        m.index_buffer = bytesField(v, "m_IndexBuffer") orelse "";

        const vd = fieldOf(v, "m_VertexData") orelse return m;
        if (intField(vd, "m_VertexCount")) |n| m.vertex_count = narrow(u32, n);
        m.vertex_data = bytesField(vd, "m_DataSize") orelse "";

        if (fieldOf(vd, "m_Channels")) |chans| {
            if (chans == .array) {
                const arr = chans.array;
                const n = @min(arr.len, m.channels.len);
                for (arr[0..n], 0..) |c, i| {
                    m.channels[i] = .{
                        .stream = narrow(u32, intField(c, "stream") orelse 0),
                        .offset = narrow(u32, intField(c, "offset") orelse 0),
                        .format = narrow(i32, intField(c, "format") orelse 0),
                        .dimension = narrow(u32, intField(c, "dimension") orelse 0),
                    };
                }
                m.channel_count = n;
            }
        }
        return m;
    }
};

test "monoscript full name trims the trailing nul" {
    const ms = MonoScript{
        .namespace = "MyGame\x00",
        .class_name = "TestClass\x00",
        .assembly = "Assembly-CSharp\x00",
    };
    try std.testing.expectEqualStrings("MyGame", ms.fullName());
    const ms2 = MonoScript{ .class_name = "Plain\x00" };
    try std.testing.expectEqualStrings("Plain", ms2.fullName());
    const ms3 = MonoScript{};
    try std.testing.expectEqualStrings("", ms3.fullName());
}

test "typed views extract fields from a generic value" {
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Width", .value = .{ .int = 64 } },
        .{ .name = "m_Height", .value = .{ .int = 32 } },
        .{ .name = "m_TextureFormat", .value = .{ .int = 20 } },
        .{ .name = "m_MipCount", .value = .{ .int = 1 } },
        .{ .name = "m_ImageData", .value = .{ .bytes = "PIXELS" } },
        .{ .name = "m_StreamData", .value = .{ .obj = &[_]value.Field{
            .{ .name = "offset", .value = .{ .uint = 512 } },
            .{ .name = "size", .value = .{ .uint = 6 } },
            .{ .name = "path", .value = .{ .string = "tex.resS" } },
        } } },
    } };
    const t = Texture2D.fromValue(v);
    try std.testing.expectEqual(@as(u32, 64), t.width);
    try std.testing.expectEqual(@as(u32, 32), t.height);
    try std.testing.expectEqual(@as(i32, 20), t.format);
    try std.testing.expectEqualStrings("PIXELS", t.image_data);
    try std.testing.expectEqual(@as(u32, 512), t.stream.offset);
    try std.testing.expectEqualStrings("tex.resS", t.stream.path);

    const g = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Player" } },
        .{ .name = "m_IsActive", .value = .{ .bool = false } },
        .{ .name = "m_Components", .value = .{ .array = &[_]value.Value{
            .{ .pptr = .{ .file_id = 0, .path_id = 5 } },
            .{ .pptr = .{ .file_id = 0, .path_id = 9 } },
        } } },
    } };
    const go = GameObject.fromValue(g);
    try std.testing.expectEqualStrings("Player", go.name);
    try std.testing.expect(!go.is_active);
    try std.testing.expectEqual(@as(usize, 2), go.components.len);
    try std.testing.expectEqual(@as(i64, 9), go.components[1].path_id);
}

test "sprite crop flips vertically like UnityPy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // 4x4 texture; pixel (x, y) = (x*64, y*64, 128, 255), row 0 first.
    const tex_w: u32 = 4;
    const tex_h: u32 = 4;
    const rgba = try a.alloc(u8, tex_w * tex_h * 4);
    for (0..4) |y| {
        for (0..4) |x| {
            const p = (y * 4 + x) * 4;
            rgba[p] = @intCast(x * 64);
            rgba[p + 1] = @intCast(y * 64);
            rgba[p + 2] = 128;
            rgba[p + 3] = 255;
        }
    }

    // sprite rect (1, 1, 2, 2) via the value tree, as a real parse yields
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "spr" } },
        .{ .name = "m_Rect", .value = .{ .obj = &[_]value.Field{
            .{ .name = "x", .value = .{ .float = 1 } },
            .{ .name = "y", .value = .{ .float = 1 } },
            .{ .name = "width", .value = .{ .float = 2 } },
            .{ .name = "height", .value = .{ .float = 2 } },
        } } },
        .{ .name = "m_PixelsToUnits", .value = .{ .float = 100 } },
    } };
    const sprite = Sprite.fromValue(v);
    const out = try sprite.spriteRgba(a, rgba, tex_w, tex_h);

    // UnityPy: crop top-origin (rows 1-2) then flip vertically, so
    // output row 0 = texture row 2, output row 1 = texture row 1.
    const expected = [_][4]u8{
        .{ 64, 128, 128, 255 }, // texture (1,2)
        .{ 128, 128, 128, 255 }, // texture (2,2)
        .{ 64, 64, 128, 255 }, // texture (1,1)
        .{ 128, 64, 128, 255 }, // texture (2,1)
    };
    try std.testing.expectEqual(@as(usize, 16), out.len);
    for (expected, 0..) |px, i| {
        try std.testing.expectEqualSlices(u8, &px, out[i * 4 ..][0..4]);
    }

    // a rect fully outside the texture is rejected
    const bad = Sprite{ .rect = .{ 4, 4, 2, 2 } };
    try std.testing.expectError(error.RectOutsideTexture, bad.spriteRgba(a, rgba, tex_w, tex_h));

    // a rect that overruns the edge clamps to the texture bounds, like
    // Pillow's crop: {3,3,4,4} on a 4x4 texture yields a 1x1 tile
    const clamped = Sprite{ .rect = .{ 3, 3, 4, 4 } };
    const out_clamped = try clamped.spriteRgba(a, rgba, tex_w, tex_h);
    try std.testing.expectEqual(@as(usize, 4), out_clamped.len);
    try std.testing.expectEqualSlices(u8, &.{ 192, 192, 128, 255 }, out_clamped);
}

test "sprite reads render settings and alpha texture from m_RD" {
    // settingsRaw 0x05 = packed(bit0=1), tight(bit1=0), rotate90-flip? (bits2-5=1)
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "packed" } },
        .{ .name = "m_PixelsToUnits", .value = .{ .float = 100 } },
        .{ .name = "m_RD", .value = .{ .obj = &[_]value.Field{
            .{ .name = "texture", .value = .{ .pptr = .{ .file_id = 0, .path_id = 10 } } },
            .{ .name = "alphaTexture", .value = .{ .pptr = .{ .file_id = 0, .path_id = 11 } } },
            .{ .name = "settingsRaw", .value = .{ .int = 0x05 } },
            .{ .name = "textureRect", .value = .{ .obj = &[_]value.Field{
                .{ .name = "x", .value = .{ .float = 0 } },
                .{ .name = "y", .value = .{ .float = 0 } },
                .{ .name = "width", .value = .{ .float = 4 } },
                .{ .name = "height", .value = .{ .float = 4 } },
            } } },
        } } },
    } };
    const s = Sprite.fromValue(v);
    try std.testing.expectEqual(@as(u32, 0x05), s.settings_raw);
    try std.testing.expect(s.isPacked());
    try std.testing.expect(s.isTight());
    try std.testing.expectEqual(@as(u32, 1), s.packingRotation());
    try std.testing.expect(s.alpha_texture != null);
    try std.testing.expectEqual(@as(i64, 11), s.alpha_texture.?.path_id);
}

test "mergeAlphaTexture keeps RGB from main, alpha from alpha R channel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const main = [_]u8{ 10, 20, 30, 255, 40, 50, 60, 255 };
    const alpha = [_]u8{ 200, 1, 2, 3, 100, 9, 8, 7 };
    const merged = try mergeAlphaTexture(a, &main, &alpha, 2, 1);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 10, 20, 30, 200, 40, 50, 60, 100 }, merged);
}

test "rotateSprite applies packing rotations" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2 columns x 1 row: red | green
    const rgba = [_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 };

    const fh = try rotateSprite(a, &rgba, 2, 1, 1); // flip left-right
    try std.testing.expectEqual(@as(u32, 2), fh.w);
    try std.testing.expectEqual(@as(u32, 1), fh.h);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 255, 255, 0, 0, 255 }, fh.data);

    const rot = try rotateSprite(a, &rgba, 2, 1, 4); // rotate90 (90° CW): 1x2 column
    try std.testing.expectEqual(@as(u32, 1), rot.w);
    try std.testing.expectEqual(@as(u32, 2), rot.h);
    // top pixel = old left (red), bottom = old right (green)
    try std.testing.expectEqualSlices(u8, &[_]u8{ 255, 0, 0, 255, 0, 255, 0, 255 }, rot.data);
}

test "maskSprite keeps the polygon, transparent elsewhere" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2x2 crop, each pixel tagged by its index in the R channel
    var crop: [2 * 2 * 4]u8 = undefined;
    for (0..4) |i| {
        crop[i * 4] = @intCast(i);
        crop[i * 4 + 1] = 0;
        crop[i * 4 + 2] = 0;
        crop[i * 4 + 3] = 255;
    }
    const mesh = SpriteMesh{
        .positions = &.{ .{ 0, 0, 0 }, .{ 0, 2, 0 }, .{ 2, 0, 0 } },
        .uvs = &.{},
        .triangles = &.{ 0, 1, 2 },
    };
    const masked = try maskSprite(a, mesh, 1, &crop, 2, 2);
    // triangle (0,0)-(0,2)-(2,0) keeps pixels 0,1,2 (x+y<=2), zeroes pixel 3
    try std.testing.expectEqual(@as(u8, 0), masked[0]);
    try std.testing.expectEqual(@as(u8, 1), masked[4]);
    try std.testing.expectEqual(@as(u8, 2), masked[8]);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, masked[12..16]);
}

test "renderSpriteMesh texture-maps a quad" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 2x2 texture with distinct texels
    var tex: [2 * 2 * 4]u8 = undefined;
    for (0..2) |y| for (0..2) |x| {
        const p = (y * 2 + x) * 4;
        tex[p] = @intCast(y * 2 + x);
        tex[p + 1] = 0;
        tex[p + 2] = 0;
        tex[p + 3] = 255;
    };
    // quad positions span 0..2, uvs map to texel centres (0.25/0.75)
    const mesh = SpriteMesh{
        .positions = &.{ .{ 0, 0, 0 }, .{ 2, 0, 0 }, .{ 0, 2, 0 }, .{ 2, 2, 0 } },
        .uvs = &.{ .{ 0.25, 0.25 }, .{ 0.75, 0.25 }, .{ 0.25, 0.75 }, .{ 0.75, 0.75 } },
        .triangles = &.{ 0, 1, 2, 1, 3, 2 },
    };
    const out = try renderSpriteMesh(a, mesh, 1, &tex, 2, 2);
    try std.testing.expectEqual(@as(u32, 2), out.w);
    try std.testing.expectEqual(@as(u32, 2), out.h);
    // every dest pixel maps back to a texel; both triangles tile the quad
    for (0..4) |i| {
        const r = i / 2;
        const c = i % 2;
        const dst = (r * 2 + c) * 4;
        const expect = @as(u8, @intCast(r * 2 + c));
        try std.testing.expectEqual(expect, out.data[dst]);
    }
}

test "className covers the UnityPy class ID table" {
    // TextAsset (49) and MonoScript (115) are the ids the enum assigns;
    // 100 is unassigned and 238 is NavMeshData, not ParticleSystem (198).
    try std.testing.expectEqualStrings("TextAsset", className(49).?);
    try std.testing.expectEqualStrings("MonoScript", className(115).?);
    try std.testing.expectEqualStrings("AnimatorController", className(91).?);
    try std.testing.expectEqualStrings("ParticleSystem", className(198).?);
    try std.testing.expectEqualStrings("NavMeshData", className(238).?);
    try std.testing.expectEqualStrings("GameObject", className(1).?);
    try std.testing.expectEqualStrings("PrefabInstance", className(1001).?);
    try std.testing.expect(className(100) == null);
    try std.testing.expect(className(9999) == null);
}
