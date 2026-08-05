// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OperationsDashboard",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "OperationsDashboard", targets: ["OperationsDashboard"])
    ],
    targets: [
        .executableTarget(
            name: "OperationsDashboard",
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "OperationsDashboardTests",
            dependencies: ["OperationsDashboard"],
            resources: [.copy("Fixtures")]
        )
    ]
)
