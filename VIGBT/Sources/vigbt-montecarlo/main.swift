import Foundation
import VIGBTCore

// Usage: swift run -c release vigbt-montecarlo [--shots N] [--seed S] [--no-fit]
// Runs the end-to-end Monte Carlo validation (SPEC §12) with the real VIGBTCore pipeline.
var config = MonteCarloConfig()
config.shots = 100_000
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--shots": config.shots = args.next().flatMap { Int($0) } ?? config.shots
    case "--seed": config.seed = args.next().flatMap { UInt64($0) } ?? config.seed
    case "--no-fit": config.useReprojectionFit = false
    case "--heading-sigma": config.headingSigmaDeg = args.next().flatMap { Double($0) } ?? config.headingSigmaDeg
    default:
        print("Unknown argument \(a). Options: --shots N --seed S --no-fit --heading-sigma DEG")
        exit(2)
    }
}
let start = Date()
let report = MonteCarlo.run(config)
print(report.summary)
print(String(format: "Elapsed %.1f s", Date().timeIntervalSince(start)))
