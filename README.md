# swiftget-cli
A fast, modern, MacOS native tool for downloading files from the web, written in Swift

swiftget

A lightweight Swift CLI to download .dmg, .zip, or any binary file from the internet — with modern flags, native macOS integration, and a splash of style.

swiftget-banner
swiftget-banner

🚀 Features

📦 Download files via URLSession
📁 Custom output filename (--output)
🌐 Custom headers like --user-agent
📊 Download progress bar
🔒 SHA256 verification
🦹 Auto-extract .zip files
🖱️ Open downloaded file in Finder
🧙 Silent mode (--quiet)
⚡ Download queue management (add, pause, resume, list)
⚡ Parallel downloads (multiple files at once)
⚡ Robust pause/resume support
⚡ CLI commands for download management
Built 100% in Swift with ArgumentParser

## Usage

```
swiftget <command> [options] <url> [destination]
```

### Commands
- `download <url> [destination]`   Download a file
- `add <url> [destination]`        Add a file to the download queue
- `pause <url>`                    Pause a download
- `resume <url>`                   Resume a paused download
- `list`                           List active and queued downloads
- `--version, -v`                  Show version information
- `--help, -h`                     Show this help message

### Examples
- `swiftget download https://example.com/file.zip ./file.zip`
- `swiftget add https://example.com/file2.zip ./file2.zip`
- `swiftget pause https://example.com/file.zip`
- `swiftget resume https://example.com/file.zip`
- `swiftget list`

## Installation

✅ Option 1: via Homebrew 

```
brew install tulio/swiftget/swiftget
```
