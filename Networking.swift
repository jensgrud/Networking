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
    var OAuthToken: String? { get set }
}

extension Router {
    
    public func buildRequest(path :String, method :HTTPMethod, accept :ContentType?, encoding :ParameterEncoding, parameters :[String: AnyObject]?, authenticationHeader :String = "Authentication") -> NSMutableURLRequest {
        
        let mutableURLRequest = NSMutableURLRequest(URL: self.baseURL.URLByAppendingPathComponent(path))
        mutableURLRequest.HTTPMethod = method.rawValue
        
        if let token = self.OAuthToken {
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

public protocol AuthenticationStrategy: class {
    
    var authenticationHeader: String { get set }
    var isRefreshing: Bool { get }
    var retries: Int { get set }
    var retriesLimit: Int { get }
    
    func refreshToken(completionHandler: (error :NSError?, token: String?) -> Void)
}

public enum ContentType: String {

    case JSON =         "application/json"
    case JSONAPI =      "application/vnd.api+json"
    case URL =          "application/x-www-form-urlencoded; charset=utf-8"
    case PropertyList = "application/x-plist"
}

public class HTTPClient : NSObject {
 
    private static let kTimeSinceLast = "com.networking.time-since-last"
    private static let kUserAgentHeader = "User-Agent"
    
    private var updateTimeintervalThreshold :Double!
    private var lastUpdate :NSDate? = NSUserDefaults.standardUserDefaults().objectForKey(kTimeSinceLast) as? NSDate {
        didSet {
            NSUserDefaults.standardUserDefaults().setObject(lastUpdate, forKey: HTTPClient.kTimeSinceLast)
        }
    }
    
    private static let userAgent: String = {
        let httpClient = "HTTP client"
        if let info = NSBundle.mainBundle().infoDictionary {
            let executable = info[kCFBundleExecutableKey as String] as? String ?? "Unknown"
            let bundle = info[kCFBundleIdentifierKey as String] as? String ?? "Unknown"
            let version = info[kCFBundleVersionKey as String] as? String ?? "Unknown"
            let os = NSProcessInfo.processInfo().operatingSystemVersionString
            let userAgent = "\(executable)/\(bundle) (\(version); OS \(os))"
            let mutableUserAgent = NSMutableString(string: userAgent) as CFMutableString
            
            let transform = NSString(string: "Any-Latin; Latin-ASCII; [:^ASCII:] Remove") as CFString
            if CFStringTransform(mutableUserAgent, UnsafeMutablePointer<CFRange>(nil), transform, false) {
                return mutableUserAgent as String
            }
        }
        return httpClient
    }()
    
    public var router :Router?
    public var authenticationStrategy :AuthenticationStrategy?

    public static let sharedInstance :HTTPClient = {
        return HTTPClient()
    }()
    
    private var callbacks :[Int:HTTPClientCallback] = [:]
    private var pendingRequests :[Int:NSURLSessionTask] = [:]
    
    public init(authenticationStrategy :AuthenticationStrategy? = nil, router :Router? = nil, updateTimeintervalThreshold :Double = 60 * 60 * 2) {
        self.router = router
        self.authenticationStrategy = authenticationStrategy
        self.updateTimeintervalThreshold = updateTimeintervalThreshold
        self.lastUpdate = NSDate.distantPast()
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

        // Finish request before starting others, if reaching threshold
        guard let lastCheck = lastUpdate where fabs(lastCheck.timeIntervalSinceNow) > updateTimeintervalThreshold else {
            return task
        }
        
        self.lastUpdate = NSDate()
        
        self.suspendAll()
        
        task.response(completionHandler: { (_, _, _, _) in
            
            self.resumeAll()
        })
        
        return task
    }
    
    // MARK: - Authentication
    
    public func performAuthentication(task :NSURLSessionTask? = nil, completionHandler: HTTPClientCallback, authenticationCallback:(NSError? -> Void)? = nil) {
        
        guard let authenticationStrategy = authenticationStrategy else {
            return
        }
        
        guard authenticationStrategy.retries < authenticationStrategy.retriesLimit + 1 else {
            
            authenticationStrategy.retries = 0
            
            if let task = task {
                task.cancel()
            }
            
            self.cancelAll()
            
            return completionHandler(statusCode: NSURLError.Cancelled.rawValue, data: nil, error: NSError(domain: "", code: 503, userInfo: ["message":"authentication limit reached"]))
        }
        
        guard !authenticationStrategy.isRefreshing else {
            
            if let task = task {
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            return
        }
        
        self.suspendAll()

        authenticationStrategy.refreshToken { (error, token) in
            
            authenticationStrategy.retries = authenticationStrategy.retries + 1
            
            if let callback = authenticationCallback {
                callback(error)
            }
            
            guard error == nil else {
                
                let delay = dispatch_time(DISPATCH_TIME_NOW, Int64(3 * Double(NSEC_PER_SEC)))
                
                dispatch_after(delay, dispatch_get_main_queue()) {
                    self.performAuthentication(task, completionHandler: completionHandler, authenticationCallback: authenticationCallback)
                }
                
                return
            }
            
            if let token = token, router = self.router {
                router.OAuthToken = token
            }
            
            self.resumeAll(token)
            
            guard let request = task?.originalRequest else {
                return
            }
            
            request.URLRequest.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
            
            self.request(request.URLRequest, callback: completionHandler)
                .response(completionHandler: { (request, response, data, error) in
                    
                    guard response?.statusCode == 200 else {
                        return
                    }
                    
                    authenticationStrategy.retries = 0
                    
                    if let iden = task?.taskIdentifier {
                        self.callbacks[iden] = nil
                        self.pendingRequests[iden] = nil
                    }
                })
        }
    }
    
    private func handleError(request :Request, response: Response<NSData, NSError>, completionHandler: HTTPClientCallback) {
        
        guard let statusCode = response.response?.statusCode else {
            
            let error = response.result.error
            
            return completionHandler(statusCode: error?.code, data: response.data, error: error)
        }
        
        switch statusCode {
        case 401:
            
            performAuthentication(request.task, completionHandler: completionHandler)
            
        default:
            
            completionHandler(statusCode: statusCode, data: response.data, error: response.result.error)
        }
    }
    
    // MARK: - Suspend/pause/cancel
    
    public func cancelAll() {
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                task.cancel()
            }
            
            for task in uploadTasks {
                task.cancel()
            }
            
            for task in downloadTasks {
                task.cancel()
            }
        }
        
        manager.startRequestsImmediately = true
        
        pendingRequests.removeAll()
        callbacks.removeAll()
    }
    
    private func suspendAll() {
        
        manager.startRequestsImmediately = false
        
        manager.session.getTasksWithCompletionHandler { dataTasks, uploadTasks, downloadTasks in
            
            for task in dataTasks {
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in uploadTasks {
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
            
            for task in downloadTasks {
                task.suspend()
                self.pendingRequests[task.taskIdentifier] = task
            }
        }
    }
    
    private func resumeAll(accessToken :String? = nil) {
        
        manager.startRequestsImmediately = true
        
        while let (identifier, task) = self.pendingRequests.popFirst() {
            
            guard let token = accessToken else {
                task.resume()
                continue
            }
            
            guard let request = task.originalRequest?.URLRequest else {
                task.resume()
                continue
            }
            
            guard let callback = self.callbacks[identifier] else {
                task.resume()
                continue
            }
            
            task.cancel()
            
            if let authenticationStrategy = self.authenticationStrategy {
                request.setValue(token, forHTTPHeaderField: authenticationStrategy.authenticationHeader)
            }
            
            self.request(request, callback: callback)
        }
    }
}