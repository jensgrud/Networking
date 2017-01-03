//
//  Networking.swift
//  Jens Grud
//
//  Created by Jens Grud on 15/05/16.
//  Copyright © 2016 Heaps. All rights reserved.
//

import Alamofire

public typealias HTTPMethod = Alamofire.Method
public typealias ParameterEncoding = Alamofire.ParameterEncoding

public typealias HTTPClientCallback = (statusCode: Int?, data: NSData?, error: NSError?) -> Void

public protocol Router :class {

    var baseURL: NSURL { get set }
    var accessToken: String? { get set }
}

extension Router {
    
    public func buildRequest(path :String, method :HTTPMethod, accept :ContentType?, encoding :ParameterEncoding, parameters :[String: AnyObject]?, authenticationHeader :String = "Authentication") -> NSMutableURLRequest {
        
        #if swift(>=2.3)
            let baseURL = self.baseURL.URLByAppendingPathComponent(path)!
        #else
            let baseURL = self.baseURL.URLByAppendingPathComponent(path)
        #endif
        
        let mutableURLRequest = NSMutableURLRequest(URL: baseURL)
        mutableURLRequest.HTTPMethod = method.rawValue
        
        if let token = self.accessToken {
            mutableURLRequest.setValue(token, forHTTPHeaderField: authenticationHeader)
        }
        
        if let accept = accept {
            mutableURLRequest.setValue(accept.rawValue, forHTTPHeaderField: "Accept")
        }
        
        return encoding.encode(mutableURLRequest, parameters: parameters).0   
    }
    
    public func buildRequest(api :API, authenticationHeader :String = "Authentication") -> NSMutableURLRequest {
        
        return self.buildRequest(api.path, method: api.method, accept: api.accept, encoding: api.encoding, parameters: api.parameters, authenticationHeader: authenticationHeader)
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
    func logEvent(event :String, error :NSError?) -> Void
}

public protocol AuthenticationStrategy: class {
    
    var authenticationHeader: String { get set }
    var isRefreshing: Bool { get }
    var retries: Int { get set }
    var retriesLimit: Int { get }
    
    func refreshToken(completionHandler: (error :NSError?, token: String?) -> Void)
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
        if let info = NSBundle.mainBundle().infoDictionary {
            let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
            let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
            let appVersion = info["CFBundleShortVersionString"] as? String ?? "Unknown"
            let appBuild = info[kCFBundleVersionKey as String] as? String ?? "Unknown"
            let os = NSProcessInfo.processInfo().operatingSystemVersionString
            let userAgent = executable + "/" + appVersion + " (" + bundle + "; build:" + appBuild + "; " + os + ")"
            let mutableUserAgent = NSMutableString(string: userAgent) as CFMutableString
            
            let transform = NSString(string: "Any-Latin; Latin-ASCII; [:^ASCII:] Remove") as CFString
            if CFStringTransform(mutableUserAgent, UnsafeMutablePointer<CFRange>(nil), transform, false) {
                return mutableUserAgent as String
            }
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
    
    private let manager: Manager = {
        
        var defaultHeaders = Alamofire.Manager.sharedInstance.session.configuration.HTTPAdditionalHeaders ?? [:]
        defaultHeaders[kUserAgentHeader] = userAgent
        
        let configuration = NSURLSessionConfiguration.defaultSessionConfiguration()
        configuration.HTTPAdditionalHeaders = defaultHeaders
        
        let manager = Manager(configuration: configuration)
        
        return manager
    }()
    
    // MARK: Fire request
    
    public func request(api :API, callback: HTTPClientCallback) -> Request? {
     
        guard let router = self.router else {
            return nil
        }
        
        var authenticationHeader :String = "Authenticate"
        
        if let authenticationStrategy = authenticationStrategy {
            authenticationHeader = authenticationStrategy.authenticationHeader
        }

        let request = router.buildRequest(api, authenticationHeader: authenticationHeader)
        
        return self.request(request, callback: callback)
    }
    
    public func request(request :NSURLRequest, callback: HTTPClientCallback) -> Request {
        
        let task = manager.request(request)
        
        task.validate().responseData { (response) in
            
            let statusCode = response.response?.statusCode
            
            guard response.result.isSuccess else {
                return self.handleError(task, response: response, completionHandler: callback)
            }
            
            callback(statusCode: statusCode, data: response.data, error: response.result.error)

            self.callbacks[task.task.taskIdentifier] = nil
        }
        
        if !manager.startRequestsImmediately {
            self.pendingRequests[task.task.taskIdentifier] = task.task
        }
        
        self.callbacks[task.task.taskIdentifier] = callback
        
        return task
    }
    
    // MARK: - Authentication
    
    public func performAuthentication(task :NSURLSessionTask? = nil, suspend :Bool = true, completionHandler: HTTPClientCallback, authenticationCallback:(NSError? -> Void)? = nil) {
        
        guard let authenticationStrategy = authenticationStrategy else {
            
            let error = NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"missing authentication strategy"])
            
            if let logging = self.logging {
                logging.logEvent("Authentication limit reached", error: error)
            }
            
            if let task = task {
                task.cancel()
            }
            
            return completionHandler(statusCode: NSURLError.UserCancelledAuthentication.rawValue, data: nil, error: error)
        }
        
