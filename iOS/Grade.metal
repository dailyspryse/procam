#include <metal_stdlib>
using namespace metal;

// Must match `GradeUniforms` in GradeRenderer.swift field for field.
// Scalars only, so Swift and Metal agree on the layout without padding rules.
struct GradeUniforms {
    float fullRange;
    float bt2020;
    float logDecode;     // Apple Log → Rec.709 conversion
    float logRaw;        // Apple Log left encoded (LUT does the conversion)
    float exposure;
    float contrast;
    float saturation;
    float vibrance;
    float temperature;
    float tint;
    float highlights;
    float shadows;
    float blackPoint;
    float liftR, liftG, liftB;
    float gammaR, gammaG, gammaB;
    float gainR, gainG, gainB;
    float vignette;
    float sharpen;
    float lutIntensity;  // 0 = no LUT
    float lutSize;
};

constant float3 kLuma709 = float3(0.2126, 0.7152, 0.0722);

static float3 yuvToRgb(float y, float2 c, constant GradeUniforms &u) {
    float Y, Cb, Cr;
    if (u.fullRange > 0.5) {
        Y = y; Cb = c.x - 0.5; Cr = c.y - 0.5;
    } else {
        Y = (y - 16.0 / 255.0) * (255.0 / 219.0);
        Cb = (c.x - 128.0 / 255.0) * (255.0 / 224.0);
        Cr = (c.y - 128.0 / 255.0) * (255.0 / 224.0);
    }
    if (u.bt2020 > 0.5) {
        return float3(Y + 1.4746 * Cr,
                      Y - 0.16455 * Cb - 0.57135 * Cr,
                      Y + 1.8814 * Cb);
    }
    return float3(Y + 1.5748 * Cr,
                  Y - 0.1873 * Cb - 0.4681 * Cr,
                  Y + 1.8556 * Cb);
}

// Apple Log, from Apple's "Apple Log Profile" white paper.
static float appleLogToLinear(float p) {
    const float R0 = -0.05641088;
    const float Rt = 0.01;
    const float c = 47.28711236;
    const float b = 0.00964052;
    const float g = 0.08550479;
    const float beta = 0.69336945;
    const float Pt = c * (Rt - R0) * (Rt - R0);
    if (p >= Pt) return exp2((p - beta) / g) - b;
    if (p >= 0.0) return sqrt(p / c) + R0;
    return R0;
}

static float3 rec2020ToRec709(float3 c) {
    return float3( 1.6605 * c.r - 0.5876 * c.g - 0.0728 * c.b,
                  -0.1246 * c.r + 1.1329 * c.g - 0.0083 * c.b,
                  -0.0182 * c.r - 0.1006 * c.g + 1.1187 * c.b);
}

// Narkowicz' ACES fit: a filmic shoulder so Log's extra highlight range
// rolls off instead of clipping.
static float3 tonemap(float3 x) {
    x *= 0.7;
    return saturate((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14));
}

static float3 srgbToLinear(float3 c) {
    c = saturate(c);
    return select(pow((c + 0.055) / 1.055, 2.4), c / 12.92, c <= 0.04045);
}

static float3 linearToSrgb(float3 c) {
    c = max(c, 0.0);
    return select(1.055 * pow(c, 1.0 / 2.4) - 0.055, c * 12.92, c <= 0.0031308);
}

static float3 applyLut(float3 rgb, texture3d<float> lut, constant GradeUniforms &u) {
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float n = u.lutSize;
    float3 coord = saturate(rgb) * ((n - 1.0) / n) + 0.5 / n;
    return lut.sample(s, coord).rgb;
}

