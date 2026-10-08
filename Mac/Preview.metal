#include <metal_stdlib>
using namespace metal;

// Monitoring overlays. These exist only in the Studio's preview — the
// virtual camera always receives the clean picture.

struct PreviewUniforms {
    float2 scale;        // aspect-fit quad scale in clip space
    float2 texel;        // 1 / texture size
    float zebra;         // 0/1
    float zebraLevel;    // luma threshold, e.g. 0.95
    float peaking;       // 0/1
    float peakThreshold;
    float falseColor;    // 0/1
    float time;
};

struct VOut {
    float4 position [[position]];
    float2 uv;
};

vertex VOut previewVertex(uint vid [[vertex_id]], constant PreviewUniforms &u [[buffer(0)]]) {
    const float2 corners[4] = { float2(-1, -1), float2(1, -1), float2(-1, 1), float2(1, 1) };
    float2 p = corners[vid];
    VOut o;
    o.position = float4(p * u.scale, 0, 1);
    o.uv = float2((p.x + 1) * 0.5, 1 - (p.y + 1) * 0.5);
    return o;
}

static float luma(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }

static float3 falseColorMap(float l) {
    // Bands loosely follow the common camera false-colour scheme (IRE).
    if (l < 0.025) return float3(0.45, 0.10, 0.65);     // crushed
    if (l < 0.10)  return float3(0.10, 0.30, 0.90);     // near black
    if (l > 0.38 && l < 0.44) return float3(0.25, 0.75, 0.30); // 18 % grey
    if (l > 0.52 && l < 0.60) return float3(0.95, 0.55, 0.70); // skin
    if (l > 0.97)  return float3(0.95, 0.15, 0.15);     // clipping
    if (l > 0.90)  return float3(0.98, 0.85, 0.20);     // near clip
    return float3(l * 0.85);
}

fragment float4 previewFragment(VOut in [[stage_in]],
                                texture2d<float> tex [[texture(0)]],
                                constant PreviewUniforms &u [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float3 c = tex.sample(s, in.uv).rgb;
    float l = luma(c);

    if (u.falseColor > 0.5) {
        c = falseColorMap(l);
    }

    if (u.peaking > 0.5) {
        float lx1 = luma(tex.sample(s, in.uv + float2(u.texel.x, 0)).rgb);
        float lx0 = luma(tex.sample(s, in.uv - float2(u.texel.x, 0)).rgb);
        float ly1 = luma(tex.sample(s, in.uv + float2(0, u.texel.y)).rgb);
        float ly0 = luma(tex.sample(s, in.uv - float2(0, u.texel.y)).rgb);
        float edge = length(float2(lx1 - lx0, ly1 - ly0));
        if (edge > u.peakThreshold) {
            c = mix(c, float3(1.0, 0.15, 0.25), 0.9);
        }
    }

    if (u.zebra > 0.5 && l >= u.zebraLevel) {
        float2 px = in.position.xy;
        float stripe = fract((px.x + px.y + u.time * 40.0) / 14.0);
        c = stripe < 0.5 ? float3(0.0) : float3(1.0);
    }

    return float4(c, 1.0);
}
