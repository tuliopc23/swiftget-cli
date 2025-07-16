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
    print("  download <url> [destination]         Download a file")
    print("  add <url> [destination]              Add a file to the download queue")
    print("  pause <url>                          Pause a download")
    print("  resume <url>                         Resume a paused download")
    print("  list                                 List active and queued downloads")
    print("  segmented <url> [destination] [--segments N] [--mirror url1,url2,...]  Segmented/chunked download with optional mirrors")
    print("  ftp <url> [destination] [--user username] [--pass password]            Download a file via FTP")
    print("  torrent <file|magnet> [destination]   Download via BitTorrent or magnet link (TODO)")
    print("  metalink <file> [destination]         Download via Metalink file (TODO)")
    print("  --version, -v                        Show version information")
    print("  --help, -h                           Show this help message")
    print("")
    print("Examples:")
    print("  swiftget ftp ftp://example.com/file.zip ./file.zip --user myuser --pass mypass")
    print("  swiftget segmented https://example.com/file.zip ./file.zip --segments 8 --mirror https://mirror1.com/file.zip,https://mirror2.com/file.zip")
    print("  swiftget list")
    print("  swiftget torrent myfile.torrent ./output_dir")
    print("  swiftget metalink myfile.metalink ./output_dir")
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
case "segmented":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid URL for segmented download")
        exit(1)
    }
    var destination: URL
    var segments = 4
    var mirrors: [URL] = []
    var i = 3
    if i < arguments.count, !arguments[i].hasPrefix("--") {
        destination = URL(fileURLWithPath: arguments[i])
        i += 1
    } else {
        destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.lastPathComponent)
    }
    while i < arguments.count {
        if arguments[i] == "--segments", i + 1 < arguments.count, let n = Int(arguments[i+1]) {
            segments = n
            i += 2
        } else if arguments[i] == "--mirror", i + 1 < arguments.count {
            mirrors = arguments[i+1].split(separator: ",").compactMap { URL(string: String($0)) }
            i += 2
        } else {
            i += 1
        }
    }
    downloadManager.addSegmentedDownload(url: url, destination: destination, segments: segments, mirrors: mirrors)
    RunLoop.main.run()
case "ftp":
    guard arguments.count >= 3, let url = parseURL(arguments[2]) else {
        print("Error: Please provide a valid FTP URL")
        exit(1)
    }
    var destination: URL
    var username = "anonymous"
    var password = ""
    var i = 3
    if i < arguments.count, !arguments[i].hasPrefix("--") {
        destination = URL(fileURLWithPath: arguments[i])
        i += 1
    } else {
        destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(url.lastPathComponent)
    }
    while i < arguments.count {
        if arguments[i] == "--user", i + 1 < arguments.count {
            username = arguments[i+1]
            i += 2
        } else if arguments[i] == "--pass", i + 1 < arguments.count {
            password = arguments[i+1]
            i += 2
        } else {
            i += 1
        }
    }
    downloadManager.addFTPDownload(url: url, destination: destination, username: username, password: password)
case "torrent":
    print("BitTorrent/magnet support is a TODO. Please check back later.")
    exit(1)
case "metalink":
    print("Metalink support is a TODO. Please check back later.")
    exit(1)
default:
    print("Error: Unknown command \(firstArg)")
    printHelp()
    exit(1)
}
