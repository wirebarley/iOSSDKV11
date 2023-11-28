//
//  FaceLivenessCameraController.swift
//  SampleApp
//
//  Created by Tapas Behera on 7/9/18.
//  Copyright © 2018 com.acuant. All rights reserved.
//

import Foundation
import UIKit
import AVFoundation
import AcuantImagePreparation

public class FaceCaptureController: UIViewController {
    fileprivate enum UI {
        static let extraHeight: CGFloat = 40
        static let maxLines: Int = 3
        
        enum Font {
            static let defaultSize: CGFloat = 25
        }
    }

    public var callback: ((FaceCaptureResult?) -> Void)?
    public var options: FaceCameraOptions?

    private var overlayView: UIView!
    private var captureSession: AcuantFaceCaptureSession!
    private var videoPreviewLayer: AVCaptureVideoPreviewLayer!
    private var faceOval: CAShapeLayer?
    private var topOverlayLayer: CAShapeLayer!
    private var imageLayer: ImagePlaceholderLayer?
    private var messageLayer: VerticallyTextLayer!
    private var cornerlayer: FaceCameraCornerOverlayView!
    private var alertView: AlertView?

    private var currentFrameTime = -1.0
    private var currentTimer: Double?
    private var backButton: UIButton!
    private var isNavigationHidden = false
    private let frameThrottleDuration = 0.2
    private var isCaptured = false

    override public func viewDidLoad() {
        super.viewDidLoad()
    }

