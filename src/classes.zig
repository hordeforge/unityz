//! Typed views over the generic value tree for the common Unity classes.
//!
//! UnityPy exposes a typed class per Unity class ID; here we provide the
//! subset needed by extraction and editing, as accessors over
//! [`value.Value`]. Fields are read by name, so files with stripped or
//! renamed fields degrade to defaults instead of failing.
//!
//! Views borrow strings and byte slices from the value tree they were built
//! from, so they live exactly as long as it does. A view whose fields are
//! variable-length lists (`GameObject`, `Font`, `ComputeShader`, the audio
//! mixer and animator families) takes the caller's allocator for those
//! lists, like `object_reader`, and fails only on out-of-memory; the rest
//! allocate nothing and cannot fail.

const std = @import("std");
const value = @import("value.zig");
const streams = @import("streams.zig");

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
        .{ .id = 1055, .name = "IHVImageFormatImporter" },
        .{ .id = 1101, .name = "AnimatorStateTransition" },
        .{ .id = 1102, .name = "AnimatorState" },
        .{ .id = 1105, .name = "HumanTemplate" },
        .{ .id = 1107, .name = "AnimatorStateMachine" },
        .{ .id = 1108, .name = "PreviewAnimationClip" },
        .{ .id = 1109, .name = "AnimatorTransition" },
        .{ .id = 1110, .name = "SpeedTreeImporter" },
        .{ .id = 1111, .name = "AnimatorTransitionBase" },
        .{ .id = 1112, .name = "SubstanceImporter" },
        .{ .id = 1113, .name = "LightmapParameters" },
        .{ .id = 1120, .name = "LightingDataAsset" },
        .{ .id = 1121, .name = "GISRaster" },
        .{ .id = 1122, .name = "GISRasterImporter" },
        .{ .id = 1123, .name = "CadImporter" },
        .{ .id = 1124, .name = "SketchUpImporter" },
        .{ .id = 1125, .name = "BuildReport" },
        .{ .id = 1126, .name = "PackedAssets" },
        .{ .id = 1127, .name = "VideoClipImporter" },
        .{ .id = 2000, .name = "ActivationLogComponent" },
        .{ .id = 100000, .name = "int" },
        .{ .id = 100001, .name = "bool" },
        .{ .id = 100002, .name = "float" },
        .{ .id = 100003, .name = "MonoObject" },
        .{ .id = 100004, .name = "Collision" },
        .{ .id = 100005, .name = "Vector3f" },
        .{ .id = 100006, .name = "RootMotionData" },
        .{ .id = 100007, .name = "Collision2D" },
        .{ .id = 100008, .name = "AudioMixerLiveUpdateFloat" },
        .{ .id = 100009, .name = "AudioMixerLiveUpdateBool" },
        .{ .id = 100010, .name = "Polygon2D" },
        .{ .id = 100011, .name = "void" },
        .{ .id = 19719996, .name = "TilemapCollider2D" },
        .{ .id = 41386430, .name = "AssetImporterLog" },
        .{ .id = 73398921, .name = "VFXRenderer" },
        .{ .id = 76251197, .name = "SerializableManagedRefTestClass" },
        .{ .id = 156049354, .name = "Grid" },
        .{ .id = 156483287, .name = "ScenesUsingAssets" },
        .{ .id = 171741748, .name = "ArticulationBody" },
        .{ .id = 181963792, .name = "Preset" },
        .{ .id = 277625683, .name = "EmptyObject" },
        .{ .id = 285090594, .name = "IConstraint" },
        .{ .id = 293259124, .name = "TestObjectWithSpecialLayoutOne" },
        .{ .id = 294290339, .name = "AssemblyDefinitionReferenceImporter" },
        .{ .id = 334799969, .name = "SiblingDerived" },
        .{ .id = 342846651, .name = "TestObjectWithSerializedMapStringNonAlignedStruct" },
        .{ .id = 367388927, .name = "SubDerived" },
        .{ .id = 369655926, .name = "AssetImportInProgressProxy" },
        .{ .id = 382020655, .name = "PluginBuildInfo" },
        .{ .id = 426301858, .name = "EditorProjectAccess" },
        .{ .id = 468431735, .name = "PrefabImporter" },
        .{ .id = 478637458, .name = "TestObjectWithSerializedArray" },
        .{ .id = 478637459, .name = "TestObjectWithSerializedAnimationCurve" },
        .{ .id = 483693784, .name = "TilemapRenderer" },
        .{ .id = 488575907, .name = "ScriptableCamera" },
        .{ .id = 612988286, .name = "SpriteAtlasAsset" },
        .{ .id = 638013454, .name = "SpriteAtlasDatabase" },
        .{ .id = 641289076, .name = "AudioBuildInfo" },
        .{ .id = 644342135, .name = "CachedSpriteAtlasRuntimeData" },
        .{ .id = 646504946, .name = "RendererFake" },
        .{ .id = 662584278, .name = "AssemblyDefinitionReferenceAsset" },
        .{ .id = 668709126, .name = "BuiltAssetBundleInfoSet" },
        .{ .id = 687078895, .name = "SpriteAtlas" },
        .{ .id = 747330370, .name = "RayTracingShaderImporter" },
        .{ .id = 825902497, .name = "RayTracingShader" },
        .{ .id = 850595691, .name = "LightingSettings" },
        .{ .id = 877146078, .name = "PlatformModuleSetup" },
        .{ .id = 890905787, .name = "VersionControlSettings" },
        .{ .id = 895512359, .name = "AimConstraint" },
        .{ .id = 937362698, .name = "VFXManager" },
        .{ .id = 994735392, .name = "VisualEffectSubgraph" },
        .{ .id = 994735403, .name = "VisualEffectSubgraphOperator" },
        .{ .id = 994735404, .name = "VisualEffectSubgraphBlock" },
        .{ .id = 1027052791, .name = "LocalizationImporter" },
        .{ .id = 1091556383, .name = "Derived" },
        .{ .id = 1111377672, .name = "PropertyModificationsTargetTestObject" },
        .{ .id = 1114811875, .name = "ReferencesArtifactGenerator" },
        .{ .id = 1152215463, .name = "AssemblyDefinitionAsset" },
        .{ .id = 1154873562, .name = "SceneVisibilityState" },
        .{ .id = 1183024399, .name = "LookAtConstraint" },
        .{ .id = 1210832254, .name = "SpriteAtlasImporter" },
        .{ .id = 1223240404, .name = "MultiArtifactTestImporter" },
        .{ .id = 1268269756, .name = "GameObjectRecorder" },
        .{ .id = 1325145578, .name = "LightingDataAssetParent" },
        .{ .id = 1386491679, .name = "PresetManager" },
        .{ .id = 1392443030, .name = "TestObjectWithSpecialLayoutTwo" },
        .{ .id = 1403656975, .name = "StreamingManager" },
        .{ .id = 1480428607, .name = "LowerResBlitTexture" },
        .{ .id = 1542919678, .name = "StreamingController" },
        .{ .id = 1571458007, .name = "RenderPassAttachment" },
        .{ .id = 1628831178, .name = "TestObjectVectorPairStringBool" },
        .{ .id = 1742807556, .name = "GridLayout" },
        .{ .id = 1766753193, .name = "AssemblyDefinitionImporter" },
        .{ .id = 1773428102, .name = "ParentConstraint" },
        .{ .id = 1803986026, .name = "FakeComponent" },
        .{ .id = 1818360608, .name = "PositionConstraint" },
        .{ .id = 1818360609, .name = "RotationConstraint" },
        .{ .id = 1818360610, .name = "ScaleConstraint" },
        .{ .id = 1839735485, .name = "Tilemap" },
        .{ .id = 1896753125, .name = "PackageManifest" },
        .{ .id = 1896753126, .name = "PackageManifestImporter" },
        .{ .id = 1953259897, .name = "TerrainLayer" },
        .{ .id = 1971053207, .name = "SpriteShapeRenderer" },
        .{ .id = 1977754360, .name = "NativeObjectType" },
        .{ .id = 1981279845, .name = "TestObjectWithSerializedMapStringBool" },
        .{ .id = 1995898324, .name = "SerializableManagedHost" },
        .{ .id = 2058629509, .name = "VisualEffectAsset" },
        .{ .id = 2058629510, .name = "VisualEffectImporter" },
        .{ .id = 2058629511, .name = "VisualEffectResource" },
        .{ .id = 2059678085, .name = "VisualEffectObject" },
        .{ .id = 2083052967, .name = "VisualEffect" },
        .{ .id = 2083778819, .name = "LocalizationAsset" },
        .{ .id = 2089858483, .name = "ScriptedImporter" },
    };
    for (names) |n| {
        if (n.id == class_id) return n.name;
    }
    return null;
}

