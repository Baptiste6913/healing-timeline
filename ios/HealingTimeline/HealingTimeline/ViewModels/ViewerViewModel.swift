import SwiftUI
import simd

/// Manages the 3D viewer state and healing simulation.
@MainActor
final class ViewerViewModel: ObservableObject {
    @Published var sliderDay: Double = 0
    @Published var currentState: HealingState = HealingState(
        day: 0, swellingLevel: 1, swellingMin: 0.65, swellingMax: 1,
        bruisingLevel: 0, bruiseColor: SIMD3<Float>(0.4, 0.1, 0.3),
        nasalVolumeDelta: 4
    )
    @Published var currentStateV2: HealingStateV2?
    @Published var displayMesh: FaceMeshData?
    @Published var displayRenderMesh: MeshPostProcess.RenderMeshData?
    @Published var showRange = false
    @Published var showSettings = false
    @Published var showShareSheet = false

    /// Whether the v2 model is active for this session.
    @Published var isV2Active: Bool = false

    /// Whether surgeon-grade render mesh is available AND passed all quality gates.
    @Published var isSurgeonGrade: Bool = false

    /// Reason the surgeon-grade path was disabled (`nil` when active).
    @Published var surgeonGradeFailReason: String?

    /// Cross-check pixel error from scan quality metrics (badge display).
    @Published var crosscheckPixelError: Float = 0

    private var baseMesh: FaceMeshData?
    private var model: HealingModel?
    private var modelV2: HealingModelV2?
    private var deformationTransfer: DeformationTransfer?

    var dayLabel: String {
        let day = Int(sliderDay)
        if day == 0 { return "Surgery Day" }
        if day == 1 { return "Day 1" }
        if day < 30 { return "Day \(day)" }
        if day < 365 {
            let months = day / 30
            return "\(months) month\(months > 1 ? "s" : "")"
        }
        return "12 months"
    }

    func setup(mesh: FaceMeshData, profile: HealingProfile) {
        baseMesh = mesh
        surgeonGradeFailReason = nil
        crosscheckPixelError = mesh.qualityMetrics?.crosscheckPixelErrorMedian ?? 0

        // ── Surgeon-grade gating (non-negotiable #3) ────────────────────
        if let renderMesh = mesh.renderMesh, let mapper = mesh.barycentricMapper {

            // Validate mapping: identity transfer should produce ~zero displacement
            let identityTransferred = mapper.transfer(
                deformedCanonical: mesh.vertices,
                canonicalIndices: mesh.triangleIndices
            )
            var maxIdentityError: Float = 0
            for i in 0..<min(renderMesh.vertices.count, identityTransferred.count) {
                let err = length(identityTransferred[i] - renderMesh.vertices[i])
                maxIdentityError = max(maxIdentityError, err)
            }

            if maxIdentityError > SurgeonGradeQualityGate.maxIdentityErrorM {
                let errMM = String(format: "%.2f", maxIdentityError * 1000)
                print("[ViewerVM] WARNING: Mapping identity error \(errMM)mm exceeds gate — canonical fallback")
                deformationTransfer = nil
                isSurgeonGrade = false
                surgeonGradeFailReason = "Mapping identity error \(errMM)mm"
            } else {
                deformationTransfer = DeformationTransfer(
                    mapper: mapper,
                    baseRenderVertices: renderMesh.vertices,
                    canonicalIndices: mesh.triangleIndices
                )
                isSurgeonGrade = true
            }

        } else if mesh.scanMode == .surgeonGrade {
            // Surgeon-grade scan requested but mapping absent → fallback
            print("[ViewerVM] WARNING: Surgeon-grade scan but no valid mapping, canonical fallback")
            deformationTransfer = nil
            isSurgeonGrade = false
            surgeonGradeFailReason = "Barycentric mapping unavailable"
        } else {
            deformationTransfer = nil
            isSurgeonGrade = mesh.hasRenderMesh
        }

        if FeatureFlags.healingModelV2Enabled {
            let profileV2 = HealingProfileV2(from: profile)
            modelV2 = HealingModelV2(profile: profileV2)
            model = nil
            isV2Active = true
        } else {
            model = HealingModel(profile: profile)
            modelV2 = nil
            isV2Active = false
        }

        setDay(Float(sliderDay))
    }

    func setDay(_ day: Float) {
        guard let baseMesh = baseMesh else { return }

        if let modelV2 = modelV2 {
            let stateV2 = modelV2.evaluate(at: day)
            currentStateV2 = stateV2
            currentState = stateV2.toV1()
            let displacedCanonical = baseMesh.displacedV2(by: stateV2)
            displayMesh = displacedCanonical

            // Transfer deformation to render mesh
            if let dt = deformationTransfer {
                let result = dt.transfer(
                    baseCanonical: baseMesh.vertices,
                    deformedCanonical: displacedCanonical.vertices,
                    deformedNormals: displacedCanonical.normals
                )
                var deformedRender = baseMesh.renderMesh!
                deformedRender.vertices = result.deformedVertices
                if let normals = result.deformedNormals {
                    deformedRender.normals = normals
                }
                displayRenderMesh = deformedRender
            } else {
                displayRenderMesh = nil
            }
        } else if let model = model {
            currentStateV2 = nil
            currentState = model.evaluate(at: day)
            let displacedCanonical = baseMesh.displaced(by: currentState)
            displayMesh = displacedCanonical

            // Transfer deformation to render mesh
            if let dt = deformationTransfer {
                let result = dt.transfer(
                    baseCanonical: baseMesh.vertices,
                    deformedCanonical: displacedCanonical.vertices,
                    deformedNormals: displacedCanonical.normals
                )
                var deformedRender = baseMesh.renderMesh!
                deformedRender.vertices = result.deformedVertices
                if let normals = result.deformedNormals {
                    deformedRender.normals = normals
                }
                displayRenderMesh = deformedRender
            } else {
                displayRenderMesh = nil
            }
        }
    }

    func exportSnapshots() {
        let exportDays: [Float] = [1, 7, 30, 365]
        for day in exportDays {
            if let modelV2 = modelV2 {
                _ = modelV2.evaluate(at: day)
            } else if let model = model {
                _ = model.evaluate(at: day)
            }
        }
    }
}
