// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

func printVersion() {
    print("swiftget version 1.0.0")
}

func printHelp() {
    print("swiftget - A CLI tool to download files")
    print("")
    print("Usage: swiftget [options] <url>")
    print("")
    print("Options:")
    print("  --version, -v    Show version information")
    print("  --help, -h       Show this help message")
    print("")
    print("Example:")
    print("  swiftget https://example.com/file.zip")
}

func downloadFile(from url: String) {
    print("Downloading from: \(url)")
    print("Feature coming soon!")
}

let arguments = CommandLine.arguments

if arguments.count == 1 {
    printHelp()
    exit(0)
}

let firstArg = arguments[1]

switch firstArg {
case "--version", "-v":
    printVersion()
case "--help", "-h":
    printHelp()
default:
    if firstArg.hasPrefix("http://") || firstArg.hasPrefix("https://") {
        downloadFile(from: firstArg)
    } else {
        print("Error: Please provide a valid URL")
        printHelp()
        exit(1)
    }
}