/// Finds a named field in a `.obj` value, or null.
pub fn fieldOf(v: value.Value, name: []const u8) ?value.Value {
    return value.fieldOf(v, name);
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

/// Texture2D (class 28): dimensions, format, mip count, and where the pixels
/// live (embedded `m_ImageData` or a streamed sidecar range).
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

/// TextAsset (class 49): name plus the raw `m_Script` bytes, text or binary.
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

/// Unity ComputeShader (class 72): one or more platform variants, each
/// holding the compiled kernel payloads. The per-kernel `code` blob is a
/// `vector<UInt8>`: DXBC for the D3D11 variant, SPIR-V binary for Vulkan,
/// and `#version`-prefixed GLSL source for OpenGL - so `extract` recovers
/// human-readable compute shaders. UnityPy has no ComputeShader handling
/// at all (AssetRipper does not handle class 72 either). The raw layout
/// was verified against all 26 real Unity 2022.3.62f2 compute shaders in
/// 7DTD (260 kernel blobs; the `code` byte vector is 4-aligned after
/// reading, and the per-variant `resourcesResolved` bool is padded to 4
/// inside the variants vector). The D3D11 code blobs carry a 16-byte
/// Unity content hash between the "DXBC" magic and the standard DXBC
/// container (version/size/chunk offsets follow at byte 20).
pub const ComputeShader = struct {
    name: []const u8 = "",
    variants: []const Variant = &.{},

    pub const Param = struct {
        name: []const u8 = "",
        type: i32 = 0,
        offset: u32 = 0,
        array_size: u32 = 0,
        row_count: u32 = 0,
        col_count: u32 = 0,
    };

    pub const ConstantBuffer = struct {
        name: []const u8 = "",
        byte_size: i32 = 0,
        params: []const Param = &.{},
    };

    pub const Kernel = struct {
        name: []const u8 = "",
        /// First unique-variant's compiled payload; the other unique
        /// variants are keyword permutations of the same kernel (their
        /// count is `unique_variants`).
        code: []const u8 = &.{},
        thread_group_size: []const u32 = &.{},
        unique_variants: usize = 0,
        cb_count: usize = 0,
        texture_count: usize = 0,
        in_buffer_count: usize = 0,
        out_buffer_count: usize = 0,
    };

    pub const Variant = struct {
        target_renderer: i32 = 0,
        target_level: i32 = 0,
        kernels: []const Kernel = &.{},
        constant_buffers: []const ConstantBuffer = &.{},
        resources_resolved: bool = false,
    };

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!ComputeShader {
        var self = ComputeShader{ .name = stringField(v, "m_Name") orelse "" };
        const variants = fieldOf(v, "variants") orelse return self;
        if (variants != .array) return self;
        var list: std.ArrayList(Variant) = .empty;
        for (variants.array) |vitem| {
            if (vitem != .obj) continue;
            var var_: Variant = .{
                .target_renderer = narrow(i32, intField(vitem, "targetRenderer") orelse 0),
                .target_level = narrow(i32, intField(vitem, "targetLevel") orelse 0),
                .resources_resolved = boolField(vitem, "resourcesResolved") orelse false,
            };
            if (fieldOf(vitem, "kernels")) |karr| {
                if (karr == .array) {
                    var kerns: std.ArrayList(Kernel) = .empty;
                    for (karr.array) |kitem| {
                        var k = Kernel{ .name = stringField(kitem, "name") orelse "" };
                        if (fieldOf(kitem, "uniqueVariants")) |uarr| {
                            if (uarr == .array) {
                                k.unique_variants = uarr.array.len;
                                if (uarr.array.len != 0) {
                                    const first = uarr.array[0];
                                    k.code = bytesField(first, "code") orelse &.{};
                                    if (fieldOf(first, "threadGroupSize")) |tg| {
                                        if (tg == .array) {
                                            var tgs: std.ArrayList(u32) = .empty;
                                            for (tg.array) |t| {
                                                if (t.asInt()) |ti| try tgs.append(allocator, narrow(u32, ti));
                                            }
                                            k.thread_group_size = try tgs.toOwnedSlice(allocator);
                                        }
                                    }
                                    for ([_][]const u8{ "cbs", "textures", "inBuffers", "outBuffers" }, 0..) |fname, i| {
                                        const n = switch (fieldOf(first, fname) orelse value.Value{ .int = 0 }) {
                                            .array => |a| a.len,
                                            else => 0,
                                        };
                                        switch (i) {
                                            0 => k.cb_count = n,
                                            1 => k.texture_count = n,
                                            2 => k.in_buffer_count = n,
                                            else => k.out_buffer_count = n,
                                        }
                                    }
                                }
                            }
                        }
                        try kerns.append(allocator, k);
                    }
                    var_.kernels = try kerns.toOwnedSlice(allocator);
                }
            }
            if (fieldOf(vitem, "constantBuffers")) |carr| {
                if (carr == .array) {
                    var cbs: std.ArrayList(ConstantBuffer) = .empty;
                    for (carr.array) |citem| {
                        var cb = ConstantBuffer{
                            .name = stringField(citem, "name") orelse "",
                            .byte_size = narrow(i32, intField(citem, "byteSize") orelse 0),
                        };
                        if (fieldOf(citem, "params")) |parr| {
                            if (parr == .array) {
                                var params: std.ArrayList(Param) = .empty;
                                for (parr.array) |pitem| {
                                    try params.append(allocator, .{
                                        .name = stringField(pitem, "name") orelse "",
                                        .type = narrow(i32, intField(pitem, "type") orelse 0),
                                        .offset = narrow(u32, intField(pitem, "offset") orelse 0),
                                        .array_size = narrow(u32, intField(pitem, "arraySize") orelse 0),
                                        .row_count = narrow(u32, intField(pitem, "rowCount") orelse 0),
                                        .col_count = narrow(u32, intField(pitem, "colCount") orelse 0),
                                    });
                                }
                                cb.params = try params.toOwnedSlice(allocator);
                            }
                        }
                        try cbs.append(allocator, cb);
                    }
                    var_.constant_buffers = try cbs.toOwnedSlice(allocator);
                }
            }
            try list.append(allocator, var_);
        }
        self.variants = try list.toOwnedSlice(allocator);
        return self;
    }

    /// Raw serialized layout for the modern (2017+) ComputeShader: the
    /// `variants` vector of platform variants, each with kernels, constant
    /// buffers, and the resourcesResolved flag. Older layouts are rejected.
    pub fn fromRaw(allocator: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian, unity_version: []const u8) !ComputeShader {
        if (!computeShaderLayoutIsModern(unity_version)) return error.UnsupportedVersion;
        var r = streams.Reader.init(bytes);
        r.endian = endian;
        var self = ComputeShader{ .name = try r.readAlignedStringBorrow() };

        const nvariants = try r.readInt(i32);
        if (nvariants < 0) return error.Malformed;
        var variants: std.ArrayList(Variant) = .empty;
        errdefer variants.deinit(allocator);
        for (0..@as(usize, @intCast(nvariants))) |_| {
            var v = Variant{
                .target_renderer = try r.readInt(i32),
                .target_level = try r.readInt(i32),
            };
            const nkernels = try r.readInt(i32);
            if (nkernels < 0) return error.Malformed;
            var kerns: std.ArrayList(Kernel) = .empty;
            errdefer kerns.deinit(allocator);
            for (0..@as(usize, @intCast(nkernels))) |_| {
                var k = Kernel{ .name = try r.readAlignedStringBorrow() };
                const nuv = try r.readInt(i32);
                if (nuv < 0) return error.Malformed;
                k.unique_variants = @intCast(nuv);
                for (0..@as(usize, @intCast(nuv))) |ui| {
                    // cbVariantIndices: vector<unsigned int>
                    const ncbv = try r.readInt(i32);
                    if (ncbv < 0) return error.Malformed;
                    try r.skip(@as(usize, @intCast(ncbv)) * 4);
                    const cb_count = try readResourceVec(&r);
                    const texture_count = try readResourceVec(&r);
                    const nbs = try r.readInt(i32);
                    if (nbs < 0) return error.Malformed;
                    try r.skip(@as(usize, @intCast(nbs)) * 8);
                    const in_buffer_count = try readResourceVec(&r);
                    const out_buffer_count = try readResourceVec(&r);
                    const code_size = try r.readInt(i32);
                    if (code_size < 0) return error.Malformed;
                    const code = try r.readSlice(@intCast(code_size));
                    try r.alignTo4(); // byte-vector run padding
                    // threadGroupSize: staticvector<unsigned int>
                    const ntgs = try r.readInt(i32);
                    if (ntgs < 0) return error.Malformed;
                    const tgs = try r.readSlice(@as(usize, @intCast(ntgs)) * 4);
                    try r.skip(8); // requirements (SInt64)
                    if (ui == 0) {
                        k.code = code;
                        k.cb_count = @intCast(cb_count);
                        k.texture_count = @intCast(texture_count);
                        k.in_buffer_count = @intCast(in_buffer_count);
                        k.out_buffer_count = @intCast(out_buffer_count);
                        const n: usize = @intCast(ntgs);
                        const tgs_out = try allocator.alloc(u32, n);
                        for (0..n) |i| {
                            tgs_out[i] = std.mem.readInt(u32, tgs[i * 4 ..][0..4], .little);
                        }
                        k.thread_group_size = tgs_out;
                    }
                }
                // variantIndices: vector<pair<string, unsigned int>>
                const nvi = try r.readInt(i32);
                if (nvi < 0) return error.Malformed;
                for (0..@as(usize, @intCast(nvi))) |_| {
                    _ = try r.readAlignedStringBorrow();
                    try r.skip(4);
                }
                try skipStringVector(&r); // globalKeywords
                try skipStringVector(&r); // localKeywords
                try skipStringVector(&r); // dynamicKeywords
                try kerns.append(allocator, k);
            }
            v.kernels = try kerns.toOwnedSlice(allocator);
            const ncb = try r.readInt(i32);
            if (ncb < 0) return error.Malformed;
            var cbs: std.ArrayList(ConstantBuffer) = .empty;
            errdefer cbs.deinit(allocator);
            for (0..@as(usize, @intCast(ncb))) |_| {
                var cb = ConstantBuffer{
                    .name = try r.readAlignedStringBorrow(),
                    .byte_size = try r.readInt(i32),
                };
                const nparams = try r.readInt(i32);
                if (nparams < 0) return error.Malformed;
                var params: std.ArrayList(Param) = .empty;
                errdefer params.deinit(allocator);
                for (0..@as(usize, @intCast(nparams))) |_| {
                    try params.append(allocator, .{
                        .name = try r.readAlignedStringBorrow(),
                        .type = try r.readInt(i32),
                        .offset = try r.readInt(u32),
                        .array_size = try r.readInt(u32),
                        .row_count = try r.readInt(u32),
                        .col_count = try r.readInt(u32),
                    });
                }
                cb.params = try params.toOwnedSlice(allocator);
                try cbs.append(allocator, cb);
            }
            v.constant_buffers = try cbs.toOwnedSlice(allocator);
            v.resources_resolved = (try r.readByte()) != 0;
            try r.alignTo4(); // bool padded to 4 inside the variants vector
            try variants.append(allocator, v);
        }
        self.variants = try variants.toOwnedSlice(allocator);
        return self;
    }
};

/// One ComputeShaderResource (cbs/textures/inBuffers/outBuffers element):
/// name, generatedName, bindPoint, samplerBindPoint, texDimension.
fn readResourceVec(r: *streams.Reader) !usize {
    const n = try r.readInt(i32);
    if (n < 0) return error.Malformed;
    for (0..@as(usize, @intCast(n))) |_| {
        _ = try r.readAlignedStringBorrow();
        _ = try r.readAlignedStringBorrow();
        try r.skip(12);
    }
    return @intCast(n);
}

/// Skips a vector of strings (the per-kernel keyword lists).
fn skipStringVector(r: *streams.Reader) !void {
    const n = try r.readInt(i32);
    if (n < 0) return error.Malformed;
    for (0..@as(usize, @intCast(n))) |_| {
        _ = try r.readAlignedStringBorrow();
    }
}

/// ComputeShader gained its variants/kernels layout with Unity 2017;
/// earlier versions use an older shape we do not attempt.
fn computeShaderLayoutIsModern(unity_version: []const u8) bool {
    var parts = std.mem.splitScalar(u8, unity_version, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return true, 10) catch return true;
    return major >= 2017;
}

/// Unity Font (class 128): glyph metrics plus the embedded TrueType/OpenType
/// data. In release binaries the font bytes always sit inline in the object
/// (`m_FontData`, i32 size + bytes) — the tree's `NoTransfer` flag only moves
/// the payload in editor/YAML layouts — so typeless files (Mono builds strip
/// type trees) decode from the raw layout with no sidecar lookup. UnityPy
/// has no Font export at all; the raw layout matches AssetStudio's 5.5+
/// Font.cs, and the char-rect/kerning counts are verified against real
/// Unity 2022.3 fonts.
pub const Font = struct {
    name: []const u8 = "",
    line_spacing: f64 = 0,
    default_material: ?value.PPtr = null,
    font_size: f64 = 0,
    texture: ?value.PPtr = null,
    ascii_start_offset: i64 = 0,
    tracking: f64 = 0,
    character_spacing: i64 = 0,
    character_padding: i64 = 0,
    convert_case: i64 = 0,
    /// Number of legacy `CharacterInfo` entries (dynamic fonts use 0).
    character_rects: usize = 0,
    /// Number of kerning pairs (each a `u16, u16, float` tuple).
    kerning_values: usize = 0,
    pixel_scale: f64 = 0,
    /// The embedded TTF/OTF bytes, empty when the font has none.
    font_data: []const u8 = &.{},
    ascent: f64 = 0,
    descent: f64 = 0,
    default_style: u64 = 0,
    /// Additional font names (dynamic fonts list their face names).
    font_names: []const []const u8 = &.{},
    fallback_fonts: []const value.PPtr = &.{},
    font_rendering_mode: i64 = 0,
    use_legacy_bounds_calculation: bool = false,
    should_round_advance_value: bool = false,

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!Font {
        var self = Font{
            .name = stringField(v, "m_Name") orelse "",
            .line_spacing = floatField(v, "m_LineSpacing") orelse 0,
            .default_material = pptrField(v, "m_DefaultMaterial"),
            .font_size = floatField(v, "m_FontSize") orelse 0,
            .texture = pptrField(v, "m_Texture"),
            .ascii_start_offset = intField(v, "m_AsciiStartOffset") orelse 0,
            .tracking = floatField(v, "m_Tracking") orelse 0,
            .character_spacing = intField(v, "m_CharacterSpacing") orelse 0,
            .character_padding = intField(v, "m_CharacterPadding") orelse 0,
            .convert_case = intField(v, "m_ConvertCase") orelse 0,
            .pixel_scale = floatField(v, "m_PixelScale") orelse 0,
            .font_data = bytesField(v, "m_FontData") orelse &.{},
            .ascent = floatField(v, "m_Ascent") orelse 0,
            .descent = floatField(v, "m_Descent") orelse 0,
            .font_rendering_mode = intField(v, "m_FontRenderingMode") orelse 0,
            .use_legacy_bounds_calculation = boolField(v, "m_UseLegacyBoundsCalculation") orelse false,
            .should_round_advance_value = boolField(v, "m_ShouldRoundAdvanceValue") orelse false,
        };
        if (fieldOf(v, "m_DefaultStyle")) |f| {
            if (f.asInt()) |i| self.default_style = narrow(u64, i);
        }
        if (fieldOf(v, "m_CharacterRects")) |f| {
            if (f == .array) self.character_rects = f.array.len;
        }
        if (fieldOf(v, "m_KerningValues")) |f| {
            if (f == .array) self.kerning_values = f.array.len;
        }
        if (fieldOf(v, "m_FontNames")) |f| {
            if (f == .array) {
                var names: std.ArrayList([]const u8) = .empty;
                for (f.array) |item| {
                    if (item == .string) try names.append(allocator, item.string);
                }
                self.font_names = try names.toOwnedSlice(allocator);
            }
        }
        if (fieldOf(v, "m_FallbackFonts")) |f| {
            if (f == .array) {
                var fonts: std.ArrayList(value.PPtr) = .empty;
                for (f.array) |item| {
                    if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item }} }, "x")) |p| {
                        try fonts.append(allocator, p);
                    }
                }
                self.fallback_fonts = try fonts.toOwnedSlice(allocator);
            }
        }
        return self;
    }

    /// Raw serialized layout for Unity 5.5 and newer (see the struct docs
    /// for the field order). Older fonts use a different pre-5.5 layout and
    /// are rejected rather than misread.
    pub fn fromRaw(allocator: std.mem.Allocator, bytes: []const u8, endian: std.builtin.Endian, unity_version: []const u8) !Font {
        if (!fontLayoutIsModern(unity_version)) return error.UnsupportedVersion;
        var r = streams.Reader.init(bytes);
        r.endian = endian;

        var self = Font{};
        self.name = try r.readAlignedStringBorrow();
        self.line_spacing = try r.readFloat(f32);
        const mat = try readPPtr(&r);
        if (mat.file_id != 0 or mat.path_id != 0) self.default_material = mat;
        self.font_size = try r.readFloat(f32);
        const tex = try readPPtr(&r);
        if (tex.file_id != 0 or tex.path_id != 0) self.texture = tex;
        self.ascii_start_offset = try r.readInt(i32);
        self.tracking = try r.readFloat(f32);
        self.character_spacing = try r.readInt(i32);
        self.character_padding = try r.readInt(i32);
        self.convert_case = try r.readInt(i32);

        // Legacy CharacterInfo entries: index, two Rectf, advance, flipped.
        // The tree sizes one entry at 41 bytes; all dynamic fonts carry 0.
        const rect_count = try r.readInt(i32);
        if (rect_count < 0) return error.Malformed;
        self.character_rects = @intCast(rect_count);
        try r.skip(@as(usize, @intCast(rect_count)) * 41);

        // Kerning pairs: u16 first, u16 second, float value (8 bytes each).
        const kern_count = try r.readInt(i32);
        if (kern_count < 0) return error.Malformed;
        self.kerning_values = @intCast(kern_count);
        try r.skip(@as(usize, @intCast(kern_count)) * 8);

        self.pixel_scale = try r.readFloat(f32);
        const data_size = try r.readInt(i32);
        if (data_size < 0) return error.Malformed;
        self.font_data = try r.readSlice(@intCast(data_size));
        self.ascent = try r.readFloat(f32);
        self.descent = try r.readFloat(f32);
        self.default_style = try r.readInt(u32);
        self.font_names = try readStringArray(allocator, &r);
        self.fallback_fonts = try readPPtrArray(allocator, &r);
        self.font_rendering_mode = try r.readInt(i32);
        self.use_legacy_bounds_calculation = (try r.readByte()) != 0;
        // m_ShouldRoundAdvanceValue joined the layout after Unity 2017.1
        // (absent in 5.x and 2017 dumps, present from 2018.4 on); 5.x-era
        // fonts end after m_UseLegacyBoundsCalculation, so reading it
        // unconditionally runs one byte past the object.
        var parts = std.mem.splitScalar(u8, unity_version, '.');
        const vmaj = std.fmt.parseInt(u32, parts.next() orelse "2018", 10) catch 2018;
        if (vmaj >= 2018) {
            self.should_round_advance_value = (try r.readByte()) != 0;
        }
        return self;
    }
};

