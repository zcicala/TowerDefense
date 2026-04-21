//
//  CelShader.metal
//  TestGame
//

#include <metal_stdlib>
#include <RealityKit/RealityKit.h>
using namespace metal;

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
