//
//  CBLTestCase.swift
//  CouchbaseLite
//
//  Copyright (c) 2017 Couchbase, Inc All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import XCTest
import Foundation
@testable import CouchbaseLiteSwift

extension String {
    func toJSONObj() -> Any {
        let d = self.data(using: .utf8)!
        return try! JSONSerialization.jsonObject(with: d, options: [])
    }
}

class CBLTestCase: XCTestCase {
    let expTimeout: TimeInterval = 20.0

    /// Opened when setting up each test case.
    var db: Database!
    
    /// Need to explicitly open by calling openOtherDB() function.
    var otherDB: Database?
    
    let databaseName = "testdb"
    
    let otherDatabaseName = "otherdb"
    
    var defaultCollection: Collection?
    
    var otherDB_defaultCollection: Collection?
    
    #if COUCHBASE_ENTERPRISE
        let directory = NSTemporaryDirectory().appending("CouchbaseLite-EE")
    #else
        let directory = NSTemporaryDirectory().appending("CouchbaseLite")
    #endif
    
    var isHostApp: Bool {
    #if os(iOS)
        let defaults = UserDefaults.standard
        return defaults.bool(forKey: "hostApp")
    #else
        return true
    #endif
    }
    
    var keyChainAccessAllowed: Bool {
    #if os(iOS)
        return self.isHostApp
    #else
        return true
    #endif
    }
    
    /// This expectation will allow overfill expectation.
    /// CBL-2363: Replicator might send extra idle status when its being stopped, which is not a bug
    func allowOverfillExpectation(description: String) -> XCTestExpectation {
        let e = super.expectation(description: description)
        e.assertForOverFulfill = false
        return e
    }
    
    override func setUp() {
        super.setUp()
        
        try? deleteDB(name: databaseName);
        
        try? deleteDB(name: otherDatabaseName);
        
        if FileManager.default.fileExists(atPath: self.directory) {
            try! FileManager.default.removeItem(atPath: self.directory)
        }
        XCTAssertTrue(!FileManager.default.fileExists(atPath: self.directory))
        
        try! initDB()
        
        LogSinks._resetApiVersion()
    }
    
    override func tearDown() {
        self.defaultCollection = nil
        self.otherDB_defaultCollection = nil
        try! db.close()
        try! otherDB?.close()
        
        LogSinks._resetApiVersion()
        
        super.tearDown()
    }
    
    func openDB(name: String) throws -> Database {
        var config = DatabaseConfiguration()
        config.directory = self.directory
        return try Database(name: name, config: config)
    }
    
    func openDB() throws {
        db = try openDB(name: databaseName)
        self.defaultCollection = try! db.defaultCollection()
    }
    
    func initDB() throws {
        try openDB()
    }
    
    func reopenDB() throws {
        try db.close()
        db = nil
        try openDB()
    }
    
    func cleanDB() throws {
        try db.delete()
        try reopenDB()
    }
    
    func openOtherDB() throws {
        otherDB = try openDB(name: otherDatabaseName)
        self.otherDB_defaultCollection = try! otherDB?.defaultCollection()
    }
    
    func reopenOtherDB() throws {
        try otherDB?.close()
        otherDB = nil
        try openOtherDB()
    }
    
    func deleteDB(name: String) throws {
        ignoreException {
            try Database.delete(withName: name, inDirectory: self.directory)
        }
    }
    
    func createDocument() -> MutableDocument {
        return MutableDocument()
    }
    
    func createDocument(_ id: String?) -> MutableDocument {
        return MutableDocument(id: id)
    }
    
    func createDocument(data: [String:Any]) -> MutableDocument {
        return MutableDocument(data: data)
    }
    
    func createDocument(_ id: String?, data: [String:Any]) -> MutableDocument {
        return MutableDocument(id: id, data: data)
    }
    
    func createDocNumbered(_ col: Collection, start: Int, num: Int) throws {
        for i in start..<start+num {
            let mdoc = createDocument("doc\(i)")
            mdoc.setInt(i, forKey: "number1")
            try col.save(document: mdoc)
        }
    }
    
    @discardableResult
    func generateDocument(withID id: String?) throws -> MutableDocument {
        let doc = createDocument(id);
        doc.setValue(1, forKey: "key")
        try saveDocument(doc)
        XCTAssertEqual(doc.sequence, 1)
        XCTAssertNotNil(doc.id)
        if id != nil {
            XCTAssertEqual(doc.id, id)
        }
        return doc
    }
    
    func saveDocument(_ document: MutableDocument) throws {
        try defaultCollection!.save(document: document)
        let savedDoc = try defaultCollection!.document(id: document.id)
        XCTAssertNotNil(savedDoc)
        XCTAssertEqual(savedDoc!.id, document.id)
    }
    
    func saveDocument(_ document: MutableDocument, eval: (Document) -> Void) throws {
        eval(document)
        try saveDocument(document)
        eval(document)
        let savedDoc = try defaultCollection!.document(id: document.id)!
        eval(savedDoc)
    }
    
    func saveDocument(_ document: MutableDocument, collection: Collection) throws {
        try collection.save(document: document)
        let savedDoc = try collection.document(id: document.id)
        XCTAssertNotNil(savedDoc)
        XCTAssertEqual(savedDoc!.id, document.id)
    }
    
    func urlForResource(name: String, ofType type: String) -> URL? {
        let res = ("Support" as NSString).appendingPathComponent(name)
        return Bundle(for: Swift.type(of:self)).url(forResource: res, withExtension: type)
    }
    
    func dataFromResource(name: String, ofType type: String) throws -> Data {
        let res = ("Support" as NSString).appendingPathComponent(name)
        let path = Bundle(for: Swift.type(of:self)).path(forResource: res, ofType: type)
        return try! NSData(contentsOfFile: path!, options: []) as Data
    }