/// PPtr as serialized in an object stream: i32 file id + i64 path id.
fn readPPtr(r: *streams.Reader) !value.PPtr {
    return .{
        .file_id = try r.readInt(i32),
        .path_id = try r.readInt(i64),
    };
}

/// Vector of strings: i32 count, then aligned strings.
fn readStringArray(allocator: std.mem.Allocator, r: *streams.Reader) ![]const []const u8 {
    const count = try r.readInt(i32);
    if (count <= 0) return &.{};
    const out = try allocator.alloc([]const u8, @intCast(count));
    errdefer allocator.free(out);
    for (out) |*s| {
        s.* = try r.readAlignedStringBorrow();
    }
    return out;
}

/// Vector of PPtrs: i32 count, then PPtrs.
fn readPPtrArray(allocator: std.mem.Allocator, r: *streams.Reader) ![]const value.PPtr {
    const count = try r.readInt(i32);
    if (count <= 0) return &.{};
    const out = try allocator.alloc(value.PPtr, @intCast(count));
    errdefer allocator.free(out);
    for (out) |*p| {
        p.* = try readPPtr(r);
    }
    return out;
}

/// True when the Unity version string describes 5.5 or newer, where the
/// Font layout above applies. Unknown strings (e.g. a bundle's "5.x.x"
/// placeholder) are treated as modern rather than rejected.
fn fontLayoutIsModern(unity_version: []const u8) bool {
    var parts = std.mem.splitScalar(u8, unity_version, '.');
    const major = std.fmt.parseInt(u32, parts.next() orelse return true, 10) catch return true;
    if (major > 5) return true;
    if (major < 5) return false;
    const minor = std.fmt.parseInt(u32, parts.next() orelse return true, 10) catch return true;
    return minor >= 5;
}

/// Unity AudioMixer family (classes 241/243/245): the controller owns the
/// mixer's runtime state (m_MixerConstant index tables), the groups form the
/// named hierarchy (`m_Children` PPtrs), and snapshots hold parameter values.
/// UnityPy has no mixer export at all.
pub const AudioMixerController = struct {
    name: []const u8 = "",
    master_group: ?value.PPtr = null,
    start_snapshot: ?value.PPtr = null,
    snapshots: []const value.PPtr = &.{},
    update_mode: i64 = 0,

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!AudioMixerController {
        var self = AudioMixerController{
            .name = stringField(v, "m_Name") orelse "",
            .master_group = pptrField(v, "m_MasterGroup"),
            .start_snapshot = pptrField(v, "m_StartSnapshot"),
            .update_mode = intField(v, "m_UpdateMode") orelse 0,
        };
        if (fieldOf(v, "m_Snapshots")) |f| {
            if (f == .array) {
                var list: std.ArrayList(value.PPtr) = .empty;
                for (f.array) |item| {
                    if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item }} }, "x")) |p| {
                        try list.append(allocator, p);
                    }
                }
                self.snapshots = try list.toOwnedSlice(allocator);
            }
        }
        return self;
    }
};

/// AudioMixerGroupController (class 243): one node of the mixer graph, with
/// its child groups and owning mixer as PPtrs.
pub const AudioMixerGroup = struct {
    name: []const u8 = "",
    children: []const value.PPtr = &.{},
    audio_mixer: ?value.PPtr = null,

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!AudioMixerGroup {
        var self = AudioMixerGroup{
            .name = stringField(v, "m_Name") orelse "",
            .audio_mixer = pptrField(v, "m_AudioMixer"),
        };
        if (fieldOf(v, "m_Children")) |f| {
            if (f == .array) {
                var list: std.ArrayList(value.PPtr) = .empty;
                for (f.array) |item| {
                    if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item }} }, "x")) |p| {
                        try list.append(allocator, p);
                    }
                }
                self.children = try list.toOwnedSlice(allocator);
            }
        }
        return self;
    }
};

/// AudioMixerSnapshotController (class 245): a named snapshot, its
/// transition time, and how many parameter values it stores.
pub const AudioMixerSnapshot = struct {
    name: []const u8 = "",
    time: f64 = 0,
    values: usize = 0,

    pub fn fromValue(v: value.Value) AudioMixerSnapshot {
        var self = AudioMixerSnapshot{
            .name = stringField(v, "m_Name") orelse "",
            .time = floatField(v, "m_Time") orelse 0,
        };
        if (fieldOf(v, "m_Values")) |f| {
            if (f == .array) self.values = f.array.len;
        }
        return self;
    }
};

