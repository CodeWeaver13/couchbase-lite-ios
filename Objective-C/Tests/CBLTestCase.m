//
//  CBLTestCase.m
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

#import "CBLTestCase.h"
#include "c4.h"
#import "CollectionUtils.h"
#import "CBLLogSinks+Reset.h"

#ifdef COUCHBASE_ENTERPRISE
#define kDatabaseDirName @"CouchbaseLite_EE"
#else
#define kDatabaseDirName @"CouchbaseLite"
#endif

const NSTimeInterval kExpTimeout = 20.0;

@implementation CBLTestCase
{
    int _c4ObjectCount;
}

@synthesize db=_db, otherDB=_otherDB, disableObjectLeakCheck=_disableObjectLeakCheck;

// TODO: Remove https://issues.couchbase.com/browse/CBL-3206
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

- (XCTestExpectation*) allowOverfillExpectationWithDescription:(NSString *)description {
    XCTestExpectation* e = [super expectationWithDescription: description];
    e.assertForOverFulfill = false;
    return e;
}

- (void) setUp {
    [super setUp];
    
    [self deleteDBNamed: kDatabaseName error: nil];
    [self deleteDBNamed: kOtherDatabaseName error: nil];
    
    _c4ObjectCount = c4_getObjectCount();
    NSString* dir = self.directory;
    if ([[NSFileManager defaultManager] fileExistsAtPath: dir]) {
        NSError* error;
        Assert([[NSFileManager defaultManager] removeItemAtPath: dir error: &error],
               @"Error deleting CouchbaseLite folder: %@", error);
    }
    [self initDB];
    
    // Debug logging to be made before this, if any
    [CBLLogSinks resetApiVersion];
}

- (void) tearDown {
    [CBLLogSinks resetApiVersion];
    
    if (_db) {
        NSError* error;
        Assert([_db close: &error], @"Failed to close db: %@", error);
        _db = nil;
    }
    
    if (_otherDB) {
        NSError* error;
        Assert([_otherDB close: &error], @"Failed to close otherdb: %@", error);
        _otherDB = nil;
    }
    
    if (!_disableObjectLeakCheck) {
        // Wait a little while for objects to be cleaned up:
        int leaks = 0;
        for (int i = 0; i < 20; i++) {
            leaks = c4_getObjectCount() - _c4ObjectCount;
            if (leaks == 0)
                break;
            else
                [NSThread sleepForTimeInterval: 0.1];
        }
        if (leaks) {
            fprintf(stderr, "**** LITECORE OBJECTS STILL NOT FREED: ****\n");
            c4_dumpInstances();
            XCTFail("%d LiteCore objects have not been freed (see above)", leaks);
        }
    }
    
    [super tearDown];
}

- (NSString*) directory {
    return [NSTemporaryDirectory() stringByAppendingPathComponent: kDatabaseDirName];
}

- (BOOL) hasHostApp {
#if TARGET_OS_IPHONE
    NSUserDefaults* defaults = [NSUserDefaults standardUserDefaults];
    return [defaults boolForKey: @"hostApp"];
#else
    return YES;
#endif
}

- (BOOL) keyChainAccessAllowed {
    #if TARGET_OS_IPHONE
        return self.hasHostApp;
    #else
        return YES;
    #endif
}

- (NSString*) databasePath: (NSString*)fileName inDirectory: (NSString*)dir {
    NSString *directory = [@"Support/databases" stringByAppendingPathComponent:dir];
    NSString* path = [[NSBundle bundleForClass: [self class]] pathForResource: fileName
                                                                       ofType: nil
                                                                  inDirectory: directory];
    Assert(path, @"FATAL: Missing file '%@' in bundle directory '%@'", fileName, directory);
    return path;
}

- (CBLDatabase*) openDBNamed: (NSString*)name error: (NSError**)error {
    CBLDatabaseConfiguration* config = [[CBLDatabaseConfiguration alloc] init];
    config.directory = self.directory;
    return [[CBLDatabase alloc] initWithName: name config: config error: error];
}

- (void) initDB {
    [self openDB];
}

