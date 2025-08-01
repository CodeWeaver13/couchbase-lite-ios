//
//  URLEndpointListenerTest+Main.m
//  CouchbaseLite
//
//  Copyright (c) 2022 Couchbase, Inc All rights reserved.
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

#import "URLEndpointListenerTest.h"
#import "CollectionUtils.h"

@interface URLEndpointListenerTest_Main : URLEndpointListenerTest
@end

@implementation URLEndpointListenerTest_Main

- (void) setUp {
    [super setUp];
}

- (void) tearDown {
    [super tearDown];
}

// TODO: Remove https://issues.couchbase.com/browse/CBL-3206
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

#pragma mark - helper methods

// Two replicators, replicates docs to the listener; validates connection status
- (void) validateMultipleReplicationsTo: (Listener*)listener replType: (CBLReplicatorType)type {
    XCTestExpectation* exp1 = [self expectationWithDescription: @"replicator#1 stopped"];
    XCTestExpectation* exp2 = [self expectationWithDescription: @"replicator#2 stopped"];
    
    NSUInteger existingDocsInListener = listener.config.database.count;
    
    // open DBs
    NSError* err = nil;
    Assert([self deleteDBNamed: @"db1" error: &err], @"Failed to delete db1 %@", err);
    Assert([self deleteDBNamed: @"db2" error: &err], @"Failed to delete db2 %@", err);
    CBLDatabase* db1 = [self openDBNamed: @"db1" error: &err];
    AssertNil(err);
    CBLDatabase* db2 = [self openDBNamed: @"db2" error: &err];
    AssertNil(err);
    
    NSData* content = [@"i am a blob" dataUsingEncoding: NSUTF8StringEncoding];
    
    // DB#1
    CBLBlob* blob1 = [[CBLBlob alloc] initWithContentType: @"text/plain" data: content];
    CBLMutableDocument* doc1 = [self createDocument: @"doc-1"];
    [doc1 setValue: blob1 forKey: @"blob"];
    Assert([db1 saveDocument: doc1 error: &err], @"Fail to save db1 %@", err);
    
    // DB#2
    CBLBlob* blob2 = [[CBLBlob alloc] initWithContentType: @"text/plain" data: content];
    CBLMutableDocument* doc2 = [self createDocument: @"doc-2"];
    [doc2 setValue: blob2 forKey: @"blob"];
    Assert([db2 saveDocument: doc2 error: &err], @"Fail to save db2 %@", err);
    
    // replicators
    CBLReplicatorConfiguration *config1, *config2;
    config1 = [[CBLReplicatorConfiguration alloc] initWithDatabase: db1 target: listener.localEndpoint];
    config2 = [[CBLReplicatorConfiguration alloc] initWithDatabase: db2 target: listener.localEndpoint];
    config1.replicatorType = type;
    config2.replicatorType = type;
    config1.pinnedServerCertificate = (__bridge SecCertificateRef) listener.tlsIdentity.certs[0];
    config2.pinnedServerCertificate = (__bridge SecCertificateRef) listener.tlsIdentity.certs[0];
    CBLReplicator* repl1 = [[CBLReplicator alloc] initWithConfig: config1];
    CBLReplicator* repl2 = [[CBLReplicator alloc] initWithConfig: config2];
    id changeListener = ^(CBLReplicatorChange * change) {
        if (change.status.activity == kCBLReplicatorStopped) {
            if (change.replicator == repl1)
                [exp1 fulfill];
            else
                [exp2 fulfill];
        }
    };
    id token1 = [repl1 addChangeListener: changeListener];
    id token2 = [repl2 addChangeListener: changeListener];
    
    // start & wait for replication
    [repl1 start];
    [repl2 start];
    [self waitForExpectations: @[exp1, exp2] timeout: kExpTimeout];
    
    NSUInteger expectedReplicatorDBDocs = existingDocsInListener;
    if (type == kCBLReplicatorTypePull || type == kCBLReplicatorTypePushAndPull) {
        // when pulled, db#1 and db#2 will be receiving each other's extra doc. ie., db#1 will get
        // the extra doc from db#2 and vice versa
        expectedReplicatorDBDocs += 1;
    }
    AssertEqual(db1.count, expectedReplicatorDBDocs);
    AssertEqual(db2.count, expectedReplicatorDBDocs);
    if (type == kCBLReplicatorTypePush || type == kCBLReplicatorTypePushAndPull) {
        // it should have two extra docs from each db#1 and db#2
        AssertEqual(listener.config.database.count, existingDocsInListener + 2);
    }
    
    // cleanup
    [repl1 removeChangeListenerWithToken: token1];
    [repl2 removeChangeListenerWithToken: token2];
    repl1 = nil;
    repl2 = nil;
    Assert([db1 close: &err], @"Failed to close db1 %@", err);
    Assert([db2 close: &err], @"Failed to close db2 %@", err);
    db1 = nil;
    db2 = nil;
}

