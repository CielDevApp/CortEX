#include <metal_stdlib>
using namespace metal;

struct FilterParams {
    float sharpenStrength;    // 0.0-1.0
    float sharpenRadius;      // pixels
    float toneCurveStrength;  // 0.0-1.0
    float hdrShadowAmount;    // 0.0-1.0
    float hdrHighlightAmount; // 0.0-1.0
    float vibranceAmount;     // 0.0-1.0
    float localToneStrength;  // 0.0-1.0
    uint  enableSharpen;      // 0 or 1
    uint  enableToneCurve;    // 0 or 1
    uint  enableHDR;          // 0 or 1
    uint  enableVibrance;     // 0 or 1
    uint  enableLocalTone;    // 0 or 1
    uint  isGrayscale;        // 0 or 1
    uint  width;
    uint  height;
};

// RGB→輝度
inline float luminance(float3 c) {
    return dot(c, float3(0.299, 0.587, 0.114));
}

// S字トーンカーブ
inline float toneCurve(float x, float strength) {
    // Hermite S-curve: 3t^2 - 2t^3, blended with linear
    float s = x * x * (3.0 - 2.0 * x);
    return mix(x, s, strength);
}

// Vibrance（彩度の低い部分をより強く補正）
inline float3 applyVibrance(float3 c, float amount) {
    float lum = luminance(c);
    float mx = max(c.r, max(c.g, c.b));
    float mn = min(c.r, min(c.g, c.b));
    float sat = (mx > 0.0) ? (mx - mn) / mx : 0.0;
    // 低彩度ほど強く効く
    float boost = amount * (1.0 - sat);
    return mix(float3(lum), c, 1.0 + boost);
}

// HDR: 暗部持ち上げ+ハイライト圧縮
inline float3 applyHDR(float3 c, float shadowAmt, float highlightAmt) {
    float lum = luminance(c);
    // 暗部: 暗いピクセルほどgamma補正で持ち上げ
    float shadowBoost = (1.0 - lum) * shadowAmt;
    float3 lifted = c + shadowBoost * (1.0 - c) * 0.3;
    // ハイライト: 明るいピクセルを圧縮
    float highlightCompress = lum * highlightAmt;
    float3 result = lifted * (1.0 - highlightCompress * 0.1);
    return clamp(result, 0.0, 1.0);
}

kernel void imageEnhance(
    texture2d<float, access::read> input [[texture(0)]],
    texture2d<float, access::write> output [[texture(1)]],
    constant FilterParams& params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    if (gid.x >= params.width || gid.y >= params.height) return;

    float4 pixel = input.read(gid);
    float3 color = pixel.rgb;

    // 1. シャープネス（Unsharp Mask: 周辺ピクセルとの差を強調）
    if (params.enableSharpen) {
        float3 blur = float3(0.0);
        int r = max(1, int(params.sharpenRadius));
        float count = 0.0;
        for (int dy = -r; dy <= r; dy++) {
            for (int dx = -r; dx <= r; dx++) {
                uint2 pos = uint2(
                    clamp(int(gid.x) + dx, 0, int(params.width) - 1),
                    clamp(int(gid.y) + dy, 0, int(params.height) - 1)
                );
                blur += input.read(pos).rgb;
                count += 1.0;
            }
        }
        blur /= count;
        float3 detail = color - blur;
        color = color + detail * params.sharpenStrength;
        color = clamp(color, 0.0, 1.0);
    }

    // 2. HDR風補正（暗部/ハイライト）
    if (params.enableHDR) {
        if (params.isGrayscale) {
            // グレースケール: 控えめ
            color = applyHDR(color, params.hdrShadowAmount * 0.5, params.hdrHighlightAmount);
        } else {
            color = applyHDR(color, params.hdrShadowAmount, params.hdrHighlightAmount);
        }
    }

    // 3. 彩度（カラーのみ）
    if (params.enableVibrance && !params.isGrayscale) {
        color = applyVibrance(color, params.vibranceAmount);
    }

    // 4. S字トーンカーブ
    if (params.enableToneCurve) {
        float strength = params.isGrayscale ? params.toneCurveStrength * 0.7 : params.toneCurveStrength;
        color.r = toneCurve(color.r, strength);
        color.g = toneCurve(color.g, strength);
        color.b = toneCurve(color.b, strength);
    }

    // 5. LocalToneMap相当（局所コントラスト: 周辺平均との差を強調）
    if (params.enableLocalTone && !params.isGrayscale) {
        // 広めのカーネルで局所平均を取得
        float3 localAvg = float3(0.0);
        int lr = 4;
        float lcount = 0.0;
        for (int dy = -lr; dy <= lr; dy += 2) {
            for (int dx = -lr; dx <= lr; dx += 2) {
                uint2 pos = uint2(
                    clamp(int(gid.x) + dx, 0, int(params.width) - 1),
                    clamp(int(gid.y) + dy, 0, int(params.height) - 1)
                );
                localAvg += input.read(pos).rgb;
                lcount += 1.0;
            }
        }
        localAvg /= lcount;
        float3 localDetail = color - localAvg;
        color = color + localDetail * params.localToneStrength * 0.3;
        color = clamp(color, 0.0, 1.0);
    }

    output.write(float4(color, pixel.a), gid);
}