- (void) openDB {
    Assert(!_db);
    NSError* error;
    _db = [self openDBNamed: kDatabaseName error: &error];
    AssertNil(error);
    AssertNotNil(_db);
}

- (void) reopenDB {
    NSError *error;
    if (_db) {
        Assert([_db close: &error], @"Close error: %@", error);
        _db = nil;
    }
    [self openDB];
}

- (void) cleanDB {
    NSError *error;
    Assert([_db delete: &error], @"Delete error: %@", error);
    [self reopenDB];
}

- (void) openOtherDB {
    Assert(!_otherDB);
    NSError* error;
    _otherDB = [self openDBNamed: kOtherDatabaseName error: &error];
    AssertNil(error);
    AssertNotNil(_db);
}

- (void) reopenOtherDB {
    if (_otherDB) {
        NSError *error;
        Assert([_otherDB close: &error], @"Close error: %@", error);
        AssertNil(error);
        _otherDB = nil;
    }
    [self openOtherDB];
}

- (BOOL) deleteDBNamed: (NSString*)name error: (NSError**)error {
    __block BOOL result;
    __block NSError* err = nil;
    [self ignoreExceptionBreakPoint: ^{
        result = [CBLDatabase deleteDatabase: name inDirectory: self.directory error: &err];
    }];
    if (error) {
        *error = err;
    }
    return result;
}

- (void) deleteDatabase: (CBLDatabase*)database {
    NSError* error;
    NSString* path = database.path;
    Assert([[NSFileManager defaultManager] fileExistsAtPath: path]);
    Assert([database delete: &error]);
    AssertNil(error);
    AssertFalse([[NSFileManager defaultManager] fileExistsAtPath: path]);
}

- (void) closeDatabase: (CBLDatabase*)database{ 
    NSError* error;
    Assert([database close:&error]);
    AssertNil(error);
}

- (CBLMutableDocument*) createDocument {
    return [[CBLMutableDocument alloc] init];
}

- (CBLMutableDocument*) createDocument: (NSString*)documentID {
    return [[CBLMutableDocument alloc] initWithID: documentID];
}

- (CBLMutableDocument*) createDocument:(NSString *)documentID data:(NSDictionary *)data {
    return [[CBLMutableDocument alloc] initWithID: documentID data: data];
}

- (CBLMutableDocument*) generateDocumentWithID: (NSString*)documentID {
    CBLMutableDocument* doc = [self createDocument: documentID];
    [doc setValue: @1 forKey:@"key"];
    [self saveDocument: doc];
    AssertEqual(doc.sequence, 1u);
    if (documentID)
        AssertEqualObjects(doc.id, documentID);
    return doc;
}

- (void) saveDocument: (CBLMutableDocument*)document {
    [self saveDocument: document collection: nil];
}

- (void) saveDocument:(CBLMutableDocument *)document collection: (nullable CBLCollection*)col {
    NSError* error;
    CBLCollection* c = col ?: [self.db defaultCollection: &error];
    AssertNotNil(c);
    
    Assert([c saveDocument: document error: &error], @"Saving error: %@", error);
    AssertNil(error);
    
    CBLDocument* savedDoc = [c documentWithID: document.id error: &error];
    AssertNotNil(savedDoc);
    AssertEqualObjects(savedDoc.id, document.id);
    AssertEqualObjects([savedDoc toDictionary], [document toDictionary]);
    AssertNil(error);
}

- (void) saveDocument: (CBLMutableDocument*)document eval: (void(^)(CBLDocument*))block {
    NSError* error;
    block(document);
    Assert([_db saveDocument: document error: &error], @"Saving error: %@", error);
    block(document);
    block([_db documentWithID: document.id]);
}

- (void) createDocNumbered: (nullable CBLCollection*)col start: (NSInteger)start num: (NSInteger)num {
    for (NSInteger i = start; i < (start+num); i++) {
        NSString* docID = [NSString stringWithFormat: @"doc%ld", (long)i];
        CBLMutableDocument* doc = [[CBLMutableDocument alloc] initWithID: docID];
        [doc setValue: @(i) forKey: @"number1"];
        [doc setValue: @(num-i) forKey: @"number2"];
        [self saveDocument: doc collection: col];
    }
}