- (void) validateActiveReplicationsAndURLEndpointListener: (BOOL)isDeleteDBs {
    if (!self.keyChainAccessAllowed) return;
    
    XCTestExpectation* stopExp1 = [self expectationWithDescription: @"replicator#1 stopped"];
    XCTestExpectation* stopExp2 = [self expectationWithDescription: @"replicator#2 stopped"];
    XCTestExpectation* idleExp1 = [self allowOverfillExpectationWithDescription: @"replicator#1 idle"];
    XCTestExpectation* idleExp2 = [self allowOverfillExpectationWithDescription: @"replicator#2 idle"];
    
    NSError* err;
    CBLMutableDocument* doc =  [self createDocument: @"db-doc"];
    Assert([self.db saveDocument: doc error: &err], @"Fail to save DB %@", err);
    doc =  [self createDocument: @"other-db-doc"];
    Assert([self.otherDB saveDocument: doc error: &err], @"Fail to save otherDB %@", err);
    
    // start listener
    [self listen];
    
    // replicator #1
    id target = [[CBLDatabaseEndpoint alloc] initWithDatabase: self.db];
    CBLReplicatorConfiguration* config = [[CBLReplicatorConfiguration alloc] initWithDatabase: self.otherDB
                                                                                       target: target];
    config.continuous = YES;
    CBLReplicator* repl1 = [[CBLReplicator alloc] initWithConfig: config];

    // replicator #2
    [self deleteDBNamed: @"db2" error: &err];
    CBLDatabase* db2 = [self openDBNamed: @"db2" error: &err];
    AssertNil(err);
    config = [[CBLReplicatorConfiguration alloc] initWithDatabase: db2
                                                           target: _listener.localEndpoint];
    config.continuous = YES;
    config.pinnedServerCertificate = (__bridge SecCertificateRef) _listener.tlsIdentity.certs[0];
    CBLReplicator* repl2 = [[CBLReplicator alloc] initWithConfig: config];
    
    id changeListener = ^(CBLReplicatorChange * change) {
        if (change.status.activity == kCBLReplicatorIdle &&
            change.status.progress.completed == change.status.progress.total) {
            if (change.replicator == repl1)
                [idleExp1 fulfill];
            else
                [idleExp2 fulfill];
            
        } else if (change.status.activity == kCBLReplicatorStopped) {
            if (change.replicator == repl1)
                [stopExp1 fulfill];
            else
                [stopExp2 fulfill];
        }
    };
    id token1 = [repl1 addChangeListener: changeListener];
    id token2 = [repl2 addChangeListener: changeListener];
    
    [repl1 start];
    [repl2 start];
    [self waitForExpectations: @[idleExp1, idleExp2] timeout: kExpTimeout];
    
    if (isDeleteDBs) {
        [db2 delete: &err];
        AssertNil(err);
        [self.otherDB delete: &err];
        AssertNil(err);
    } else {
        [db2 close: &err];
        AssertNil(err);
        [self.otherDB close: &err];
        AssertNil(err);
    }
    
    [self waitForExpectations: @[stopExp1, stopExp2] timeout: kExpTimeout];
    [repl1 removeChangeListenerWithToken: token1];
    [repl2 removeChangeListenerWithToken: token2];
    [self stopListen];
}

- (void) validateActiveReplicatorAndURLEndpointListeners: (BOOL)isDeleteDB {
    if (!self.keyChainAccessAllowed) return;
    
    XCTestExpectation* idleExp = [self allowOverfillExpectationWithDescription: @"replicator idle"];
    XCTestExpectation* stopExp = [self expectationWithDescription: @"replicator stopped"];

    // start listener#1 and listener#2
    NSError* err;
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    Listener* listener1 = [[Listener alloc] initWithConfig: config];
    Listener* listener2 = [[Listener alloc] initWithConfig: config];
    Assert([listener1 startWithError: &err]);
    AssertNil(err);
    Assert([listener2 startWithError: &err]);
    AssertNil(err);
    
    CBLMutableDocument* doc =  [self createDocument: @"db-doc"];
    Assert([self.db saveDocument: doc error: &err], @"Fail to save DB %@", err);
    doc =  [self createDocument: @"other-db-doc"];
    Assert([self.otherDB saveDocument: doc error: &err], @"Fail to save otherDB %@", err);
    
    // start replicator
    CBLReplicatorConfiguration* rConfig = [[CBLReplicatorConfiguration alloc] initWithDatabase: self.db
                                                                                        target: listener1.localEndpoint];
    rConfig.continuous = YES;
    rConfig.pinnedServerCertificate = (__bridge SecCertificateRef) listener1.tlsIdentity.certs[0];
    CBLReplicator* replicator = [[CBLReplicator alloc] initWithConfig: rConfig];
    id token = [replicator addChangeListener: ^(CBLReplicatorChange * change) {
        if (change.status.activity == kCBLReplicatorIdle &&
            change.status.progress.completed == change.status.progress.total) {
            [idleExp fulfill];
        } else if (change.status.activity == kCBLReplicatorStopped) {
            [stopExp fulfill];
        }
    }];
    [replicator start];
    [self waitForExpectations: @[idleExp] timeout: kExpTimeout];
    
    // delete / close
    if (isDeleteDB)
        [self.otherDB delete: &err];
    else
        [self.otherDB close: &err];
    
    [self waitForExpectations: @[stopExp] timeout: kExpTimeout];
    
    // cleanup
    [replicator removeChangeListenerWithToken: token];
    [self stopListener: listener1];
    [self stopListener: listener2];
}

#pragma mark - Tests

- (void) testDefaultProperties {
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    
    // disable TLS
    AssertEqual(config.disableTLS, kCBLDefaultListenerDisableTls);
    config.disableTLS = YES;
    AssertEqual(config.disableTLS, YES);
    
    // Port
    AssertEqual(config.port, kCBLDefaultListenerPort);
    config.port = kWsPort;
    AssertEqual(config.port, kWsPort);
    
    // enable delta sync
    AssertEqual(config.enableDeltaSync, kCBLDefaultListenerEnableDeltaSync);
    config.enableDeltaSync = YES;
    AssertEqual(config.enableDeltaSync, YES);
    
    AssertEqual(config.readOnly, kCBLDefaultListenerReadOnly);
    config.readOnly = YES;
    AssertEqual(config.readOnly, YES);
}

- (void) testPort {
    // initialize a listener
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.port = kWsPort;
    config.disableTLS = YES;
    Listener* listener = [[Listener alloc] initWithConfig: config];
    AssertEqual(listener.port, 0);
    
    // start listener
    NSError* err = nil;
    Assert([listener startWithError: &err]);
    AssertNil(err);
    AssertEqual(listener.port, kWsPort);
    
    // stops
    [self stopListener: listener];
    AssertEqual(listener.port, 0);
}

- (void) testEmptyPort {
    // initialize a listener
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.port = 0;
    config.disableTLS = YES;
    Listener* listener = [[Listener alloc] initWithConfig: config];
    AssertEqual(listener.port, 0);
    
    // start listener
    NSError* err = nil;
    Assert([listener startWithError: &err]);
    AssertNil(err);
    Assert(listener.port != 0);
    
    // stops
    [self stopListener: listener];
    AssertEqual(listener.port, 0);
}

