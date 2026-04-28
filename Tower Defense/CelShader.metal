//
//  CelShader.metal
//  TestGame
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

// MARK: - Watercolor helpers

static float wc_hash(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453);
}

static float wc_noise(float2 p) {
    float2 i = floor(p);
    float2 f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    return mix(mix(wc_hash(i),              wc_hash(i + float2(1, 0)), u.x),
               mix(wc_hash(i + float2(0,1)), wc_hash(i + float2(1,1)), u.x), u.y);
}

// Fractal Brownian Motion — blotchy layered noise
static float wc_fbm(float2 p, int octaves) {
    float v = 0.0, amp = 0.5, freq = 1.0;
    for (int i = 0; i < octaves; i++) {
        v += wc_noise(p * freq) * amp;
        p  = p * 2.13 + float2(1.7, 9.2);
        amp *= 0.5;
    }
    return v;
}

[[visible]]
void celSurfaceShader(realitykit::surface_parameters params)
{
    half3 baseColor = (half3)params.material_constants().base_color_tint();
    float3 normal = normalize(params.geometry().normal());

    // Simple directional light from upper-right-front
    float3 lightDir = normalize(float3(0.5, 1.0, 0.8));
    float NdotL = dot(normal, lightDir);

    // Quantize into 3 bands for cel shading
    half intensity;
    if (NdotL > 0.6)
        intensity = 1.0h;
    else if (NdotL > 0.2)
        intensity = 0.6h;
    else
        intensity = 0.3h;

    half3 color = baseColor * intensity;

    // Selection highlight: custom.value[0] = selection amount (0 or 1)
    float selection = params.uniforms().custom_parameter()[0];
    if (selection > 0.5) {
        // Brighten and add a warm rim glow
        float rim = 1.0 - max(0.0, dot(normal, normalize(float3(0, 1, 0.5))));
        rim = pow(rim, 2.0);
        half3 glowColor = half3(1.0h, 0.85h, 0.4h); // warm gold
        color = mix(color, color * 1.4h + glowColor * (half)rim * 0.5h, half(selection));
    }

    // Range highlight: custom.value[1] = 1 when cell is within tower fire range
    float rangeGlow = params.uniforms().custom_parameter()[1];
    if (rangeGlow > 0.5) {
        float rim = 1.0 - max(0.0, dot(normal, normalize(float3(0, 1, 0))));
        rim = pow(rim, 3.0);
        half3 rangeColor = half3(0.3h, 0.75h, 1.0h); // cool blue
        color = color * 1.15h + rangeColor * (half)(rim * 0.5 + 0.12);
    }

    params.surface().set_emissive_color(color);
}
// MARK: - Watercolor enemy shader

[[visible]]
void watercolorSurfaceShader(realitykit::surface_parameters params)
{
    half3 baseColor = (half3)params.material_constants().base_color_tint();
    float3 normal   = normalize(params.geometry().normal());

    // UV from mesh coords — scale so blobs cover ~1/3 of the surface at a time
    float2 uv = params.geometry().uv0() * 4.5;

    // Domain warp: pull the UV through noise so blobs become irregular and organic
    float2 warp = float2(wc_fbm(uv * 0.65 + float2(3.2, 1.7), 3),
                         wc_fbm(uv * 0.65 + float2(8.1, 5.4), 3));
    float2 warpedUV = uv + warp * 2.8;

    // Primary blotch layer
    float blotch = wc_fbm(warpedUV * 0.75, 4);  // 0..1

    // High-frequency grain for paper texture
    float grain = wc_fbm(uv * 6.0 + float2(0.3, 2.1), 2) - 0.5;  // −0.5..+0.5

    // Map blotch to pigment density:
    //   low values → pooled dark paint (edges of blobs)
    //   high values → washed-out light centre
    float pooling = smoothstep(0.30, 0.70, blotch);

    half3 darkPaint  = baseColor * 0.50h;   // paint pooling in valleys
    half3 lightWash  = baseColor * 1.30h;   // thin wash on peaks
    half3 color = mix(darkPaint, lightWash, (half)pooling);

    // Add subtle paper grain
    color = clamp(color + (half)(grain * 0.08), 0.0h, 1.4h);

    // Soft diffuse — watercolour has gentle light, no hard bands
    float3 lightDir = normalize(float3(0.5, 1.0, 0.8));
    float NdotL  = saturate(dot(normal, lightDir));
    float diffuse = NdotL * 0.28 + 0.72;
    color *= (half)diffuse;

    // Silhouette edge darkening — paint naturally pools at contour edges
    float edgeNdotV = saturate(dot(normal, normalize(float3(0.2, 1.0, 0.4))));
    float edgeDark  = pow(1.0 - edgeNdotV, 2.8);
    color *= (1.0h - (half)(edgeDark * 0.50));

    // Warm paper bleed on the light wash areas
    half3 paperWarm = half3(1.06h, 0.97h, 0.90h);
    color *= mix(half3(1.0h), paperWarm, (half)pooling * 0.35h);

    params.surface().set_emissive_color(saturate(color));
}

