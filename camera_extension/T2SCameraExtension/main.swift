import Foundation
import CoreMediaIO

let providerSource = T2SProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)

CFRunLoopRun()