- (void) testBusyPort {
    [self listenWithTLS: NO];
    
    // initialize a listener at same port
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.port = _listener.config.port;
    config.disableTLS = YES;
    Listener* listener2 = [[Listener alloc] initWithConfig: config];
    
    // Already in use when starting the second listener
    [self ignoreException:^{
        NSError* err = nil;
        [listener2 startWithError: &err];
        AssertEqual(err.code, EADDRINUSE);
        AssertEqual(err.domain, NSPOSIXErrorDomain);
    }];
    
    // stops
    [self stopListen];
}

- (void) testURLs {
    if (!self.keyChainAccessAllowed) return;
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    _listener = [[Listener alloc] initWithConfig: config];
    AssertNil(_listener.urls);
    
    // start listener
    NSError* err = nil;
    Assert([_listener startWithError: &err]);
    AssertNil(err);
    Assert(_listener.urls.count != 0);
    
    // stops
    [self stopListener: _listener];
    AssertEqual(_listener.urls.count, 0);
}

- (void) testConnectionStatus {
    XCTestExpectation* replicatorStop = [self expectationWithDescription: @"Replicator Stopped"];
    XCTestExpectation* pullFilterBusy = [self expectationWithDescription: @"Pull filter busy"];
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.port = kWsPort;
    config.disableTLS = YES;
    _listener = [[Listener alloc] initWithConfig: config];
    AssertEqual(_listener.status.connectionCount, 0);
    AssertEqual(_listener.status.activeConnectionCount, 0);
    
    // start listener
    NSError* err = nil;
    Assert([_listener startWithError: &err]);
    AssertNil(err);
    AssertEqual(_listener.status.connectionCount, 0);
    AssertEqual(_listener.status.activeConnectionCount, 0);
    
    // save doc on remote end
    CBLMutableDocument* doc = [self createDocument];
    Assert([self.otherDB saveDocument: doc error: &err], @"Failed to save %@", err);
    
    CBLReplicatorConfiguration* rConfig = [self configWithTarget: _listener.localEndpoint
                                                            type: kCBLReplicatorTypePull
                                                      continuous: NO];
    __block Listener* weakListener = _listener;
    __block uint64_t maxConnectionCount = 0, maxActiveCount = 0;
    [rConfig setPullFilter: ^BOOL(CBLDocument * _Nonnull document, CBLDocumentFlags flags) {
        Listener* strongListener = weakListener;
        maxConnectionCount = MAX(strongListener.status.connectionCount, maxConnectionCount);
        maxActiveCount = MAX(strongListener.status.activeConnectionCount, maxActiveCount);
        [pullFilterBusy fulfill];
        return true;
    }];
    CBLReplicator* replicator = [[CBLReplicator alloc] initWithConfig: rConfig];
    id token = [replicator addChangeListener: ^(CBLReplicatorChange* change) {
        if (change.status.activity == kCBLReplicatorStopped)
            [replicatorStop fulfill];
    }];
    
    [replicator start];
    [self waitForExpectations: @[pullFilterBusy, replicatorStop] timeout: kExpTimeout];
    [replicator removeChangeListenerWithToken: token];
    
    AssertEqual(maxActiveCount, 1);
    AssertEqual(maxConnectionCount, 1);
    AssertEqual(self.otherDB.count, 1);
    
    // stops
    [self stopListener: _listener];
    AssertEqual(_listener.status.connectionCount, 0);
    AssertEqual(_listener.status.activeConnectionCount, 0);
}

- (void) testTLSListenerAnonymousIdentity {
    if (!self.keyChainAccessAllowed) return;
    
    NSError* error;
    CBLMutableDocument* doc = [self createDocument];
    Assert([self.otherDB saveDocument: doc error: &error], @"Fail to save otherDB %@", error);
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    Listener* listener = [[Listener alloc] initWithConfig: config];
    AssertNil(listener.tlsIdentity);
    
    Assert([listener startWithError: &error]);
    AssertNil(error);
    AssertNotNil(listener.tlsIdentity);
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    // different pinned cert
    CBLTLSIdentity* identity = [self tlsIdentity: NO];
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef)identity.certs[0]
              errorCode: CBLErrorTLSCertUnknownRoot
            errorDomain: CBLErrorDomain];
    [self cleanupTLSIdentity: NO];
    
    // No pinned cert
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: nil
              errorCode: CBLErrorTLSCertUnknownRoot
            errorDomain: CBLErrorDomain];
    
    [self stopListener: listener];
    AssertNil(listener.tlsIdentity);
}

- (void) testTLSListenerUserIdentity {
    if (!self.keyChainAccessAllowed) return;
    
    NSError* error;
    CBLMutableDocument* doc = [self createDocument];
    Assert([self.otherDB saveDocument: doc error: &error], @"Fail to save otherDB %@", error);
    
    CBLTLSIdentity* tlsIdentity = [self tlsIdentity: YES];
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.tlsIdentity = tlsIdentity;
    Listener* listener = [[Listener alloc] initWithConfig: config];
    AssertNil(listener.tlsIdentity);
    
    Assert([listener startWithError: &error]);
    AssertNil(error);
    AssertNotNil(listener.tlsIdentity);
    AssertEqual(listener.tlsIdentity, tlsIdentity);
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    // different pinned cert
    CBLTLSIdentity* identity = [self tlsIdentity: NO];
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef)identity.certs[0]
              errorCode: CBLErrorTLSCertUnknownRoot
            errorDomain: CBLErrorDomain];
    [self cleanupTLSIdentity: NO];
    
    // No pinned cert
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: nil
              errorCode: CBLErrorTLSCertUnknownRoot
            errorDomain: CBLErrorDomain];
    
    [self stopListener: listener];
    AssertNil(listener.tlsIdentity);
}

