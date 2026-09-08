import Foundation
import MLX

/// Native MLX inference for the pinned IBM Granite Speech 5.0 TurboCTC model.
/// Adapted from mlx-audio's MIT-licensed granite_speech5_ctc implementation;
/// see THIRD_PARTY_NOTICES.md. No Python process or remote inference is used.
/// Own this instance on one actor: MLX arrays and evaluation are serialized.
final class GraniteTurboModel {
    private let weights: [String: MLXArray]
    private let tokenizer: GraniteTurboTokenizer

    init(directory: URL) throws {
        var loaded = try MLX.loadArrays(url: directory.appendingPathComponent("model.safetensors"))
        for (name, shape) in Self.expectedShapes {
            guard let value = loaded[name], value.shape == shape else {
                throw GraniteTurboError.invalidModel("Missing or incompatible tensor: \(name)")
            }
            if name.hasSuffix("conv.depthwise_conv.weight") {
                loaded[name] = value.transposed(0, 2, 1)
            }
        }
        weights = loaded
        tokenizer = try GraniteTurboTokenizer(data: Data(contentsOf: directory.appendingPathComponent("tokenizer.json")))
        MLX.eval(Array(weights.values))
    }

    func transcribe(_ samples: [Float]) throws -> String {
        guard !samples.isEmpty else { return "" }
        try Task.checkCancellation()
        let features = GraniteTurboFeatures.compute(samples)
        let ids = try tokenIDs(features: features)
        return try tokenizer.decode(ids)
    }

    /// Kept internal for numerical parity checks against the reference engine.
    func tokenIDs(features: MLXArray) throws -> [Int32] {
        var hidden = linear(features.asType(weight("input_linear.weight").dtype), "input_linear")
        let positions = MLXArray(0..<128)
        let distances = positions.expandedDimensions(axis: 1) - positions.expandedDimensions(axis: 0) + 512
        for index in 0..<16 {
            try Task.checkCancellation()
            let base = "layers.\(index)."
            hidden = hidden + 0.5 * feedForward(norm(hidden, base + "norm_feed_forward1"), base + "feed_forward1")
            hidden = hidden + attention(norm(hidden, base + "norm_self_att"), base + "self_attn", distances)
            let conv = convolution(norm(hidden, base + "norm_conv"), base + "conv", stride: index < 2 ? 2 : 1)
            if index < 2 {
                let half = hidden.dim(1) / 2
                let residual = hidden[0..., 0..<(half * 2)].reshaped([1, half, 2, 1024]).mean(axis: 2)
                hidden = residual + conv[0..., 0..<half]
            } else {
                hidden = hidden + conv
            }
            hidden = hidden + 0.5 * feedForward(norm(hidden, base + "norm_feed_forward2"), base + "feed_forward2")
            hidden = norm(hidden, base + "norm_out")
            if index == 7 {
                let probabilities = softmax(linear(hidden, "out").asType(.float32), axis: -1).asType(hidden.dtype)
                hidden = hidden + linear(probabilities, "out_mid")
            }
            // Bound lazy graph memory and give cancellation a chance between
            // conformer blocks, including when processing long meeting spans.
            MLX.eval(hidden)
        }
        let ids = linear(hidden, "out")[0].argMax(axis: -1).asType(.int32)
        MLX.eval(ids)
        return ids.asArray(Int32.self)
    }

    private func weight(_ name: String) -> MLXArray {
        // All required keys and shapes are checked once, before inference.
        weights["encoder." + name]!
    }

    private func linear(_ input: MLXArray, _ name: String, bias: Bool = true) -> MLXArray {
        let transposed = weight(name + ".weight").T
        return bias ? addMM(weight(name + ".bias"), input, transposed) : matmul(input, transposed)
    }

    private func norm(_ input: MLXArray, _ name: String) -> MLXArray {
        MLXFast.layerNorm(input, weight: weight(name + ".weight"), bias: weight(name + ".bias"), eps: 1e-5)
    }

    private func feedForward(_ input: MLXArray, _ name: String) -> MLXArray {
        let projected = linear(input, name + ".linear1")
        return linear(projected * sigmoid(projected), name + ".linear2")
    }