/// Unity ParticleSystem (class 198): the emitter's timeline plus its module
/// configuration. A compact summary (main/emission/shape values and the
/// enabled module flags) is what `extract` surfaces; UnityPy has no
/// ParticleSystem export at all.
pub const ParticleSystem = struct {
    game_object: ?value.PPtr = null,
    duration: f64 = 0,
    looping: bool = false,
    prewarm: bool = false,
    play_on_awake: bool = false,
    simulation_speed: f64 = 0,
    scaling_mode: i64 = 0,
    stop_action: i64 = 0,
    culling_mode: i64 = 0,
    // InitialModule summary
    start_lifetime: f64 = 0,
    start_speed: f64 = 0,
    start_size: f64 = 0,
    gravity_modifier: f64 = 0,
    max_particles: i64 = 0,
    // EmissionModule
    emission_enabled: bool = false,
    rate_over_time: f64 = 0,
    burst_count: usize = 0,
    // ShapeModule
    shape_enabled: bool = false,
    shape_type: i64 = 0,
    shape_angle: f64 = 0,
    shape_radius: f64 = 0,
    // Enabled module flags, in Unity's module order.
    module_flags: [22]bool = .{false} ** 22,

    pub fn fromValue(v: value.Value) ParticleSystem {
        var self = ParticleSystem{
            .game_object = pptrField(v, "m_GameObject"),
            .duration = floatField(v, "lengthInSec") orelse 0,
            .looping = boolField(v, "looping") orelse false,
            .prewarm = boolField(v, "prewarm") orelse false,
            .play_on_awake = boolField(v, "playOnAwake") orelse false,
            .simulation_speed = floatField(v, "simulationSpeed") orelse 0,
            .scaling_mode = intField(v, "scalingMode") orelse 0,
            .stop_action = intField(v, "stopAction") orelse 0,
            .culling_mode = intField(v, "cullingMode") orelse 0,
        };
        if (fieldOf(v, "InitialModule")) |m| {
            self.start_lifetime = curveScalar(m, "startLifetime");
            self.start_speed = curveScalar(m, "startSpeed");
            self.start_size = curveScalar(m, "startSize");
            self.gravity_modifier = curveScalar(m, "gravityModifier");
            self.max_particles = intField(m, "maxNumParticles") orelse 0;
        }
        if (fieldOf(v, "EmissionModule")) |m| {
            self.emission_enabled = boolField(m, "enabled") orelse false;
            self.rate_over_time = curveScalar(m, "rateOverTime");
            if (fieldOf(m, "m_BurstCount")) |b| self.burst_count = narrow(usize, b.asInt() orelse 0);
        }
        if (fieldOf(v, "ShapeModule")) |m| {
            self.shape_enabled = boolField(m, "enabled") orelse false;
            self.shape_type = intField(m, "type") orelse 0;
            self.shape_angle = floatField(m, "angle") orelse 0;
            self.shape_radius = curveScalar(m, "radius");
        }
        const modules = [_][]const u8{
            "InitialModule",                "EmissionModule",     "ShapeModule",
            "SizeModule",                   "RotationModule",     "ColorModule",
            "UVModule",                     "VelocityModule",     "InheritVelocityModule",
            "LifetimeByEmitterSpeedModule", "ForceModule",        "ExternalForcesModule",
            "ClampVelocityModule",          "NoiseModule",        "SizeBySpeedModule",
            "RotationBySpeedModule",        "ColorBySpeedModule", "CollisionModule",
            "TriggerModule",                "SubModule",          "LightsModule",
            "TrailModule",
        };
        for (modules, 0..) |name, i| {
            if (fieldOf(v, name)) |m| {
                self.module_flags[i] = boolField(m, "enabled") orelse false;
            }
        }
        return self;
    }
};

/// The scalar of a MinMaxCurve value: `scalar` when the state is constant,
/// otherwise the min/max bounds. Values come from the file, so a missing or
/// malformed curve degrades to 0.
fn curveScalar(v: value.Value, name: []const u8) f64 {
    const f = fieldOf(v, name) orelse return 0;
    const scalar = floatField(f, "scalar") orelse return 0;
    if (scalar != 0) return scalar;
    // Two-constant curves carry the range in minScalar/maxScalar; prefer the
    // max so a positive range reads as its upper bound.
    const min_scalar = floatField(f, "minScalar") orelse 0;
    const max_scalar = floatField(f, "maxScalar") orelse 0;
    if (max_scalar != 0) return max_scalar;
    return min_scalar;
}

/// Unity AnimatorController (class 91): the animator's layer/state-machine
/// constants plus the TOS hash-to-path table that names them. Layer and
/// state names are not stored as strings - the constants carry name hashes
/// that resolve through `m_TOS` (e.g. a state's `m_NameID` maps to
/// "balloon_spin"). UnityPy has no AnimatorController export at all.
pub const AnimatorController = struct {
    name: []const u8 = "",
    clips: []const value.PPtr = &.{},
    /// m_TOS: hash -> transform/state path.
    tos: []const TosEntry = &.{},
    layers: []const Layer = &.{},
    states: []const State = &.{},
    state_machine_count: usize = 0,
    any_state_transitions: usize = 0,
    default_state: i64 = 0,
    parameters: usize = 0,

    pub const TosEntry = struct {
        hash: u32 = 0,
        path: []const u8 = "",
    };

    pub const Layer = struct {
        state_machine_index: i64 = 0,
        binding: u32 = 0,
        blending_mode: i64 = 0,
        default_weight: f64 = 0,
        ik_pass: bool = false,
    };

    pub const State = struct {
        name_id: u32 = 0,
        full_path_id: u32 = 0,
        speed: f64 = 0,
        loop: bool = false,
        transition_count: usize = 0,
        blend_tree_count: usize = 0,
    };

    /// Resolves a name hash through the TOS table.
    pub fn tosPath(self: *const AnimatorController, hash: u32) []const u8 {
        for (self.tos) |t| {
            if (t.hash == hash) return t.path;
        }
        return "";
    }

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!AnimatorController {
        var self = AnimatorController{ .name = stringField(v, "m_Name") orelse "" };
        if (fieldOf(v, "m_TOS")) |f| {
            if (f == .array) {
                var list: std.ArrayList(TosEntry) = .empty;
                for (f.array) |item| {
                    const arr = switch (item) {
                        .array => |a| a,
                        else => continue,
                    };
                    if (arr.len < 2) continue;
                    const hash = arr[0].asInt() orelse continue;
                    const path = switch (arr[1]) {
                        .string => |s| s,
                        else => continue,
                    };
                    try list.append(allocator, .{ .hash = narrow(u32, hash), .path = path });
                }
                self.tos = try list.toOwnedSlice(allocator);
            }
        }
        if (fieldOf(v, "m_AnimationClips")) |f| {
            if (f == .array) {
                var list: std.ArrayList(value.PPtr) = .empty;
                for (f.array) |item| {
                    if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item }} }, "x")) |p| {
                        try list.append(allocator, p);
                    }
                }
                self.clips = try list.toOwnedSlice(allocator);
            }
        }
        const controller = fieldOf(v, "m_Controller") orelse return self;
        if (fieldOf(controller, "m_LayerArray")) |f| {
            if (f == .array) {
                var list: std.ArrayList(Layer) = .empty;
                for (f.array) |item| {
                    const data = fieldOf(item, "data") orelse continue;
                    try list.append(allocator, .{
                        .state_machine_index = intField(data, "m_StateMachineIndex") orelse 0,
                        .binding = narrow(u32, intField(data, "m_Binding") orelse 0),
                        .blending_mode = intField(data, "(int&)m_LayerBlendingMode") orelse intField(data, "m_LayerBlendingMode") orelse 0,
                        .default_weight = floatField(data, "m_DefaultWeight") orelse 0,
                        .ik_pass = boolField(data, "m_IKPass") orelse false,
                    });
                }
                self.layers = try list.toOwnedSlice(allocator);
            }
        }
        if (fieldOf(controller, "m_StateMachineArray")) |f| {
            if (f == .array) {
                self.state_machine_count = f.array.len;
                for (f.array) |item| {
                    const data = fieldOf(item, "data") orelse continue;
                    self.any_state_transitions += if (fieldOf(data, "m_AnyStateTransitionConstantArray")) |a| (if (a == .array) a.array.len else 0) else 0;
                    self.default_state = intField(data, "m_DefaultState") orelse 0;
                    if (fieldOf(data, "m_StateConstantArray")) |sa| {
                        if (sa == .array) {
                            var states: std.ArrayList(State) = .empty;
                            for (sa.array) |sitem| {
                                const sdata = fieldOf(sitem, "data") orelse continue;
                                var st = State{
                                    .name_id = narrow(u32, intField(sdata, "m_NameID") orelse 0),
                                    .full_path_id = narrow(u32, intField(sdata, "m_FullPathID") orelse 0),
                                    .speed = floatField(sdata, "m_Speed") orelse 0,
                                    .loop = boolField(sdata, "m_Loop") orelse false,
                                };
                                if (fieldOf(sdata, "m_TransitionConstantArray")) |ta| {
                                    if (ta == .array) st.transition_count = ta.array.len;
                                }
                                if (fieldOf(sdata, "m_BlendTreeConstantArray")) |ba| {
                                    if (ba == .array) st.blend_tree_count = ba.array.len;
                                }
                                try states.append(allocator, st);
                            }
                            self.states = try states.toOwnedSlice(allocator);
                        }
                    }
                }
            }
        }
        if (fieldOf(controller, "m_Values")) |f| {
            if (fieldOf(f, "data")) |d| {
                if (fieldOf(d, "m_ValueArray")) |va| {
                    if (va == .array) self.parameters = va.array.len;
                }
            }
        }
        return self;
    }
};

/// Unity AnimatorOverrideController (class 221): the base controller plus
/// the clip-override pairs (original -> replacement). UnityPy has no export
/// for it.
pub const AnimatorOverrideController = struct {
    name: []const u8 = "",
    controller: ?value.PPtr = null,
    overrides: []const Override = &.{},

    pub const Override = struct {
        original: ?value.PPtr = null,
        replacement: ?value.PPtr = null,
    };

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!AnimatorOverrideController {
        var self = AnimatorOverrideController{
            .name = stringField(v, "m_Name") orelse "",
            .controller = pptrField(v, "m_Controller"),
        };
        if (fieldOf(v, "m_Clips")) |f| {
            if (f == .array) {
                var list: std.ArrayList(Override) = .empty;
                for (f.array) |item| {
                    try list.append(allocator, .{
                        .original = pptrField(item, "m_OriginalClip"),
                        .replacement = pptrField(item, "m_OverrideClip"),
                    });
                }
                self.overrides = try list.toOwnedSlice(allocator);
            }
        }
        return self;
    }
};

/// Unity Animator (class 95): the component binding an Avatar and an
/// AnimatorController to a GameObject, with the playback flags. UnityPy has
/// no export for it.
pub const Animator = struct {
    game_object: ?value.PPtr = null,
    avatar: ?value.PPtr = null,
    controller: ?value.PPtr = null,
    culling_mode: i64 = 0,
    update_mode: i64 = 0,
    apply_root_motion: bool = false,
    linear_velocity_blending: bool = false,
    stabilize_feet: bool = false,
    has_transform_hierarchy: bool = false,
    allow_constant_clip_sampling_optimization: bool = false,
    keep_animator_state_on_disable: bool = false,
    write_default_values_on_disable: bool = false,

    pub fn fromValue(v: value.Value) Animator {
        return .{
            .game_object = pptrField(v, "m_GameObject"),
            .avatar = pptrField(v, "m_Avatar"),
            .controller = pptrField(v, "m_Controller"),
            .culling_mode = intField(v, "m_CullingMode") orelse 0,
            .update_mode = intField(v, "m_UpdateMode") orelse 0,
            .apply_root_motion = boolField(v, "m_ApplyRootMotion") orelse false,
            .linear_velocity_blending = boolField(v, "m_LinearVelocityBlending") orelse false,
            .stabilize_feet = boolField(v, "m_StabilizeFeet") orelse false,
            .has_transform_hierarchy = boolField(v, "m_HasTransformHierarchy") orelse false,
            .allow_constant_clip_sampling_optimization = boolField(v, "m_AllowConstantClipSamplingOptimization") orelse false,
            .keep_animator_state_on_disable = boolField(v, "m_KeepAnimatorStateOnDisable") orelse false,
            .write_default_values_on_disable = boolField(v, "m_WriteDefaultValuesOnDisable") orelse false,
        };
    }
};