        guard authenticationStrategy.retries < authenticationStrategy.retriesLimit else {
            
            authenticationStrategy.retries = 0
            authenticationStrategy.refreshTokenLimitReached()
            
            self.cancelAll()
            
            let error = NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"authentication limit reached"])
            
            if let logging = self.logging {
                logging.logEvent("Authentication limit reached", error: error)
            }
            
            return completionHandler(statusCode: NSURLError.UserCancelledAuthentication.rawValue, data: nil, error: error)
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
                
                switch error.code {
                case 504:
                    
                    authenticationStrategy.retries = 0
                    
                    self.resumeAll()
                    
                    if let logging = self.logging {
                        logging.logEvent("Authentication error", error: error)
                    }
                    
                    completionHandler(statusCode: NSURLErrorCancelled, data: nil, error: error)
                    
                default:
                    
                    let delay = dispatch_time(DISPATCH_TIME_NOW, Int64(3 * Double(NSEC_PER_SEC)))
                    
                    dispatch_after(delay, dispatch_get_main_queue()) {
                        self.performAuthentication(task, completionHandler: completionHandler, authenticationCallback: authenticationCallback)
                    }
                }
                
                return
            }
            
            authenticationStrategy.retries = 0
            
            if let token = token, router = self.router {
                router.accessToken = token
            }
            
            self.resumeAll(token)
            
            guard let request = task?.originalRequest?.URLRequest else {
                return
            }
            
            request.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
            
            self.request(request, callback: completionHandler)
        }
    }
    
    private func handleError(request :Request, response: Response<NSData, NSError>, completionHandler: HTTPClientCallback) {
        
        guard let statusCode = response.response?.statusCode else {
            
            let error = response.result.error
            
            if let logging = logging {
                logging.logEvent("Network error", error: error)
            }
            
            return completionHandler(statusCode: error?.code, data: response.data, error: error)
        }
        
        if let error = response.result.error where error.code == NSURLError.Cancelled.rawValue {
            return
        }
        
        switch statusCode {
        case 401:
            
            self.performAuthentication(request.task, completionHandler: completionHandler)
            
        default:
            
            self.callbacks[request.task.taskIdentifier] = nil
            
            if let logging = logging {
                logging.logEvent("Network error", error: response.result.error)
            }
            
            completionHandler(statusCode: statusCode, data: response.data, error: response.result.error)
        }
    }
    
    // MARK: - Upload
    
    public func uploadImage(image :UIImage, request :URLRequestConvertible, name :String = "file", filename :String = "filename.jpeg", mimeType :MimeType = .JPEG, callback: HTTPClientCallback) {
        
        guard let data = UIImageJPEGRepresentation(image, 0.8) else {
            return callback(statusCode: -1, data: nil, error: NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid data"]))
        }
        
        return self.uploadData(data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
    }
    
    public func uploadVideo(path :String, request :URLRequestConvertible, name :String = "file", filename :String = "filename.mpeg", mimeType :MimeType = .MPEG, callback: HTTPClientCallback) {
        
        guard let data = NSData(contentsOfFile: path) else {
            return callback(statusCode: -1, data: nil, error: NSError(domain: "", code: 502, userInfo: [NSLocalizedDescriptionKey:"invalid data"]))
        }
        
        return self.uploadData(data, request: request, name: name, filename: filename, mimeType: mimeType, callback: callback)
    }
    
    public func uploadData(data :NSData, request :URLRequestConvertible, name :String, filename :String, mimeType :MimeType, callback: HTTPClientCallback) {
        
        self.manager.upload(request, multipartFormData: { (formdata) in
            
            formdata.appendBodyPart(data: data, name: name, fileName: filename, mimeType: mimeType.rawValue)
            
            }) { (result) in
                
                switch result {
                case .Success(let task, _, _):
                    
                    task.responseData(completionHandler: { (response) in
                        
                        guard response.result.isSuccess else {
                            return self.handleError(task, response: response, completionHandler: callback)
                        }
                        
                        callback(statusCode: response.response?.statusCode, data: response.data, error: response.result.error)
                    })
                    
                case .Failure(let encodingError):
                    
                    callback(statusCode: -1, data: nil, error: NSError(domain: "", code: 503, userInfo: [NSLocalizedDescriptionKey:"encoding failed \(encodingError)"]))
                }
        }
    }
    
    // MARK: - Suspend/pause/cancel
    
    public func cancelAll() {

        let error = NSError(domain: "", code: 503, userInfo: nil)
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(statusCode: NSURLError.Cancelled.rawValue, data: nil, error: error)
                }
                
                task.cancel()
            }
            
            for task in uploadTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(statusCode: NSURLError.Cancelled.rawValue, data: nil, error: error)
                }
                
                task.cancel()
            }
            
            for task in downloadTasks {
                
                if let callback = self.callbacks[task.taskIdentifier] {
                    callback(statusCode: NSURLError.Cancelled.rawValue, data: nil, error: error)
                }
                
                task.cancel()
            }
        }
        
        while let (_, task) = self.pendingRequests.popFirst() {
            
            if let callback = self.callbacks[task.taskIdentifier] {
                callback(statusCode: NSURLError.Cancelled.rawValue, data: nil, error: error)
            }
            
            task.cancel()
        }
        
        manager.startRequestsImmediately = true
        
        pendingRequests.removeAll()
        callbacks.removeAll()
    }
    
    private func suspendAll(currentTask :NSURLSessionTask? = nil) {
        
        manager.startRequestsImmediately = false
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                
                if let current = currentTask where current.taskIdentifier == task.taskIdentifier {
                    continue
                }
                
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in uploadTasks {
                
                if let current = currentTask where current.taskIdentifier == task.taskIdentifier {
                    continue
                }
                
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in downloadTasks {
                
                if let current = currentTask where current.taskIdentifier == task.taskIdentifier {
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
                self.resume(task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            for task in uploadTasks {
                self.resume(task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            for task in downloadTasks {
                self.resume(task, identifier: task.taskIdentifier, accessToken: accessToken)
            }
            
            while let (identifier, task) = self.pendingRequests.popFirst() {
                self.resume(task, identifier: identifier, accessToken: accessToken)
            }
        }
        
    }
    
    private func resume(task :NSURLSessionTask, identifier :Int, accessToken :String? = nil) {
        
        self.pendingRequests[identifier] = nil
        
        guard let token = accessToken else {
            return task.resume()
        }
        
        guard let request = task.originalRequest?.URLRequest else {
            return task.resume()
        }
        
        guard let callback = self.callbacks[identifier] else {
            return task.resume()
        }
        
        if let authenticationStrategy = self.authenticationStrategy {
            request.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
        }
        
        self.request(request) { (statusCode, data, error) in
            callback(statusCode: statusCode, data: data, error: error)
            
            self.callbacks[identifier] = nil
            
            task.cancel()
        }
    }
}