    func stringFromResource(name: String, ofType type: String) throws -> String {
        let res = ("Support" as NSString).appendingPathComponent(name)
        let path = Bundle(for: Swift.type(of:self)).path(forResource: res, ofType: type)
        return try String(contentsOfFile: path!, encoding: String.Encoding.utf8)
    }
    
    func decodeFromJSONResource<T: Decodable>(_ name: String, as type: T.Type, limit: Int? = nil) throws -> Array<T> {
        let contents = try stringFromResource(name: name, ofType: "json")
        var n = 0
        var result: Array<T> = []
        contents.enumerateLines(invoking: { (line: String, stop: inout Bool) in
            n += 1
            let decoder = JSONDecoder()
            result.append(try! decoder.decode(T.self, from: line.data(using: String.Encoding.utf8)!))
            if n == limit {
                stop = true
            }
        })
        return result
    }
    
    func loadJSONResource(_ name: String, collection: Collection) throws {
        try loadJSONResource(name, collection: collection, limit: Int.max)
    }
    
    func loadJSONResource(_ name: String, collection: Collection, limit: Int, idKey: String? = nil) throws {
        try autoreleasepool {
            let contents = try stringFromResource(name: name, ofType: "json")
            var n = 0
            contents.enumerateLines(invoking: { (line: String, stop: inout Bool) in
                n += 1
                let json = line.data(using: String.Encoding.utf8, allowLossyConversion: false)
                var dict = try! JSONSerialization.jsonObject(with: json!, options: []) as! [String:Any]
                let docID: String
                if let idKey = idKey {
                    docID = dict.removeValue(forKey: idKey) as! String
                } else {
                    docID = String(format: "doc-%03llu", n)
                }
                let doc = MutableDocument(id: docID, data: dict)
                try! collection.save(document: doc)
                if n == limit {
                    stop = true
                }
            })
        }
    }
    
    func loadJSONResource(name: String) throws {
        try loadJSONResource(name, collection: self.defaultCollection!)
    }
    
    func jsonFromDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        formatter.timeZone = NSTimeZone(abbreviation: "UTC")! as TimeZone
        return formatter.string(from: date).appending("Z")
    }
    
    func dateFromJson(_ date: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        formatter.timeZone = NSTimeZone.local
        return formatter.date(from: date)!
    }
    
    func blobForString(_ string: String) -> Blob {
        let data = string.data(using: .utf8)!
        return Blob(contentType: "text/plain", data: data)
    }
    
    func expectError(domain: String, code: Int, block: @escaping () throws -> Void) {
        CBLTestHelper.allowException {
            var error: NSError?
            do {
                try block()
            }
            catch let e as NSError {
                error = e
            }
            
            XCTAssertNotNil(error, "Block expected to fail but didn't")
            XCTAssertEqual(error?.domain, domain)
            XCTAssertEqual(error?.code, code)
        }
    }
    
    func expectException(exception: NSExceptionName, block: @escaping () -> Void) {
        var exceptionThrown = false
        do {
            try CBLTestHelper.catchException {
                block()
            }
        } catch {
            XCTAssertEqual((error as NSError).domain, exception.rawValue)
            exceptionThrown = true
        }
        
        XCTAssert(exceptionThrown, "No exception thrown")
    }
    
    func ignoreException(block: @escaping () throws -> Void) {
        CBLTestHelper.allowException {
            try? block()
        }
    }
    
    @discardableResult
    func verifyQuery(_ query: Query, block: (UInt64, Result) throws ->Void) throws -> UInt64 {
        var n: UInt64 = 0
        for row in try query.execute() {
            n += 1
            try block(n, row)
        }
        return n
    }
    
    func isUsingIndex(named indexName: String, for query: Query) throws -> Bool {
        let plan = try query.explain()
        let usingIndex = "USING INDEX \(indexName)"
        let usingCoveringIndex = "USING COVERING INDEX \(indexName)"
        return plan.contains(usingIndex) || plan.contains(usingCoveringIndex)
    }
    
    func getRickAndMortyJSON() throws -> String {
        var content = "Earth(C-137)".data(using: .utf8)!
        var blob = Blob(contentType: "text/plain", data: content)
        try self.db.saveBlob(blob: blob)
        
        content = "Grandpa Rick".data(using: .utf8)!
        blob = Blob(contentType: "text/plain", data: content)
        try self.db.saveBlob(blob: blob)
        
        return try stringFromResource(name: "rick_morty", ofType: "json")
    }
    
    func createSecCertFromPEM(_ pem: String) throws -> SecCertificate {
        // Split lines and filter out header/footer
        let lines = pem
            .components(separatedBy: .newlines)
            .filter { !$0.contains("BEGIN CERTIFICATE") && !$0.contains("END CERTIFICATE") }
        
        // Join base64 lines
        let base64String = lines.joined()
        
        // Decode base64 to Data
        guard let certData = Data(base64Encoded: base64String) else {
            throw NSError(domain: "CertDecode", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid base64 certificate"])
        }
        
        // Create SecCertificate
        guard let cert = SecCertificateCreateWithData(nil, certData as CFData) else {
            throw NSError(domain: "CertDecode", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create SecCertificate"])
        }
        
        return cert
    }
    
}

/** Comparing JSON Dictionary */
public func ==(lhs: [String: Any], rhs: [String: Any] ) -> Bool {
    return NSDictionary(dictionary: lhs).isEqual(to: rhs)
}

/** Comparing JSON Array */
public func ==(lhs: [Any], rhs: [Any] ) -> Bool {
    return NSArray(array: lhs).isEqual(to: rhs)
}