/// GameObject (class 1): name, layer, tag, active flag, and the PPtrs of its
/// components (the first is normally its Transform).
pub const GameObject = struct {
    name: []const u8 = "",
    layer: i64 = 0,
    is_active: bool = true,
    tag: []const u8 = "",
    /// PPtrs to Component objects.
    components: []const value.PPtr = &.{},

    pub fn fromValue(allocator: std.mem.Allocator, v: value.Value) std.mem.Allocator.Error!GameObject {
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
            if (pptrField(.{ .obj = &.{.{ .name = "x", .value = item }} }, "x")) |p| {
                try list.append(allocator, p);
            }
        }
        self.components = try list.toOwnedSlice(allocator);
        return self;
    }
};

/// Transform (class 4): local position, rotation (quaternion x,y,z,w), and
/// scale, plus PPtrs to its GameObject and parent (`m_Father`).
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

/// Sprite (class 213): source texture and optional alpha texture, atlas
/// rect, pixels-per-unit, and the packing settings bitfield with helpers.
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

/// Material (class 21): name and shader PPtr; property blocks are read by
/// the extractor straight from the value tree.
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

/// MonoBehaviour (class 114): the fixed header (GameObject, enabled,
/// script PPtr, name) and the serialized script payload as raw bytes.
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
    /// The script payload reference (m_Script): file id + path id.
    script: ?value.PPtr = null,

    pub fn fromValue(v: value.Value) MonoScript {
        return .{
            .name = stringField(v, "m_Name") orelse "",
            .class_name = stringField(v, "m_ClassName") orelse "",
            .namespace = stringField(v, "m_Namespace") orelse "",
            .assembly = stringField(v, "m_AssemblyName") orelse "",
            .script = pptrField(v, "m_Script"),
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

/// AssetBundle (class 142): the bundle's own name; the `m_Container` path
/// map is exported by the extractor from the value tree.
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

    /// The channel's layout, or null when absent (dimension 0). The channel
    /// may live in any vertex stream; use [`channelByteOffset`] to read it.
    pub fn channel(self: *const Mesh, index: usize) ?MeshChannel {
        if (index >= self.channel_count) return null;
        const c = self.channels[index];
        if (c.dimension == 0) return null;
        return c;
    }

    /// One derived vertex stream's byte range (implicit layout).
    pub const StreamLayout = struct { offset: usize, stride: usize };

    /// Derives the implicit per-stream base offsets and strides from the
    /// channel table, mirroring UnityPy's `MeshHandler.get_streams`: each
    /// stream's stride is the rounded 4-byte span of its channels (so a
    /// single-stream mesh keeps the exact old `stride()` value), and later
    /// streams start at `vertex_count * stride` (16-byte aligned) past the
    /// earlier ones. Returns the number of populated streams (0-based index
    /// range 0..n), or null when a channel uses an unsupported format/stream.
    pub fn streamLayout(self: *const Mesh, out: *[4]StreamLayout) ?usize {
        var max_stream: usize = 0;
        for (self.channelSlice()) |c| {
            if (c.dimension == 0) continue;
            if (c.stream > max_stream) max_stream = @intCast(c.stream);
            _ = formatSize(c.format) orelse return null;
        }
        if (max_stream >= 4) return null; // Unity writes at most 3
        const vcount: usize = self.vertex_count;
        var offset: usize = 0;
        for (0..max_stream + 1) |s| {
            var max_end: usize = 0;
            for (self.channelSlice()) |c| {
                if (c.dimension == 0 or c.stream != s) continue;
                const fs = formatSize(c.format) orelse return null;
                max_end = @max(max_end, @as(usize, c.offset) + @as(usize, c.dimension) * fs);
            }
            const stream_stride = (max_end + 3) / 4 * 4;
            out[s] = .{ .offset = offset, .stride = stream_stride };
            offset = (offset + vcount * stream_stride + 15) / 16 * 16;
        }
        return max_stream + 1;
    }

    /// Byte offset of channel `index` at `vertex` within `vertex_data`,
    /// honoring the implicit per-stream layout. Null when the channel is
    /// absent, uses a non-float/unsupported format, or the layout is bad.
    pub fn channelByteOffset(self: *const Mesh, index: usize, vertex: usize) ?usize {
        const c = self.channel(index) orelse return null;
        _ = formatSize(c.format) orelse return null;
        var layout: [4]StreamLayout = undefined;
        const nstreams = self.streamLayout(&layout) orelse return null;
        if (@as(usize, c.stream) >= nstreams) return null;
        const st = layout[c.stream];
        return st.offset + @as(usize, c.offset) + vertex * st.stride;
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
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
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
    const go = try GameObject.fromValue(allocator, g);
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
    // high-range registered class ids (scripts/modules/editor)
    try std.testing.expectEqualStrings("PackedAssets", className(1126).?);
    try std.testing.expectEqualStrings("AnimatorStateMachine", className(1107).?);
    try std.testing.expectEqualStrings("SpriteAtlas", className(687078895).?);
    try std.testing.expectEqualStrings("Tilemap", className(1839735485).?);
    try std.testing.expectEqualStrings("GridLayout", className(1742807556).?);
    try std.testing.expectEqualStrings("VisualEffect", className(2083052967).?);
    try std.testing.expect(className(100) == null);
    try std.testing.expect(className(9999) == null);
    try std.testing.expect(className(2089858484) == null);
}

test "mesh multi-stream layout and per-vertex reads" {
    // Two streams: stream 0 has position (offset 0) + normal (offset 12),
    // stride 24; stream 1 (offset 48 = round16(2*24)) has UV (offset 0),
    // stride 8. vertex_count = 2.
    var m = Mesh{ .vertex_count = 2 };
    m.channels[0] = .{ .stream = 0, .offset = 0, .format = 0, .dimension = 3 };
    m.channels[1] = .{ .stream = 0, .offset = 12, .format = 0, .dimension = 3 };
    m.channels[4] = .{ .stream = 1, .offset = 0, .format = 0, .dimension = 2 };
    m.channel_count = 5;

    var layout: [4]Mesh.StreamLayout = undefined;
    const nstreams = m.streamLayout(&layout).?;
    try std.testing.expectEqual(@as(usize, 2), nstreams);
    try std.testing.expectEqual(@as(usize, 0), layout[0].offset);
    try std.testing.expectEqual(@as(usize, 24), layout[0].stride);
    try std.testing.expectEqual(@as(usize, 48), layout[1].offset);
    try std.testing.expectEqual(@as(usize, 8), layout[1].stride);

    // vertex 1 of channel 0 (pos) sits at 0 + 1*24; channel 1 (normal) at
    // 12 + 1*24; channel 4 (uv, stream 1) at 48 + 1*8.
    try std.testing.expectEqual(@as(usize, 24), m.channelByteOffset(0, 1).?);
    try std.testing.expectEqual(@as(usize, 36), m.channelByteOffset(1, 1).?);
    try std.testing.expectEqual(@as(usize, 56), m.channelByteOffset(4, 1).?);

    // Fill vertex_data. stream 0 (bytes 0..47): v0 pos(1,2,3)/nrm(4,5,6),
    // v1 pos(7,8,9)/nrm(10,11,12). stream 1 (bytes 48..63): v0 uv(0.5,0.25),
    // v1 uv(0.75,0.125).
    var data: [64]u8 = undefined;
    const vals = [_]f32{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 0.5, 0.25, 0.75, 0.125 };
    for (vals, 0..) |f, i| std.mem.writeInt(u32, data[i * 4 ..][0..4], @bitCast(f), .little);
    m.vertex_data = &data;
    const endian = std.builtin.Endian.little;

    // vertex 1 position (channel 0) = (7,8,9), normal (channel 1) = (10,11,12)
    try std.testing.expectEqual(@as(f32, 7), @as(f32, @bitCast(std.mem.readInt(u32, data[24..][0..4], endian))));
    try std.testing.expectEqual(@as(f32, 9), @as(f32, @bitCast(std.mem.readInt(u32, data[32..][0..4], endian))));
    try std.testing.expectEqual(@as(f32, 10), @as(f32, @bitCast(std.mem.readInt(u32, data[36..][0..4], endian))));
    // vertex 1 uv (channel 4, stream 1) = (0.75, 0.125)
    try std.testing.expectEqual(@as(f32, 0.75), @as(f32, @bitCast(std.mem.readInt(u32, data[56..][0..4], endian))));
    try std.testing.expectEqual(@as(f32, 0.125), @as(f32, @bitCast(std.mem.readInt(u32, data[60..][0..4], endian))));
}

test "font fromValue reads the type-tree fields" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "LiberationSans" } },
        .{ .name = "m_LineSpacing", .value = .{ .float = 18.4 } },
        .{ .name = "m_DefaultMaterial", .value = .{ .pptr = .{ .file_id = 0, .path_id = 128 } } },
        .{ .name = "m_FontSize", .value = .{ .float = 16 } },
        .{ .name = "m_Texture", .value = .{ .pptr = .{ .file_id = 0, .path_id = 324 } } },
        .{ .name = "m_AsciiStartOffset", .value = .{ .int = 0 } },
        .{ .name = "m_Tracking", .value = .{ .float = 1 } },
        .{ .name = "m_CharacterSpacing", .value = .{ .int = 0 } },
        .{ .name = "m_CharacterPadding", .value = .{ .int = 1 } },
        .{ .name = "m_ConvertCase", .value = .{ .int = -2 } },
        .{ .name = "m_CharacterRects", .value = .{ .array = &.{} } },
        .{ .name = "m_KerningValues", .value = .{ .array = &[_]value.Value{ .{ .obj = &.{} }, .{ .obj = &.{} } } } },
        .{ .name = "m_PixelScale", .value = .{ .float = 0.1 } },
        .{ .name = "m_FontData", .value = .{ .bytes = "OTTO" } },
        .{ .name = "m_Ascent", .value = .{ .float = 14.6 } },
        .{ .name = "m_Descent", .value = .{ .float = -3.2 } },
        .{ .name = "m_DefaultStyle", .value = .{ .uint = 1 } },
        .{ .name = "m_FontNames", .value = .{ .array = &[_]value.Value{ .{ .string = "Liberation Sans" }, .{ .string = "Noto Sans CJK JP" } } } },
        .{ .name = "m_FallbackFonts", .value = .{ .array = &[_]value.Value{.{ .pptr = .{ .file_id = 0, .path_id = 583 } }} } },
        .{ .name = "m_FontRenderingMode", .value = .{ .int = 0 } },
        .{ .name = "m_UseLegacyBoundsCalculation", .value = .{ .bool = false } },
        .{ .name = "m_ShouldRoundAdvanceValue", .value = .{ .bool = true } },
    } };
    const f = try Font.fromValue(allocator, v);
    try std.testing.expectEqualStrings("LiberationSans", f.name);
    try std.testing.expectEqual(@as(f64, 18.4), f.line_spacing);
    try std.testing.expectEqual(@as(f64, 16), f.font_size);
    try std.testing.expectEqual(@as(i64, 324), f.texture.?.path_id);
    try std.testing.expectEqual(@as(usize, 2), f.kerning_values);
    try std.testing.expectEqual(@as(f64, 0.1), f.pixel_scale);
    try std.testing.expectEqualStrings("OTTO", f.font_data);
    try std.testing.expectEqual(@as(f64, -3.2), f.descent);
    try std.testing.expectEqual(@as(u64, 1), f.default_style);
    try std.testing.expectEqual(@as(usize, 2), f.font_names.len);
    try std.testing.expectEqualStrings("Noto Sans CJK JP", f.font_names[1]);
    try std.testing.expectEqual(@as(i64, 583), f.fallback_fonts[0].path_id);
    try std.testing.expect(f.should_round_advance_value);
}

