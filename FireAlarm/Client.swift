//
//  Client.swift
//  FireAlarm
//
//  Created by NobodyNada on 8/27/16.
//  Copyright © 2016 NobodyNada. All rights reserved.
//

import Foundation
import Dispatch

extension String {
	var urlEncodedString: String {
		var allowed = CharacterSet.urlQueryAllowed
		allowed.remove(charactersIn: "&+")
		return self.addingPercentEncoding(withAllowedCharacters: allowed)!
	}
	
	init(urlParameters: [String:Any]) {
		var result = [String]()
		
		for (key, value) in urlParameters {
			result.append("\(key.urlEncodedString)=\(String(describing: value).urlEncodedString)")
		}
		
		self.init(result.joined(separator: "&"))!
	}
}

func + <K, V> (left: [K:V], right: [K:V]) -> [K:V] {
	var result = left
	for (k, v) in right {
		result[k] = v
	}
	return result
}

//https://stackoverflow.com/a/24052094/3476191
func += <K, V> (left: inout [K:V], right: [K:V]) {
	for (k, v) in right {
		left[k] = v
	}
}

open class Client: NSObject, URLSessionDataDelegate {
	
	static let apiKey = "HNA2dbrFtyTZxeHN6rThNg(("
	
	var session: URLSession!
	
	var loggedIn = false
	
	var cookies = [HTTPCookie]()
	
	/*public func urlSession(_ session: URLSession,
	didReceive challenge: URLAuthenticationChallenge,
	completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
	completionHandler(.useCredential, nil)
	}*/
	
	private func processCookieDomain(domain: String) -> String {
		return URL(string: domain)?.host ?? domain
	}
	
	func addCookies(_ newCookies: [HTTPCookie]) {
		var toAdd = newCookies.map {cookie -> HTTPCookie in
			var properties = cookie.properties ?? [:]
			properties[HTTPCookiePropertyKey.domain] = processCookieDomain(domain: cookie.domain)
			return HTTPCookie(properties: properties) ?? cookie
		}
		for i in 0..<cookies.count {	//for each existing cookie...
			if let index = toAdd.index(where: { $0.name == cookies[i].name && $0.domain == cookies[i].domain }) {
				//if this cookie needs to be replaced, replace it
				cookies[index] = toAdd[index]
				toAdd.remove(at: index)
			}
		}
		cookies.append(contentsOf: toAdd)
	}
	
	func cookieHost(_ host: String, matchesDomain domain: String) -> Bool {
		let hostFields = host.components(separatedBy: ".")
		var domainFields = domain.components(separatedBy: ".")
		if hostFields.count == 0 || domainFields.count == 0 {
			return false
		}
		
		if domainFields.first!.isEmpty {
			domainFields.removeFirst()
		}
		
		//if the domain starts with a dot, match any host which is a subdomain of domain
		var hostIndex = hostFields.count - 1
		for i in (0...domainFields.count - 1).reversed() {
			if hostIndex == 0 && i != 0 {
				return false
			}
			if domainFields[i] != hostFields[hostIndex] {
				return false
			}
			
			hostIndex -= 1
		}
		return true
	}
	
	func cookieHeaders(forURL url: URL) -> [String:String] {
		return HTTPCookie.requestHeaderFields(with: cookies.filter {
			cookieHost(url.host ?? "", matchesDomain: $0.domain)
		})
	}
	
	let queue = DispatchQueue(label: "Client queue", attributes: [.concurrent])
	
	fileprivate var _fkey: String!
	
	var fkey: String! {
		if _fkey == nil {
			//Get the chat fkey.
			let joinFavorites: String = try! get("https://chat.\(host.rawValue)/chats/join/favorite")
			
			guard let inputIndex = joinFavorites.range(of: "type=\"hidden\"")?.upperBound else {
				fatalError("Could not find fkey")
			}
			let input = joinFavorites.substring(from: inputIndex)
			
			guard let fkeyStartIndex = input.range(of: "value=\"")?.upperBound else {
				fatalError("Could not find fkey")
			}
			let fkeyStart = input.substring(from: fkeyStartIndex)
			
			guard let fkeyEnd = fkeyStart.range(of: "\"")?.lowerBound else {
				fatalError("Could not find fkey")
			}
			
			
			_fkey = fkeyStart.substring(to: fkeyEnd)
		}
		return _fkey
	}
	
