//
//  NotificationTest.swift
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
import CouchbaseLiteSwift

class NotificationTest: CBLTestCase {
    
    func testDatabaseChange() throws {
        let x = self.expectation(description: "change")
        
        let token = defaultCollection!.addChangeListener { (change) in
            XCTAssertEqual(change.documentIDs.count, 10)
            x.fulfill()
        }
       
        try db.inBatch {
            for i in 0...9 {
                let doc = createDocument("doc-\(i)")
                doc.setValue("demo", forKey: "type")
                try saveDocument(doc)
            }
        }
        waitForExpectations(timeout: expTimeout, handler: nil)
        
        token.remove()
    }
    
    func testDocumentChange() throws {
        let doc1 = createDocument("doc1")
        doc1.setValue("Scott", forKey: "name")
        try saveDocument(doc1)
        
        let doc2 = createDocument("doc2")
        doc2.setValue("Daniel", forKey: "name")
        try saveDocument(doc2)
        
        let x = self.expectation(description: "Got all changes")
        
        var changes = Set<String>()
        changes.insert("doc1")
        changes.insert("doc2")
        changes.insert("doc3")
        
        let handler = { (change: DocumentChange) in
            changes.remove(change.documentID)
            if changes.count == 0 {
                x.fulfill()
            }
        }
        
        // Add change listeners:
        let listener1 = defaultCollection!.addDocumentChangeListener(id: "doc1", listener: handler)
        let listener2 = defaultCollection!.addDocumentChangeListener(id: "doc2", listener: handler)
        let listener3 = defaultCollection!.addDocumentChangeListener(id: "doc3", listener: handler)
        
        // Update doc1:
        doc1.setValue("Scott Tiger", forKey: "name")
        try saveDocument(doc1)
        
        // Delete doc2:
        try defaultCollection!.delete(document: doc2)
        
        // Create doc3:
        let doc3 = createDocument("doc3")
        doc3.setValue("Jack", forKey: "name")
        try saveDocument(doc3)
        
        waitForExpectations(timeout: expTimeout, handler: nil)
        
        listener1.remove()
        listener2.remove()
        listener3.remove()
    }
    
    func testAddSameChangeListeners() throws {
        let doc1 = createDocument("doc1")
        doc1.setValue("Scott", forKey: "name")
        try saveDocument(doc1)
        
        let x = self.expectation(description: "Got all changes")
        
        var count = 0
        let handler = { (change: DocumentChange) in
            count = count + 1
            if count == 3 {
                x.fulfill()
            }
        }
        
        // Add change listeners:
        let listener1 = defaultCollection!.addDocumentChangeListener(id: "doc1", listener: handler)
        let listener2 = defaultCollection!.addDocumentChangeListener(id: "doc1", listener: handler)
        let listener3 = defaultCollection!.addDocumentChangeListener(id: "doc1", listener: handler)
        
        // Update doc1:
        doc1.setValue("Scott Tiger", forKey: "name")
        try saveDocument(doc1)
        
        waitForExpectations(timeout: expTimeout, handler: nil)
        
        listener1.remove()
        listener2.remove()
        listener3.remove()
    }
    
    func testRemoveDocumentChangeListener() throws {
        let doc1 = createDocument("doc1")
        doc1.setValue("Scott", forKey: "name")
        try saveDocument(doc1)
        
        let x1 = self.expectation(description: "change")
        
        // Add change listener:
        let token = defaultCollection!.addDocumentChangeListener(id: "doc1") { (change) in
            x1.fulfill()
        }
        
        // Update doc1:
        doc1.setValue("Scott Tiger", forKey: "name")
        try saveDocument(doc1)
        
        waitForExpectations(timeout: expTimeout, handler: nil)
        
        // Remove change listener:
        token.remove()
        
        doc1.setValue("Scott Tiger", forKey: "name")
        try saveDocument(doc1)
        
        // Let's wait for 0.5 seconds:
        let x2 = expectation(description: "No changes")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            x2.fulfill()
        }
        waitForExpectations(timeout: expTimeout, handler: nil)
        
        // Remove again:
        token.remove()
    }
    
}
