//
//  Networking.swift
//  Jens Grud
//
//  Created by Jens Grud on 15/05/16.
//  Copyright © 2016 Heaps. All rights reserved.
//

import Alamofire

public typealias HTTPMethod = Alamofire.HTTPMethod
public typealias ParameterEncoding = Alamofire.ParameterEncoding

public protocol Router :RequestAdapter {
    
    var logging :Logging? { get }
    
    func isAuthenticated() -> Bool
    func isProviderAuthenticated() -> Bool

    var baseURL: URL { get set }
    var authenticationStrategy :AuthenticationStrategy? { get }
}

extension Router {
    
    public func adapt(_ urlRequest: URLRequest) throws -> URLRequest {
        
        var urlRequest = urlRequest
        
        if let strategy = self.authenticationStrategy, let token = strategy.accessToken  {
            urlRequest.setValue(token, forHTTPHeaderField: strategy.authenticationHeader)
        }
        
        return urlRequest
    }
    
    public func buildRequest(path :String, method :HTTPMethod, accept :ContentType?, encoding :ParameterEncoding, parameters :[String: AnyObject]?) -> URLRequest? {
        
        let baseURL = self.baseURL.appendingPathComponent(path)
        
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = method.rawValue 
        
        if let accept = accept {
            urlRequest.setValue(accept.rawValue, forHTTPHeaderField: "Accept")
        }
        
        do {
            return try encoding.encode(urlRequest, with: parameters)
        } catch {
            return nil 
        }
    }
    
    public func buildRequest(api :API) -> URLRequest? {
        
        return self.buildRequest(path: api.path, method: api.method, accept: api.accept, encoding: api.encoding, parameters: api.parameters)
    }
}

public protocol API {

    var path: String { get }
    var method: HTTPMethod { get }
    var encoding : ParameterEncoding { get }
    var accept : ContentType? { get }
    var parameters: [String: AnyObject]? { get }
}

public protocol Logging: class {
    func logEvent(event :String, error :Error?) -> Void
}

public protocol Authentication {
    var accessToken: String? { get }
    var expirationDate: Date? { get }
    var lastAuthentication: Date? { get }
}

public protocol AuthenticationDataProvider : API, Authentication {
    func isAuthenticated() -> Bool
}

public typealias RequestRetryCompletion = (_ shouldRetry: Bool, _ timeDelay: TimeInterval) -> Void
public typealias RefreshCompletion = (_ error: Error?, _ authResponse: AuthResponse?) -> Void

public protocol AuthenticationStrategy: RequestRetrier, Authentication {
    
    var router :Router { get }
    
    var authenticationHeader: String { get }
    
    var isRefreshing: Bool { get }
    var retries: Int { get set }
    var retriesLimit: Int { get }
    
    var authenticationDataProvider :AuthenticationDataProvider { get }
    
    func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion)
    func refreshToken(with manager :SessionManager, and completion: @escaping RefreshCompletion) -> DataRequest?
}

public enum ContentType: String {

    case JSON =         "application/json"
    case JSONAPI =      "application/vnd.api+json"
    case URL =          "application/x-www-form-urlencoded; charset=utf-8"
    case PropertyList = "application/x-plist"
}

public enum MimeType: String {
    
    case JPEG = "image/jpeg"
    case MPEG = "video/mp4"
}

public class HTTPClient {
 
    private static let kUserAgentHeader = "User-Agent"
    
    private static let userAgent: String = {
        let httpClient = "HTTP client"
        if let info = Bundle.main.infoDictionary {
            
            let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
            let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
            let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
            let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"
            let os = ProcessInfo.processInfo.operatingSystemVersionString
            let userAgent = executable + "/" + appVersion + " (" + bundle + "; build:" + appBuild + "; " + os + ")"
            
            return userAgent
        }
        return httpClient
    }()
    
    public var router :Router
    
    // MARK: - Initialization
    
    public init(router :Router) {
        self.router = router
        self.manager.adapter = self.router
        self.manager.retrier = self.router.authenticationStrategy
    }
    
    // MARK: - Manager
    
    open let manager: SessionManager = {
        
        var defaultHeaders = SessionManager.defaultHTTPHeaders
        defaultHeaders[kUserAgentHeader] = userAgent
        
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = defaultHeaders
        
        return SessionManager(configuration: configuration)
    }()
    
    // MARK: - Build request
    
    @discardableResult
    public func request(api :API) -> DataRequest? {
     
        guard let request = self.router.buildRequest(api: api) else {
            return nil
        }
        
        return self.manager.request(request)
    }
    
    // MARK: - Upload
    
    public typealias UploadCallback = (_ request :UploadRequest?, _ error :Error?) -> Void
    