test "font fromRaw parses the serialized 5.5+ layout" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var tmp: [8]u8 = undefined;
    const putInt = struct {
        fn put(list: *std.ArrayList(u8), b: []u8, comptime T: type, v: T) !void {
            std.mem.writeInt(T, b[0..@sizeOf(T)], v, .little);
            try list.appendSlice(std.testing.allocator, b[0..@sizeOf(T)]);
        }
    }.put;
    // m_Name: "TestFont" (8 chars; 4 + 8 = 12 is already 4-aligned)
    try putInt(&buf, &tmp, i32, 8);
    try buf.appendSlice(std.testing.allocator, "TestFont");
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 19.5))); // m_LineSpacing
    try putInt(&buf, &tmp, i32, 0); // m_DefaultMaterial.m_FileID
    try putInt(&buf, &tmp, i64, 126); // m_DefaultMaterial.m_PathID
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 16))); // m_FontSize
    try putInt(&buf, &tmp, i32, 0); // m_Texture.m_FileID
    try putInt(&buf, &tmp, i64, 234); // m_Texture.m_PathID
    try putInt(&buf, &tmp, i32, 0); // m_AsciiStartOffset
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 1))); // m_Tracking
    try putInt(&buf, &tmp, i32, 0); // m_CharacterSpacing
    try putInt(&buf, &tmp, i32, 1); // m_CharacterPadding
    try putInt(&buf, &tmp, i32, -2); // m_ConvertCase
    try putInt(&buf, &tmp, i32, 0); // m_CharacterRects count (dynamic font)
    try putInt(&buf, &tmp, i32, 2); // m_KerningValues count
    try putInt(&buf, &tmp, u16, 70); // kerning pair (70, 44, -1)
    try putInt(&buf, &tmp, u16, 44);
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, -1)));
    try putInt(&buf, &tmp, u16, 80); // kerning pair (80, 46, -1)
    try putInt(&buf, &tmp, u16, 46);
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, -1)));
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 0.1))); // m_PixelScale
    try putInt(&buf, &tmp, i32, 4); // m_FontData size
    try buf.appendSlice(std.testing.allocator, "OTTO"); // inline font data
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 11.79))); // m_Ascent
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, -2.57))); // m_Descent
    try putInt(&buf, &tmp, u32, 0); // m_DefaultStyle
    try putInt(&buf, &tmp, i32, 1); // m_FontNames count
    try putInt(&buf, &tmp, i32, 8); // "TestFace" (4 + 8 = 12, already aligned)
    try buf.appendSlice(std.testing.allocator, "TestFace");
    try putInt(&buf, &tmp, i32, 1); // m_FallbackFonts count
    try putInt(&buf, &tmp, i32, 0); // fallback m_FileID
    try putInt(&buf, &tmp, i64, 583); // fallback m_PathID
    try putInt(&buf, &tmp, i32, 0); // m_FontRenderingMode
    try buf.appendSlice(std.testing.allocator, &.{ 0, 1 }); // m_UseLegacyBoundsCalculation, m_ShouldRoundAdvanceValue

    const f = try Font.fromRaw(allocator, buf.items, .little, "2022.3.62f2");
    try std.testing.expectEqualStrings("TestFont", f.name);
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, 19.5))), f.line_spacing);
    try std.testing.expectEqual(@as(i64, 126), f.default_material.?.path_id);
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, 16))), f.font_size);
    try std.testing.expectEqual(@as(i64, 234), f.texture.?.path_id);
    try std.testing.expectEqual(@as(usize, 0), f.character_rects);
    try std.testing.expectEqual(@as(usize, 2), f.kerning_values);
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, 0.1))), f.pixel_scale);
    try std.testing.expectEqualStrings("OTTO", f.font_data);
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, 11.79))), f.ascent);
    try std.testing.expectEqual(@as(f64, @floatCast(@as(f32, -2.57))), f.descent);
    try std.testing.expectEqualStrings("TestFace", f.font_names[0]);
    try std.testing.expectEqual(@as(i64, 583), f.fallback_fonts[0].path_id);
    try std.testing.expect(!f.use_legacy_bounds_calculation);
    try std.testing.expect(f.should_round_advance_value);
}

test "font fromRaw: 5.x fonts end before m_ShouldRoundAdvanceValue" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    // m_ShouldRoundAdvanceValue joined the layout after 2017.1 (absent in
    // 5.x/2017 dumps, present from 2018.4). A 5.6 font's serialized body
    // ends after the m_UseLegacyBoundsCalculation bool, so parsing it with
    // the modern layout reads one byte past the object.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var tmp: [8]u8 = undefined;
    const putInt = struct {
        fn put(list: *std.ArrayList(u8), b: []u8, comptime T: type, v: T) !void {
            std.mem.writeInt(T, b[0..@sizeOf(T)], v, .little);
            try list.appendSlice(std.testing.allocator, b[0..@sizeOf(T)]);
        }
    }.put;
    // Same body as the modern-layout test, minus the trailing
    // m_ShouldRoundAdvanceValue byte.
    try putInt(&buf, &tmp, i32, 8);
    try buf.appendSlice(std.testing.allocator, "TestFont");
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 19.5)));
    try putInt(&buf, &tmp, i32, 0);
    try putInt(&buf, &tmp, i64, 126);
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 16)));
    try putInt(&buf, &tmp, i32, 0);
    try putInt(&buf, &tmp, i64, 234);
    try putInt(&buf, &tmp, i32, 0);
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 1)));
    try putInt(&buf, &tmp, i32, 0);
    try putInt(&buf, &tmp, i32, 1);
    try putInt(&buf, &tmp, i32, -2);
    try putInt(&buf, &tmp, i32, 0); // m_CharacterRects
    try putInt(&buf, &tmp, i32, 0); // m_KerningValues
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 0.1))); // m_PixelScale
    try putInt(&buf, &tmp, i32, 4); // m_FontData
    try buf.appendSlice(std.testing.allocator, "OTTO");
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, 11.79))); // m_Ascent
    try putInt(&buf, &tmp, u32, @bitCast(@as(f32, -2.57))); // m_Descent
    try putInt(&buf, &tmp, u32, 0); // m_DefaultStyle
    try putInt(&buf, &tmp, i32, 0); // m_FontNames
    try putInt(&buf, &tmp, i32, 0); // m_FallbackFonts
    try putInt(&buf, &tmp, i32, 0); // m_FontRenderingMode
    try buf.appendSlice(std.testing.allocator, &.{0}); // m_UseLegacyBoundsCalculation only

    const f = try Font.fromRaw(allocator, buf.items, .little, "5.6.5p4");
    try std.testing.expectEqualStrings("TestFont", f.name);
    try std.testing.expectEqual(@as(i64, 126), f.default_material.?.path_id);
    try std.testing.expect(!f.should_round_advance_value);
    // the same body parsed as a modern font needs the extra byte
    try std.testing.expectError(error.OutOfBounds, Font.fromRaw(allocator, buf.items, .little, "2022.3.62f2"));
}

test "font fromRaw version gate and truncation" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    // pre-5.5 layouts are rejected, unknown version strings pass
    try std.testing.expectError(error.UnsupportedVersion, Font.fromRaw(allocator, &.{}, .little, "5.4.6f1"));
    try std.testing.expectError(error.UnsupportedVersion, Font.fromRaw(allocator, &.{}, .little, "4.7.2f1"));
    // empty body: the gate passes and the first field read fails out of
    // bounds - anything else would mean the version gate misfired
    try std.testing.expectError(error.OutOfBounds, Font.fromRaw(allocator, &.{}, .little, "5.5.0f1"));
    try std.testing.expectError(error.OutOfBounds, Font.fromRaw(allocator, &.{}, .little, "2022.3.62f2"));
    // a body cut short mid-object reads out of bounds
    try std.testing.expectError(error.OutOfBounds, Font.fromRaw(allocator, "\x04\x00\x00\x00TEST", .little, "2022.3.62f2"));
    // a negative character-rect count (corrupt data) is malformed
    // head: name "" + lineSpacing + material + fontSize + texture + spacing
    // ints, ending in the m_CharacterRects count
    var head: [60]u8 = undefined;
    std.mem.writeInt(i32, head[0..4], 0, .little); // m_Name length 0
    std.mem.writeInt(u32, head[4..8], 0, .little); // m_LineSpacing
    std.mem.writeInt(i32, head[8..12], 0, .little); // m_DefaultMaterial.m_FileID
    std.mem.writeInt(i64, head[12..20], 0, .little); // m_DefaultMaterial.m_PathID
    std.mem.writeInt(u32, head[20..24], 0, .little); // m_FontSize
    std.mem.writeInt(i32, head[24..28], 0, .little); // m_Texture.m_FileID
    std.mem.writeInt(i64, head[28..36], 0, .little); // m_Texture.m_PathID
    std.mem.writeInt(i32, head[36..40], 0, .little); // m_AsciiStartOffset
    std.mem.writeInt(u32, head[40..44], 0, .little); // m_Tracking
    std.mem.writeInt(i32, head[44..48], 0, .little); // m_CharacterSpacing
    std.mem.writeInt(i32, head[48..52], 0, .little); // m_CharacterPadding
    std.mem.writeInt(i32, head[52..56], 0, .little); // m_ConvertCase
    std.mem.writeInt(i32, head[56..60], -1, .little); // m_CharacterRects count = -1
    try std.testing.expectError(error.Malformed, Font.fromRaw(allocator, &head, .little, "2022.3.62f2"));
}