- (void) testNonTLSNullListenerAuthenticator {
    if (!self.keyChainAccessAllowed) return;
    
    NSError* err;
    CBLMutableDocument* doc1 =  [self createDocument];
    Assert([self.otherDB saveDocument: doc1 error: &err], @"Fail to save to otherDB %@", err);
    Listener* listener = [self listenWithTLS: NO];
    AssertNil(listener.tlsIdentity);
    
    // Replicator - No Authenticator:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: nil
              errorCode: 0
            errorDomain: nil];
    
    // Replicator - Basic Authenticator
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daniel" password: @"456"]
             serverCert: nil
              errorCode: 0
            errorDomain: nil];
    
    // Replicator - Certificate Authenticator
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
             serverCert: nil
              errorCode: 0
            errorDomain: nil];
    
    // cleanup client cert authenticator identity
    [self cleanupTLSIdentity: NO];
    
    [self stopListener: listener];
}

- (void) testNonTLSPasswordListenerAuthenticator {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    CBLListenerPasswordAuthenticator* auth = [[CBLListenerPasswordAuthenticator alloc] initWithBlock:
        ^BOOL(NSString *username, NSString *password) {
            return ([username isEqualToString: @"daniel"] && [password isEqualToString: @"123"]);
        }];
    Listener* listener = [self listenWithTLS: NO auth: auth];
    
    // Replicator - No Authenticator:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: nil
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - Wrong Username:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daneil" password: @"456"]
             serverCert: nil
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - Wrong Password:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daniel" password: @"456"]
             serverCert: nil
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - ClientCert Authenticator
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
             serverCert: nil
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // cleanup client cert authenticator identity
    [self cleanupTLSIdentity: NO];
    
    // Replicator - Success:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daniel" password: @"123"]
             serverCert: nil
              errorCode: 0
            errorDomain: nil];
    
    [self stopListener: listener];
}

- (void) testTLSPasswordListenerAuthenticator {
    if (!self.keyChainAccessAllowed) return;
    
    NSError* err;
    CBLMutableDocument* doc1 =  [self createDocument];
    Assert([self.otherDB saveDocument: doc1 error: &err], @"Fail to save to otherDB %@", err);
    
    // Listener:
    CBLListenerPasswordAuthenticator* auth = [[CBLListenerPasswordAuthenticator alloc] initWithBlock:
        ^BOOL(NSString *username, NSString *password) {
            return ([username isEqualToString: @"daniel"] && [password isEqualToString: @"123"]);
        }];
    Listener* listener = [self listenWithTLS: YES auth: auth];
    
    // Replicator - No Authenticator:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - Wrong Username:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daneil" password: @"456"]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - Wrong Password:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daniel" password: @"456"]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // Replicator - Different ClientCertAuthenticator
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: CBLErrorHTTPAuthRequired
            errorDomain: CBLErrorDomain];
    
    // cleanup client cert authenticator identity
    [self cleanupTLSIdentity: NO];
    
    // Replicator - Success:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLBasicAuthenticator alloc] initWithUsername: @"daniel" password: @"123"]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    [self stopListener: listener];
    
}

- (void) testClientCertAuthWithCallback {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    CBLListenerCertificateAuthenticator* listenerAuth =
        [[CBLListenerCertificateAuthenticator alloc] initWithBlock: ^BOOL(NSArray *certs) {
            AssertEqual(certs.count, 1);
            SecCertificateRef cert = (__bridge SecCertificateRef)(certs[0]);
            CFStringRef cnRef;
            OSStatus status = SecCertificateCopyCommonName(cert, &cnRef);
            AssertEqual(status, errSecSuccess);
            NSString* cn = (NSString*)CFBridgingRelease(cnRef);
            return [cn isEqualToString: @"daniel"];
        }];
    
    Listener* listener = [self listenWithTLS: YES auth: listenerAuth];
    AssertNotNil(listener);
    AssertEqual(listener.tlsIdentity.certs.count, 1);
    
    // Replicator:
    
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    // Cleanup client cert authenticator identity
    [self cleanupTLSIdentity: NO];
    
    [self stopListener: listener];
}

- (void) testClientCertAuthWithCallbackError {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    CBLListenerCertificateAuthenticator* listenerAuth =
        [[CBLListenerCertificateAuthenticator alloc] initWithBlock: ^BOOL(NSArray *certs) {
            AssertEqual(certs.count, 1);
            return NO;
        }];
    
    Listener* listener = [self listenWithTLS: YES auth: listenerAuth];
    AssertNotNil(listener);
    AssertEqual(listener.tlsIdentity.certs.count, 1);
    
    // Replicator:
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: CBLErrorTLSClientCertRejected
            errorDomain: CBLErrorDomain];
    
    // Cleanup:
    [self cleanupTLSIdentity: NO];
    
    [self stopListener: listener];
}

- (void) testClientCertAuthRootCerts {
#if TARGET_OS_OSX
    XCTSkip(@"CBL-7005 : importIdentityWithData not working on newer macOS");
#endif
    
    if (!self.keyChainAccessAllowed) return;
    
    NSData* rootCertData = [self dataFromResource: @"identity/client-ca" ofType: @"der"];
    SecCertificateRef rootCertRef = SecCertificateCreateWithData(kCFAllocatorDefault, (CFDataRef)rootCertData);
    AssertNotNil((__bridge id)rootCertRef);
    
    CBLListenerCertificateAuthenticator* listenerAuth =
        [[CBLListenerCertificateAuthenticator alloc] initWithRootCerts: @[(id)CFBridgingRelease(rootCertRef)]];
    Listener* listener = [self listenWithTLS: YES auth: listenerAuth];
    AssertNotNil(listener);
    
    // Cleanup:
    __block NSError* error;
    [self ignoreExceptionBreakPoint: ^{
        Assert([CBLTLSIdentity deleteIdentityWithLabel: kClientCertLabel error: &error]);
    }];
    
    // Create client identity:
    NSData* clientIdentityData = [self dataFromResource: @"identity/client" ofType: @"p12"];
    __block CBLTLSIdentity* identity;
    [self ignoreException: ^{
        identity = [CBLTLSIdentity importIdentityWithData: clientIdentityData
                                                 password: @"123"
                                                    label: kClientCertLabel
                                                    error: &error];
    }];
    AssertNotNil(identity);
    AssertNil(error);
    
    // Start Replicator:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: identity]
                 serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
                  errorCode: 0
                errorDomain: nil];
    }];

    // Cleanup:
    [self ignoreExceptionBreakPoint: ^{
        Assert([CBLTLSIdentity deleteIdentityWithLabel: kClientCertLabel error: &error]);
    }];
    [self stopListener: listener];
}

