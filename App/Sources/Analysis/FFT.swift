import Foundation
import Accelerate

/// Radix-2 real FFT wrapper around vDSP. Not thread-safe; create one per thread.
final class FFT {
    let size: Int
    private let log2n: vDSP_Length
    private let setup: FFTSetup
    private var realBuffer: [Float]
    private var imagBuffer: [Float]
    private var window: [Float]

    init(size: Int) {
        precondition(size > 0 && (size & (size - 1)) == 0, "FFT size must be a power of two")
        self.size = size
        self.log2n = vDSP_Length(log2(Double(size)).rounded())
        self.setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        self.realBuffer = [Float](repeating: 0, count: size / 2)
        self.imagBuffer = [Float](repeating: 0, count: size / 2)
        self.window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Magnitude spectrum (size/2 bins) of a windowed frame. `frame` must contain `size` samples.
    func magnitudes(of frame: [Float], into output: inout [Float]) {
        precondition(frame.count >= size)
        precondition(output.count >= size / 2)
        var windowed = [Float](repeating: 0, count: size)
        frame.withUnsafeBufferPointer { src in
            vDSP_vmul(src.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(size))
        }
        realBuffer.withUnsafeMutableBufferPointer { realPtr in
            imagBuffer.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!, imagp: imagPtr.baseAddress!)
                windowed.withUnsafeBytes { raw in
                    let complexPtr = raw.baseAddress!.assumingMemoryBound(to: DSPComplex.self)
                    vDSP_ctoz(complexPtr, 2, &split, 1, vDSP_Length(size / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                // Zero the Nyquist term packed into imagp[0] so bin 0 is pure DC.
                imagPtr.baseAddress!.pointee = 0
                output.withUnsafeMutableBufferPointer { out in
                    vDSP_zvabs(&split, 1, out.baseAddress!, 1, vDSP_Length(size / 2))
                }
            }
        }
    }
}
