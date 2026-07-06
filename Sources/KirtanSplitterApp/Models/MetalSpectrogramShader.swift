import Foundation

enum MetalSpectrogramShader {
    static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertexOut {
        float4 position [[position]];
        float2 uv;
    };

    struct Uniforms {
        float start;
        float span;
        float gain;
        float pad;
    };

    vertex VertexOut spectrogram_vertex(uint vertexID [[vertex_id]]) {
        constexpr float2 positions[6] = {
            float2(-1.0, -1.0),
            float2( 1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0, -1.0),
            float2( 1.0,  1.0),
            float2(-1.0,  1.0)
        };
        constexpr float2 uvs[6] = {
            float2(0.0, 1.0),
            float2(1.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 1.0),
            float2(1.0, 0.0),
            float2(0.0, 0.0)
        };

        VertexOut out;
        out.position = float4(positions[vertexID], 0.0, 1.0);
        out.uv = uvs[vertexID];
        return out;
    }

    static float3 spectrogramColor(float rawValue) {
        float value = pow(clamp(rawValue, 0.0, 1.0), 0.82);
        if (value < 0.22) {
            float t = value / 0.22;
            return float3(
                0.01 + 0.03 * t,
                0.018 + 0.07 * t,
                0.05 + 0.28 * t
            );
        }
        if (value < 0.58) {
            float t = (value - 0.22) / 0.36;
            return float3(
                0.04 + 0.72 * t,
                0.09 + 0.30 * t,
                0.33 - 0.20 * t
            );
        }
        float t = (value - 0.58) / 0.42;
        return float3(
            0.76 + 0.24 * t,
            0.39 + 0.40 * t,
            0.13 + 0.03 * t
        );
    }

    fragment float4 spectrogram_fragment(
        VertexOut in [[stage_in]],
        texture2d<float, access::sample> spectrogram [[texture(0)]],
        constant Uniforms& uniforms [[buffer(0)]]
    ) {
        constexpr sampler linearSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::linear,
            mip_filter::none
        );

        float sourceX = clamp(uniforms.start + in.uv.x * uniforms.span, 0.0, 1.0);
        float sourceY = clamp(1.0 - in.uv.y, 0.0, 1.0);
        float value = spectrogram.sample(linearSampler, float2(sourceX, sourceY)).r * uniforms.gain;
        return float4(spectrogramColor(value), 1.0);
    }
    """
}
