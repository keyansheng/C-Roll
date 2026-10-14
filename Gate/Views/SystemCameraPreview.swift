import AVFoundation
import SwiftUI
import UIKit

/// Hosts a controller-owned layer. This view never changes the capture graph.
struct SystemCameraPreview: UIViewRepresentable {
    let previewLayer: AVCaptureVideoPreviewLayer

    func makeUIView(context: Context) -> PreviewSurface {
        PreviewSurface(previewLayer: previewLayer)
    }

    func updateUIView(_ uiView: PreviewSurface, context: Context) {
        uiView.setNeedsLayout()
    }

    static func dismantleUIView(_ uiView: PreviewSurface, coordinator: ()) {
        uiView.previewLayer.removeFromSuperlayer()
    }
}

final class PreviewSurface: UIView {
    let previewLayer: AVCaptureVideoPreviewLayer

    init(previewLayer: AVCaptureVideoPreviewLayer) {
        self.previewLayer = previewLayer
        super.init(frame: .zero)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { fatalError("Use init(previewLayer:)") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        previewLayer.frame = bounds
        CATransaction.commit()
    }
}
