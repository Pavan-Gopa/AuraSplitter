import Metal
import MetalKit
import SwiftUI

struct MetalSpectrogramView: NSViewRepresentable {
    let sourceID: String
    let spectrogram: SpectrogramData
    let viewport: AudioPreviewViewport
    let minDb: Double
    let maxDb: Double

    func makeCoordinator() -> MetalSpectrogramCoordinator {
        MetalSpectrogramCoordinator()
    }

    func makeNSView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        view.colorPixelFormat = .bgra8Unorm
        view.framebufferOnly = true
        view.enableSetNeedsDisplay = true
        view.isPaused = true
        view.preferredFramesPerSecond = 60
        view.clearColor = MTLClearColor(red: 0.015, green: 0.018, blue: 0.026, alpha: 1)
        view.delegate = context.coordinator
        context.coordinator.configureIfNeeded(for: view)
        return view
    }

    func updateNSView(_ nsView: MTKView, context: Context) {
        context.coordinator.configureIfNeeded(for: nsView)
        context.coordinator.update(
            sourceID: sourceID,
            spectrogram: spectrogram,
            viewport: viewport,
            minDb: minDb,
            maxDb: maxDb
        )
        nsView.draw()
    }
}

final class MetalSpectrogramCoordinator: NSObject, MTKViewDelegate {
    private struct TextureSignature: Equatable {
        let sourceID: String
        let width: Int
        let height: Int
        let valueCount: Int
        let fingerprint: Double
    }

    private struct Uniforms {
        var start: Float
        var span: Float
        var minDb: Float
        var maxDb: Float
    }

    private var device: MTLDevice?
    private var commandQueue: MTLCommandQueue?
    private var pipelineState: MTLRenderPipelineState?
    private var spectrogramTexture: MTLTexture?
    private var textureSignature: TextureSignature?
    private var uniforms = Uniforms(start: 0, span: 1, minDb: -120.0, maxDb: -40.0)

    func configureIfNeeded(for view: MTKView) {
        guard pipelineState == nil, let device = view.device else { return }
        self.device = device
        commandQueue = device.makeCommandQueue()

        do {
            let library = try device.makeLibrary(source: MetalSpectrogramShader.source, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "spectrogram_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "spectrogram_fragment")
            descriptor.colorAttachments[0].pixelFormat = view.colorPixelFormat
            pipelineState = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            NSLog("AuraSplitter Metal spectrogram shader failed: \(error)")
        }
    }

    func update(sourceID: String, spectrogram: SpectrogramData, viewport: AudioPreviewViewport, minDb: Double, maxDb: Double) {
        uniforms = Uniforms(
            start: Float(viewport.start),
            span: Float(viewport.span),
            minDb: Float(minDb),
            maxDb: Float(maxDb)
        )

        let signature = TextureSignature(
            sourceID: sourceID,
            width: spectrogram.columns,
            height: spectrogram.bins,
            valueCount: spectrogram.values.count,
            fingerprint: Self.fingerprint(for: spectrogram.values)
        )
        guard signature != textureSignature else { return }
        textureSignature = signature
        uploadTexture(from: spectrogram)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pipelineState,
              let commandQueue,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable
        else { return }

        descriptor.colorAttachments[0].clearColor = view.clearColor
        descriptor.colorAttachments[0].loadAction = .clear
        descriptor.colorAttachments[0].storeAction = .store

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else { return }
        encoder.setRenderPipelineState(pipelineState)
        guard let spectrogramTexture else {
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.commit()
            return
        }
        encoder.setFragmentTexture(spectrogramTexture, index: 0)
        var nextUniforms = uniforms
        encoder.setFragmentBytes(&nextUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
        encoder.endEncoding()

        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    private func uploadTexture(from spectrogram: SpectrogramData) {
        guard let device, let payload = MetalSpectrogramTexturePayload(spectrogram: spectrogram) else {
            spectrogramTexture = nil
            return
        }

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: payload.width,
            height: payload.height,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .shared

        guard let texture = device.makeTexture(descriptor: descriptor) else {
            spectrogramTexture = nil
            return
        }

        payload.floats.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            texture.replace(
                region: MTLRegionMake2D(0, 0, payload.width, payload.height),
                mipmapLevel: 0,
                withBytes: baseAddress,
                bytesPerRow: payload.width * MemoryLayout<Float>.stride
            )
        }
        spectrogramTexture = texture
    }

    private static func fingerprint(for values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let middle = values[values.count / 2]
        return (values.first ?? 0) + middle * 3 + (values.last ?? 0) * 7
    }
}