    public func uploadImage(image :UIImage, request :URLRequestConvertible, name :String = "file", filename :String = "filename.jpeg", mimeType :MimeType = .JPEG, callback: @escaping UploadCallback) {
        
        guard let data = UIImageJPEGRepresentation(image, 0.8) else {
            return callback(nil, NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid data"]))
        }
        
        self.uploadData(data: data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
    }
    
    public func uploadVideo(path :String, request :URLRequestConvertible, name :String = "file", filename :String = "filename.mpeg", mimeType :MimeType = .MPEG, callback: @escaping UploadCallback) {
        
        guard let pathURL = URL(string: path) else {
            return callback(nil, NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid path"]))
        }
        
        do {
            let data = try Data(contentsOf: pathURL)
            self.uploadData(data: data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
        } catch (let e) {
            callback(nil, e)
        }
    }
    
    public func uploadData(data :Data, request :URLRequestConvertible, name :String, filename :String, mimeType :MimeType, callback: @escaping UploadCallback) {
        
        self.manager.upload(multipartFormData: { (formdata) in
            
            formdata.append(data, withName: name, fileName: filename, mimeType: mimeType.rawValue)
            
        }, with: request) { (result) in
            
                switch result {
                case .success(let task, _, _):
                    
                    callback(task, nil)
                    
                case .failure(let encodingError):
                    
                    callback(nil, encodingError)
                }
        }
    }
}

// MARK: - Response object serialization

public protocol ResponseObjectSerializable {
    init?(response: HTTPURLResponse, representation: Any)
}

extension DataRequest {
    
    @discardableResult
    func responseObject<T: ResponseObjectSerializable>(
        queue: DispatchQueue? = nil,
        completionHandler: @escaping (DataResponse<T>) -> Void)
        -> Self
    {
        let responseSerializer = DataResponseSerializer<T> { request, response, data, error in
            guard error == nil else { return .failure(BackendError.network(error: error!)) }
            
            let jsonResponseSerializer = DataRequest.jsonResponseSerializer(options: .allowFragments)
            let result = jsonResponseSerializer.serializeResponse(request, response, data, nil)
            
            guard case let .success(jsonObject) = result else {
                return .failure(BackendError.jsonSerialization(error: result.error!))
            }
            
            guard let response = response, let responseObject = T(response: response, representation: jsonObject) else {
                return .failure(BackendError.objectSerialization(reason: "JSON could not be serialized: \(jsonObject)"))
            }
            
            return .success(responseObject)
        }
        
        return response(queue: queue, responseSerializer: responseSerializer, completionHandler: completionHandler)
    }
}

// MARK: - Response object collection serialization

public protocol ResponseCollectionSerializable {
    static func collection(from response: HTTPURLResponse, withRepresentation representation: Any) -> [Self]
}

public extension ResponseCollectionSerializable where Self: ResponseObjectSerializable {
    static func collection(from response: HTTPURLResponse, withRepresentation representation: Any) -> [Self] {
        var collection: [Self] = []
        
        guard let representation = representation as? [[String: Any]] else {
            return collection
        }
        
        for itemRepresentation in representation {
            if let item = Self(response: response, representation: itemRepresentation) {
                collection.append(item)
            }
        }
        
        return collection
    }
}

public extension DataRequest {
    @discardableResult
    func responseCollection<T: ResponseCollectionSerializable>(
        queue: DispatchQueue? = nil,
        completionHandler: @escaping (DataResponse<[T]>) -> Void) -> Self
    {
        let responseSerializer = DataResponseSerializer<[T]> { request, response, data, error in
            guard error == nil else { return .failure(BackendError.network(error: error!)) }
            
            let jsonSerializer = DataRequest.jsonResponseSerializer(options: .allowFragments)
            let result = jsonSerializer.serializeResponse(request, response, data, nil)
            
            guard case let .success(jsonObject) = result else {
                return .failure(BackendError.jsonSerialization(error: result.error!))
            }
            
            guard let response = response else {
                let reason = "Response collection could not be serialized due to nil response."
                return .failure(BackendError.objectSerialization(reason: reason))
            }
            
            return .success(T.collection(from: response, withRepresentation: jsonObject))
        }
        
        return response(responseSerializer: responseSerializer, completionHandler: completionHandler)
    }
}

// MARK: - Capture any underlying Error from the URLSession API

enum BackendError: Error {
    case network(error: Error)
    case jsonSerialization(error: Error)
    case objectSerialization(reason: String)
}

// MARK: - Authentication response struct

public struct AuthResponse: ResponseObjectSerializable, Authentication {
    
    public let accessToken: String?
    public let expirationDate: Date?
    public var lastAuthentication: Date?
    
    public init?(response: HTTPURLResponse, representation: Any) {
        guard
            let representation = representation as? [String: Any],
            let accessToken = representation["access_token"] as? String
            else { return nil }
        
        let expirationString = representation["expires"] as? String
        
        self.accessToken = accessToken
        self.expirationDate = expirationString?.asDate // "2017-04-11T13:53:50+0000"
    }
}

private extension DateFormatter {
    convenience init(dateFormat: String) {
        self.init()
        self.dateFormat = dateFormat
    }
}

private extension String {
    struct S {
        static let formatter = DateFormatter(dateFormat: "yyyy-MM-dd'T'HH:mm:ssZZZZZ")
    }
    var asDate: Date? {
        guard let asDate = S.formatter.date(from: self) else {
            return nil
        }
        return asDate
    }
}

// MARK: - Authentication strategy

open class OAuth2Strategy: AuthenticationStrategy, Authentication {
    
    open var router: Router
    
    open var authenticationHeader: String
    open var accessToken: String?
    open var lastAuthentication: Date?
    open var expirationDate: Date?
    
    open var isRefreshing = false
    open var retries = 0
    open let retriesLimit = 4
    
    private let lock = NSLock()
    
    private var requestsToRetry: [RequestRetryCompletion] = []
    
    // MARK: - Initialization
    
    public init(router :Router, accessToken: String? = nil, authenticationHeader :String, authenticationDataProvider :AuthenticationDataProvider) {
        self.router = router
        self.authenticationHeader = authenticationHeader
        self.authenticationDataProvider = authenticationDataProvider
        
        if let accessToken = accessToken {
            self.accessToken = accessToken
        }
    }
    
    // MARK: - Auth data provider
    
    public var authenticationDataProvider: AuthenticationDataProvider
    
    // MARK: - RequestRetrier
    
    public func should(_ manager: SessionManager, retry request: Request, with error: Error, completion: @escaping RequestRetryCompletion) {
        
        lock.lock() ; defer { lock.unlock() }
        
        guard let response = request.task?.response as? HTTPURLResponse, response.statusCode == 401 else {
            return completion(false, 0.0)
        }
        
        requestsToRetry.append(completion)
        
        guard !isRefreshing else {
            return
        }
        
        refreshToken(with: manager) { [weak self] error, authResponse in
            
            guard let strongSelf = self else { return }
            
            strongSelf.lock.lock() ; defer { strongSelf.lock.unlock() }
            
            if let accessToken = authResponse?.accessToken {
                strongSelf.accessToken = accessToken
            }
            
            if let expirationDate = authResponse?.expirationDate {
                strongSelf.expirationDate = expirationDate
            }
            
            strongSelf.lastAuthentication = Date()
            
            let shouldRetry = error == nil
            
            // Retry if we succeeded
            strongSelf.requestsToRetry.forEach { $0(shouldRetry, 0.0) }
            strongSelf.requestsToRetry.removeAll()
            
            if let logging = strongSelf.router.logging, !shouldRetry {
                logging.logEvent(event: "Authentication failed", error: error)
            }
        }
    }
    
    // MARK: - Private - Refresh Tokens
    @discardableResult
    public func refreshToken(with manager :SessionManager, and completion: @escaping RefreshCompletion) -> DataRequest? {
        
        guard !isRefreshing else {
            return nil
        }
        
        guard let request = router.buildRequest(api: authenticationDataProvider) else {
            completion(NSError(domain: "", code: 504, userInfo: [NSLocalizedDescriptionKey:"Could not build auth request"]), nil)
            return nil
        }
        
        isRefreshing = true
        
        return manager.request(request).responseObject { [weak self] (response: DataResponse<AuthResponse>) in
            
            guard let strongSelf = self else { return }
            
            strongSelf.isRefreshing = false
            strongSelf.retries = strongSelf.retries + 1
            
            guard let statusCode = response.response?.statusCode else {
                return completion(NSError(domain: "", code: 505, userInfo: [NSLocalizedDescriptionKey:"Request failed"]), nil)
            }
            
            switch statusCode {
            case 200:
                
                guard let authResponse = response.result.value else {
                    return completion(NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"Could not parse authentication response"]), nil)
                }
                
                strongSelf.retries = 0
                
                completion(nil, authResponse)
                
            default:
                
                if strongSelf.retries < strongSelf.retriesLimit {
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(strongSelf.retries) * Double(strongSelf.retries)) {
                        
                        strongSelf.refreshToken(with: manager, and: completion)
                    }
                }
                else {
                    
                    completion(NSError(domain: "", code: 506, userInfo: [NSLocalizedDescriptionKey:"Authentication limit reached"]), nil)
                    
                    strongSelf.refreshTokenLimitReached()
                    
                }
            }
        }
    }
    
    // MARK: - Retry limit reached
    open func refreshTokenLimitReached() {
        self.retries = 0
        
        if let logging = router.logging {
            logging.logEvent(event: "Authentication failed", error: NSError(domain: "", code: 501, userInfo: [NSLocalizedDescriptionKey:"Authentication limit reached"]))
        }
    }
}
