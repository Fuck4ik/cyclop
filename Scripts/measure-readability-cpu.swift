#!/usr/bin/env swift
// Reproduces the readabilityHandler CPU spin from TranscriberBridge.launch()
// (and NowPlayingFeed.launch(), same shape) and measures whether it is
// actually fixed.
//
// Usage:
//   swift Scripts/measure-readability-cpu.swift broken [seconds]
//   swift Scripts/measure-readability-cpu.swift fixed  [seconds]
//
// Spawns a short-lived child process with two pipes wired up exactly like
// launch() does — a stdout "output" pipe and a stderr "errors" pipe, each
// with its own readabilityHandler that reads availableData and bails out on
// an empty chunk. The child (`/bin/echo`) exits almost immediately, closing
// both pipes. From then on, every read returns "readable, zero bytes" —
// `readabilityHandler` is level-triggered and GCD re-invokes it the instant
// it returns if the fd is still marked readable, which a closed pipe is,
// forever. "broken" skips the line that nils the handler on that empty
// chunk (the bug as reported: two of these spin an idle core each,
// permanently, the moment a worker process dies or is stopped). "fixed"
// keeps it, matching TranscriberBridge/NowPlayingFeed as they stand now.
//
// Reports this script's own process CPU time (getrusage, sums every thread —
// the handler runs on a GCD background queue, not the thread that sleeps
// below) over a fixed wall-clock window, default 16s to match the number
// quoted in review.

import Foundation

let args = CommandLine.arguments
let mode = args.count > 1 ? args[1] : "fixed"
let duration = args.count > 2 ? (Double(args[2]) ?? 16) : 16.0
let broken = (mode == "broken")

guard mode == "broken" || mode == "fixed" else {
    FileHandle.standardError.write("usage: measure-readability-cpu.swift <broken|fixed> [seconds]\n".data(using: .utf8)!)
    exit(1)
}

func cpuTime() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000
    let sys = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000
    return user + sys
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/bin/echo")
task.arguments = ["hi"]

let output = Pipe()
let errors = Pipe()
task.standardOutput = output
task.standardError = errors

output.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    guard !chunk.isEmpty else {
        if !broken { handle.readabilityHandler = nil }
        return
    }
}

errors.fileHandleForReading.readabilityHandler = { handle in
    let chunk = handle.availableData
    guard !chunk.isEmpty else {
        if !broken { handle.readabilityHandler = nil }
        return
    }
}

try task.run()
task.waitUntilExit() // /bin/echo exits almost instantly — both pipes hit EOF right after.

print("[\(mode)] child exited, pipes at EOF, measuring for \(duration)s of wall time...")
let before = cpuTime()
Thread.sleep(forTimeInterval: duration)
let after = cpuTime()

let delta = after - before
print(String(format: "[%@] CPU time: %.4fs over %.2fs wall  (%.2f cores busy)", mode, delta, duration, delta / duration))