    override public func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        self.isNavigationHidden = self.navigationController?.isNavigationBarHidden ?? false
        self.navigationController?.setNavigationBarHidden(true, animated: false)
        self.options = self.options ?? FaceCameraOptions()
        addCaptureSessionObservers()
    }

    override public func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startCameraView()
        handleRotateToPortraitAlertIfPhone()
    }

    override public var prefersStatusBarHidden: Bool {
        return true
    }

    override public func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)

        captureSession.stop()
        NotificationCenter.default.removeObserver(self)
        navigationController?.setNavigationBarHidden(self.isNavigationHidden, animated: false)
    }

    public override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)

        coordinator.animate(alongsideTransition: { [weak self] context in
            guard let self = self else { return }

            let newFrame = CGRect(origin: self.view.frame.origin, size: size)
            self.rotateCameraPreview(to: self.view.window?.faceCaptureInterfaceOrientation, frame: newFrame)
            self.handleRotateToPortraitAlertIfPhone()
        })
    }

    public override func viewDidLayoutSubviews() {
        alertView?.frame = view.frame
    }

    private func addCaptureSessionObservers() {
        NotificationCenter.default.addObserver(forName: .AVCaptureSessionWasInterrupted,
                                               object: captureSession,
                                               queue: .main) { [weak self] _ in
            guard let self = self, self.alertView == nil else { return }

            let alertView = AlertView(frame: self.view.bounds, text: NSLocalizedString("acuant_face_camera_paused", comment: ""))
            self.view.addSubview(alertView)
            self.alertView = alertView
        }

        NotificationCenter.default.addObserver(forName: .AVCaptureSessionInterruptionEnded,
                                               object: captureSession,
                                               queue: .main) { [weak self] _ in
            guard let self = self else { return }

            self.alertView?.removeFromSuperview()
            self.alertView = nil
        }
    }

    private func handleRotateToPortraitAlertIfPhone() {
        guard
            UIDevice.current.userInterfaceIdiom == .phone,
            let interfaceOrientation = self.view.window?.faceCaptureInterfaceOrientation
        else {
            return
        }

        if interfaceOrientation.isLandscape {
            self.alertView = AlertView(frame: self.view.frame,
                                       text: NSLocalizedString("acuant_face_camera_rotate_portrait", comment: ""))
            self.view.addSubview(self.alertView!)
            self.captureSession.stop()
        } else if !captureSession.isRunning {
            self.alertView?.removeFromSuperview()
            self.captureSession.resume()
        }
    }

    func startCameraView() {
        guard let frontCameraDevice = AVCaptureDevice.default(.builtInWideAngleCamera, for: AVMediaType.video, position: .front) else {
            navigationController?.popViewController(animated: true)
            return
        }

        captureSession = AcuantFaceCaptureSession(captureDevice: frontCameraDevice) { [weak self] faceResult in
            if self?.shouldSkipFrame(faceType: faceResult.state) ?? true {
                return
            }
            
            DispatchQueue.main.async {
                self?.handleOval(state: faceResult.state, faceRect: faceResult.faceRect, aperture: faceResult.cleanAperture)
                switch faceResult.state {
                case AcuantFaceState.NONE:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_initial", color: self?.options?.fontColorDefault)
                case AcuantFaceState.FACE_TOO_CLOSE:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_face_too_close", color: self?.options?.fontColorError)
                case AcuantFaceState.FACE_TOO_FAR:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_face_too_far", color: self?.options?.fontColorError)
                case AcuantFaceState.FACE_HAS_ANGLE:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_face_has_angle", color: self?.options?.fontColorError)
                case AcuantFaceState.FACE_NOT_IN_FRAME:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_face_not_in_frame", color: self?.options?.fontColorError)
                case AcuantFaceState.FACE_MOVED:
                    self?.cancelCountdown()
                    self?.addMessage(messageKey: "acuant_face_camera_face_moved", color: self?.options?.fontColorError)
                case AcuantFaceState.FACE_GOOD_DISTANCE:
                    if let image = faceResult.image {
                        self?.handleCountdown(image: image)
                    }
                }
            }
        }

        videoPreviewLayer = AVCaptureVideoPreviewLayer(session: captureSession)
        videoPreviewLayer.videoGravity = .resizeAspectFill
        videoPreviewLayer.frame = view.layer.bounds

        overlayView = createSemiTransparentOverlay()
        view.addSubview(overlayView!)

        /// topOverlayLayer의 높이를 계산할 때 messageLayer의 폰트를 참고하기 때문에, messageLayer를 먼저 생성.
        messageLayer = createMessageLayer()
        topOverlayLayer = createTopOverlay()
        
        /// layer에 쌓을 때는 topOverlayLayer 위에 messageLayer가 쌓이기 때문에, topOverlayLayer를 먼저 add.
        videoPreviewLayer.addSublayer(topOverlayLayer)
        videoPreviewLayer.addSublayer(messageLayer)

        cornerlayer = FaceCameraCornerOverlayView()
        cornerlayer.setFrame(frame: view.frame)

        if options!.showOval {
            faceOval = CAShapeLayer()
            faceOval?.fillColor = UIColor.clear.cgColor
            faceOval?.strokeColor = options!.bracketColorGood
            faceOval?.opacity = 0.5
            faceOval?.lineWidth = 5.0
            videoPreviewLayer.addSublayer(faceOval!)
        }

        videoPreviewLayer.addSublayer(cornerlayer)

        if let image = UIImage(named: options!.defaultImageUrl) {
            imageLayer = ImagePlaceholderLayer(image: image, bounds: view.bounds)
            videoPreviewLayer.addSublayer(imageLayer!)
        }

        view.layer.addSublayer(videoPreviewLayer)

        captureSession?.start {
            self.rotateCameraPreview(to: self.view.window?.faceCaptureInterfaceOrientation, frame: self.view.frame)
        }
        addNavigationBackButton()
    }

    private func rotateCameraPreview(to interfaceOrientation: UIInterfaceOrientation?, frame: CGRect) {
        guard let connection = videoPreviewLayer.connection,
              connection.isVideoOrientationSupported,
              let orientation = interfaceOrientation else {
            return
        }

        videoPreviewLayer.frame = frame
        connection.videoOrientation = orientation.faceCaptureVideoOrientation ?? .portrait

        topOverlayLayer.path = createRectanglePath().cgPath
        imageLayer?.setFrame(frame)

        if orientation.isLandscape {
            cornerlayer.setHorizontalDefaultCorners(frame: frame)
        } else {
            cornerlayer.setDefaultCorners(frame: frame)
        }
        videoPreviewLayer.removeAllAnimations()
    }

    private func cancelCountdown() {
        currentTimer = nil
    }

    private func getTargetWidth(width: Int, height: Int) -> Int {
        if width > height {
            return Int(720 * (Float(width)/Float(height)))
        } else {
            return 720
        }
    }

    private func handleCountdown(image: UIImage) {
        if currentTimer == nil {
            currentTimer = CFAbsoluteTimeGetCurrent()
        }
        let time = self.options!.totalCaptureTime - Int(CFAbsoluteTimeGetCurrent() - (currentTimer ?? CFAbsoluteTimeGetCurrent()))
        
        if time > 0 {
            self.addMessage(messageKey: "acuant_face_camera_capturing_\(time)", color: self.options!.fontColorGood)
        } else if !self.isCaptured {
            self.isCaptured = true
            self.navigationController?.popViewController(animated: true)
            if let resized = ImagePreparation.resize(image: image,
                                                     targetWidth: getTargetWidth(width: Int(image.size.width),
                                                                                 height: Int(image.size.height))),
               let signedImageData = ImagePreparation.sign(image: resized),
               let signedImage = UIImage(data: signedImageData) {
                callback?(FaceCaptureResult(image: signedImage, jpegData: signedImageData))
            } else {
                callback?(nil)
            }
        }
    }
    
    func handleImage(state: AcuantFaceState) {
        if let defaultImg = imageLayer {
            if state == .NONE {
                defaultImg.isHidden = false
            } else {
                defaultImg.isHidden = true
            }
        }
    }
    
    func handleOval(state: AcuantFaceState, faceRect: CGRect?, aperture: CGRect?) {
        handleImage(state: state)
        setLookFromState(state: state)
        
        if let faceRect = faceRect, let aperture = aperture, state == AcuantFaceState.FACE_GOOD_DISTANCE {
            var scaled = CGRect(x: (faceRect.origin.x - 150) / aperture.width,
                                y: 1 - ((faceRect.origin.y) / aperture.height + (faceRect.height) / aperture.height),
                                width: (faceRect.width + 150) / aperture.width,
                                height: faceRect.height / aperture.height)
            if let orientation = view.window?.faceCaptureInterfaceOrientation, orientation.isLandscape {
                scaled = CGRect(x: faceRect.origin.x / aperture.width,
                                y: 1 - ((faceRect.origin.y) / aperture.height + (faceRect.height) / aperture.height),
                                width: faceRect.width / aperture.width,
                                height: (faceRect.height + 150) / aperture.height)
            }
            let faceRect = videoPreviewLayer.layerRectConverted(fromMetadataOutputRect: scaled)
            faceOval?.isHidden = false
            faceOval?.path = UIBezierPath(ovalIn: faceRect).cgPath
            cornerlayer.setCorners(point1: CGPoint(x: faceRect.origin.x, y: faceRect.origin.y),
                                   point2: CGPoint(x: faceRect.origin.x + faceRect.size.width, y: faceRect.origin.y),
                                   point3: CGPoint(x: faceRect.origin.x + faceRect.size.width, y: faceRect.origin.y + faceRect.size.height),
                                   point4: CGPoint(x: faceRect.origin.x, y: faceRect.origin.y + faceRect.size.height))
        } else {
            self.faceOval?.isHidden = true
            if let orientation = view.window?.faceCaptureInterfaceOrientation, orientation.isLandscape {
                cornerlayer.setHorizontalDefaultCorners(frame: view.bounds)
            } else {
                cornerlayer.setDefaultCorners(frame: view.bounds)
            }
        }
    }
    
    func shouldSkipFrame(faceType: AcuantFaceState) -> Bool {
        var skipFrame = false
        if currentFrameTime < 0
            || (faceType == AcuantFaceState.FACE_GOOD_DISTANCE)
            || CFAbsoluteTimeGetCurrent() - currentFrameTime >= self.frameThrottleDuration {
            currentFrameTime = CFAbsoluteTimeGetCurrent()
        } else {
            skipFrame = true
        }
        return skipFrame
    }

    func createTopOverlay() -> CAShapeLayer {
        let rectPath = createRectanglePath()
        let fillLayer = CAShapeLayer()
        fillLayer.path = rectPath.cgPath
        fillLayer.fillRule = CAShapeLayerFillRule.evenOdd
        fillLayer.fillColor = UIColor(red: 0, green: 0, blue: 0, alpha: 0.6).cgColor
        return fillLayer
    }

    func createRectanglePath() -> UIBezierPath {
        let topPadding = getSafeArea()
        let textHeight = CGFloat(UI.maxLines) * messageLayer.fontSize
        let height = textHeight + UI.extraHeight + topPadding
        
        return UIBezierPath(rect: CGRect(x: 0, y: 0, width: Int(view.bounds.width), height: Int(height)))
    }

    func createSemiTransparentOverlay() -> UIView {
        let view = UIView(frame: view.bounds)
        view.backgroundColor = UIColor.black.withAlphaComponent(0.1)
        return view
    }

    func addMessage(messageKey: String, color: CGColor? = UIColor.red.cgColor, fontSize: CGFloat = UI.Font.defaultSize){
        messageLayer.fontSize = fontSize
        messageLayer.foregroundColor = color
        messageLayer.string = NSLocalizedString(messageKey, comment: "")
        messageLayer.frame = getMessageRect()
    }
    
    func addNavigationBackButton() {
        var attribs: [NSAttributedString.Key: Any?] = [:]
        attribs[NSAttributedString.Key.font] = UIFont.systemFont(ofSize: 20)
        attribs[NSAttributedString.Key.foregroundColor] = UIColor.gray
        attribs[NSAttributedString.Key.baselineOffset] = 4

        let str = NSMutableAttributedString.init(string: "ⓧ", attributes: attribs as [NSAttributedString.Key: Any])
        backButton = UIButton()
        backButton.setAttributedTitle(str, for: .normal)
        backButton.addTarget(self, action: #selector(backTapped(_:)), for: .touchUpInside)
        backButton.isOpaque=true
        backButton.imageView?.contentMode = .scaleAspectFit
        backButton.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(backButton)

        NSLayoutConstraint.activate([
            backButton.widthAnchor.constraint(equalToConstant: 50),
            backButton.heightAnchor.constraint(equalToConstant: 50),
            backButton.topAnchor.constraint(equalTo: view.topAnchor, constant: 0),
            backButton.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: 0)
        ])
    }

    @objc internal func backTapped(_ sender: Any) {
        callback?(nil)
        self.navigationController?.popViewController(animated: true)
    }

    public func setLookFromState(state: AcuantFaceState) {
        var color = UIColor.black.cgColor
        switch state {
        case .FACE_GOOD_DISTANCE:
            color = self.options!.bracketColorGood
        case .NONE:
            color = self.options!.bracketColorDefault
        default:
            color = self.options!.bracketColorError
        }
        self.cornerlayer.setColor(color: color)
    }
    
    private func createMessageLayer(fontSize: CGFloat = UI.Font.defaultSize) -> VerticallyTextLayer {
        messageLayer = VerticallyTextLayer()
        messageLayer.fontSize = fontSize
        messageLayer.frame = getMessageRect()
        messageLayer.contentsScale = UIScreen.main.scale
        messageLayer.alignmentMode = CATextLayerAlignmentMode.center
        messageLayer.foregroundColor = UIColor.white.cgColor
        messageLayer.isWrapped = true
        messageLayer.truncationMode = .middle
        return messageLayer
    }
    
    func getSafeArea() -> CGFloat {
        if let window = UIApplication.shared.keyWindow {
            return window.safeAreaInsets.top
        } else {
            return 0
        }
    }
    
    func getMessageRect() -> CGRect {
        let width = view.safeAreaLayoutGuide.layoutFrame.size.width
        let topPadding = getSafeArea()
        let textHeight = CGFloat(UI.maxLines) * messageLayer.fontSize
        let height = textHeight + UI.extraHeight
        let padding = topPadding == 0 ? -CGFloat((UI.maxLines - 1) * 3) : topPadding - (UI.extraHeight / 2)
        return CGRect(x: 0, y: padding, width: width, height: height)
    }
    
    /// 높이를 텍스트 라인에 맞게 조절하기 위한 CustomTextLayer
    fileprivate class VerticallyTextLayer : CATextLayer {
        func calculateMaxLines() -> Int {
            let maxSize = CGSize(width: frame.size.width, height: .greatestFiniteMagnitude)
            let font = UIFont(descriptor: self.font!.fontDescriptor, size: self.fontSize)
            let charSize = font.lineHeight
            let text = (self.string ?? "") as! NSString
            /// boundingRect를 이용하여 width를 제한한 상태에서 height 구하기
            let textSize = text.boundingRect(with: maxSize, options: .usesLineFragmentOrigin, attributes: [NSAttributedString.Key.font: font], context: nil)
            /// 총 Height / 한 줄 Height = Line 수
            let linesRoundedUp = Int(ceil(textSize.height / charSize))
            /// MaxLine보다 큰 경우, MaxLine으로 제한 후 ... 처리
            if linesRoundedUp > UI.maxLines {
                return UI.maxLines
            }
            
            return linesRoundedUp
        }

        override func draw(in context: CGContext) {
            let height = self.bounds.size.height
            let fontSize = self.fontSize
            let lines = CGFloat(calculateMaxLines())
            let textSize = lines * fontSize
            /// 위 여백을 위해 남은 공간을 2로 나누어 적용
            let yDiff = (height - textSize) / 2
            
            context.saveGState()
            context.translateBy(x: 0, y: yDiff)
            super.draw(in: context)
            context.restoreGState()
        }
    }
}
