//
//  Examples.swift
//  Jens Grud
//
//  Created by Jens Grud on 15/06/16.
//  Copyright © 2016 Heaps. All rights reserved.
//

import Networking

let baseTestURL = URL(string: "https://backend.example.com")!

private let httpClient = HTTPClient(router: MyRouter())

public typealias HTTPClientCallback = (_ statusCode: Int?, _ data: Data?, _ error: Error?) -> Void

extension HTTPClient {
    
    @discardableResult
    public func request(api :API, callback: @escaping HTTPClientCallback) -> DataRequest? {
        
        guard let task = self.request(api: api) else {
            return nil
        }
        
        task.validate().responseData { (response) in
            callback(response.response?.statusCode, response.data, response.result.error)
        }
        
        return task
    }
}

let accessTokenKey = "access_token"
let authenticationHeader = "X-Authentication-Header"

class MyRouter :Router {
    
    var baseURL: URL = baseTestURL
    lazy var authenticationStrategy :AuthenticationStrategy? = {
        
        return FBAuthenticationStrategy(router :self, authenticationHeader: authenticationHeader, authenticationDataProvider : FBAuthenticationStrategy.FacebookAuthProvider())
    }()
    
    public func isAuthenticated() -> Bool {
        // TODO: Have a look at this
        return self.authenticationStrategy?.accessToken != nil
    }
}

enum MyAPI : API {
    case dummy(String)
}

extension MyAPI {
    
    var path: String {
        switch self {
        case .dummy(let dummyString):
            return "/dummy/\(dummyString)"
        }
    }
    var method: HTTPMethod {
        switch self {
        default:
            return .get
        }
    }
    var encoding: ParameterEncoding {
        switch self {
        default:
            return URLEncoding.default
        }
    }
    var parameters: [String: AnyObject]? {
        switch self {
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

open class FBAuthenticationStrategy: OAuth2Strategy {
    
    // MARK: - Initialization
    
    override init(router :Router, accessToken: String = "", authenticationHeader: String, authenticationDataProvider: AuthenticationDataProvider) {
        super.init(router :router,
                   accessToken: accessToken,
                   authenticationHeader: authenticationHeader,
                   authenticationDataProvider: authenticationDataProvider)
    }
    
    // MARK: - Auth data provider
    
    public class FacebookAuthProvider: AuthenticationDataProvider {
        
        public var accessTokenKey: String = "access_token"
        
        public var accept: ContentType? = .JSON
        public var encoding: ParameterEncoding = JSONEncoding.default
        public var method: HTTPMethod = .post
        public var path: String = "/authenticate"
        public var parameters: [String : AnyObject]?
        
        public init(parameters :[String:AnyObject] = [:]) {
            self.parameters = parameters
        }
        
        public func generateAuthenticationData() -> [String : Any]? {
            
            if var parameters = self.parameters {
                parameters["fb_id"] = "123" as AnyObject?
                parameters["oauth_token"] = "123" as AnyObject?
            }
            
            return self.parameters
        }
    }
    
    override open func refreshTokenLimitReached() {
        super.refreshTokenLimitReached()
    }
}