- (void) testClientCertAuthRootCertsError {
    if (!self.keyChainAccessAllowed) return;
    
    NSData* rootCertData = [self dataFromResource: @"identity/client-ca" ofType: @"der"];
    SecCertificateRef rootCertRef = SecCertificateCreateWithData(kCFAllocatorDefault, (CFDataRef)rootCertData);
    AssertNotNil((__bridge id)rootCertRef);
    
    CBLListenerCertificateAuthenticator* listenerAuth =
        [[CBLListenerCertificateAuthenticator alloc] initWithRootCerts: @[(id)CFBridgingRelease(rootCertRef)]];
    Listener* listener = [self listenWithTLS: YES auth: listenerAuth];
    AssertNotNil(listener);
    
    // Start Replicator:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: [[CBLClientCertificateAuthenticator alloc] initWithIdentity: [self tlsIdentity: NO]]
                 serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
                  errorCode: CBLErrorTLSClientCertRejected
                errorDomain: CBLErrorDomain];
    }];

    // Cleanup:
    [self cleanupTLSIdentity: NO];
    
    [self stopListener: listener];
}

- (void) testEmptyNetworkInterface {
#if TARGET_OS_OSX
    XCTSkip(@"Not applicable test on some network environment");
#endif
    
    if (!self.keyChainAccessAllowed) return;
    
    [self listen];
    NSArray* urls = _listener.urls;
    
    /** Link local addresses cannot be assigned via network interface because they don't map to any given interface.  */
    NSPredicate* p = [NSPredicate predicateWithFormat: @"NOT(SELF.host CONTAINS ':') AND NOT(SELF.host CONTAINS '.local')"];
    NSArray* notLinkLocal = [urls filteredArrayUsingPredicate: p];
    
    NSError* err = nil;
    for (uint i = 0; i < notLinkLocal.count; i++ ) {
        // separate db instance!
        NSURL* url = notLinkLocal[i];
        CBLDatabase* db = [[CBLDatabase alloc] initWithName: $sprintf(@"db-%d", i) error: &err];
        AssertNil(err);
        CBLMutableDocument* doc = [self createDocument];
        [doc setString: url.absoluteString forKey: @"url"];
        [db saveDocument: doc error: &err];
        AssertNil(err);
        
        // separate replicator instance
        id end = [[CBLURLEndpoint alloc] initWithURL: url];
        id rConfig = [[CBLReplicatorConfiguration alloc] initWithDatabase: db target: end];
        [rConfig setPinnedServerCertificate: (SecCertificateRef)(_listener.tlsIdentity.certs.firstObject)];
        [self run: rConfig errorCode: 0 errorDomain: nil];
        
        // remove the separate db
        [self deleteDatabase: db];
    }
    
    AssertEqual(self.otherDB.count, notLinkLocal.count);
    CBLQuery* q = [CBLQueryBuilder select: @[[CBLQuerySelectResult all]]
                                     from: [CBLQueryDataSource database: self.otherDB]];
    CBLQueryResultSet* rs = [q execute: &err];
    AssertNil(err);
    NSMutableArray* result = [NSMutableArray arrayWithCapacity: notLinkLocal.count];
    for(CBLQueryResult* res in rs.allObjects) {
        CBLDictionary* dict = [res dictionaryAtIndex: 0];
        [result addObject: [NSURL URLWithString: [dict stringForKey: @"url"]]];
    }
    
    AssertEqualObjects(result, notLinkLocal);
    
    // validate 0.0.0.0 meta-address should return same empty response.
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.networkInterface = @"0.0.0.0";
    config.port = kWssPort;
    [self listen: config];
    AssertEqualObjects(urls, _listener.urls);
    
    [self stopListen];
}

- (void) testUnavailableNetworkInterface {
    if (!self.keyChainAccessAllowed) return;
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.networkInterface = @"1.1.1.256";
    [self ignoreException:^{
        [self listen: config errorCode: CBLErrorUnknownHost errorDomain: CBLErrorDomain];
    }];
    
    config.networkInterface = @"blah";
    [self ignoreException:^{
        [self listen: config errorCode: CBLErrorUnknownHost errorDomain: CBLErrorDomain];
    }];
}

- (void) testNetworkInterfaceName {
    if (!self.keyChainAccessAllowed) return;
    
    NSArray* interfaces = [Listener allInterfaceNames];
    for (NSString* i in interfaces) {
        Config* config = [[Config alloc] initWithDatabase: self.otherDB];
        config.networkInterface = i;
        
        [self listen: config];
        
        /// make sure, connection is successful and no error thrown!
        
        [self stopListen];
    }
}

- (void) testMultipleListenersOnSameDatabase {
    if (!self.keyChainAccessAllowed) return;
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    Listener* listener1 = [[Listener alloc] initWithConfig: config];
    Listener* listener2 = [[Listener alloc] initWithConfig: config];
    
    NSError* err = nil;
    Assert([listener1 startWithError: &err]);
    AssertNil(err);
    Assert([listener2 startWithError: &err]);
    AssertNil(err);
    
    // replicate doc
    [self generateDocumentWithID: @"doc-1"];
    [self runWithTarget: listener1.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) listener1.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    [listener2 stop];
    [self stopListener: listener1];
    AssertEqual(self.otherDB.count, 1);
}

