import SwiftUI
import ARKit
import Combine

// MARK: - Scan Phase (internal state machine)

/// Fine-grained phases of the scan protocol.
enum ScanPhase: Equatable {
    case idle               // No face detected yet
    case detecting          // Face found, stabilising
    case countdown(Float)   // Stabilisation countdown (seconds remaining)
    case collecting         // Collecting frames during countdown
    case capturing          // Aggregation + export in progress
    case done               // Capture complete
}

// MARK: - View Model

/// Manages the multi-phase face scanning session.
@MainActor
final class ScanViewModel: ObservableObject {

    // ── Published state ──────────────────────────────────────────────────
    @Published var trackingState: ScanTrackingState = .notTracking
    @Published var instructionText = "Position your face in the frame"
    @Published var canCapture = false
    @Published var capturedMesh: FaceMeshData?
    @Published var lastFrameRMS: Float = 0
    @Published var scanPhase: ScanPhase = .idle
    @Published var countdownProgress: Float = 0   // 0→1 during countdown
    @Published var framesCollected: Int = 0

    // ── Internal / AR state ──────────────────────────────────────────────
    var arSession: ARSession?
    var faceAnchor: ARFaceAnchor?
    private var stableFrameCount = 0
    private let requiredStableFrames = 15          // ~0.5s warmup

    // ── Frame buffers ────────────────────────────────────────────────────
    private var frameBuffer: [[SIMD3<Float>]] = []
    private var frameTimestamps: [TimeInterval] = []       // ARFrame.timestamp per frame
    private var previousFrameVertices: [SIMD3<Float>]?
    private var rmsHistory: [Float] = []           // consecutive-frame RMS values

    // ── Pose buffers ─────────────────────────────────────────────────────
    private var faceTransformBuffer: [simd_float4x4] = []
    private var cameraTransformBuffer: [simd_float4x4] = []

    // ── Depth buffers (Tier 2) ───────────────────────────────────────────
    private var depthBundles: [DepthBundle] = []

    // ── Countdown state ──────────────────────────────────────────────────
    private var countdownStart: Date?
    private var countdownPausedAccum: TimeInterval = 0
    private var countdownPauseStart: Date?
    private var isCountdownPaused = false

    // ── Camera frame buffer (surgeon-grade texture baking) ─────────────
    private var cameraFrameBuffers: [TextureBaker.CameraFrame] = []

    // ── Constants ────────────────────────────────────────────────────────
    private var isDenseMode: Bool { FeatureFlags.hybridScan3DEnabled && FeatureFlags.depthCorrectionEnabled }
    private var captureFrameTarget: Int {
        isDenseMode ? FeatureFlags.denseCaptureFrameTarget : FeatureFlags.captureFrameTarget
    }
    private var scanCountdownSeconds: Float {
        isDenseMode ? FeatureFlags.denseCaptureCountdownSeconds : FeatureFlags.scanCountdownSeconds
    }
    private var microMovementThreshold: Float { FeatureFlags.microMovementThresholdM }

    // MARK: - Tracking Update (called ~30 fps from coordinator)

