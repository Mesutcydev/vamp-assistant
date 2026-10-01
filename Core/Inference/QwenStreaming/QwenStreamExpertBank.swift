import Foundation
import Metal
import MLX

/// Fixed, contiguous expert slots shared by CPU writes and Metal reads.
/// The generation gate owns this bank. A commit is permitted only after the
/// previous gather has completed MLX.eval; no lazy graph may escape the pool.
/// MLX array handles are never indexed/mutated/replaced after allocation. Only
/// their shared backing bytes change, between fully evaluated forwards.
final class QwenStreamExpertBank {
    struct Component {
        let array: MLXArray
        let buffer: any MTLBuffer
        let stride: Int
    }
    let slots: Int
    let components: [String: Component]

    init(slots: Int, locations: [String: QwenStreamTensorLocation]) throws {
        guard slots > 0, let device = MTLCreateSystemDefaultDevice(), device.hasUnifiedMemory else {
            throw EngineError.loadFailed("Reusable Qwen expert slots require shared Metal memory.")
        }
        self.slots = slots
        var components = [String: Component]()
        for (name, location) in locations.sorted(by: { $0.key < $1.key }) {
            guard location.byteCount > 0, location.byteCount <= UInt64(Int.max / slots) else {
                throw EngineError.loadFailed("Invalid Qwen expert slot size.")
            }
            let array = MLXArray.zeros([slots] + location.shape, dtype: try QwenStreamArrays.dtype(location)).contiguous()
            MLX.eval(array)
            guard array.nbytes == slots * Int(location.byteCount),
                  let buffer = array.asMTLBuffer(device: device, noCopy: true),
                  buffer.storageMode == .shared, buffer.length >= array.nbytes,
                  array.asData(access: .noCopy).data.withUnsafeBytes({
                      $0.baseAddress == UnsafeRawPointer(buffer.contents())
                  }) else {
                throw EngineError.loadFailed("Could not allocate shared Qwen expert slots.")
            }
            components[name] = Component(array: array, buffer: buffer, stride: Int(location.byteCount))
        }
        self.components = components
    }

    func commit(_ payloads: [String: Data], to slot: Int) throws {
        guard (0..<slots).contains(slot), payloads.count == components.count,
              components.allSatisfy({ payloads[$0.key]?.count == $0.value.stride }) else {
            throw EngineError.loadFailed("Invalid Qwen expert slot payload.")
        }
        for (name, component) in components {
            payloads[name]!.withUnsafeBytes { bytes in
                component.buffer.contents().advanced(by: slot * component.stride)
                    .copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
            }
        }
    }
}
