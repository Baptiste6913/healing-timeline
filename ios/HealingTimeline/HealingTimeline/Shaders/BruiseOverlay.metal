#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - RealityKit CustomMaterial Surface Shader (surgeon-grade v1)
// ═══════════════════════════════════════════════════════════════════════════
//
// Custom parameter packing (SIMD4<Float>):
//   .x  = bruiseLevel   (0-1)
//   .y  = bruiseColor.r  (0-1)
//   .z  = bruiseColor.g  (0-1)
//   .w  = bruiseColor.b  (0-1)
//
// The base albedo atlas is sampled from the material's base-color texture
// and is NEVER modified — all bruise tinting is additive/multiplicative
// in this shader.  This enforces NON-NEGOTIABLE #1.

[[visible]]
void bruiseSurfaceShader(
    realitykit::surface_parameters params
) {
    // ── Sample immutable base atlas ─────────────────────────────────────
    auto tex = params.textures();
    float2 uv = params.geometry().uv0();
    half4 baseColor = tex.base_color().sample(uv);

    // ── Unpack custom uniforms ──────────────────────────────────────────
    float4 customParam = params.uniforms().custom_parameter();
    float  bruiseLevel = customParam.x;
    half3  bruiseColor = half3(customParam.y, customParam.z, customParam.w);

    // ── Early out if no bruise ──────────────────────────────────────────
    if (bruiseLevel < 0.01h) {
        params.surface().set_base_color(baseColor.rgb);
        params.surface().set_roughness(0.6h);
        params.surface().set_metallic(0.0h);
        return;
    }

    // ── Zone-based spatial falloff ──────────────────────────────────────
    // Use model-space Y as a proxy for "distance from nose bridge".
    // The nose region (Y ≈ 0) gets full bruise; farther regions attenuate.
    float3 modelPos = params.geometry().model_position();
    float distFromCenter = length(modelPos.xy);        // radial distance in XY
    float zoneFactor = 1.0 - smoothstep(0.0, 0.06, distFromCenter);  // 6cm falloff
    zoneFactor = zoneFactor * zoneFactor;               // sharper falloff

    // ── Blend bruise color (non-destructive overlay) ────────────────────
    float blendFactor = bruiseLevel * zoneFactor;
    half3 bruised = mix(baseColor.rgb, bruiseColor, half(blendFactor * 0.7));

    // ── Subcutaneous darkening ──────────────────────────────────────────
    half darken = half(1.0 - blendFactor * 0.15);
    bruised *= darken;

    // ── Write surface ───────────────────────────────────────────────────
    params.surface().set_base_color(bruised);
    params.surface().set_roughness(0.6h);
    params.surface().set_metallic(0.0h);
}

// ═══════════════════════════════════════════════════════════════════════════
// MARK: - Legacy standalone shaders (kept for reference / fallback)
// ═══════════════════════════════════════════════════════════════════════════

// Bruise parameters passed via buffer (legacy)
struct BruiseParams {
    float bruiseLevel;      // 0-1 intensity
    float3 bruiseColor;     // current bruise RGB
    float3 zoneCenter;      // center of bruise zone (world space)
    float zoneRadius;       // falloff radius
    float fadePower;        // smoothstep power
};

// Fragment function for bruise overlay on skin texture (legacy/standalone)
fragment float4 bruiseOverlayFragment(
    float4 position [[position]],
    float3 worldPosition,
    float3 worldNormal,
    float2 texCoord,
    constant BruiseParams &params [[buffer(0)]],
    texture2d<float> baseTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    float4 baseColor = baseTexture.sample(textureSampler, texCoord);

    float dist = length(worldPosition - params.zoneCenter);
    float zoneFactor = 1.0 - smoothstep(0.0, params.zoneRadius, dist);
    zoneFactor = pow(zoneFactor, params.fadePower);

    float blendFactor = params.bruiseLevel * zoneFactor;
    float3 bruised = mix(baseColor.rgb, params.bruiseColor, blendFactor * 0.7);
    float darken = 1.0 - blendFactor * 0.15;
    bruised *= darken;

    return float4(bruised, baseColor.a);
}

// Vertex function for mesh deformation / swelling (legacy/standalone)
struct VertexIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 texCoord [[attribute(2)]];
};

struct VertexOut {
    float4 position [[position]];
    float3 worldPosition;
    float3 worldNormal;
    float2 texCoord;
};

struct SwellParams {
    float4x4 modelViewProjection;
    float4x4 modelMatrix;
    float displacementMM;
    float3 zoneCenter;
    float zoneRadius;
};

vertex VertexOut swellingVertex(
    VertexIn in [[stage_in]],
    constant SwellParams &params [[buffer(1)]]
) {
    VertexOut out;

    float dist = length(in.position - params.zoneCenter);
    float influence = 1.0 - smoothstep(0.0, params.zoneRadius, dist);
    influence = influence * influence;

    float displacementM = params.displacementMM * 0.001;
    float3 displaced = in.position + in.normal * (displacementM * influence);

    out.position = params.modelViewProjection * float4(displaced, 1.0);
    out.worldPosition = (params.modelMatrix * float4(displaced, 1.0)).xyz;
    out.worldNormal = normalize((params.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;

    return out;
}