	enum Host: String {
		case StackOverflow = "stackoverflow.com"
		case StackExchange = "stackexchange.com"
		case MetaStackExchange = "meta.stackexchange.com"
		
		var chatHost: String {
			return "chat." + rawValue
		}
		
		var url: URL {
			return URL(string: "https://" + rawValue)!
		}
		
		var chatHostURL: URL {
			return URL(string: "https://" + chatHost)!
		}
	}
	
	let host: Host
	
	enum RequestError: Error {
		case invalidURL(url: String)
		case notUTF8
	}
	
	public func urlSession(
		_ session: URLSession,
		task: URLSessionTask,
		willPerformHTTPRedirection response: HTTPURLResponse,
		newRequest request: URLRequest,
		completionHandler: @escaping (URLRequest?) -> Void) {
		
		var headers = [String:String]()
		for (k, v) in response.allHeaderFields {
			headers[String(describing: k)] = String(describing: v)
		}
		#if os(Linux)
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, forURL: response.url ?? URL(fileURLWithPath: "invalid")))
		#else
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, for: response.url ?? URL(fileURLWithPath: "invalid")))
		#endif
		completionHandler(request)
	}
	
	func performRequest(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
		var req = request
		
		let sema = DispatchSemaphore(value: 0)
		var data: Data!
		var resp: URLResponse!
		var error: NSError!
		
		let url = req.url ?? URL(fileURLWithPath: ("invalid"))
		
		for (key, val) in cookieHeaders(forURL: url) {
			req.setValue(val, forHTTPHeaderField: key)
		}
		
		queue.async {
			
			self.session.dataTask(with: req, completionHandler: {inData, inResp, inError in
				(data, resp, error) = (inData, inResp, inError as NSError!)
				sema.signal()
			}) .resume()
			
		}
		
		sema.wait()
		
		guard let response = resp as? HTTPURLResponse , data != nil else {
			print(error)
			throw error
		}
		//print(response.allHeaderFields)
		var headers = [String:String]()
		for (k, v) in response.allHeaderFields {
			headers[String(describing: k)] = String(describing: v)
		}
		#if os(Linux)
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, forURL: url))
		#else
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, for: url))
		#endif
		
		return (data, response)
	}
	
	func get(_ url: String) throws -> (Data, HTTPURLResponse) {
		guard let nsUrl = URL(string: url) else {
			throw RequestError.invalidURL(url: url)
		}
		var request = URLRequest(url: nsUrl)
		request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")
		return try performRequest(request)
	}
	
	func post(_ url: String, _ data: [String:Any]) throws -> (Data, HTTPURLResponse) {
		guard let nsUrl = URL(string: url) else {
			throw RequestError.invalidURL(url: url)
		}
		var request = URLRequest(url: nsUrl)
		request.httpMethod = "POST"
		//request.setValue(String(request.httpBody?.count ?? 0), forHTTPHeaderField: "Content-Length")
		//request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type" )
		let url = request.url ?? URL(fileURLWithPath: ("invalid"))
		for (key, val) in cookieHeaders(forURL: url ) {
			request.setValue(val, forHTTPHeaderField: key)
		}
		
		
		let sema = DispatchSemaphore(value: 0)
		var responseData: Data!
		var resp: URLResponse!
		var error: NSError!
		
		queue.async {
			#if os(Linux)
				self.session.uploadTask(
					with: request,
					fromData: String(urlParameters: data).data(using: String.Encoding.utf8),
					completionHandler: {inData, inResp, inError in
						(responseData, resp, error) = (inData, inResp, inError as NSError!)
						sema.signal()
				}) .resume()
			#else
				self.session.uploadTask(
					with: request,
					from: String(urlParameters: data).data(using: String.Encoding.utf8),
					completionHandler: {inData, inResp, inError in
						(responseData, resp, error) = (inData, inResp, inError as NSError!)
						sema.signal()
				}) .resume()
			#endif
			
		}
		
		sema.wait()
		
		guard let response = resp as? HTTPURLResponse , responseData != nil else {
			print(error)
			throw error
		}
		var headers = [String:String]()
		for (k, v) in response.allHeaderFields {
			headers[String(describing: k)] = String(describing: v)
		}
		#if os(Linux)
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, forURL: url))
		#else
			addCookies(HTTPCookie.cookies(withResponseHeaderFields: headers, for: url))
		#endif
		
		return (responseData, response)
	}
	
	enum APIError: Error {
		case badURL(string: String)
		case badJSON(json: String)
		case apiError(id: Int?, name: String?, message: String?)
		case noItems(response: [String:AnyObject])
		case test(response: [String:AnyObject])
	}
	
	var apiFilter: String!
	
	func api(_ request: String) throws -> [String:AnyObject] {
		var urlString = "https://api.stackexchange.com/2.2"
		if request.hasPrefix("/") {
			urlString.append(request)
		}
		else {
			urlString.append("/" + request)
		}
		
		guard var components = URLComponents(string: urlString) else {
			throw APIError.badURL(string: urlString)
		}
		
		//if the request DOESN'T contain a key, add it
		if !((components.queryItems?.contains { $0.name == "key" }) ?? false) {
			var items = components.queryItems ?? []
			items.append(URLQueryItem(name: "key", value: Client.apiKey))
			components.queryItems = items
		}
		
		guard let url = components.string else {
			throw APIError.badURL(string: "how is the URL not a string")
		}
		
		let responseString: String = try get(url)
		
		guard let responseData = responseString.data(using: .utf8) else {
			throw APIError.badJSON(json: responseString)
		}
		
		guard let response = try JSONSerialization.jsonObject(with: responseData, options: []) as? [String:AnyObject] else {
			throw APIError.badJSON(json: responseString)
		}
		
		let errorID = response["error_id"] as? Int
		let errorName = response["error_name"] as? String
		let errorMessage = response["error_message"] as? String
		
		if errorID != nil || errorName != nil || errorMessage != nil {
			throw APIError.apiError(id: errorID, name: errorName, message: errorMessage)
		}
		
		guard let item = (response["items"] as? [[String:AnyObject]])?.first else {
			throw APIError.noItems(response: response)
		}
		
		return item
		
		
		
		
	}
	
	func questionWithID(_ id: Int, site: String = "stackoverflow") throws -> Post {
		if apiFilter == nil {
			apiFilter = try! api("filters/create?include=question.title;question.body;question.tags&unsafe=false")["filter"] as! String
		}
		let response = try api("questions/\(id)?site=\(site)&filter=\(apiFilter!)")
		guard let title = response["title"] as? String, let body = response["body"] as? String else {
			throw APIError.badJSON(json: String(describing: response))
		}
		guard let tags = response["tags"] as? [String] else {
			throw APIError.badJSON(json: String(describing: response))
		}
		
		return Post(
			id: id,
			title: title.stringByDecodingHTMLEntities,
			body: body.stringByDecodingHTMLEntities,
			tags: tags,
			creationDate: (response["creation_date"] as? Int) ?? -1,
			lastActivityDate: (response["last_activity_date"] as? Int) ?? -1
		)
		
	}
	
	
	func performRequest(_ request: URLRequest) throws -> String {
		let (data, _) = try performRequest(request)
		guard let string = String(data: data, encoding: String.Encoding.utf8) else {
			throw RequestError.notUTF8
		}
		return string
	}
	
	func get(_ url: String) throws -> String {
		let (data, _) = try get(url)
		guard let string = String(data: data, encoding: String.Encoding.utf8) else {
			throw RequestError.notUTF8
		}
		return string
	}
	
	func post(_ url: String, _ fields: [String:Any]) throws -> String {
		let (data, _) = try post(url, fields)
		guard let string = String(data: data, encoding: String.Encoding.utf8) else {
			throw RequestError.notUTF8
		}
		return string
	}
	
	func parseJSON(_ json: String) throws -> Any {
		return try JSONSerialization.jsonObject(with: json.data(using: String.Encoding.utf8)!, options: .allowFragments)
	}
	
	
	override convenience init() {
		self.init(host: .StackOverflow)
	}
	
	init(host: Host) {
		self.host = host
		
		let configuration =  URLSessionConfiguration.default
		
		super.init()
		
		/*configuration.connectionProxyDictionary = [
		"HTTPEnable" : 1,
		kCFNetworkProxiesHTTPProxy as AnyHashable : "192.168.1.234",
		kCFNetworkProxiesHTTPPort as AnyHashable : 8080,
		
		"HTTPSEnable" : 1,
		kCFNetworkProxiesHTTPSProxy as AnyHashable : "192.168.1.234",
		kCFNetworkProxiesHTTPSPort as AnyHashable : 8080
		]*/
		
		configuration.httpCookieStorage = nil
		//clearCookies(configuration.httpCookieStorage!)
		
		session = URLSession(
			configuration: configuration,
			delegate: self, delegateQueue: nil
		)
		
		//check if we're already logged in
		let request = URLRequest(url: URL(string: "https://stackexchange.com/users/logout")!)
		
		let semaphore = DispatchSemaphore(value: 0)
		
		let task = session.dataTask(with: request, completionHandler: {data, resp, error in
			guard let response = (resp as? HTTPURLResponse) , error == nil else {
				self.loggedIn = false
				semaphore.signal()
				return
			}
			
			self.loggedIn = response.statusCode == 200 && response.url?.lastPathComponent == "logout"
			semaphore.signal()
		})
		
		task.resume()
		
		semaphore.wait()
	}
	
	enum LoginError: Error {
		case alreadyLoggedIn
		case loginDataNotFound
		case loginFailed(message: String)
	}
	
	fileprivate func getHiddenInputs(_ string: String) -> [String:String] {
		var result = [String:String]()
		
		let components = string.components(separatedBy: "<input type=\"hidden\"")
		
		for input in components[1..<components.count] {
			guard let nameStartIndex = input.range(of: "name=\"")?.upperBound else {
				continue
			}
			let nameStart = input.substring(from: nameStartIndex)
			
			guard let nameEndIndex = nameStart.range(of: "\"")?.lowerBound else {
				continue
			}
			let name = nameStart.substring(to: nameEndIndex)
			
			guard let valueStartIndex = nameStart.range(of: "value=\"")?.upperBound else {
				continue
			}
			let valueStart = nameStart.substring(from: valueStartIndex)
			
			guard let valueEndIndex = valueStart.range(of: "\"")?.lowerBound else {
				continue
			}
			
			let value = valueStart.substring(to: valueEndIndex)
			
			result[name] = value
		}
		
		return result
	}
	
	func loginWithEmail(_ email: String, password: String) throws {
		if loggedIn {
			throw LoginError.alreadyLoggedIn
		}
		
		print("Logging in...")
		
		let loginPage: String = try get(post("https://stackexchange.com/users/signin",
		                                     ["from" : "https://stackexchange.com/users/login/log-in"]
		))
		
		let hiddenInputs = getHiddenInputs(loginPage)
		
		guard hiddenInputs["affId"] != nil && hiddenInputs["fkey"] != nil else {
			throw LoginError.loginDataNotFound
		}
		
		let fields: [String:Any] = [
			"email":email,
			"password":password,
			"affId" : hiddenInputs["affId"]!,
			"fkey" : hiddenInputs["fkey"]!
		]
		let (linkData, _) = try post(
			"https://openid.stackexchange.com/affiliate/form/login/submit", fields
		)
		
		let page = String(data: linkData, encoding: String.Encoding.utf8)!
		
		if let errorStartIndex = page.range(of: "<div class=\"error\"><p>")?.upperBound {
			let errorStart = page.substring(from: errorStartIndex)
			let errorEndIndex = errorStart.range(of: "</p></div>")!.lowerBound
			let error = errorStart.substring(to: errorEndIndex)
			
			throw LoginError.loginFailed(message: error)
		}
		
		let linkStart = page.substring(from: page.range(of: "<a href=\"")!.upperBound)
		let linkEndIndex = linkStart.range(of: "\"")!.lowerBound
		let link = linkStart.substring(to: linkEndIndex)
		
		let (_,_) = try get(link)
		
		
		if !(host == .StackExchange) {
			//Login to host.
			let hostLoginURL = "https://\(host.rawValue)/users/login"
			let hostLoginPage: String = try get(hostLoginURL)
			guard let fkey = getHiddenInputs(hostLoginPage)["fkey"] else {
				throw LoginError.loginDataNotFound
			}
			
			let (_,_) = try post(hostLoginURL, [
				"email" : email,
				"password" : password,
				"fkey" : fkey
				]
			)
		}
	}
	
	
}
