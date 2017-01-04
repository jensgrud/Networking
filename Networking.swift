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

public typealias HTTPClientCallback = (_ statusCode: Int?, _ data: Data?, _ error: Error?) -> Void

public protocol Router :class {

    var baseURL: URL { get set }
    var accessToken: String? { get set }
}

extension Router {
    
    public func buildRequest(path :String, method :HTTPMethod, accept :ContentType?, encoding :ParameterEncoding, parameters :[String: AnyObject]?, authenticationHeader :String = "Authentication") -> URLRequest? {
        
        let baseURL = self.baseURL.appendingPathComponent(path)
        
        var urlRequest = URLRequest(url: baseURL)
        urlRequest.httpMethod = method.rawValue 
        
        if let token = self.accessToken {
            urlRequest.setValue(token, forHTTPHeaderField: authenticationHeader)
        }
        
        if let accept = accept {
            urlRequest.setValue(accept.rawValue, forHTTPHeaderField: "Accept")
        }
        
        do {
            return try encoding.encode(urlRequest, with: parameters)
        } catch {
            return nil 
        }
    }
    
    public func buildRequest(api :API, authenticationHeader :String = "Authentication") -> URLRequest? {
        
        return self.buildRequest(path: api.path, method: api.method, accept: api.accept, encoding: api.encoding, parameters: api.parameters, authenticationHeader: authenticationHeader)
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

public protocol AuthenticationStrategy: class {
    
    var authenticationHeader: String { get set }
    var isRefreshing: Bool { get }
    var retries: Int { get set }
    var retriesLimit: Int { get }
    
    func refreshToken(_ completionHandler: @escaping (_ error: NSError?, _ token: String?) -> Void)
    func refreshTokenLimitReached() -> Void
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

public class HTTPClient : NSObject {
 
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
    
    public var router :Router?
    public var logging :Logging?
    public var authenticationStrategy :AuthenticationStrategy?

    public static let sharedInstance :HTTPClient = {
        return HTTPClient()
    }()
    
    private var callbacks :[Int:HTTPClientCallback] = [:]
    private var pendingRequests :[Int:NSURLSessionTask] = [:]
    
    public init(authenticationStrategy :AuthenticationStrategy? = nil, router :Router? = nil, logging :Logging? = nil) {
        self.router = router
        self.authenticationStrategy = authenticationStrategy
        self.logging = logging
    }
    
    // MARK: Manager
    
    private let manager: SessionManager = {
        
        var defaultHeaders = SessionManager.default.session.configuration.httpAdditionalHeaders ?? [:]
        defaultHeaders[kUserAgentHeader] = userAgent
        
        let configuration = URLSessionConfiguration.default
        configuration.httpAdditionalHeaders = defaultHeaders
        
        let manager = SessionManager(configuration: configuration)
        
        return manager
    }()
    
    // MARK: Fire request
    
    public func request(api :API, callback: @escaping HTTPClientCallback) -> Request? {
     
        guard let router = self.router else {
            
            callback(URLError.unknown.rawValue, nil, NSError(domain: "", code: 501, userInfo: [NSLocalizedDescriptionKey:"missing router"]))
            
            return nil
        }
        
        var authenticationHeader :String = "Authenticate"
        
        if let authenticationStrategy = authenticationStrategy {
            authenticationHeader = authenticationStrategy.authenticationHeader
        }

        guard let request = router.buildRequest(api: api, authenticationHeader: authenticationHeader) else {
            
            callback(URLError.unknown.rawValue, nil, NSError(domain: "", code: 501, userInfo: [NSLocalizedDescriptionKey:"could not build request"]))
            
            return nil
        }
        
        return self.request(request: request, callback: callback)
    }
    
    public func request(request :URLRequest, callback: @escaping HTTPClientCallback) -> Request {
        
        let task = manager.request(request)
        
        guard let subTask = task.task else {
            
            callback(URLError.unknown.rawValue, nil, NSError(domain: "", code: 501, userInfo: [NSLocalizedDescriptionKey:"missing url session task"]))
                        
            return task
        }
        
        task.validate().responseData { (response) in
            
            let statusCode = response.response?.statusCode
            
            guard response.result.isSuccess else {
                return self.handleError(request: task, response: response, completionHandler: callback)
            }
            
            callback(statusCode, response.data, response.result.error)

            self.callbacks[subTask.taskIdentifier] = nil
        }
        
        if !manager.startRequestsImmediately {
            self.pendingRequests[subTask.taskIdentifier] = task.task
        }
        
        self.callbacks[subTask.taskIdentifier] = callback
        
        return task
    }
    
    // MARK: - Authentication
    
    public func performAuthentication(task :URLSessionTask? = nil, suspend :Bool = true, completionHandler: @escaping HTTPClientCallback, authenticationCallback:((Error?) -> Void)? = nil) {
        
        guard let authenticationStrategy = authenticationStrategy else {
            
            let error = NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"missing authentication strategy"])
            
            if let logging = self.logging {
                logging.logEvent(event: "Authentication limit reached", error: error)
            }
            
            if let task = task {
                task.cancel()
            }
            
            return completionHandler(URLError.userCancelledAuthentication.rawValue, nil, error)
        }
        
        guard authenticationStrategy.retries < authenticationStrategy.retriesLimit else {
            
            authenticationStrategy.retries = 0
            authenticationStrategy.refreshTokenLimitReached()
            
            self.cancelAll()
            
            let error = NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"authentication limit reached"])
            
            if let logging = self.logging {
                logging.logEvent(event: "Authentication limit reached", error: error)
            }
            
            return completionHandler(URLError.userCancelledAuthentication.rawValue, nil, error)
        }
        