- (void) testMultipleReplicatorsToListener {
    if (!self.keyChainAccessAllowed) return;
    
    [self listen]; // writable listener
    
    // save a doc on listenerDB
    NSError* err = nil;
    CBLMutableDocument* doc = [self createDocument: @"doc"];
    [doc setValue: @"Tiger" forKey: @"species"];
    Assert([self.otherDB saveDocument: doc error: &err], @"Failed to save listener DB %@", err);
    
    // pushAndPull can cause race; so only push is validated
    [self validateMultipleReplicationsTo: _listener replType: kCBLReplicatorTypePush];
    
    // cleanup
    [self stopListen];
}

- (void) testMultipleReplicatorsOnReadOnlyListener {
    if (!self.keyChainAccessAllowed) return;
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.readOnly = YES;
    [self listen: config];
    
    // save a doc on listenerDB
    NSError* err = nil;
    CBLMutableDocument* doc = [self createDocument: @"doc"];
    [doc setValue: @"Tiger" forKey: @"species"];
    Assert([self.otherDB saveDocument: doc error: &err], @"Failed to save listener DB %@", err);
    
    [self validateMultipleReplicationsTo: _listener replType: kCBLReplicatorTypePull];
    
    // cleanup
    [self stopListen];
}

- (void) testReadOnlyListener {
    if (!self.keyChainAccessAllowed) return;
    
    NSError* err;
    CBLMutableDocument* doc1 =  [self createDocument];
    Assert([self.db saveDocument: doc1 error: &err], @"Fail to save db1 %@", err);
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.readOnly = YES;
    [self listen: config];
    
    // Push Replication to ReadOnly Listener
    [self ignoreException: ^{
        [self runWithTarget: _listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
                 serverCert: (__bridge SecCertificateRef) _listener.tlsIdentity.certs[0]
                  errorCode: CBLErrorHTTPForbidden
                errorDomain: CBLErrorDomain];
    }];
    
    // cleanup
    [self stopListen];
}

- (void) testCloseWithActiveListener {
    if (!self.keyChainAccessAllowed) return;
    
    [self listen];
    
    NSError* err = nil;
    CBLTLSIdentity* identity = _listener.tlsIdentity;
    
    // Close database should also stop the listener:
    Assert([self.otherDB close: &err]);
    AssertNil(err);
    
    AssertEqual(_listener.port, 0);
    AssertEqual(_listener.urls.count, 0);
    
    // Cleanup:
    if (identity) {
        [self deleteFromKeyChain: identity];
    }
}

- (void) testReplicatorServerCertificate {
    if (!self.keyChainAccessAllowed) return;
    
    XCTestExpectation* x1 = [self allowOverfillExpectationWithDescription: @"idle"];
    XCTestExpectation* x2 = [self expectationWithDescription: @"stopped"];
    
    Listener* listener = [self listen];
    
    SecCertificateRef serverCert = (__bridge SecCertificateRef) listener.tlsIdentity.certs[0];
    CBLReplicator* replicator = [self replicator: self.otherDB
                                       continous: YES
                                          target: listener.localEndpoint
                                      serverCert: serverCert];
    [replicator addChangeListener: ^(CBLReplicatorChange *change) {
        CBLReplicatorActivityLevel activity = change.status.activity;
        if (activity == kCBLReplicatorIdle)
            [x1 fulfill];
        else if (activity == kCBLReplicatorStopped && !change.status.error)
            [x2 fulfill];
    }];
    Assert(replicator.serverCertificate == NULL);
    
    [replicator start];
    
    [self waitForExpectations: @[x1] timeout: kExpTimeout];
    
    SecCertificateRef receivedServerCert = replicator.serverCertificate;
    Assert(receivedServerCert != NULL);
    [self checkEqualForCert: serverCert andCert: receivedServerCert];
    [self releaseCF: receivedServerCert];
    
    [replicator stop];
    
    [self waitForExpectations: @[x2] timeout: kExpTimeout];
    
    receivedServerCert = replicator.serverCertificate;
    Assert(receivedServerCert != NULL);
    [self checkEqualForCert: serverCert andCert: receivedServerCert];
    [self releaseCF: receivedServerCert];
    
    [self stopListen];
}

- (void) testReplicatorServerCertificateWithTLSError {
    if (!self.keyChainAccessAllowed) return;
    
    XCTestExpectation* x1 = [self expectationWithDescription: @"stopped"];
    
    Listener* listener = [self listen];
    
    SecCertificateRef serverCert = (__bridge SecCertificateRef) listener.tlsIdentity.certs[0];
    CBLReplicator* replicator = [self replicator: self.otherDB
                                       continous: YES
                                          target: listener.localEndpoint
                                      serverCert: nil];
    [replicator addChangeListener: ^(CBLReplicatorChange *change) {
        CBLReplicatorActivityLevel activity = change.status.activity;
        if (activity == kCBLReplicatorStopped && change.status.error) {
            AssertEqual(change.status.error.code, CBLErrorTLSCertUnknownRoot);
            [x1 fulfill];
        }
    }];
    Assert(replicator.serverCertificate == NULL);
    
    [replicator start];
    
    [self waitForExpectations: @[x1] timeout: kExpTimeout];
    SecCertificateRef receivedServerCert = replicator.serverCertificate;
    Assert(receivedServerCert != NULL);
    [self checkEqualForCert: serverCert andCert: receivedServerCert];
    
    // Use the received certificate to pin:
    serverCert = receivedServerCert;
    x1 = [self allowOverfillExpectationWithDescription: @"idle"];
    XCTestExpectation* x2 = [self expectationWithDescription: @"stopped"];
    replicator = [self replicator: self.otherDB
                        continous: YES
                           target: listener.localEndpoint
                       serverCert: serverCert];
    [replicator addChangeListener: ^(CBLReplicatorChange *change) {
        CBLReplicatorActivityLevel activity = change.status.activity;
        if (activity == kCBLReplicatorIdle)
            [x1 fulfill];
        else if (activity == kCBLReplicatorStopped && !change.status.error)
            [x2 fulfill];
    }];
    Assert(replicator.serverCertificate == NULL);
    
    [replicator start];
    
    [self waitForExpectations: @[x1] timeout: kExpTimeout];
    receivedServerCert = replicator.serverCertificate;
    Assert(receivedServerCert != NULL);
    [self checkEqualForCert: serverCert andCert: receivedServerCert];
    [self releaseCF: receivedServerCert];
    
    [replicator stop];
    
    [self waitForExpectations: @[x2] timeout: kExpTimeout];
    receivedServerCert = replicator.serverCertificate;
    Assert(receivedServerCert != NULL);
    [self checkEqualForCert: serverCert andCert: receivedServerCert];
    [self releaseCF: receivedServerCert];
    [self releaseCF: serverCert];
    
    [self stopListen];
}