kernel void grade(texture2d<float, access::read> lumaTex [[texture(0)]],
                  texture2d<float, access::sample> chromaTex [[texture(1)]],
                  texture3d<float> lut [[texture(2)]],
                  texture2d<float, access::write> outTex [[texture(3)]],
                  constant GradeUniforms &u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]])
{
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;

    constexpr sampler cs(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);

    float y = lumaTex.read(gid).r;
    float2 c = chromaTex.sample(cs, uv).rg;
    float3 rgb = yuvToRgb(y, c, u);

    // Detail for sharpening, taken from the untouched luma so grading
    // cannot amplify noise it has already lifted.
    float detail = 0.0;
    if (u.sharpen > 0.001) {
        uint2 maxp = uint2(w - 1, h - 1);
        float n = lumaTex.read(uint2(gid.x, gid.y > 0 ? gid.y - 1 : 0)).r
                + lumaTex.read(uint2(gid.x, min(gid.y + 1, maxp.y))).r
                + lumaTex.read(uint2(gid.x > 0 ? gid.x - 1 : 0, gid.y)).r
                + lumaTex.read(uint2(min(gid.x + 1, maxp.x), gid.y)).r;
        detail = y - n * 0.25;
    }

    float evGain = exp2(u.exposure);
    float3 wb = float3(1.0 + 0.12 * u.temperature,
                       1.0 - 0.10 * u.tint,
                       1.0 - 0.12 * u.temperature);

    if (u.logRaw > 0.5) {
        // Apple Log kept encoded for a conversion LUT. One stop is a fixed
        // code-value offset on the log curve.
        rgb += u.exposure * 0.08550479;
        if (u.lutIntensity > 0.0) {
            rgb = mix(rgb, applyLut(rgb, lut, u), u.lutIntensity);
        }
        rgb = srgbToLinear(rgb) * wb;
        rgb = linearToSrgb(rgb);
    } else if (u.logDecode > 0.5) {
        float3 lin = float3(appleLogToLinear(rgb.r), appleLogToLinear(rgb.g), appleLogToLinear(rgb.b));
        lin = max(rec2020ToRec709(lin), 0.0) * evGain * wb;
        rgb = linearToSrgb(tonemap(lin));
    } else {
        float3 lin = srgbToLinear(rgb) * evGain * wb;
        rgb = linearToSrgb(lin);
    }

    // Shadows / highlights: lift or pull luma in a band, endpoints fixed.
    float L = dot(saturate(rgb), kLuma709);
    float shadowW = 6.75 * L * (1.0 - L) * (1.0 - L);   // peaks at 1/3
    float highW = 6.75 * L * L * (1.0 - L);             // peaks at 2/3
    float newL = L + 0.25 * u.shadows * shadowW + 0.25 * u.highlights * highW;
    rgb *= newL / max(L, 1e-4);

    // Contrast around 18 % grey (sRGB-encoded).
    rgb = (rgb - 0.46) * u.contrast + 0.46;

    // Lift / gamma / gain.
    float3 lift = float3(u.liftR, u.liftG, u.liftB);
    float3 gamma = float3(u.gammaR, u.gammaG, u.gammaB);
    float3 gain = float3(u.gainR, u.gainG, u.gainB);
    rgb = rgb * gain + lift * (1.0 - rgb);
    rgb = pow(max(rgb, 0.0), 1.0 / max(gamma, 0.05));

    rgb = u.blackPoint + rgb * (1.0 - u.blackPoint);

    // Saturation and vibrance (vibrance favours muted colours).
    float luma = dot(rgb, kLuma709);
    rgb = mix(float3(luma), rgb, u.saturation);
    float chroma = max(rgb.r, max(rgb.g, rgb.b)) - min(rgb.r, min(rgb.g, rgb.b));
    rgb = mix(float3(luma), rgb, 1.0 + u.vibrance * (1.0 - saturate(chroma * 2.0)));

    if (u.logRaw < 0.5 && u.lutIntensity > 0.0) {
        rgb = mix(rgb, applyLut(rgb, lut, u), u.lutIntensity);
    }

    rgb += u.sharpen * 2.0 * detail;

    if (u.vignette > 0.001) {
        float2 d = (uv - 0.5) * float2(float(w) / float(h), 1.0);
        float r = length(d) / length(float2(float(w) / float(h), 1.0) * 0.5);
        rgb *= 1.0 - u.vignette * smoothstep(0.35, 1.0, r);
    }

    outTex.write(float4(saturate(rgb), 1.0), gid);
}

// Background blur: blend the graded frame with a blurred copy wherever the
// person mask says "not a person".
kernel void compositeBlur(texture2d<float, access::read> sharpTex [[texture(0)]],
                          texture2d<float, access::read> blurTex [[texture(1)]],
                          texture2d<float, access::sample> maskTex [[texture(2)]],
                          texture2d<float, access::write> outTex [[texture(3)]],
                          uint2 gid [[thread_position_in_grid]])
{
    uint w = outTex.get_width();
    uint h = outTex.get_height();
    if (gid.x >= w || gid.y >= h) return;
    constexpr sampler ms(filter::linear, address::clamp_to_edge, coord::normalized);
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float person = smoothstep(0.25, 0.75, maskTex.sample(ms, uv).r);
    float4 sharp = sharpTex.read(gid);
    float4 blurred = blurTex.read(gid);
    outTex.write(mix(blurred, sharp, person), gid);
}