    func updateTracking(anchor: ARFaceAnchor?, frame: ARFrame?) {
        guard let anchor = anchor else {
            resetTracking(reason: "Position your face in the frame")
            return
        }

        faceAnchor = anchor
        stableFrameCount += 1

        // ── Extract vertices ─────────────────────────────────────────────
        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let currentVerts = (0..<vertexCount).map { i -> SIMD3<Float> in
            let v = geometry.vertices[i]
            return SIMD3<Float>(v.x, v.y, v.z)
        }

        // ── Frame-to-frame RMS ───────────────────────────────────────────
        if let prev = previousFrameVertices {
            lastFrameRMS = MeshProcessor.computeFrameRMS(previous: prev, current: currentVerts)
            rmsHistory.append(lastFrameRMS)
        }
        previousFrameVertices = currentVerts

        // ── Phase: detecting (warmup) ────────────────────────────────────
        if stableFrameCount < requiredStableFrames {
            trackingState = .tracking
            scanPhase = .detecting
            instructionText = "Aligning… keep steady"
            return
        }

        // ── Phase: countdown / collecting ────────────────────────────────
        trackingState = .ready

        // Start countdown if not started
        if countdownStart == nil {
            countdownStart = Date()
            countdownPausedAccum = 0
            scanPhase = .countdown(scanCountdownSeconds)
            instructionText = isDenseMode
                ? "Hold still — dense scan (\(Int(scanCountdownSeconds))s)"
                : "Hold still — neutral expression"
        }

        // Check micro-movement: pause if jitter too high
        let isStable = lastFrameRMS < microMovementThreshold || rmsHistory.count < 3
        if !isStable && !isCountdownPaused {
            isCountdownPaused = true
            countdownPauseStart = Date()
            instructionText = "Movement detected — hold still"
        } else if isStable && isCountdownPaused {
            isCountdownPaused = false
            if let pauseStart = countdownPauseStart {
                countdownPausedAccum += Date().timeIntervalSince(pauseStart)
            }
            countdownPauseStart = nil
        }

        // Compute elapsed (excluding paused time)
        let now = Date()
        var elapsed = now.timeIntervalSince(countdownStart ?? now) - countdownPausedAccum
        if isCountdownPaused, let pauseStart = countdownPauseStart {
            elapsed -= now.timeIntervalSince(pauseStart)
        }
        let remaining = max(0, Float(scanCountdownSeconds) - Float(elapsed))
        countdownProgress = min(1.0, Float(elapsed) / Float(scanCountdownSeconds))

        // ── Collect frame into buffer ────────────────────────────────────
        frameBuffer.append(currentVerts)
        framesCollected = frameBuffer.count

        // Store pose data
        faceTransformBuffer.append(anchor.transform)
        if let f = frame {
            cameraTransformBuffer.append(f.camera.transform)
            frameTimestamps.append(f.timestamp)

            // Tier 2: capture depth bundle if available
            if let depthData = f.capturedDepthData {
                let bundle = buildDepthBundle(
                    depthData: depthData,
                    frame: f,
                    faceTransform: anchor.transform,
                    faceVertices: currentVerts
                )
                depthBundles.append(bundle)
            }

            // Surgeon-grade: capture camera frames for texture baking (every 5th frame)
            if isDenseMode && frameBuffer.count % 5 == 0 {
                if let pixelBuffer = f.capturedImage as CVPixelBuffer? {
                    let camFrame = TextureBaker.CameraFrame(
                        pixelBuffer: pixelBuffer,
                        cameraTransform: f.camera.transform,
                        faceTransform: anchor.transform,
                        intrinsics: f.camera.intrinsics,
                        imageWidth: CVPixelBufferGetWidth(pixelBuffer),
                        imageHeight: CVPixelBufferGetHeight(pixelBuffer),
                        timestamp: f.timestamp
                    )
                    cameraFrameBuffers.append(camFrame)
                }
            }
        } else {
            frameTimestamps.append(CACurrentMediaTime())
        }

        // ── Update UI ────────────────────────────────────────────────────
        if remaining > 0 {
            scanPhase = .countdown(remaining)
            if !isCountdownPaused {
                let rmsStr = String(format: "%.2f", lastFrameRMS * 1000)
                instructionText = "Hold still — \(String(format: "%.1f", remaining))s (\(framesCollected)f, \(rmsStr)mm)"
            }
            canCapture = false
        } else {
            scanPhase = .collecting
            canCapture = true
            let rmsStr = String(format: "%.2f", lastFrameRMS * 1000)
            instructionText = "Ready! Tap capture (\(framesCollected) frames, \(rmsStr)mm)"
        }

        // ── Cap buffer to 2× target to avoid memory bloat ───────────────
        let maxBuffer = captureFrameTarget * 2
        if frameBuffer.count > maxBuffer {
            let excess = frameBuffer.count - maxBuffer
            frameBuffer.removeFirst(excess)
            frameTimestamps.removeFirst(min(excess, frameTimestamps.count))
            faceTransformBuffer.removeFirst(min(excess, faceTransformBuffer.count))
            cameraTransformBuffer.removeFirst(min(excess, cameraTransformBuffer.count))
            // Don't trim depthBundles (they're sparse and lightweight refs)
        }
    }