- (NSURL*) urlForResource: (NSString*)resourceName ofType: (NSString*)type {
    NSString* res = [@"Support" stringByAppendingPathComponent: resourceName];
    return [[NSBundle bundleForClass: [self class]] URLForResource: res withExtension: type];
}

- (NSData*) dataFromResource: (NSString*)resourceName ofType: (NSString*)type {
    NSString* res = [@"Support" stringByAppendingPathComponent: resourceName];
    NSString* path = [[NSBundle bundleForClass: [self class]] pathForResource: res
                                                                       ofType: type];
    Assert(path, @"Missing test file %@.%@", resourceName, type);
    NSData* contents = [NSData dataWithContentsOfFile: path
                                              options: 0
                                                error: NULL];
    Assert(contents);
    return contents;
}

- (NSString*) stringFromResource: (NSString*)resourceName ofType: (NSString*)type {
    NSData* contents = [self dataFromResource: resourceName ofType: type];
    NSString* str = [[NSString alloc] initWithData: contents
                                          encoding: NSUTF8StringEncoding];
    Assert(str);
    return str;
}

- (NSString*) randomStringWithLength: (NSUInteger)length {
    static NSString *chars = @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXZY0123456789";
    NSMutableString *s = [NSMutableString stringWithCapacity: length];
    for (NSUInteger i = 0; i < length; i++) {
        [s appendFormat:@"%C",
            [chars characterAtIndex: (arc4random() % [chars length])]];
    }
    return s;
}

- (void) loadJSONResource: (NSString*)resourceName {
    NSError* error = nil;
    CBLCollection* defaultCollection = [self.db defaultCollection: &error];
    AssertNil(error);
    
    [self loadJSONResource: resourceName toCollection: defaultCollection];
    
}

- (void) loadJSONResource: (NSString*)resourceName toCollection: (CBLCollection*)collection {
    @autoreleasepool {
        NSString* contents = [self stringFromResource: resourceName ofType: @"json"];
        return [self loadJSONString: contents named: resourceName toCollection: collection];
    }
}

- (void) loadJSONString: (NSString*)contents named: (NSString*)resourceName {
    NSError* error = nil;
    CBLCollection* defaultCollection = [self.db defaultCollection: &error];
    AssertNil(error);
    
    [self loadJSONString: contents named: resourceName toCollection: defaultCollection];
}

- (void) loadJSONString: (NSString*)contents
                  named: (NSString*)resourceName
           toCollection: (CBLCollection*)collection {
    @autoreleasepool {
        __block uint64_t n = 0;
        [contents enumerateLinesUsingBlock: ^(NSString *line, BOOL *stop) {
            NSError* err;
            CBLMutableDocument* doc = [[CBLMutableDocument alloc] initWithID: $sprintf(@"doc-%03llu", ++n)
                                                                        json: line error: &err];
            Assert([collection saveDocument: doc error: &err], @"Couldn't save document: %@", err);
        }];
    }
}

- (CBLBlob*) blobForString: (NSString*)string {
    return [[CBLBlob alloc] initWithContentType: @"text/plain"
                                           data: [string dataUsingEncoding: NSUTF8StringEncoding]];
}

- (SecCertificateRef) createSecCertFromPEM: (NSString*)pem {
    // Separate the lines and remove BEGIN/END headers
    NSMutableArray<NSString*>*lines = [NSMutableArray array];
    for (NSString* line in [pem componentsSeparatedByCharactersInSet: [NSCharacterSet newlineCharacterSet]]) {
        if (![line containsString: @"BEGIN CERTIFICATE"] && ![line containsString: @"END CERTIFICATE"]) {
            [lines addObject:line];
        }
    }
    
    // Join the base64 lines
    NSString* base64String = [lines componentsJoinedByString: @""];
    
    // Decode base64 to NSData
    NSData* certData = [[NSData alloc] initWithBase64EncodedString: base64String options: 0];
    AssertNotNil(certData);
    
    return SecCertificateCreateWithData(NULL, (__bridge CFDataRef)certData);
}

