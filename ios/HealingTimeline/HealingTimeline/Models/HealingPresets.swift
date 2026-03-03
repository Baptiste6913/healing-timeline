import Foundation

/// V2 healing profile with multi-compartment parameters.
///
/// Extends the v1 `HealingProfile` with osteotomy intensity,
/// primary-vs-revision classification, and steroid protocol —
/// all of which influence compartment-specific healing curves.
struct HealingProfileV2: Codable, Equatable {

    // MARK: - Enums

    enum SkinThickness: String, Codable, CaseIterable {
        case thin, medium, thick
    }

    enum SurgeryType: String, Codable, CaseIterable {
        case primary, revision
    }

    enum OsteotomyIntensity: String, Codable, CaseIterable {
        case none       // no bony work
        case lateral    // lateral osteotomy only
        case full       // lateral + medial / percutaneous
    }

    enum SteroidProtocol: String, Codable, CaseIterable {
        case none
        case single     // single intra-op dose
        case multiDose  // multi-dose protocol (intra-op + post-op)
    }

    // MARK: - Properties

    var skinThickness: SkinThickness = .medium
    var surgeryType: SurgeryType = .primary
    var osteotomy: OsteotomyIntensity = .lateral
    var steroidProtocol: SteroidProtocol = .none
    var bruisingPresent: Bool = true
    var age: Int? = nil

    // MARK: - V1 Conversion

    /// Create a v2 profile from an existing v1 profile (sensible defaults).
    init(from v1: HealingProfile) {
        self.skinThickness = SkinThickness(rawValue: v1.skinThickness.rawValue) ?? .medium
        self.surgeryType = .primary
        self.osteotomy = .lateral
        self.steroidProtocol = .none
        self.bruisingPresent = v1.bruisingPresent
        self.age = v1.age
    }

    init(
        skinThickness: SkinThickness = .medium,
        surgeryType: SurgeryType = .primary,
        osteotomy: OsteotomyIntensity = .lateral,
        steroidProtocol: SteroidProtocol = .none,
        bruisingPresent: Bool = true,
        age: Int? = nil
    ) {
        self.skinThickness = skinThickness
        self.surgeryType = surgeryType
        self.osteotomy = osteotomy
        self.steroidProtocol = steroidProtocol
        self.bruisingPresent = bruisingPresent
        self.age = age
    }
}
