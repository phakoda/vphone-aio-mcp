import MCP
import System
import Darwin
import Foundation

enum VPhoneMCPMainError: Error {
    case failedToDuplicateStdio
}

@main
struct VPhoneMCPMain {
    static func main() {
        vphoneMCPDebug("main enter")
        let runtime = VPhoneSessionController()

        Task {
            do {
                await runtime.prepareUI()
                vphoneMCPDebug("main UI prepared")

                let server = Server(
                    name: "vphone-mcp",
                    version: "0.1.0",
                    instructions: """
                        Control the virtual iPhone through screenshots and normalized touch gestures.
                        Typical loop: call `vphone_status`, then `vphone_start`, then alternate between
                        `vphone_screenshot` and touch tools (`vphone_tap`, `vphone_swipe`).
                        Coordinates are normalized with origin at the top-left corner of the phone display.
                        """
                    ,
                    capabilities: .init(
                        tools: .init(listChanged: false)
                    )
                )
                vphoneMCPDebug("main server configured")

                await server.withMethodHandler(ListTools.self) { _ in
                    ListTools.Result(tools: VPhoneMCPTools.all)
                }

                await server.withMethodHandler(CallTool.self) { params in
                    await VPhoneMCPToolHandler.handle(params, runtime: runtime)
                }

                let stdinCopy = dup(STDIN_FILENO)
                let stdoutCopy = dup(STDOUT_FILENO)
                guard stdinCopy >= 0, stdoutCopy >= 0 else {
                    throw VPhoneMCPMainError.failedToDuplicateStdio
                }

                let transport = StdioTransport(
                    input: System.FileDescriptor(rawValue: stdinCopy),
                    output: System.FileDescriptor(rawValue: stdoutCopy)
                )
                try await server.start(transport: transport)
                vphoneMCPDebug("main server started")
                await server.waitUntilCompleted()
                vphoneMCPDebug("main server completed")
                await runtime.shutdown()
                vphoneMCPDebug("main shutdown complete")
            } catch {
                vphoneMCPDebug("main fatal error: \(error.localizedDescription)")
            }

            CFRunLoopStop(CFRunLoopGetMain())
        }

        RunLoop.main.run()
    }
}