    // MARK: - Build Depth Bundle (disparity→depth, intrinsics rescale, calibration, cross-validation refs)

    private func buildDepthBundle(
        depthData: AVDepthData,
        frame: ARFrame,
        faceTransform: simd_float4x4,
        faceVertices: [SIMD3<Float>]
    ) -> DepthBundle {

        // 1) Ensure Float32 depth in meters (convert from disparity if needed)
        let (depthMap, originalType) = DepthCorrectionService.ensureDepthFloat32(depthData)

        let depthW = CVPixelBufferGetWidth(depthMap)
        let depthH = CVPixelBufferGetHeight(depthMap)

        // 2) Rescale intrinsics from camera reference dimensions to depth map dimensions
        let cameraIntrinsics = frame.camera.intrinsics
        let refDims = depthData.cameraCalibrationData?.intrinsicMatrixReferenceDimensions
            ?? CGSize(width: CGFloat(frame.camera.imageResolution.width),
                      height: CGFloat(frame.camera.imageResolution.height))

        let rescaledIntrinsics = DepthCorrectionService.rescaleIntrinsics(
            cameraIntrinsics,
            fromReferenceWidth: Float(refDims.width),
            fromReferenceHeight: Float(refDims.height),
            toDepthWidth: depthW,
            toDepthHeight: depthH
        )

        // 3) Extract pixel size from calibration data if available
        let pixelSizeMM: Float? = depthData.cameraCalibrationData?.pixelSize

        // 4) Extract accuracy / quality / filter metadata
        let accuracyStr: String
        switch depthData.depthDataAccuracy {
        case .absolute: accuracyStr = "absolute"
        case .relative: accuracyStr = "relative"
        @unknown default: accuracyStr = "unknown"
        }

        let qualityStr: String
        switch depthData.depthDataQuality {
        case .high: qualityStr = "high"
        case .low: qualityStr = "low"
        @unknown default: qualityStr = "unknown"
        }

        let isFiltered = depthData.isDepthDataFiltered

        // 5) Extract extrinsic matrix from calibration data (RGB camera → depth camera)
        let extrinsicMatrix: simd_float4x3? = depthData.cameraCalibrationData?.extrinsicMatrix

        // 6) Build cross-validation reference projections via ARCamera.projectPoint
        //    Coordinates are in depth buffer native pixel space (.landscapeLeft = front camera native orientation)
        var referenceProjections: [DepthReferenceProjection]? = nil
        if !faceVertices.isEmpty {
            let roiIndices = DepthCorrectionService.buildNoseMidfaceROI(vertices: faceVertices)
            let depthViewport = CGSize(width: CGFloat(depthW), height: CGFloat(depthH))
            var refs: [DepthReferenceProjection] = []

            for idx in roiIndices.prefix(20) {  // limit per frame to control memory
                let v = faceVertices[idx]
                let worldPos = faceTransform * SIMD4<Float>(v, 1)
                let worldPoint = SIMD3<Float>(worldPos.x, worldPos.y, worldPos.z)

                // ARCamera.projectPoint handles orientation + intrinsics internally
                let projected = frame.camera.projectPoint(
                    worldPoint,
                    orientation: .landscapeLeft,
                    viewportSize: depthViewport
                )

                refs.append(DepthReferenceProjection(
                    vertexFaceLocal: v,
                    depthPixelU: Float(projected.x),
                    depthPixelV: Float(projected.y)
                ))
            }
            referenceProjections = refs.isEmpty ? nil : refs
        }

        return DepthBundle(
            depthMap: depthMap,
            intrinsics: rescaledIntrinsics,
            depthResolution: SIMD2<Int>(depthW, depthH),
            timestamp: frame.timestamp,
            faceTransform: faceTransform,
            cameraTransform: frame.camera.transform,
            originalDepthDataType: originalType,
            pixelSizeMM: pixelSizeMM,
            depthDataAccuracy: accuracyStr,
            depthDataQuality: qualityStr,
            isDepthDataFiltered: isFiltered,
            extrinsicMatrix: extrinsicMatrix,
            referenceProjections: referenceProjections
        )
    }

    // MARK: - Lost Tracking

