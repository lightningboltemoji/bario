// A native process drawing a bubble with Metal, composited by bario with no copy at all
// (DESIGN.md section 9.3). It hands a running bar a pair of IOSurfaces under a name, then each
// frame draws a moving wave into the one not showing and says so with `frame`.
//
//   item "wave" module="data" {
//     content {
//       raster width=80 height=20 {
//         source surface="wave"
//       }
//     }
//   }
//
//   swift run surface-example wave 30
//
// When it exits, its surfaces go with it and the node shows nothing.
import BarioKit
import Foundation
import Metal

let arguments = CommandLine.arguments.dropFirst()
let name = arguments.first ?? "wave"
let seconds = arguments.dropFirst().first.flatMap(Double.init) ?? 10

let shaders = """
#include <metal_stdlib>
using namespace metal;

struct Out { float4 position [[position]]; float2 uv; };

vertex Out vertex_main(uint id [[vertex_id]]) {
    float2 corners[3] = { float2(-1, -1), float2(3, -1), float2(-1, 3) };
    Out out;
    out.position = float4(corners[id], 0, 1);
    out.uv = corners[id] * 0.5 + 0.5;
    return out;
}

fragment float4 fragment_main(Out in [[stage_in]], constant float &time [[buffer(0)]]) {
    float wave = 0.5 + 0.32 * sin(in.uv.x * 12.0 - time * 4.0) * sin(time * 0.7 + in.uv.x * 3.0);
    float line = smoothstep(0.09, 0.0, abs(in.uv.y - wave));
    float3 colour = mix(float3(0.2, 0.8, 1.0), float3(1.0, 0.4, 0.8), in.uv.x);
    return float4(colour * line, line);
}
"""

guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
    fatalError("no Metal device")
}
let library = try device.makeLibrary(source: shaders, options: nil)
let pipelineDescriptor = MTLRenderPipelineDescriptor()
pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertex_main")
pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragment_main")
pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)

// 80 × 20 points at 2x.
let producer = try SurfaceProducer(name: name, width: 160, height: 40)
let textures = producer.surfaces.map { surface -> MTLTexture in
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: surface.width,
                                                              height: surface.height, mipmapped: false)
    descriptor.usage = [.renderTarget]
    descriptor.storageMode = .shared
    return device.makeTexture(descriptor: descriptor, iosurface: surface, plane: 0)!
}

print("drawing \(name) for \(seconds)s; show it with a raster node whose source is {\"surface\": \"\(name)\"}")
let start = Date()
while Date().timeIntervalSince(start) < seconds {
    var time = Float(Date().timeIntervalSince(start))
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = textures[producer.nextIndex]
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    let buffer = queue.makeCommandBuffer()!
    let encoder = buffer.makeRenderCommandEncoder(descriptor: pass)!
    encoder.setRenderPipelineState(pipeline)
    encoder.setFragmentBytes(&time, length: MemoryLayout<Float>.size, index: 0)
    encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
    encoder.endEncoding()
    buffer.commit()
    buffer.waitUntilCompleted()
    try producer.present()
    Thread.sleep(forTimeInterval: 1.0 / 60)
}
