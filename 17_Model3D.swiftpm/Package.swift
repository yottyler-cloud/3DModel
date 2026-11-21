// swift-tools-version: 5.9
import PackageDescription
import AppleProductTypes

let package = Package(
    name: "Model3D",
    platforms: [.iOS("16.0")],
    products: [
        .iOSApplication(
            name: "Model3D",
            targets: ["AppModule"],
            bundleIdentifier: "jp.taireru.model3d",
            displayVersion: "17",
            bundleVersion: "17",
            appIcon: .placeholder(icon: .pencil),
            accentColor: .presetColor(.blue),
            supportedDeviceFamilies: [.pad],
            supportedInterfaceOrientations: [.portrait, .landscapeLeft, .landscapeRight]
        )
    ],
    targets: [.executableTarget(name: "AppModule", path: "Sources")]
)
