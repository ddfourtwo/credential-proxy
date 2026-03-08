import SwiftUI

// Start the HTTP server synchronously before SwiftUI takes over the run loop.
// This ensures the server is listening by the time any MCP relay connects.
ServerManager.startShared()
CredentialProxyApp.main()