    func lostTracking() {
        resetTracking(reason: "Face lost — reposition")
    }

    private func resetTracking(reason: String) {
        trackingState = .notTracking
        stableFrameCount = 0
        canCapture = false
        scanPhase = .idle
        countdownStart = nil
        countdownProgress = 0
        isCountdownPaused = false
        countdownPauseStart = nil
        countdownPausedAccum = 0
        frameBuffer.removeAll()
        frameTimestamps.removeAll()
        faceTransformBuffer.removeAll()
        cameraTransformBuffer.removeAll()
        depthBundles.removeAll()
        cameraFrameBuffers.removeAll()
        previousFrameVertices = nil
        rmsHistory.removeAll()
        framesCollected = 0
        instructionText = reason
    }

    // MARK: - Capture

    func capture() {
        guard let anchor = faceAnchor else { return }
        scanPhase = .capturing
        instructionText = "Processing…"
        canCapture = false

        let geometry = anchor.geometry
        let vertexCount = geometry.vertices.count
        let captureStart = countdownStart ?? Date()
        let scanDuration = Float(Date().timeIntervalSince(captureStart))

        // ── Trimmed-mean aggregation ─────────────────────────────────────
        let usableBuffer: [[SIMD3<Float>]]
        if frameBuffer.count > captureFrameTarget {
            usableBuffer = Array(frameBuffer.suffix(captureFrameTarget))
        } else {
            usableBuffer = frameBuffer
        }

        let trimPercent = FeatureFlags.trimPercent
        let (aggregated, framesUsed) = MeshProcessor.trimmedMeanAggregate(
            frameBuffer: usableBuffer,
            vertexCount: vertexCount,
            trimPercent: trimPercent
        )

        var vertices = aggregated

        // ── Convergence RMS ──────────────────────────────────────────────
        let lastRawFrame: [SIMD3<Float>]
        if let last = frameBuffer.last, last.count == vertexCount {
            lastRawFrame = last
        } else {
            lastRawFrame = (0..<vertexCount).map { i in
                let v = geometry.vertices[i]
                return SIMD3<Float>(v.x, v.y, v.z)
            }
        }
        let convergenceRMS = MeshProcessor.computeFrameRMS(previous: vertices, current: lastRawFrame)

        // ── Pose stability ───────────────────────────────────────────────
        let (rotStdDeg, transStdMM) = computePoseStability()

        // ── Mean frame RMS ───────────────────────────────────────────────
        let meanRMS: Float
        if rmsHistory.isEmpty {
            meanRMS = 0
        } else {
            meanRMS = rmsHistory.reduce(0, +) / Float(rmsHistory.count)
        }

        // ── Depth metadata (always extracted, regardless of Tier 2 status) ──
        let depthFramesAvailable = depthBundles.count
        let depthAccuracy: String
        let depthQuality: String
        let depthFiltered: Bool
        if let firstBundle = depthBundles.first {
            depthAccuracy = firstBundle.depthDataAccuracy
            depthQuality = firstBundle.depthDataQuality
            depthFiltered = firstBundle.isDepthDataFiltered
        } else {
            depthAccuracy = "none"
            depthQuality = "none"
            depthFiltered = false
        }

        // Compute depth FPS
        let depthFPS: Float
        if depthBundles.count >= 2 {
            let firstTs = depthBundles.first!.timestamp
            let lastTs = depthBundles.last!.timestamp
            let span = Float(lastTs - firstTs)
            depthFPS = span > 0 ? Float(depthBundles.count) / span : 0
        } else {
            depthFPS = 0
        }

        // Detect original depth data type for logging
        let depthDataTypeRaw: OSType = depthBundles.first?.originalDepthDataType ?? 0
        let depthResW = depthBundles.first?.depthResolution.x ?? 0
        let depthResH = depthBundles.first?.depthResolution.y ?? 0

        // ── Tier 2: Depth correction (if enabled) ────────────────────────
        var depthApplied = false
        var scanMode: ScanMode = .coarseStable
        var registrationDiag = RegistrationDiagnostics.zero
        var crosscheckMedian: Float = 0

        if FeatureFlags.depthCorrectionEnabled && !depthBundles.isEmpty {
            let result = DepthCorrectionService.correct(
                vertices: vertices,
                depthBundles: depthBundles,
                faceTransforms: Array(faceTransformBuffer.suffix(captureFrameTarget)),
                frameTransforms: Array(cameraTransformBuffer.suffix(captureFrameTarget))
            )
            registrationDiag = result.registrationDiagnostics
            crosscheckMedian = result.crossValidation?.medianPixelError ?? 0
            if !result.autoDisabled {
                vertices = result.correctedVertices
                depthApplied = true
                scanMode = .depthCorrected
                print("[ScanVM] Depth correction applied: \(result.framesApplied) frames, mean delta \(String(format: "%.3f", result.meanDeltaMM))mm")
            } else {
                print("[ScanVM] Depth correction auto-disabled: \(result.autoDisableReason ?? "unknown")")
            }
        }

        // ── Zone weights + normals ───────────────────────────────────────
        var texCoords = [SIMD2<Float>]()
        var zoneWeights = [Float]()

        for i in 0..<vertexCount {
            let tc = geometry.textureCoordinates[i]
            texCoords.append(SIMD2<Float>(tc.x, tc.y))
            zoneWeights.append(computeZoneWeight(vertex: vertices[i]))
        }

        let indices = geometry.triangleIndices.map { UInt32($0) }
        let normals = MeshProcessor.computeNormals(vertices: vertices, indices: indices)

        // ── Build quality metrics ────────────────────────────────────────
        let deviceModel = Self.currentDeviceModel()
        let metrics = ScanQualityMetrics(
            framesCollected: frameBuffer.count,
            framesUsed: framesUsed,
            trimPercent: trimPercent,
            meanFrameRMS: meanRMS,
            convergenceRMS: max(0, convergenceRMS),
            poseRotationStdDeg: rotStdDeg,
            poseTranslationStdMM: transStdMM,
            depthFramesAvailable: depthFramesAvailable,
            depthCorrectionApplied: depthApplied,
            depthDataType: fourCCString(depthDataTypeRaw),
            depthResolutionW: depthResW,
            depthResolutionH: depthResH,
            depthFramesPerSecond: depthFPS,
            registrationMedianAbsErrorMm: registrationDiag.medianAbsErrorMm,
            registrationMADAbsErrorMm: registrationDiag.madAbsErrorMm,
            registrationBiasMm: registrationDiag.biasMm,
            depthDataAccuracy: depthAccuracy,
            depthDataQuality: depthQuality,
            isDepthDataFiltered: depthFiltered,
            crosscheckPixelErrorMedian: crosscheckMedian,
            scanDurationSeconds: scanDuration,
            deviceModel: deviceModel,
            scanMode: scanMode,
            timestamp: Date()
        )

        // ── Build FaceMeshData ───────────────────────────────────────────
        var mesh = FaceMeshData(
            vertices: vertices,
            normals: normals,
            triangleIndices: indices,
            textureCoordinates: texCoords,
            zoneWeights: zoneWeights,
            scanMode: scanMode,
            qualityMetrics: metrics
        )

        // ── Surgeon-grade: Dense 3D pipeline ─────────────────────────────
        if isDenseMode && depthApplied {
            instructionText = "Building dense 3D model…"

            let pipelineResult = DenseScanPipeline.run(
                canonicalVertices: vertices,
                canonicalNormals: normals,
                canonicalIndices: indices,
                depthBundles: depthBundles,
                cameraFrames: cameraFrameBuffers,
                faceTransforms: Array(faceTransformBuffer.suffix(captureFrameTarget)),
                cameraTransforms: Array(cameraTransformBuffer.suffix(captureFrameTarget))
            )

            if pipelineResult.succeeded {
                mesh.renderMesh = pipelineResult.renderMesh
                mesh.barycentricMapper = pipelineResult.barycentricMapper
                mesh.textureAtlas = pipelineResult.textureAtlas
                mesh.denseROICoverage = pipelineResult.coverage
                mesh.scanMode = .surgeonGrade

                let timingsStr = pipelineResult.phaseTimings.map { "\($0.key)=\(String(format: "%.2f", $0.value))s" }.joined(separator: " ")
                print("[ScanVM] Surgeon-grade pipeline PASSED: \(timingsStr)")
            } else {
                print("[ScanVM] Surgeon-grade pipeline FALLBACK: \(pipelineResult.failReason ?? "unknown") — keeping \(scanMode.rawValue)")
                mesh.denseROICoverage = pipelineResult.coverage
            }
        }

        // ── Export instrumentation ───────────────────────────────────────
        let timestamp = Int(Date().timeIntervalSince1970)
        let baseName = "scan_\(timestamp)"
        MeshProcessor.saveMeshToDocuments(mesh: mesh, filename: baseName, format: .obj)
        MeshProcessor.saveMeshToDocuments(mesh: mesh, filename: baseName, format: .ply)
        MeshProcessor.saveStatsJSON(metrics: metrics, filename: baseName)

        print("[ScanVM] Capture complete: mode=\(scanMode.rawValue) grade=\(metrics.grade.label) frames=\(framesUsed)/\(frameBuffer.count) rms=\(String(format: "%.3f", meanRMS * 1000))mm convergence=\(String(format: "%.3f", convergenceRMS * 1000))mm poseRot=\(String(format: "%.1f", rotStdDeg))deg depth=\(depthFramesAvailable)f applied=\(depthApplied) accuracy=\(depthAccuracy) quality=\(depthQuality) crosscheck=\(String(format: "%.2f", crosscheckMedian))px")

        scanPhase = .done
        capturedMesh = mesh
    }