test "computeShader fromValue reads the variant tree" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    const unique = value.Value{ .obj = &[_]value.Field{
        .{ .name = "code", .value = .{ .bytes = "DXBC" } },
        .{ .name = "threadGroupSize", .value = .{ .array = &.{ .{ .uint = 16 }, .{ .uint = 16 }, .{ .uint = 1 } } } },
        .{ .name = "cbs", .value = .{ .array = &.{} } },
        .{ .name = "textures", .value = .{ .array = &.{.{ .obj = &.{} }} } },
        .{ .name = "inBuffers", .value = .{ .array = &.{} } },
        .{ .name = "outBuffers", .value = .{ .array = &.{} } },
    } };
    const kernel = value.Value{ .obj = &[_]value.Field{
        .{ .name = "name", .value = .{ .string = "CS" } },
        .{ .name = "uniqueVariants", .value = .{ .array = &.{unique} } },
    } };
    const cb = value.Value{ .obj = &[_]value.Field{
        .{ .name = "name", .value = .{ .string = "Params" } },
        .{ .name = "byteSize", .value = .{ .int = 16 } },
        .{ .name = "params", .value = .{ .array = &.{.{ .obj = &[_]value.Field{
            .{ .name = "name", .value = .{ .string = "_Params" } },
            .{ .name = "type", .value = .{ .int = 0 } },
            .{ .name = "offset", .value = .{ .uint = 0 } },
            .{ .name = "arraySize", .value = .{ .uint = 0 } },
            .{ .name = "rowCount", .value = .{ .uint = 1 } },
            .{ .name = "colCount", .value = .{ .uint = 4 } },
        } }} } },
    } };
    const variant = value.Value{ .obj = &[_]value.Field{
        .{ .name = "targetRenderer", .value = .{ .int = 2 } },
        .{ .name = "targetLevel", .value = .{ .int = 0 } },
        .{ .name = "kernels", .value = .{ .array = &.{kernel} } },
        .{ .name = "constantBuffers", .value = .{ .array = &.{cb} } },
        .{ .name = "resourcesResolved", .value = .{ .bool = true } },
    } };
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Histogram" } },
        .{ .name = "variants", .value = .{ .array = &.{variant} } },
    } };
    const cs = try ComputeShader.fromValue(allocator, v);
    try std.testing.expectEqualStrings("Histogram", cs.name);
    try std.testing.expectEqual(@as(usize, 1), cs.variants.len);
    try std.testing.expectEqual(@as(i32, 2), cs.variants[0].target_renderer);
    try std.testing.expectEqualStrings("CS", cs.variants[0].kernels[0].name);
    try std.testing.expectEqualStrings("DXBC", cs.variants[0].kernels[0].code);
    try std.testing.expectEqual(@as(u32, 16), cs.variants[0].kernels[0].thread_group_size[1]);
    try std.testing.expectEqual(@as(usize, 1), cs.variants[0].kernels[0].texture_count);
    try std.testing.expectEqualStrings("Params", cs.variants[0].constant_buffers[0].name);
    try std.testing.expectEqual(@as(u32, 4), cs.variants[0].constant_buffers[0].params[0].col_count);
    try std.testing.expect(cs.variants[0].resources_resolved);
}

test "computeShader fromRaw parses the serialized 2017+ layout" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    var tmp: [8]u8 = undefined;
    const putInt = struct {
        fn put(list: *std.ArrayList(u8), b: []u8, comptime T: type, v: T) !void {
            std.mem.writeInt(T, b[0..@sizeOf(T)], v, .little);
            try list.appendSlice(std.testing.allocator, b[0..@sizeOf(T)]);
        }
    }.put;
    try putInt(&buf, &tmp, i32, 6); // m_Name "TestCS" (4 + 6 = 10, pad 2)
    try buf.appendSlice(std.testing.allocator, "TestCS");
    try buf.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try putInt(&buf, &tmp, i32, 1); // variants count
    try putInt(&buf, &tmp, i32, 2); // targetRenderer
    try putInt(&buf, &tmp, i32, 0); // targetLevel
    try putInt(&buf, &tmp, i32, 1); // kernels count
    try putInt(&buf, &tmp, i32, 2); // kernel name "CS" (4 + 2 = 6, pad 2)
    try buf.appendSlice(std.testing.allocator, "CS");
    try buf.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try putInt(&buf, &tmp, i32, 1); // uniqueVariants count
    try putInt(&buf, &tmp, i32, 1); // cbVariantIndices count
    try putInt(&buf, &tmp, u32, 0); // [0]
    try putInt(&buf, &tmp, i32, 1); // cbs count
    try putInt(&buf, &tmp, i32, 6); // cb name "Params"
    try buf.appendSlice(std.testing.allocator, "Params");
    try buf.appendSlice(std.testing.allocator, &.{ 0, 0 });
    try putInt(&buf, &tmp, i32, 0); // generatedName
    try putInt(&buf, &tmp, i32, 0); // bindPoint
    try putInt(&buf, &tmp, i32, -1); // samplerBindPoint
    try putInt(&buf, &tmp, i32, -1); // texDimension
    try putInt(&buf, &tmp, i32, 1); // textures count
    try putInt(&buf, &tmp, i32, 3); // texture name "src"
    try buf.appendSlice(std.testing.allocator, "src");
    try buf.appendSlice(std.testing.allocator, &.{0});
    try putInt(&buf, &tmp, i32, 0); // generatedName
    try putInt(&buf, &tmp, i32, 0); // bindPoint
    try putInt(&buf, &tmp, i32, -1); // samplerBindPoint
    try putInt(&buf, &tmp, i32, -1); // texDimension
    try putInt(&buf, &tmp, i32, 0); // builtinSamplers
    try putInt(&buf, &tmp, i32, 0); // inBuffers
    try putInt(&buf, &tmp, i32, 0); // outBuffers
    try putInt(&buf, &tmp, i32, 4); // code size
    try buf.appendSlice(std.testing.allocator, "DXBC");
    try putInt(&buf, &tmp, i32, 3); // threadGroupSize count
    try putInt(&buf, &tmp, u32, 8); // x
    try putInt(&buf, &tmp, u32, 8); // y
    try putInt(&buf, &tmp, u32, 1); // z
    try putInt(&buf, &tmp, i64, 0); // requirements
    try putInt(&buf, &tmp, i32, 0); // variantIndices
    try putInt(&buf, &tmp, i32, 0); // globalKeywords
    try putInt(&buf, &tmp, i32, 0); // localKeywords
    try putInt(&buf, &tmp, i32, 0); // dynamicKeywords
    try putInt(&buf, &tmp, i32, 1); // constantBuffers count
    try putInt(&buf, &tmp, i32, 3); // cb name "CB0"
    try buf.appendSlice(std.testing.allocator, "CB0");
    try buf.appendSlice(std.testing.allocator, &.{0});
    try putInt(&buf, &tmp, i32, 16); // byteSize
    try putInt(&buf, &tmp, i32, 1); // params count
    try putInt(&buf, &tmp, i32, 1); // param name "v"
    try buf.appendSlice(std.testing.allocator, "v");
    try buf.appendSlice(std.testing.allocator, &.{ 0, 0, 0 });
    try putInt(&buf, &tmp, i32, 0); // type
    try putInt(&buf, &tmp, u32, 0); // offset
    try putInt(&buf, &tmp, u32, 0); // arraySize
    try putInt(&buf, &tmp, u32, 4); // rowCount
    try putInt(&buf, &tmp, u32, 4); // colCount
    try putInt(&buf, &tmp, u8, 1); // resourcesResolved
    try buf.appendSlice(std.testing.allocator, &.{ 0, 0, 0 }); // struct pad

    const cs = try ComputeShader.fromRaw(allocator, buf.items, .little, "2022.3.62f2");
    try std.testing.expectEqualStrings("TestCS", cs.name);
    try std.testing.expectEqual(@as(usize, 1), cs.variants.len);
    try std.testing.expectEqual(@as(i32, 2), cs.variants[0].target_renderer);
    try std.testing.expectEqualStrings("CS", cs.variants[0].kernels[0].name);
    try std.testing.expectEqualStrings("DXBC", cs.variants[0].kernels[0].code);
    try std.testing.expectEqual(@as(u32, 8), cs.variants[0].kernels[0].thread_group_size[1]);
    try std.testing.expectEqual(@as(usize, 1), cs.variants[0].kernels[0].cb_count);
    try std.testing.expectEqual(@as(usize, 1), cs.variants[0].kernels[0].texture_count);
    try std.testing.expectEqualStrings("CB0", cs.variants[0].constant_buffers[0].name);
    try std.testing.expectEqual(@as(i32, 16), cs.variants[0].constant_buffers[0].byte_size);
    try std.testing.expectEqual(@as(u32, 4), cs.variants[0].constant_buffers[0].params[0].row_count);
    try std.testing.expect(cs.variants[0].resources_resolved);
}

test "computeShader fromRaw version gate" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    try std.testing.expectError(error.UnsupportedVersion, ComputeShader.fromRaw(allocator, &.{}, .little, "5.6.7f1"));
    try std.testing.expectError(error.UnsupportedVersion, ComputeShader.fromRaw(allocator, &.{}, .little, "2016.4.40f1"));
    // empty body: the gate passes and the first field read fails out of
    // bounds - anything else would mean the version gate misfired
    try std.testing.expectError(error.OutOfBounds, ComputeShader.fromRaw(allocator, &.{}, .little, "2017.1.0f1"));
    try std.testing.expectError(error.OutOfBounds, ComputeShader.fromRaw(allocator, &.{}, .little, "2022.3.62f2"));
    // a negative variant count is malformed
    try std.testing.expectError(error.Malformed, ComputeShader.fromRaw(allocator, "\x01\x00\x00\x00A\x00\x00\x00\x00\xff\xff\xff\xff", .little, "2022.3.62f2"));
}

test "audio mixer family fromValue reads the graph fields" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    const ctrl = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "MasterAudioMixer" } },
        .{ .name = "m_MasterGroup", .value = .{ .pptr = .{ .file_id = 0, .path_id = 613 } } },
        .{ .name = "m_StartSnapshot", .value = .{ .pptr = .{ .file_id = 0, .path_id = 661 } } },
        .{ .name = "m_Snapshots", .value = .{ .array = &[_]value.Value{ .{ .pptr = .{ .file_id = 0, .path_id = 661 } }, .{ .pptr = .{ .file_id = 0, .path_id = 664 } } } } },
        .{ .name = "m_UpdateMode", .value = .{ .int = 0 } },
    } };
    const ac = try AudioMixerController.fromValue(allocator, ctrl);
    try std.testing.expectEqualStrings("MasterAudioMixer", ac.name);
    try std.testing.expectEqual(@as(i64, 613), ac.master_group.?.path_id);
    try std.testing.expectEqual(@as(i64, 661), ac.start_snapshot.?.path_id);
    try std.testing.expectEqual(@as(usize, 2), ac.snapshots.len);
    try std.testing.expectEqual(@as(i64, 664), ac.snapshots[1].path_id);

    const group = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Master" } },
        .{ .name = "m_Children", .value = .{ .array = &[_]value.Value{ .{ .pptr = .{ .file_id = 0, .path_id = 652 } }, .{ .pptr = .{ .file_id = 0, .path_id = 629 } } } } },
        .{ .name = "m_AudioMixer", .value = .{ .pptr = .{ .file_id = 0, .path_id = 606 } } },
    } };
    const g = try AudioMixerGroup.fromValue(allocator, group);
    try std.testing.expectEqualStrings("Master", g.name);
    try std.testing.expectEqual(@as(usize, 2), g.children.len);
    try std.testing.expectEqual(@as(i64, 629), g.children[1].path_id);
    try std.testing.expectEqual(@as(i64, 606), g.audio_mixer.?.path_id);

    const snap = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Default_Mix" } },
        .{ .name = "m_Time", .value = .{ .float = 0.1 } },
        .{ .name = "m_Values", .value = .{ .array = &[_]value.Value{ .{ .float = 0 }, .{ .float = 1 } } } },
    } };
    const s = AudioMixerSnapshot.fromValue(snap);
    try std.testing.expectEqualStrings("Default_Mix", s.name);
    try std.testing.expectEqual(@as(f64, 0.1), s.time);
    try std.testing.expectEqual(@as(usize, 2), s.values);
}