        guard !authenticationStrategy.isRefreshing else {
            
            if let task = task {
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            return
        }
        
        if suspend {
            self.suspendAll()
        }

        authenticationStrategy.refreshToken { (error, token) in
            
            authenticationStrategy.retries = authenticationStrategy.retries + 1
            
            if let callback = authenticationCallback {
                callback(error)
            }
            
            if let task = task {
                self.callbacks[task.taskIdentifier] = nil
                self.pendingRequests[task.taskIdentifier] = nil
                task.cancel()
            }
            
            if let error = error {
                
                switch error._code {
                case 504:
                    
                    authenticationStrategy.retries = 0
                    
                    self.resumeAll()
                    
                    if let logging = self.logging {
                        logging.logEvent(event: "Authentication error", error: error)
                    }
                    
                    completionHandler(NSURLErrorCancelled, nil, error)
                    
                default:
                    
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.performAuthentication(task: task, completionHandler: completionHandler, authenticationCallback: authenticationCallback)
                    }
                }
                
                return
            }
            
            authenticationStrategy.retries = 0
            
            if let token = token, let router = self.router {
                router.accessToken = token
            }
            
            self.resumeAll(accessToken: token)
            
            guard var request = task?.originalRequest?.urlRequest else {
                return
            }
            
            request.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
            
            self.request(request: request, callback: completionHandler)
        }
    }
    
    private func handleError(request :Request, response: DataResponse<Data>, completionHandler: @escaping HTTPClientCallback) {
        
        guard let statusCode = response.response?.statusCode else {
            
            let error = response.result.error
            
            if let logging = logging {
                logging.logEvent(event: "Network error", error: error)
            }
            
            return completionHandler(error?._code, response.data, error)
        }
        
        if let error = response.result.error, error._code == URLError.cancelled.rawValue {
            return
        }
        
        switch statusCode {
        case 401:
            
            self.performAuthentication(task: request.task, completionHandler: completionHandler)
            
        default:
            
            if let task = request.task {
                self.callbacks[task.taskIdentifier] = nil
            }
            
            if let logging = logging {
                logging.logEvent(event: "Network error", error: response.result.error)
            }
            
            completionHandler(statusCode, response.data, response.result.error)
        }
    }
    
    // MARK: - Upload
    
    public func uploadImage(image :UIImage, request :URLRequestConvertible, name :String = "file", filename :String = "filename.jpeg", mimeType :MimeType = .JPEG, callback: @escaping HTTPClientCallback) {
        
        guard let data = UIImageJPEGRepresentation(image, 0.8) else {
            return callback(-1, nil, NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid data"]))
        }
        
        return self.uploadData(data: data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
    }
    
    public func uploadVideo(path :String, request :URLRequestConvertible, name :String = "file", filename :String = "filename.mpeg", mimeType :MimeType = .MPEG, callback: @escaping HTTPClientCallback) {
        
        guard let pathURL = URL(string: path) else {
            return callback(-1, nil, NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid path"]))
        }
        
        let data = try! Data(contentsOf: pathURL)
        
        return self.uploadData(data: data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
    }
    
    public func uploadData(data :Data, request :URLRequestConvertible, name :String, filename :String, mimeType :MimeType, callback: @escaping HTTPClientCallback) {
        
        self.manager.upload(multipartFormData: { (formdata) in
            
            formdata.append(data, withName: name, fileName: filename, mimeType: mimeType.rawValue)
            
        }, with: request) { (result) in
            
                switch result {
                case .success(let task, _, _):
                    
                    task.responseData(completionHandler: { (response) in
                        
                        guard response.result.isSuccess else {
                            return self.handleError(request: task, response: response, completionHandler: callback)
                        }
                        
                        callback(response.response?.statusCode, response.data, response.result.error)
                    })
                    
                case .failure(let encodingError):
                    
                    callback(-1, nil, NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"encoding failed \(encodingError)"]))
                }
        }
    }
    
    // MARK: - Suspend/pause/cancel
    
    public func cancelAll() {

        let error = NSError(domain: "", code: 503, userInfo: nil)
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(URLError.cancelled.rawValue, nil, error)
                }
                
                task.cancel()
            }
            
            for task in uploadTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(URLError.cancelled.rawValue, nil, error)
                }
                
                task.cancel()
            }
            
            for task in downloadTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(URLError.cancelled.rawValue, nil, error)
                }
                
                task.cancel()
            }
        }
        
        while let (_, task) = self.pendingRequests.popFirst() {
            
            if let callback = self.callbacks[task.taskIdentifier] {
                callback(URLError.cancelled.rawValue, nil, error)
            }
            
            task.cancel()
        }
        
        manager.startRequestsImmediately = true
        
        pendingRequests.removeAll()
        callbacks.removeAll()
    }
    
    private func suspendAll(currentTask :URLSessionTask? = nil) {
        
        manager.startRequestsImmediately = false
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                
                if let current = currentTask, current.taskIdentifier == task.taskIdentifier {
                    continue
                }
                
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in uploadTasks {
                
                if let current = currentTask, current.taskIdentifier == task.taskIdentifier {
                    continue
                }
                
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in downloadTasks {
                
                if let current = currentTask, current.taskIdentifier == task.taskIdentifier {
                    continue
                }
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
        }
    }
    
    private func resumeAll(accessToken :String? = nil) {
        
        manager.startRequestsImmediately = true
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                self.resume(task: task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            for task in uploadTasks {
                self.resume(task: task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            for task in downloadTasks {
                self.resume(task: task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            while let (identifier, task) = self.pendingRequests.popFirst() {
                self.resume(task: task, identifier: identifier, accessToken: accessToken)
            }
        }
        
    }
    
    private func resume(task :URLSessionTask, identifier :Int, accessToken :String? = nil) {
        
        self.pendingRequests[identifier] = nil
        
        guard let token = accessToken else {
            return task.resume()
        }
        
        guard var request = task.originalRequest?.urlRequest else {
            return task.resume()
        }
        
        guard let callback = self.callbacks[identifier] else {
            return task.resume()
        }
        
        if let authenticationStrategy = self.authenticationStrategy {
            request.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
        }
        
        self.request(request: request) { (statusCode, data, error) in
            callback(statusCode, data, error)
            
            self.callbacks[identifier] = nil
            
            task.cancel()
        }
    }
}
