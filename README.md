# SwiftGet - Modern Download Manager

A fast, modern download manager built with Swift, designed to compete with aria2, wget, and other major download tools.

## Features

### ✅ Core Download Features
- **HTTP/HTTPS Downloads** - Full support with modern URLSession
- **Resume Downloads** - Continue interrupted downloads automatically
- **Progress Bars** - Real-time progress with speed and ETA
- **Checksum Verification** - MD5, SHA1, SHA256 support
- **Custom Headers** - User-Agent and custom HTTP headers
- **Proxy Support** - HTTP, HTTPS, and SOCKS proxy configuration

### ✅ Advanced Features
- **Configuration Management** - Persistent settings with JSON config
- **Archive Extraction** - Automatic ZIP extraction
- **Cross-platform** - Linux and macOS support
- **Modern Architecture** - Swift 6.1 with async/await and actors

### 🚧 Coming Soon
- **Multi-connection Downloads** - Segmented downloads for faster speeds
- **FTP/SFTP Support** - Additional protocol support
- **BitTorrent Support** - P2P downloads
- **Batch Processing** - Queue management and scheduling

## Installation

### Prerequisites
- Swift 6.1 or later
- Linux (Ubuntu 22.04+) or macOS 12+

### Build from Source
```bash
git clone https://github.com/tuliopc23/swiftget-cli.git
cd swiftget-cli
swift build -c release
```

### Install Binary
```bash
# Copy to system path
sudo cp .build/release/swiftget /usr/local/bin/
```

### Homebrew (Coming Soon)
```bash
brew install tuliopc23/swiftget/swiftget
```

## Usage

### Basic Download
```bash
# Download a single file
swiftget https://example.com/file.zip

# Download to specific directory
swiftget -d ~/Downloads https://example.com/file.zip

# Download with custom filename
swiftget -o myfile.zip https://example.com/file.zip
```

### Advanced Options
```bash
# Resume interrupted download
swiftget --continue https://example.com/largefile.zip

# Download with checksum verification
swiftget --checksum sha256:abc123... https://example.com/file.zip

# Use proxy
swiftget --proxy http://proxy.example.com:8080 https://example.com/file.zip

# Custom user agent and headers
swiftget --user-agent "MyApp/1.0" --header "Authorization: Bearer token" https://api.example.com/file.zip

# Quiet mode (no progress bar)
swiftget --quiet https://example.com/file.zip

# Auto-extract archives
swiftget --extract https://example.com/archive.zip
```

### Configuration Management
```bash
# Show current configuration
swiftget config --show

# Set default user agent
swiftget config --set "default-user-agent=SwiftGet/1.0"

# Set default download directory
swiftget config --set "default-directory=/home/user/Downloads"
```

## Performance

SwiftGet is designed for performance and efficiency:

- **Memory Efficient** - Streaming downloads, minimal memory usage
- **Concurrent** - Actor-based architecture for thread safety
- **Fast** - Modern Swift with optimized networking
- **Reliable** - Comprehensive error handling and retry logic

## Comparison with Other Tools

| Feature | SwiftGet | aria2 | wget | curl | axel |
|---------|----------|-------|------|------|------|
| HTTP/HTTPS | ✅ | ✅ | ✅ | ✅ | ✅ |
| Resume Downloads | ✅ | ✅ | ✅ | ✅ | ✅ |
| Progress Bars | ✅ | ✅ | ✅ | ✅ | ✅ |
| Checksum Verification | ✅ | ✅ | ❌ | ❌ | ❌ |
| Config Management | ✅ | ✅ | ✅ | ✅ | ❌ |
| Multi-connection | 🚧 | ✅ | ❌ | ❌ | ✅ |
| Modern Language | ✅ | ❌ | ❌ | ❌ | ❌ |

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Add tests for new functionality
5. Submit a pull request

## License

MIT License - see LICENSE file for details.

## Roadmap

See [ANALYSIS_AND_PLAN.md](ANALYSIS_AND_PLAN.md) for detailed development roadmap and feature plans.
