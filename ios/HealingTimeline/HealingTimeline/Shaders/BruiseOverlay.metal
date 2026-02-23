#include <metal_stdlib>
using namespace metal;

// Custom surface shader for bruise color overlay.
// Applied as a post-process or custom material modifier.

// Bruise parameters passed via buffer
struct BruiseParams {
    float bruiseLevel;      // 0-1 intensity
    float3 bruiseColor;     // current bruise RGB
    float3 zoneCenter;      // center of bruise zone (world space)
    float zoneRadius;       // falloff radius
    float fadePower;        // smoothstep power
};

// Fragment function for bruise overlay on skin texture
fragment float4 bruiseOverlayFragment(
    // Standard inputs
    float4 position [[position]],
    float3 worldPosition,
    float3 worldNormal,
    float2 texCoord,
    // Custom uniforms
    constant BruiseParams &params [[buffer(0)]],
    texture2d<float> baseTexture [[texture(0)]],
    sampler textureSampler [[sampler(0)]]
) {
    // Sample base skin color
    float4 baseColor = baseTexture.sample(textureSampler, texCoord);

    // Compute distance from bruise zone center
    float dist = length(worldPosition - params.zoneCenter);
    float zoneFactor = 1.0 - smoothstep(0.0, params.zoneRadius, dist);
    zoneFactor = pow(zoneFactor, params.fadePower);

    // Blend bruise color
    float blendFactor = params.bruiseLevel * zoneFactor;
    float3 bruised = mix(baseColor.rgb, params.bruiseColor, blendFactor * 0.7);

    // Darken slightly in bruise area (subcutaneous blood absorption)
    float darken = 1.0 - blendFactor * 0.15;
    bruised *= darken;

    return float4(bruised, baseColor.a);
}

// Vertex function for mesh deformation (swelling)
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
    float displacementMM;    // max displacement in mm
    float3 zoneCenter;       // nose tip position
    float zoneRadius;        // influence radius
};

vertex VertexOut swellingVertex(
    VertexIn in [[stage_in]],
    constant SwellParams &params [[buffer(1)]]
) {
    VertexOut out;

    // Compute zone influence
    float dist = length(in.position - params.zoneCenter);
    float influence = 1.0 - smoothstep(0.0, params.zoneRadius, dist);
    influence = influence * influence; // quadratic falloff

    // Displace along normal
    float displacementM = params.displacementMM * 0.001; // mm to meters
    float3 displaced = in.position + in.normal * (displacementM * influence);

    out.position = params.modelViewProjection * float4(displaced, 1.0);
    out.worldPosition = (params.modelMatrix * float4(displaced, 1.0)).xyz;
    out.worldNormal = normalize((params.modelMatrix * float4(in.normal, 0.0)).xyz);
    out.texCoord = in.texCoord;

    return out;
}