// helper method to check error
- (void) expectError: (NSErrorDomain)domain code: (NSInteger)code in: (BOOL (^)(NSError**))block {
    if ([self isProfiling])
        return;
    
    ++gC4ExpectExceptions;
    NSError* error;
    BOOL succeeded = block(&error);
    --gC4ExpectExceptions;

    if (succeeded) {
        XCTFail("Block expected to fail but didn't");
    } else {
        XCTAssert([domain isEqualToString: error.domain] && code == error.code,
                  "Block expected to return error (%@ %ld), but instead returned %@",
                  domain, (long)code, error);
    }
}

- (void) expectException: (NSString*)name in: (void (^) (void))block {
    if ([self isProfiling])
        return;
    
    ++gC4ExpectExceptions;
    XCTAssertThrowsSpecificNamed(block(), NSException, name);
    --gC4ExpectExceptions;
}

- (void) mayHaveException: (NSString*)name in: (void (^) (void))block {
    if ([self isProfiling])
        return;
    
    @try {
        ++gC4ExpectExceptions;
        block();
    }
    @catch (NSException* e) {
        AssertEqualObjects(e.name, name);
    }
    @finally {
        --gC4ExpectExceptions;
    }
}

- (void) ignoreException: (void (^) (void))block {
    if ([self isProfiling])
        return;
    
    @try {
        ++gC4ExpectExceptions;
        block();
    }
    @catch (NSException* e) { }
    @finally {
        --gC4ExpectExceptions;
    }
}

- (void) ignoreExceptionBreakPoint: (void (^) (void))block {
    ++gC4ExpectExceptions;
    block();
    --gC4ExpectExceptions;
}

- (uint64_t) verifyQuery: (CBLQuery*)q
            randomAccess: (BOOL)randomAccess
                    test: (void (^)(uint64_t n, CBLQueryResult *result))block {
    NSError* error;
    CBLQueryResultSet* rs = [q execute: &error];
    Assert(rs, @"Query failed: %@", error);
    uint64_t n = 0;
    for (CBLQueryResult *r in rs) {
        block(++n, r);
    }
    
    rs = [q execute: &error];
    Assert(rs, @"Query failed: %@", error);
    NSArray* all = rs.allObjects;
    AssertEqual(all.count, n);
    if (randomAccess && n > 0) {
        // Note: the block's 1st parameter is 1-based, while NSArray is 0-based
        block(n,       all[(NSUInteger)(n-1)]);
        block(1,       all[0]);
        block(n/2 + 1, all[(NSUInteger)(n/2)]);
    }
    return n;
}

- (BOOL) isUsingIndexNamed: (NSString*)indexName forQuery: (CBLQuery*)query {
    NSError* error;
    NSString* plan = [query explain: &error];
    AssertNil(error);
    AssertNotNil(plan);
    
    NSString *usingIndex = [NSString stringWithFormat:@"USING INDEX %@", indexName];
    NSString *usingCoveringIndex = [NSString stringWithFormat:@"USING COVERING INDEX %@", indexName];
    
    return ([plan rangeOfString:usingIndex].location != NSNotFound ||
            [plan rangeOfString:usingCoveringIndex].location != NSNotFound);
}

- (BOOL) isProfiling {
    return NSProcessInfo.processInfo.environment[@"PROFILING"] != nil;
}

- (NSString*) getRickAndMortyJSON {
    NSError* err;
    NSData* content = [@"Earth(C-137)" dataUsingEncoding: NSUTF8StringEncoding];
    CBLBlob* blob = [[CBLBlob alloc] initWithContentType:@"text/plain" data: content];
    [self.db saveBlob: blob error: &err];
    
    content = [@"Grandpa Rick" dataUsingEncoding: NSUTF8StringEncoding];
    blob = [[CBLBlob alloc] initWithContentType:@"text/plain" data: content];
    [self.db saveBlob: blob error: &err];
    
    return [self stringFromResource: @"rick_morty" ofType: @"json"];
}

#pragma clang diagnostic pop

@end