- (void) testReplicatorServerCertificateWithTLSDisabled {
    XCTestExpectation* x1 = [self allowOverfillExpectationWithDescription: @"idle"];
    XCTestExpectation* x2 = [self expectationWithDescription: @"stopped"];
    
    Listener* listener = [self listenWithTLS: NO];
    
    CBLReplicator* replicator = [self replicator: self.otherDB
                                       continous: YES
                                          target: listener.localEndpoint
                                      serverCert: nil];
    [replicator addChangeListener: ^(CBLReplicatorChange *change) {
        CBLReplicatorActivityLevel level = change.status.activity;
        if (level == kCBLReplicatorIdle)
            [x1 fulfill];
        else if (level == kCBLReplicatorStopped && !change.status.error)
            [x2 fulfill];
    }];
    Assert(replicator.serverCertificate == NULL);
    
    [replicator start];
    
    [self waitForExpectations: @[x1] timeout: kExpTimeout];
    Assert(replicator.serverCertificate == NULL);
    
    [replicator stop];
    
    [self waitForExpectations: @[x2] timeout: kExpTimeout];
    Assert(replicator.serverCertificate == NULL);
    
    [self stopListen];
}

- (void) testPinnedServerCertificate {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    Listener* listener = [self listenWithTLS: YES];
    AssertNotNil(listener);
    AssertEqual(listener.tlsIdentity.certs.count, 1);
    
    self.disableDefaultServerCertPinning = YES;
    
    // Replicator - TLS Error:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
       acceptSelfSignedOnly: NO
                 serverCert: nil
                  errorCode: CBLErrorTLSCertUnknownRoot
                errorDomain: CBLErrorDomain];
    }];
    
    // Replicator - Success:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
       acceptSelfSignedOnly: NO
                 serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
                  errorCode: 0
                errorDomain: nil];
    }];
    
    [self stopListener: listener];
}

- (void) testListenerWithImportIdentity {
#if TARGET_OS_OSX
    XCTSkip(@"CBL-7005 : importIdentityWithData not working on newer macOS");
#endif
    
    if (!self.keyChainAccessAllowed) return;
    
    NSError* err = nil;
    NSData* data = [self dataFromResource: @"identity/certs" ofType: @"p12"];
    __block CBLTLSIdentity* identity;
    [self ignoreException: ^{
        NSError* error = nil;
        identity = [CBLTLSIdentity importIdentityWithData: data password: @"123"
                                                    label:kServerCertLabel error:&error];
        AssertNil(error);
    }];
    AssertEqual(identity.certs.count, 2);
    
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.tlsIdentity = identity;
    _listener = [[Listener alloc] initWithConfig: config];
    AssertNil(_listener.tlsIdentity);
    
    [self ignoreException:^{
        NSError* error = nil;
        Assert([_listener startWithError: &error]);
        AssertNil(error);
    }];
    
    AssertNotNil(_listener.tlsIdentity);
    AssertEqual(_listener.tlsIdentity, config.tlsIdentity);
    
    // make sure, replication works
    [self generateDocumentWithID: @"doc-1"];
    AssertEqual(self.otherDB.count, 0);
    [self runWithTarget: _listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) _listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    AssertEqual(self.otherDB.count, 1u);
    
    // stop and cleanup
    [self stopListen];
    Assert([CBLTLSIdentity deleteIdentityWithLabel: kServerCertLabel error: &err]);
    AssertNil(err);
}

- (void) testStopListener {
    XCTestExpectation* x1 = [self allowOverfillExpectationWithDescription: @"idle"];
    XCTestExpectation* x2 = [self expectationWithDescription: @"stopped"];
    
    // Listen:
    Listener* listener = [self listenWithTLS: NO];
    
    // Replicator:
    CBLURLEndpoint* target = listener.localEndpoint;
    CBLReplicator* replicator = [self replicator: self.otherDB
                                       continous: YES
                                          target: target
                                      serverCert: nil];
    [replicator addChangeListener: ^(CBLReplicatorChange *change) {
        CBLReplicatorActivityLevel level = change.status.activity;
        if (level == kCBLReplicatorIdle)
            [x1 fulfill];
        else if (level == kCBLReplicatorStopped)
            [x2 fulfill];
    }];
    [replicator start];
    
    // Wait until idle then stop the listener:
    [self waitForExpectations: @[x1] timeout: kExpTimeout];
    
    // Stop listen:
    [self stopListen];
    
    // Wait for the replicator to be stopped:
    [self waitForExpectations: @[x2] timeout: kExpTimeout];
    
    // Check error
    AssertEqual(replicator.status.error.code, CBLErrorWebSocketGoingAway);
    
    // Check to ensure that the replicator is not accessible:
    [self runWithTarget: target
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: nil
            maxAttempts: 2 // to make fail(stop) early
              errorCode: ECONNREFUSED
            errorDomain: NSPOSIXErrorDomain];
}

