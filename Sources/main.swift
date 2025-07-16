// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation

// Add this import for DownloadManager
import DownloadManager

func printVersion() {
    print("swiftget version 1.0.0")
}

// Add DownloadManager instance
let downloadManager = DownloadManager(maxParallelDownloads: 2)

func printHelp() {
    print("swiftget - A CLI tool to download files")
    print("")
    print("Usage: swiftget <command> [options] <url> [destination]")
    print("")
    print("Commands:")
    print("  download <url> [destination]   Download a file")
    print("  add <url> [destination]        Add a file to the download queue")
    print("  pause <url>                    Pause a download")
    print("  resume <url>                   Resume a paused download")
    print("  list                           List active and queued downloads")
    print("  --version, -v                  Show version information")
    print("  --help, -h                     Show this help message")
    print("")
    print("Examples:")
    print("  swiftget download https://example.com/file.zip ./file.zip")
    print("  swiftget add https://example.com/file2.zip ./file2.zip")
    print("  swiftget pause https://example.com/file.zip")
    print("  swiftget resume https://example.com/file.zip")
    print("  swiftget list")
}

func parseURL(_ arg: String) -> URL? {
    return URL(string: arg)
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
case "download":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid URL for download")
        exit(1)
    }
    let destination: URL
    if arguments.count >= 4 {
        destination = URL(fileURLWithPath: arguments[3])
    } else {
        destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.lastPathComponent)
    }
    downloadManager.addDownload(url: url, destination: destination)
    RunLoop.main.run()
case "add":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid URL to add to queue")
        exit(1)
    }
    let destination: URL
    if arguments.count >= 4 {
        destination = URL(fileURLWithPath: arguments[3])
    } else {
        destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.lastPathComponent)
    }
    downloadManager.addDownload(url: url, destination: destination)
    print("Added to queue: \(url)")
case "pause":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid URL to pause")
        exit(1)
    }
    downloadManager.pauseDownload(url: url)
case "resume":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid URL to resume")
        exit(1)
    }
    downloadManager.resumeDownload(url: url)
    RunLoop.main.run()
case "list":
    downloadManager.listDownloads()
default:
    print("Error: Unknown command \(firstArg)")
    printHelp()
    exit(1)
}
