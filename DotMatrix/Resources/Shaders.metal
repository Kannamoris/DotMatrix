#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

struct DisplayUniforms {
    // Screen size in pixels, used to size the LCD grid.
    float2 sourceSize;
    // 0 = off, 1 = full strength.
    float gridStrength;
    // 0 = nearest neighbour, 1 = smoothed.
    float smoothing;
    // Sub-region of the source to show, normalised: xy = origin, zw = size.
    // The battle view uses this to drop the game's own menu and message box
    // and present only the battlefield.
    float4 sourceRect;
};

/// Fullscreen triangle. Cheaper than a quad and avoids the diagonal seam.
vertex VertexOut display_vertex(uint vertexID [[vertex_id]]) {
    float2 positions[3] = { float2(-1.0, -3.0), float2(-1.0, 1.0), float2(3.0, 1.0) };
    float2 coords[3]    = { float2( 0.0,  2.0), float2( 0.0, 0.0), float2(2.0, 0.0) };

    VertexOut out;
    out.position = float4(positions[vertexID], 0.0, 1.0);
    out.texCoord = coords[vertexID];
    return out;
}

fragment float4 display_fragment(VertexOut in [[stage_in]],
                                 texture2d<float> source [[texture(0)]],
                                 constant DisplayUniforms &uniforms [[buffer(0)]]) {
    constexpr sampler nearestSampler(filter::nearest, address::clamp_to_edge);
    constexpr sampler linearSampler(filter::linear, address::clamp_to_edge);

    // Remap into the requested sub-region before sampling.
    float2 coord = uniforms.sourceRect.xy + in.texCoord * uniforms.sourceRect.zw;

    float4 color = mix(source.sample(nearestSampler, coord),
                       source.sample(linearSampler, coord),
                       uniforms.smoothing);

    // Darken the pixel edges to suggest the gaps between LCD cells. Only
    // visible when each source pixel covers several output pixels.
    if (uniforms.gridStrength > 0.0) {
        float2 pixel = coord * uniforms.sourceSize;
        float2 distanceToEdge = abs(fract(pixel) - 0.5) * 2.0;
        float edge = max(distanceToEdge.x, distanceToEdge.y);
        float grid = smoothstep(0.75, 1.0, edge);
        color.rgb *= 1.0 - grid * uniforms.gridStrength * 0.35;
    }

    return color;
}
