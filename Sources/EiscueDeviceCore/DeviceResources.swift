import Foundation

// Backend localization shares these resources without exporting a bundle API
// or relying on an ambiguous Bundle.module across package targets.
package enum EiscueDeviceResources {
    package static let bundle: Bundle = .module
}
