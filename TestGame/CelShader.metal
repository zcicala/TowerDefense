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

    params.surface().set_emissive_color(baseColor * intensity);
}