    // MARK: - Pose Stability

    private func computePoseStability() -> (rotStdDeg: Float, transStdMM: Float) {
        guard faceTransformBuffer.count >= 2 else { return (0, 0) }

        var translations: [SIMD3<Float>] = []
        var rotationAngles: [Float] = []

        for t in faceTransformBuffer {
            let trans = SIMD3<Float>(t.columns.3.x, t.columns.3.y, t.columns.3.z)
            translations.append(trans)

            let trace = t.columns.0.x + t.columns.1.y + t.columns.2.z
            let cosAngle = (trace - 1) / 2
            let angle = acos(min(1, max(-1, cosAngle)))
            rotationAngles.append(angle)
        }

        let meanRot = rotationAngles.reduce(0, +) / Float(rotationAngles.count)
        let rotVar = rotationAngles.map { ($0 - meanRot) * ($0 - meanRot) }.reduce(0, +) / Float(rotationAngles.count)
        let rotStdDeg = sqrt(rotVar) * 180 / Float.pi

        let meanTrans = translations.reduce(SIMD3<Float>.zero, +) / Float(translations.count)
        let transVar = translations.map { t -> Float in
            let d = t - meanTrans
            return dot(d, d)
        }.reduce(0, +) / Float(translations.count)
        let transStdMM = sqrt(transVar) * 1000

        return (rotStdDeg, transStdMM)
    }

