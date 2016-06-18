//
//  Examples.swift
//  Jens Grud
//
//  Created by Jens Grud on 15/06/16.
//  Copyright © 2016 Heaps. All rights reserved.
//

import FBSDKLoginKit
import Networking

let authenticationData = [
    "platform":"ios",
    "os_version":UIDevice.currentDevice().systemVersion,
    "timezone":NSTimeZone.systemTimeZone().name,
]

let fbAuthenticationStrategy = FBAuthenticationStrategy(authData: authenticationData)

let httpClient = Networking.HTTPClient(authenticationStrategy: fbAuthenticationStrategy, router: MyRouter())

class MyRouter :Networking.Router {
    
    var baseURL: NSURL = NSURL(string: "https://backend.example.com")! {
        didSet {
        }
    }
    
    var OAuthToken: String? {
        didSet {
        }
    }
}

enum MyAPI : API {
    case Authenticate([String:AnyObject])
    case UserCreate([String: AnyObject])
    case UserRead(String)
    case UserUpdate(String, [String: AnyObject])
    case UserDestroy(String)
}

extension MyAPI {
    
    var path: String {
        switch self {
        case .Authenticate:
            return "/authenticate"
        case .UserCreate:
            return "/users"
        case .UserRead(let userID):
            return "/users/\(userID)"
        case .UserUpdate(let userID, _):
            return "/users/\(userID)"
        case .UserDestroy(let userID):
            return "/users/\(userID)"
        }
    }
    var method: HTTPMethod {
        switch self {
        case .Authenticate, .UserCreate:
            return .POST
        case .UserRead:
            return .GET
        case .UserUpdate:
            return .PUT
        case .UserDestroy:
            return .DELETE
        }
    }
    var encoding: ParameterEncoding {
        switch self {
        case .Authenticate, UserCreate, UserUpdate:
            return .JSON
        default:
            return .URL
        }
    }
    var parameters: [String: AnyObject]? {
        switch self {
        case .Authenticate(let parameters):
            return parameters
        case .UserCreate(let parameters):
            return parameters
        case .UserUpdate(_, let parameters):
             return parameters
        default:
            return nil
        }
    }
    var accept: ContentType? {
        switch self {
        default:
            return .JSON
        }
    }
}

public class FBAuthenticationStrategy: AuthenticationStrategy {
    
    public var authenticationHeader = "Authentication"
    public var isRefreshing = false
    public var retries = 0
    public let retriesLimit = 3
    
    private var authData: [String:String]!
    
    let authClient = Networking.HTTPClient(router: MyRouter())
    
    public init(authData :[String:String]) {
        self.authData = authData
    }
    
    public func refreshToken(completionHandler: (error: NSError?, token: String?) -> Void) {
        
        guard !isRefreshing else {
            return
        }
        
        guard let accessToken = FBSDKAccessToken.currentAccessToken() else {
            return completionHandler(error: NSError(domain: "", code: 501, userInfo: ["message":"token missing"]), token: nil)
        }
        
        guard let userId = accessToken.userID, oAuthToken = accessToken.tokenString else {
            return completionHandler(error: NSError(domain: "", code: 502, userInfo: ["message":"invalid token data"]), token: nil)
        }
        
        self.isRefreshing = true
        
        authData["fb_id"] = userId
        authData["oauth_token"] = oAuthToken
        
        authClient.request(MyAPI.Authenticate(authData)) { (statusCode, data, error) in
            
            self.isRefreshing = false
            
            switch statusCode! {
            case 200:
                
                guard let data = data else {
                    return completionHandler(error: NSError(domain: "", code: 503, userInfo: ["message":"could not parse response"]), token: nil)
                }
                
                var info :AnyObject!
                
                do {
                    info  = try NSJSONSerialization.JSONObjectWithData(data, options: NSJSONReadingOptions())
                } catch let error as NSError? {
                    return completionHandler(error: error, token: nil)
                }
                
                if let token = info["access_token"] as? String {
                    
                    completionHandler(error: nil, token: token)
                }
                else {
                    
                    completionHandler(error: NSError(domain: "", code: 504, userInfo: ["message":"token missing"]), token: nil)
                }
                
            default:
                
                completionHandler(error:
                    NSError(domain: "", code: 505, userInfo: ["message":"request failed"]), token: nil)
            }
        }
    }
}