test "particleSystem fromValue reads the module summary" {
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_GameObject", .value = .{ .pptr = .{ .file_id = 0, .path_id = 1416 } } },
        .{ .name = "lengthInSec", .value = .{ .float = 5 } },
        .{ .name = "looping", .value = .{ .bool = true } },
        .{ .name = "simulationSpeed", .value = .{ .float = 1 } },
        .{ .name = "scalingMode", .value = .{ .int = 1 } },
        .{ .name = "InitialModule", .value = .{ .obj = &[_]value.Field{
            .{ .name = "startLifetime", .value = .{ .obj = &[_]value.Field{.{ .name = "scalar", .value = .{ .float = 2.5 } }} } },
            .{ .name = "startSpeed", .value = .{ .obj = &[_]value.Field{ .{ .name = "scalar", .value = .{ .float = 0 } }, .{ .name = "minScalar", .value = .{ .float = 3 } }, .{ .name = "maxScalar", .value = .{ .float = 6 } } } } },
            .{ .name = "startSize", .value = .{ .obj = &[_]value.Field{.{ .name = "scalar", .value = .{ .float = 1 } }} } },
            .{ .name = "gravityModifier", .value = .{ .obj = &[_]value.Field{.{ .name = "scalar", .value = .{ .float = 0.5 } }} } },
            .{ .name = "maxNumParticles", .value = .{ .int = 1000 } },
        } } },
        .{ .name = "EmissionModule", .value = .{ .obj = &[_]value.Field{
            .{ .name = "enabled", .value = .{ .bool = true } },
            .{ .name = "rateOverTime", .value = .{ .obj = &[_]value.Field{.{ .name = "scalar", .value = .{ .float = 10 } }} } },
            .{ .name = "m_BurstCount", .value = .{ .int = 2 } },
        } } },
        .{ .name = "ShapeModule", .value = .{ .obj = &[_]value.Field{
            .{ .name = "enabled", .value = .{ .bool = true } },
            .{ .name = "type", .value = .{ .int = 4 } },
            .{ .name = "angle", .value = .{ .float = 25 } },
            .{ .name = "radius", .value = .{ .obj = &[_]value.Field{.{ .name = "scalar", .value = .{ .float = 1 } }} } },
        } } },
        .{ .name = "NoiseModule", .value = .{ .obj = &[_]value.Field{.{ .name = "enabled", .value = .{ .bool = true } }} } },
        .{ .name = "TrailModule", .value = .{ .obj = &[_]value.Field{.{ .name = "enabled", .value = .{ .bool = false } }} } },
    } };
    const ps = ParticleSystem.fromValue(v);
    try std.testing.expectEqual(@as(i64, 1416), ps.game_object.?.path_id);
    try std.testing.expectEqual(@as(f64, 5), ps.duration);
    try std.testing.expect(ps.looping);
    try std.testing.expectEqual(@as(i64, 1), ps.scaling_mode);
    try std.testing.expectEqual(@as(f64, 2.5), ps.start_lifetime);
    // two-constant curve: scalar 0, so the max bound wins
    try std.testing.expectEqual(@as(f64, 6), ps.start_speed);
    try std.testing.expectEqual(@as(f64, 1), ps.start_size);
    try std.testing.expectEqual(@as(i64, 1000), ps.max_particles);
    try std.testing.expect(ps.emission_enabled);
    try std.testing.expectEqual(@as(f64, 10), ps.rate_over_time);
    try std.testing.expectEqual(@as(usize, 2), ps.burst_count);
    try std.testing.expectEqual(@as(i64, 4), ps.shape_type);
    try std.testing.expectEqual(@as(f64, 25), ps.shape_angle);
    try std.testing.expectEqual(@as(f64, 1), ps.shape_radius);
    try std.testing.expect(ps.module_flags[13]); // NoiseModule
    try std.testing.expect(!ps.module_flags[21]); // TrailModule
}

test "animatorController fromValue resolves TOS names" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "PlayOnSpawn" } },
        .{ .name = "m_TOS", .value = .{ .array = &[_]value.Value{
            .{ .array = &[_]value.Value{ .{ .uint = 756556552 }, .{ .string = "Base Layer" } } },
            .{ .array = &[_]value.Value{ .{ .uint = 2427234550 }, .{ .string = "balloon_spin" } } },
        } } },
        .{ .name = "m_AnimationClips", .value = .{ .array = &[_]value.Value{.{ .pptr = .{ .file_id = 0, .path_id = 576 } }} } },
        .{ .name = "m_Controller", .value = .{ .obj = &[_]value.Field{
            .{ .name = "m_LayerArray", .value = .{ .array = &[_]value.Value{.{ .obj = &[_]value.Field{
                .{ .name = "data", .value = .{ .obj = &[_]value.Field{
                    .{ .name = "m_StateMachineIndex", .value = .{ .int = 0 } },
                    .{ .name = "m_Binding", .value = .{ .uint = 756556552 } },
                    .{ .name = "(int&)m_LayerBlendingMode", .value = .{ .int = 0 } },
                    .{ .name = "m_DefaultWeight", .value = .{ .float = 1 } },
                    .{ .name = "m_IKPass", .value = .{ .bool = false } },
                } } },
            } }} } },
            .{ .name = "m_StateMachineArray", .value = .{ .array = &[_]value.Value{.{ .obj = &[_]value.Field{
                .{ .name = "data", .value = .{ .obj = &[_]value.Field{
                    .{ .name = "m_DefaultState", .value = .{ .int = 0 } },
                    .{ .name = "m_AnyStateTransitionConstantArray", .value = .{ .array = &[_]value.Value{.{ .obj = &.{} }} } },
                    .{ .name = "m_StateConstantArray", .value = .{ .array = &[_]value.Value{.{ .obj = &[_]value.Field{
                        .{ .name = "data", .value = .{ .obj = &[_]value.Field{
                            .{ .name = "m_NameID", .value = .{ .uint = 2427234550 } },
                            .{ .name = "m_FullPathID", .value = .{ .uint = 917444821 } },
                            .{ .name = "m_Speed", .value = .{ .float = 1 } },
                            .{ .name = "m_Loop", .value = .{ .bool = true } },
                            .{ .name = "m_TransitionConstantArray", .value = .{ .array = &[_]value.Value{.{ .obj = &.{} }} } },
                            .{ .name = "m_BlendTreeConstantArray", .value = .{ .array = &[_]value.Value{.{ .obj = &.{} }} } },
                        } } },
                    } }} } },
                } } },
            } }} } },
        } } },
    } };
    const ac = try AnimatorController.fromValue(allocator, v);
    try std.testing.expectEqualStrings("PlayOnSpawn", ac.name);
    try std.testing.expectEqual(@as(usize, 2), ac.tos.len);
    try std.testing.expectEqualStrings("Base Layer", ac.tosPath(756556552));
    try std.testing.expectEqualStrings("balloon_spin", ac.tosPath(2427234550));
    try std.testing.expectEqualStrings("", ac.tosPath(12345));
    try std.testing.expectEqual(@as(usize, 1), ac.layers.len);
    try std.testing.expectEqualStrings("Base Layer", ac.tosPath(ac.layers[0].binding));
    try std.testing.expectEqual(@as(i64, 0), ac.layers[0].blending_mode);
    try std.testing.expectEqual(@as(f64, 1), ac.layers[0].default_weight);
    try std.testing.expectEqual(@as(usize, 1), ac.state_machine_count);
    try std.testing.expectEqual(@as(usize, 1), ac.states.len);
    try std.testing.expectEqualStrings("balloon_spin", ac.tosPath(ac.states[0].name_id));
    try std.testing.expectEqual(@as(usize, 1), ac.states[0].transition_count);
    try std.testing.expectEqual(@as(usize, 1), ac.states[0].blend_tree_count);
    try std.testing.expect(ac.states[0].loop);
    try std.testing.expectEqual(@as(usize, 1), ac.any_state_transitions);
    try std.testing.expectEqual(@as(i64, 576), ac.clips[0].path_id);
}

test "animatorOverrideController fromValue reads the override pairs" {
    var view_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer view_arena.deinit();
    const allocator = view_arena.allocator();
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "3PWeaponController" } },
        .{ .name = "m_Controller", .value = .{ .pptr = .{ .file_id = 0, .path_id = 129 } } },
        .{ .name = "m_Clips", .value = .{ .array = &[_]value.Value{.{ .obj = &[_]value.Field{
            .{ .name = "m_OriginalClip", .value = .{ .pptr = .{ .file_id = 0, .path_id = 77 } } },
            .{ .name = "m_OverrideClip", .value = .{ .pptr = .{ .file_id = 0, .path_id = 67 } } },
        } }} } },
    } };
    const oc = try AnimatorOverrideController.fromValue(allocator, v);
    try std.testing.expectEqualStrings("3PWeaponController", oc.name);
    try std.testing.expectEqual(@as(i64, 129), oc.controller.?.path_id);
    try std.testing.expectEqual(@as(usize, 1), oc.overrides.len);
    try std.testing.expectEqual(@as(i64, 77), oc.overrides[0].original.?.path_id);
    try std.testing.expectEqual(@as(i64, 67), oc.overrides[0].replacement.?.path_id);
}

test "monoScript fromValue reads the registry fields" {
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_Name", .value = .{ .string = "Item_Base" } },
        .{ .name = "m_ClassName", .value = .{ .string = "Item_Base" } },
        .{ .name = "m_Namespace", .value = .{ .string = "ItemClass" } },
        .{ .name = "m_AssemblyName", .value = .{ .string = "Assembly-CSharp" } },
        .{ .name = "m_Script", .value = .{ .pptr = .{ .file_id = 1, .path_id = 10 } } },
    } };
    const ms = MonoScript.fromValue(v);
    try std.testing.expectEqualStrings("Item_Base", ms.name);
    try std.testing.expectEqualStrings("ItemClass", ms.namespace);
    try std.testing.expectEqualStrings("Assembly-CSharp", ms.assembly);
    try std.testing.expectEqual(@as(i32, 1), ms.script.?.file_id);
    try std.testing.expectEqual(@as(i64, 10), ms.script.?.path_id);
}

test "animator fromValue reads the component refs and flags" {
    const v = value.Value{ .obj = &[_]value.Field{
        .{ .name = "m_GameObject", .value = .{ .pptr = .{ .file_id = 0, .path_id = 786 } } },
        .{ .name = "m_Avatar", .value = .{ .pptr = .{ .file_id = 0, .path_id = 581 } } },
        .{ .name = "m_Controller", .value = .{ .pptr = .{ .file_id = 0, .path_id = 582 } } },
        .{ .name = "m_UpdateMode", .value = .{ .int = 0 } },
        .{ .name = "m_ApplyRootMotion", .value = .{ .bool = false } },
        .{ .name = "m_StabilizeFeet", .value = .{ .bool = true } },
    } };
    const an = Animator.fromValue(v);
    try std.testing.expectEqual(@as(i64, 786), an.game_object.?.path_id);
    try std.testing.expectEqual(@as(i64, 581), an.avatar.?.path_id);
    try std.testing.expectEqual(@as(i64, 582), an.controller.?.path_id);
    try std.testing.expect(!an.apply_root_motion);
    try std.testing.expect(an.stabilize_feet);
}