    // MARK: - Device Info

    private static func currentDeviceModel() -> String {
        var sysinfo = utsname()
        uname(&sysinfo)
        return withUnsafePointer(to: &sysinfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(validatingUTF8: $0) ?? "unknown"
            }
        }
    }

    // MARK: - Helpers

    private func fourCCString(_ code: OSType) -> String {
        guard code != 0 else { return "none" }
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "\(code)"
    }

    // MARK: - Zone Weight Computation

    private func computeZoneWeight(vertex: SIMD3<Float>) -> Float {
        let x = vertex.x
        let y = vertex.y
        let z = vertex.z

        let tipDist = length(vertex - SIMD3<Float>(0, -0.015, 0.03))
        if tipDist < 0.012 { return 1.0 }

        let dorsumDist = abs(x) + abs(y + 0.005) * 2
        if dorsumDist < 0.015 && z > 0.02 { return 0.7 }

        if abs(x) > 0.008 && abs(x) < 0.02 && y < 0 && y > -0.025 && z > 0.015 {
            return 0.5
        }

        if abs(y - 0.01) < 0.012 && abs(x) < 0.03 && abs(x) > 0.01 {
            return 0.4
        }

        if abs(x) > 0.02 && abs(x) < 0.05 && y < 0.01 && y > -0.04 {
            return 0.2
        }

        return 0.0
    }
}