- (void) testChainedCertServerAndCertPinning {
#if TARGET_OS_OSX
    XCTSkip(@"CBL-7005 : importIdentityWithData not working on newer macOS");
#endif
    
    if (!self.keyChainAccessAllowed) return;
    
    NSData* data = [self dataFromResource: @"identity/certs" ofType: @"p12"];
    
    // Ignore the exception so that the exception breakpoint will not be triggered.
    __block NSError* error;
    __block CBLTLSIdentity* identity;
    Assert([CBLTLSIdentity deleteIdentityWithLabel: kServerCertLabel error: &error]);
    AssertNil(error);
    [self ignoreException: ^{
        identity = [CBLTLSIdentity importIdentityWithData: data
        password: @"123"
           label: kServerCertLabel
           error: &error];
    }];
    AssertEqual(identity.certs.count, 2);
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.tlsIdentity = identity;
    
    // Ignore the exception from signing using the imported private key
    [self ignoreException:^{
        [self listen: config];
    }];
    
    // pinning root cert should be successful(CBL-2973)
    [self runWithTarget: _listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) identity.certs[1]
              errorCode: 0
            errorDomain: nil];
    
    // pinning leaf cert shoud be successful
    [self runWithTarget: _listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
             serverCert: (__bridge SecCertificateRef) identity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    // cleanup
    [self stopListen];
    Assert([CBLTLSIdentity deleteIdentityWithLabel: kServerCertLabel error: &error]);
    AssertNil(error);
}

#pragma mark - acceptSelfSignedOnly tests

- (void) testAcceptOnlySelfSignedCertificate {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    Listener* listener = [self listenWithTLS: YES];
    AssertNotNil(listener);
    AssertEqual(listener.tlsIdentity.certs.count, 1);
    
    self.disableDefaultServerCertPinning = YES;
    
    // Replicator - TLS Error:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
       acceptSelfSignedOnly: NO
                 serverCert: nil
                  errorCode: CBLErrorTLSCertUnknownRoot
                errorDomain: CBLErrorDomain];
    }];
    
    // Replicator - Success:
    [self ignoreException: ^{
        [self runWithTarget: listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
       acceptSelfSignedOnly: YES
                 serverCert: nil
                  errorCode: 0
                errorDomain: nil];
    }];
    
    [self stopListener: listener];
}

- (void) testAcceptOnlySelfSignedCertificateWithPinnedCertificate {
    if (!self.keyChainAccessAllowed) return;
    
    // Listener:
    Listener* listener = [self listenWithTLS: YES];
    AssertNotNil(listener);
    AssertEqual(listener.tlsIdentity.certs.count, 1);
    
    // listener = cert1; replicator.pin = cert2; acceptSelfSigned = true => fail
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
   acceptSelfSignedOnly: YES
             serverCert: self.defaultServerCert
              errorCode: CBLErrorTLSCertUnknownRoot
            errorDomain: CBLErrorDomain];
    
    // listener = cert1; replicator.pin = cert1; acceptSelfSigned = false => pass
    [self runWithTarget: listener.localEndpoint
                   type: kCBLReplicatorTypePushAndPull
             continuous: NO
          authenticator: nil
   acceptSelfSignedOnly: NO
             serverCert: (__bridge SecCertificateRef) listener.tlsIdentity.certs[0]
              errorCode: 0
            errorDomain: nil];
    
    [self stopListener: listener];
}

- (void) testAcceptSelfSignedWithNonSelfSignedCert {
#if TARGET_OS_OSX
    XCTSkip(@"CBL-7005 : importIdentityWithData not working on newer macOS");
#endif
    
    if (!self.keyChainAccessAllowed) return;
    
    NSData* data = [self dataFromResource: @"identity/certs" ofType: @"p12"];
    
    // Ignore the exception so that the exception breakpoint will not be triggered.
    __block NSError* error;
    __block CBLTLSIdentity* identity;
    Assert([CBLTLSIdentity deleteIdentityWithLabel: kServerCertLabel error: &error]);
    AssertNil(error);
    [self ignoreException: ^{
        identity = [CBLTLSIdentity importIdentityWithData: data
        password: @"123"
           label: kServerCertLabel
           error: &error];
    }];
    AssertEqual(identity.certs.count, 2);
    Config* config = [[Config alloc] initWithDatabase: self.otherDB];
    config.tlsIdentity = identity;
    
    // Ignore the exception from signing using the imported private key
    [self ignoreException:^{
        [self listen: config];
    }];
    
    [self generateDocumentWithID: @"doc-1"];
    AssertEqual(self.otherDB.count, 0);
    
    self.disableDefaultServerCertPinning = YES;
    
    // Reject the server with non-self-signed cert
    [self ignoreException: ^{
        [self runWithTarget: _listener.localEndpoint
                       type: kCBLReplicatorTypePushAndPull
                 continuous: NO
              authenticator: nil
       acceptSelfSignedOnly: YES
                 serverCert: nil
                  errorCode: CBLErrorTLSCertUntrusted
                errorDomain: CBLErrorDomain];
    }];
    
    // cleanup
    [self stopListen];
    Assert([CBLTLSIdentity deleteIdentityWithLabel: kServerCertLabel error: &error]);
    AssertNil(error);
}

#pragma mark - Close & Delete Replicators and Listeners

- (void) testCloseWithActiveReplicationsAndURLEndpointListener {
    [self validateActiveReplicationsAndURLEndpointListener: NO];
}

- (void) testDeleteWithActiveReplicationsAndURLEndpointListener {
    [self validateActiveReplicationsAndURLEndpointListener: YES];
}

- (void) testCloseWithActiveReplicatorAndURLEndpointListeners {
    [self validateActiveReplicatorAndURLEndpointListeners: NO];
}

- (void) testDeleteWithActiveReplicatorAndURLEndpointListeners {
    [self validateActiveReplicatorAndURLEndpointListeners: YES];
}

#pragma clang diagnostic pop

- (void) testCollections {
    NSError* error = nil;
    CBLCollection* collection = [self.db createCollectionWithName: @"collection1"
                                                      scope: @"scope1"
                                                      error: &error];
    Config* config = [[Config alloc] initWithCollections: @[collection]];
    AssertEqual(config.collections.count, 1);
    CBLCollection* c = (CBLCollection*)config.collections.firstObject;
    AssertEqualObjects(c.name, @"collection1");
}

@end
