#include <metal_stdlib>
#include <CoreImage/CoreImage.h>

using namespace metal;

extern "C" { namespace coreimage {
    float4 gateLog(sample_t s) {
        return float4(log2(1.0f + 15.0f * max(s.rgb, float3(0.0f))) / 4.0f, 1.0f);
    }

    float4 rec709(sample_t s) {
        float3 x = max(s.rgb, float3(0.0f));
        float3 low = 4.5f * x;
        float3 high = 1.099f * pow(x, float3(0.45f)) - 0.099f;
        return float4(clamp(mix(low, high, step(float3(0.018f), x)), 0.0f, 1.0f), 1.0f);
    }

    float4 exposureAssist(sample_t s, float mode, destination dest) {
        float y = dot(s.rgb, float3(0.2126f, 0.7152f, 0.0722f));
        if (mode < 1.5f) {
            float stripe = step(0.5f, fract((dest.coord().x + dest.coord().y) / 12.0f));
            return y > 0.95f ? float4(mix(float3(0.06f), float3(1.0f, 0.85f, 0.25f), stripe), 1.0f) : float4(s);
        }
        float3 c = float3(y);
        if (y < 0.03f) c = float3(0.35f, 0.12f, 0.6f);
        else if (y < 0.10f) c = float3(0.1f, 0.3f, 0.85f);
        else if (y > 0.95f) c = float3(1.0f, 0.1f, 0.12f);
        else if (y > 0.80f) c = float3(1.0f, 0.8f, 0.1f);
        else if (y > 0.40f && y < 0.45f) c = float3(0.15f, 0.8f, 0.45f);
        else if (y > 0.55f && y < 0.65f) c = float3(0.95f, 0.5f, 0.6f);
        return float4(c, 1.0f);
    }
} }
