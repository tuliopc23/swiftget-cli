import Foundation
import Network
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Mock HTTP server for testing download functionality
class MockServer {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "MockServer")
    private var isRunning = false
    
    // Test data configurations
    struct TestFile {
        let path: String
        let data: Data
        let contentType: String
        let supportsRanges: Bool
        let simulateSlowResponse: Bool
        let simulateError: Bool
        
        init(path: String, data: Data, contentType: String = "application/octet-stream", 
             supportsRanges: Bool = true, simulateSlowResponse: Bool = false, 
             simulateError: Bool = false) {
            self.path = path
            self.data = data
            self.contentType = contentType
            self.supportsRanges = supportsRanges
            self.simulateSlowResponse = simulateSlowResponse
            self.simulateError = simulateError
        }
    }
    
    private var testFiles: [String: TestFile] = [:]
    
    init(port: UInt16 = 0) {
        self.port = port
        setupDefaultTestFiles()
    }
    
    private func setupDefaultTestFiles() {
        // Small test file
        let smallData = Data("Hello, SwiftGet! This is a small test file.".utf8)
        testFiles["/small.txt"] = TestFile(path: "/small.txt", data: smallData, contentType: "text/plain")
        
        // Medium test file (1MB)
        let mediumData = Data(repeating: 0x41, count: 1024 * 1024) // 1MB of 'A'
        testFiles["/medium.bin"] = TestFile(path: "/medium.bin", data: mediumData)
        
        // Large test file (10MB)
        let largeData = Data(repeating: 0x42, count: 10 * 1024 * 1024) // 10MB of 'B'
        testFiles["/large.bin"] = TestFile(path: "/large.bin", data: largeData)
        
        // File that doesn't support ranges
        testFiles["/no-ranges.txt"] = TestFile(
            path: "/no-ranges.txt", 
            data: Data("This server doesn't support range requests.".utf8),
            contentType: "text/plain",
            supportsRanges: false
        )
        
        // File that simulates slow response
        testFiles["/slow.txt"] = TestFile(
            path: "/slow.txt",
            data: Data("This response is intentionally slow.".utf8),
            contentType: "text/plain",
            simulateSlowResponse: true
        )
        
        // File that simulates server error
        testFiles["/error.txt"] = TestFile(
            path: "/error.txt",
            data: Data(),
            simulateError: true
        )
    }
    
    func addTestFile(_ testFile: TestFile) {
        testFiles[testFile.path] = testFile
    }
    
    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: parameters, on: NWEndpoint.Port(integerLiteral: port))
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }
        
        listener?.start(queue: queue)
        isRunning = true
        
        // Get the actual port if we used 0 (random port)
        if let listener = listener, let actualPort = listener.port {
            return actualPort.rawValue
        }
        
        return port
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }
    
    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            if let data = data, !data.isEmpty {
                self?.processRequest(data: data, connection: connection)
            }
            
            if isComplete {
                connection.cancel()
            } else if error == nil {
                // Continue receiving
                self?.handleConnection(connection)
            }
        }
    }
    
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestString = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let lines = requestString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let components = requestLine.components(separatedBy: " ")
        guard components.count >= 3 else {
            sendResponse(connection: connection, statusCode: 400, body: "Bad Request")
            return
        }
        
        let method = components[0]
        let path = components[1]
        
        // Parse headers
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            if line.isEmpty { break }
            let headerComponents = line.components(separatedBy: ": ")
            if headerComponents.count == 2 {
                headers[headerComponents[0].lowercased()] = headerComponents[1]
            }
        }
        
        handleRequest(method: method, path: path, headers: headers, connection: connection)
    }
    
    private func handleRequest(method: String, path: String, headers: [String: String], connection: NWConnection) {
        guard let testFile = testFiles[path] else {
            sendResponse(connection: connection, statusCode: 404, body: "Not Found")
            return
        }
        
        // Simulate error if configured
        if testFile.simulateError {
            sendResponse(connection: connection, statusCode: 500, body: "Internal Server Error")
            return
        }
        
        // Simulate slow response if configured
        if testFile.simulateSlowResponse {
            DispatchQueue.global().asyncAfter(deadline: .now() + 2.0) {
                self.processFileRequest(method: method, testFile: testFile, headers: headers, connection: connection)
            }
        } else {
            processFileRequest(method: method, testFile: testFile, headers: headers, connection: connection)
        }
    }
    
    private func processFileRequest(method: String, testFile: TestFile, headers: [String: String], connection: NWConnection) {
        if method == "HEAD" {
            // HEAD request - return headers only
            var responseHeaders = [
                "Content-Length": "\(testFile.data.count)",
                "Content-Type": testFile.contentType
            ]
            
            if testFile.supportsRanges {
                responseHeaders["Accept-Ranges"] = "bytes"
            }
            
            sendResponse(connection: connection, statusCode: 200, headers: responseHeaders, body: nil)
            return
        }
        
        if method == "GET" {
            // Handle range requests
            if let rangeHeader = headers["range"], testFile.supportsRanges {
                handleRangeRequest(testFile: testFile, rangeHeader: rangeHeader, connection: connection)
            } else {
                // Full file request
                let responseHeaders = [
                    "Content-Length": "\(testFile.data.count)",
                    "Content-Type": testFile.contentType,
                    "Accept-Ranges": testFile.supportsRanges ? "bytes" : "none"
                ]
                
                sendResponse(connection: connection, statusCode: 200, headers: responseHeaders, body: testFile.data)
            }
            return
        }
        
        sendResponse(connection: connection, statusCode: 405, body: "Method Not Allowed")
    }
    
    private func handleRangeRequest(testFile: TestFile, rangeHeader: String, connection: NWConnection) {
        // Parse range header: "bytes=start-end"
        let rangeString = rangeHeader.replacingOccurrences(of: "bytes=", with: "")
        let rangeParts = rangeString.components(separatedBy: "-")
        
        guard rangeParts.count == 2 else {
            sendResponse(connection: connection, statusCode: 416, body: "Range Not Satisfiable")
            return
        }
        
        let startString = rangeParts[0]
        let endString = rangeParts[1]
        
        let start = startString.isEmpty ? 0 : Int(startString) ?? 0
        let end = endString.isEmpty ? testFile.data.count - 1 : Int(endString) ?? testFile.data.count - 1
        
        guard start >= 0 && end < testFile.data.count && start <= end else {
            sendResponse(connection: connection, statusCode: 416, body: "Range Not Satisfiable")
            return
        }
        
        let rangeData = testFile.data.subdata(in: start..<(end + 1))
        let responseHeaders = [
            "Content-Length": "\(rangeData.count)",
            "Content-Type": testFile.contentType,
            "Content-Range": "bytes \(start)-\(end)/\(testFile.data.count)",
            "Accept-Ranges": "bytes"
        ]
        
        sendResponse(connection: connection, statusCode: 206, headers: responseHeaders, body: rangeData)
    }
    
    private func sendResponse(connection: NWConnection, statusCode: Int, headers: [String: String] = [:], body: Data?) {
        let statusText = HTTPURLResponse.localizedString(forStatusCode: statusCode)
        var response = "HTTP/1.1 \(statusCode) \(statusText)\r\n"
        
        // Add default headers
        response += "Server: SwiftGet-MockServer/1.0\r\n"
        response += "Connection: close\r\n"
        
        // Add custom headers
        for (key, value) in headers {
            response += "\(key): \(value)\r\n"
        }
        
        response += "\r\n"
        
        var responseData = Data(response.utf8)
        if let body = body {
            responseData.append(body)
        }
        
        connection.send(content: responseData, completion: .contentProcessed { error in
            if let error = error {
                print("MockServer send error: \(error)")
            }
            connection.cancel()
        })
    }
    
    var baseURL: String {
        guard let listener = listener, let port = listener.port else {
            return "http://localhost:0"
        }
        return "http://localhost:\(port.rawValue)"
    }
}

// MARK: - Test Utilities

extension MockServer {
    /// Create test data of specified size with pattern
    static func createTestData(size: Int, pattern: UInt8 = 0x41) -> Data {
        return Data(repeating: pattern, count: size)
    }
    
    /// Create test data with specific content for verification
    static func createPatternedTestData(size: Int) -> Data {
        var data = Data()
        for i in 0..<size {
            data.append(UInt8(i % 256))
        }
        return data
    }
}
