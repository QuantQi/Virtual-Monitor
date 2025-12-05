import Foundation
import NIOSSL
import Logging

/// Errors that can occur during TLS configuration
enum TLSConfigurationError: Error, CustomStringConvertible {
    case missingCertificatePath
    case missingKeyPath
    case certificateLoadFailed(path: String, underlying: Error)
    case keyLoadFailed(path: String, underlying: Error)
    case contextCreationFailed(underlying: Error)
    
    var description: String {
        switch self {
        case .missingCertificatePath:
            return "TLS enabled but VM_TLS_CERT_PATH not set"
        case .missingKeyPath:
            return "TLS enabled but VM_TLS_KEY_PATH not set"
        case .certificateLoadFailed(let path, let error):
            return "Failed to load TLS certificate from '\(path)': \(error)"
        case .keyLoadFailed(let path, let error):
            return "Failed to load TLS private key from '\(path)': \(error)"
        case .contextCreationFailed(let error):
            return "Failed to create SSL context: \(error)"
        }
    }
}

/// Creates an NIOSSLContext from AppConfiguration if TLS is enabled and configured.
/// - Parameter config: The application configuration
/// - Returns: An NIOSSLContext if TLS is enabled and properly configured, nil otherwise
/// - Throws: TLSConfigurationError if TLS is enabled but configuration is invalid
func makeServerSSLContext(from config: AppConfiguration) throws -> NIOSSLContext? {
    let logger = Logger(label: "com.virtualmonitor.tls")
    
    guard config.tlsEnabled else {
        logger.debug("TLS is disabled")
        return nil
    }
    
    guard let certPath = config.tlsCertPath else {
        throw TLSConfigurationError.missingCertificatePath
    }
    
    guard let keyPath = config.tlsKeyPath else {
        throw TLSConfigurationError.missingKeyPath
    }
    
    logger.info("Loading TLS certificate from: \(certPath)")
    logger.info("Loading TLS private key from: \(keyPath)")
    
    // Load certificate chain
    let certificates: [NIOSSLCertificate]
    do {
        certificates = try NIOSSLCertificate.fromPEMFile(certPath)
    } catch {
        throw TLSConfigurationError.certificateLoadFailed(path: certPath, underlying: error)
    }
    
    guard !certificates.isEmpty else {
        throw TLSConfigurationError.certificateLoadFailed(
            path: certPath,
            underlying: NSError(domain: "TLS", code: -1, userInfo: [NSLocalizedDescriptionKey: "No certificates found in file"])
        )
    }
    
    // Load private key
    let privateKey: NIOSSLPrivateKey
    do {
        privateKey = try NIOSSLPrivateKey(file: keyPath, format: .pem)
    } catch {
        throw TLSConfigurationError.keyLoadFailed(path: keyPath, underlying: error)
    }
    
    // Build TLS configuration with reasonable defaults
    let tlsConfig = TLSConfiguration.makeServerConfiguration(
        certificateChain: certificates.map { .certificate($0) },
        privateKey: .privateKey(privateKey)
    )
    
    // Create SSL context
    do {
        let sslContext = try NIOSSLContext(configuration: tlsConfig)
        logger.info("TLS context created successfully (minimum TLS version: 1.2)")
        return sslContext
    } catch {
        throw TLSConfigurationError.contextCreationFailed(underlying: error)
    }
}
