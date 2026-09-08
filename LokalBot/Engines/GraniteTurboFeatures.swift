import Foundation
import MLX

/// Granite 5's 16 kHz, HTK log-mel + delta frontend. The window, reflection,
/// float64-built filterbank and frame stacking match mlx-audio's reference.
/// See THIRD_PARTY_NOTICES.md for the upstream implementation and MIT notice.
enum GraniteTurboFeatures {
    static func compute(_ samples: [Float]) -> MLXArray {
        // SpeechActivity normally supplies much longer spans. Padding tiny
        // clips also keeps both encoder subsampling layers well defined.
        let minimumSamples = 1_280
        var waveform = samples
        if waveform.count < minimumSamples {
            waveform += Array(repeating: 0, count: minimumSamples - waveform.count)
        }
        let frameCount = 2 * ((waveform.count / 160 + 1) / 2)
        let needed = (frameCount - 1) * 160 + 1
        if waveform.count < needed {
            waveform += Array(repeating: 0, count: needed - waveform.count)
        }
        let prefix = Array(waveform[1...256].reversed())
        let suffix = Array(waveform[(waveform.count - 257)..<(waveform.count - 1)].reversed())
        let paddedWave = MLXArray(prefix + waveform + suffix)
        let frames = asStrided(paddedWave, [frameCount, 512], strides: [160, 1])
        let spectrum = MLXFFT.rfft(frames * window())
        let power = MLX.abs(spectrum).square()
        var logMel = MLX.log10(MLX.maximum(matmul(power, melFilters()), 1e-10))
        logMel = MLX.maximum(logMel, logMel.max() - 8) / 4 + 1
        let replicated = concatenated([logMel[0..<1], logMel, logMel[(frameCount - 1)..<frameCount]])
        let delta = (replicated[2..<(frameCount + 2)] - replicated[0..<frameCount]) / 2
        return concatenated([logMel, delta], axis: -1).reshaped([1, frameCount / 2, 320])
    }

    private static func window() -> MLXArray {
        // dsp.hanning constructs its coefficients in CPU float64, then casts
        // to float32. Generating the cosine on the GPU subtly changes CTC IDs.
        let hann = MLXArray((0..<400).map { Float(0.5 * (1 - cos(2 * Double.pi * Double($0) / 400))) })
        return concatenated([MLXArray.zeros([56]), hann, MLXArray.zeros([56])])
    }

    private static func melFilters() -> MLXArray {
        let melMaximum = 2595 * log10(1 + 8_000.0 / 700)
        let points = (0..<82).map { index in
            700 * (pow(10, (Double(index) * melMaximum / 81) / 2595) - 1)
        }
        var weights = [Float]()
        weights.reserveCapacity(257 * 80)
        for bin in 0..<257 {
            let frequency = Double(bin) * 8_000 / 256
            for mel in 0..<80 {
                let rising = (frequency - points[mel]) / (points[mel + 1] - points[mel])
                let falling = (points[mel + 2] - frequency) / (points[mel + 2] - points[mel + 1])
                weights.append(Float(max(0, min(rising, falling))))
            }
        }
        return MLXArray(weights, [257, 80])
    }
}
