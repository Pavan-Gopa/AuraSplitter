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
        float minDb;
        float maxDb;
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
        float value = pow(clamp(rawValue, 0.0, 1.0), 0.90);
        if (value < 0.15) {
            float t = value / 0.15;
            return mix(float3(0.0, 0.0, 0.0), float3(0.02, 0.02, 0.12), t);
        } else if (value < 0.35) {
            float t = (value - 0.15) / 0.20;
            return mix(float3(0.02, 0.02, 0.12), float3(0.18, 0.02, 0.22), t);
        } else if (value < 0.60) {
            float t = (value - 0.35) / 0.25;
            return mix(float3(0.18, 0.02, 0.22), float3(0.72, 0.22, 0.02), t);
        } else if (value < 0.85) {
            float t = (value - 0.60) / 0.25;
            return mix(float3(0.72, 0.22, 0.02), float3(0.98, 0.68, 0.02), t);
        } else {
            float t = (value - 0.85) / 0.15;
            return mix(float3(0.98, 0.68, 0.02), float3(1.0, 1.0, 0.85), t);
        }
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
        float rawDb = spectrogram.sample(linearSampler, float2(sourceX, sourceY)).r;
        float norm = clamp((rawDb - uniforms.minDb) / (uniforms.maxDb - uniforms.minDb), 0.0, 1.0);
        return float4(spectrogramColor(norm), 1.0);
    }
    """
}