    private func attention(_ input: MLXArray, _ name: String, _ distances: MLXArray) -> MLXArray {
        let length = input.dim(1)
        let paddedLength = ((length + 127) / 128) * 128
        let paddedInput = padded(input, widths: [IntOrPair(0), IntOrPair((0, paddedLength - length)), IntOrPair(0)])
        let shape = [1, paddedLength / 128, 128, 8, 128]
        func heads(_ projection: String) -> MLXArray {
            linear(paddedInput, name + projection, bias: false).reshaped(shape).transposed(0, 1, 3, 2, 4)
        }
        let query = heads(".q_proj")
        let key = heads(".k_proj")
        let value = heads(".v_proj")
        let scale = Float(1 / sqrt(128.0))
        let relative = weight(name + ".rel_pos_emb.weight").take(distances, axis: 0) * scale
        var positionBias = einsum("bmhcd,crd->bmhcr", query, relative)
        if paddedLength != length {
            let mask = (MLXArray(0..<paddedLength) .< length).reshaped([1, paddedLength / 128, 1, 1, 128])
            positionBias = MLX.where(mask, positionBias, MLXArray(-Float.greatestFiniteMagnitude).asType(positionBias.dtype))
        }
        let logits = matmul(query, key.transposed(0, 1, 2, 4, 3)) * scale + positionBias
        let probabilities = softmax(logits.asType(.float32), axis: -1).asType(query.dtype)
        let output = matmul(probabilities, value).transposed(0, 1, 3, 2, 4).reshaped([1, paddedLength, 1024])
        return linear(output[0..., 0..<length], name + ".o_proj")
    }

    private func convolution(_ input: MLXArray, _ name: String, stride: Int) -> MLXArray {
        let projected = linear(input, name + ".pointwise_lin1")
        let halves = split(projected, parts: 2, axis: -1)
        let gated = halves[0] * sigmoid(halves[1])
        let convolved = conv1d(gated, weight(name + ".depthwise_conv.weight"), stride: stride, padding: 3, groups: 2048)
        let floatInput = convolved.asType(.float32)
        let mean = weight(name + ".norm.running_mean").asType(.float32)
        let variance = weight(name + ".norm.running_var").asType(.float32)
        let scale = weight(name + ".norm.weight").asType(.float32)
        let bias = weight(name + ".norm.bias").asType(.float32)
        let normalized = ((floatInput - mean) * rsqrt(variance + 1e-5) * scale + bias).asType(convolved.dtype)
        return linear(normalized * sigmoid(normalized), name + ".pointwise_lin2")
    }

    private static var expectedShapes: [String: [Int]] {
        var shapes: [String: [Int]] = [:]
        func linear(_ name: String, _ input: Int, _ output: Int, bias: Bool = true) {
            shapes["encoder." + name + ".weight"] = [output, input]
            if bias { shapes["encoder." + name + ".bias"] = [output] }
        }
        linear("input_linear", 320, 1024)
        linear("out", 1024, 16384)
        linear("out_mid", 16384, 1024)
        for index in 0..<16 {
            let base = "layers.\(index)."
            for ff in ["feed_forward1", "feed_forward2"] {
                linear(base + ff + ".linear1", 1024, 4096)
                linear(base + ff + ".linear2", 4096, 1024)
            }
            for projection in ["q_proj", "k_proj", "v_proj"] {
                linear(base + "self_attn." + projection, 1024, 1024, bias: false)
            }
            linear(base + "self_attn.o_proj", 1024, 1024)
            shapes["encoder." + base + "self_attn.rel_pos_emb.weight"] = [1025, 128]
            linear(base + "conv.pointwise_lin1", 1024, 4096)
            linear(base + "conv.pointwise_lin2", 2048, 1024)
            shapes["encoder." + base + "conv.depthwise_conv.weight"] = [2048, 1, 7]
            for suffix in ["weight", "bias", "running_mean", "running_var"] {
                shapes["encoder." + base + "conv.norm." + suffix] = [2048]
            }
            for norm in ["norm_feed_forward1", "norm_self_att", "norm_conv", "norm_feed_forward2", "norm_out"] {
                shapes["encoder." + base + norm + ".weight"] = [1024]
                shapes["encoder." + base + norm + ".bias"] = [1024]
            }
        }
        return shapes
    }
}
