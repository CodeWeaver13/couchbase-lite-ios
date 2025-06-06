//
//  LogTestOld.m
//  CouchbaseLite
//
//  Copyright (c) 2018 Couchbase, Inc All rights reserved.
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
#import "CBLLog+Logging.h"

@interface CustomLogger : NSObject <CBLLogger>

@property (nonatomic) CBLLogLevel level;

@property (nonatomic, readonly) NSArray* lines;

- (void) reset;

- (BOOL) containsString: (NSString *)string;

@end

@interface FileLoggerBackup: NSObject

@property (nonatomic, nullable) CBLLogFileConfiguration* config;

@property (nonatomic) CBLLogLevel level;

@end

@interface LogTestOld : CBLTestCase

@end

@implementation LogTestOld {
    FileLoggerBackup* _backup;
    CBLLogLevel _backupConsoleLevel;
    CBLLogDomain _backupConsoleDomain;
    NSString* logFileDirectory;
}

// TODO: Remove https://issues.couchbase.com/browse/CBL-3206
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

- (void) setUp {
    [super setUp];
    NSString* folderName = [NSString stringWithFormat: @"LogTestLogs_%d", arc4random()];
    logFileDirectory = [NSTemporaryDirectory() stringByAppendingPathComponent: folderName];
    _backup = [[FileLoggerBackup alloc] init];
    _backup.level = CBLDatabase.log.file.level;
    _backup.config = CBLDatabase.log.file.config;
}

- (void) tearDown {
    [[NSFileManager defaultManager] removeItemAtPath: logFileDirectory error: nil];
    
    CBLDatabase.log.file.level = _backup.level;
    CBLDatabase.log.file.config = _backup.config;
    CBLDatabase.log.console.level = _backupConsoleLevel;
    CBLDatabase.log.console.domains = _backupConsoleDomain;
    
    _backup = nil;
    CBLDatabase.log.custom = nil;
    [super tearDown];
}

- (CBLLogFileConfiguration*) logFileConfig {
    return [[CBLLogFileConfiguration alloc] initWithDirectory: logFileDirectory];
}

- (NSArray<NSURL*>*) getLogsInDirectory: (NSString*)directory
                             properties: (nullable NSArray<NSURLResourceKey>*)keys
                           onlyInfoLogs: (BOOL)onlyInfo {
    AssertNotNil(directory);
    NSURL* path = [NSURL fileURLWithPath: directory];
    AssertNotNil(path);
    
    NSError* error;
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL: path
                                                   includingPropertiesForKeys: keys ? keys : @[]
                                                                      options: 0
                                                                        error: &error];
    NSString* format = @"pathExtension == 'cbllog'";
    if (onlyInfo) {
        format = [NSString stringWithFormat: @"%@ && lastPathComponent BEGINSWITH 'cbl_info_'", format];
    }
    NSPredicate* predicate = [NSPredicate predicateWithFormat: format];
    return [files filteredArrayUsingPredicate: predicate];
}

- (void) writeOneKiloByteOfLog {
    NSString* inputString = @"11223344556677889900"; // 20B + (27B, 24B, 24B, 24B, 29B)  ~44B line
    for(int i = 0; i < 23; i++) {
        CBLDebug(Database, @"%@", inputString);
        CBLLogInfo(Database, @"%@", inputString);
        CBLLogVerbose(Database, @"%@", inputString);
        CBLWarn(Database, @"%@", inputString);
        CBLWarnError(Database, @"%@", inputString);
    }
    [self writeAllLogs: @"-"]; // 25B : total ~1037Bytes
}

- (void) writeAllLogs: (NSString*)string {
    CBLDebug(Database, @"%@", string);
    CBLLogInfo(Database, @"%@", string);
    CBLLogVerbose(Database, @"%@", string);
    CBLWarn(Database, @"%@", string);
    CBLWarnError(Database, @"%@", string);
}

- (BOOL) isKeywordPresentInAnyLog: (NSString*)keyword path: (NSString*)path {
    NSArray* files = [self getLogsInDirectory: path properties: nil onlyInfoLogs: NO];
    NSError* error;
    for (NSURL* url in files) {
        NSString* contents = [NSString stringWithContentsOfURL: url
                                                      encoding: NSASCIIStringEncoding
                                                         error: &error];
        AssertNil(error);
        if ([contents rangeOfString: keyword].location != NSNotFound) {
            return YES;
        }
    }
    return NO;
}

- (void) testCustomLoggingLevels {
    CBLLogInfo(Database, @"IGNORE");
    CustomLogger* customLogger = [[CustomLogger alloc] init];
    
    for (NSUInteger i = 5; i >= 1; i--) {
        [customLogger reset];
        customLogger.level = (CBLLogLevel)i;
        CBLDatabase.log.custom = customLogger;
        CBLLogVerbose(Database, @"TEST VERBOSE");
        CBLLogInfo(Database, @"TEST INFO");
        CBLWarn(Database, @"TEST WARNING");
        CBLWarnError(Database, @"TEST ERROR");
        AssertEqual(customLogger.lines.count, 5 - i);
    }
}

- (void) testFileLoggingLevels {
    CBLLogFileConfiguration* config = [self logFileConfig];
    config.usePlainText = YES;
    CBLDatabase.log.file.config = config;
    
    for (NSUInteger i = 5; i >= 1; i--) {
        CBLDatabase.log.file.level = (CBLLogLevel)i;
        CBLLogVerbose(Database, @"TEST VERBOSE");
        CBLLogInfo(Database, @"TEST INFO");
        CBLWarn(Database, @"TEST WARNING");
        CBLWarnError(Database, @"TEST ERROR");
    }
    
    NSError* error;
    NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: config.directory
                                                                         error: &error];
    for (NSString* file in files) {
        NSString* log = [config.directory stringByAppendingPathComponent: file];
        NSString* content = [NSString stringWithContentsOfFile: log
                                                      encoding: NSUTF8StringEncoding
                                                         error: &error];
        __block int lineCount = 0;
        [content enumerateLinesUsingBlock: ^(NSString *line, BOOL *stop) {
            lineCount++;
        }];
        
        if ([file rangeOfString: @"verbose"].location != NSNotFound)
            AssertEqual(lineCount, 3);
        else if ([file rangeOfString: @"info"].location != NSNotFound)
            AssertEqual(lineCount, 4);
        else if ([file rangeOfString: @"warning"].location != NSNotFound)
            AssertEqual(lineCount, 5);
        else if ([file rangeOfString: @"error"].location != NSNotFound)
            AssertEqual(lineCount, 6);
    }
}

- (void) testFileLoggingDefaultBinaryFormat {
    CBLLogFileConfiguration* config = [self logFileConfig];
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelInfo;
    
    CBLLogInfo(Database, @"TEST INFO");
    NSArray* files = [self getLogsInDirectory: config.directory
                                   properties: @[NSFileModificationDate]
                                 onlyInfoLogs: YES];
    NSArray* sorted = [files sortedArrayUsingComparator: ^NSComparisonResult(NSURL* url1,
                                                                             NSURL* url2) {
        NSError* err;
        NSDate *date1 = nil;
        [url1 getResourceValue: &date1
                        forKey: NSURLContentModificationDateKey
                         error: &err];
        
        NSDate* date2 = nil;
        [url2 getResourceValue: &date2
                        forKey: NSURLContentModificationDateKey
                         error: &err];
        return [date1 compare: date2];
    }];
    
    NSURL* last = [sorted lastObject];
    AssertNotNil(last);
    
    NSError* error;
    NSFileHandle* sourceFileHandle = [NSFileHandle fileHandleForReadingFromURL: last error: &error];
    NSData* begainData = [sourceFileHandle readDataOfLength: 4];
    AssertNotNil(begainData);
    Byte *bytes = (Byte *)[begainData bytes];
    Assert(bytes[0] == 0xcf && bytes[1] == 0xb2 && bytes[2] == 0xab && bytes[3] == 0x1b,
           @"because the log should be in binary format");
}

- (void) testFileLoggingUsePlainText {
    CBLLogFileConfiguration* config = [self logFileConfig];
    AssertEqual(config.usePlainText, kCBLDefaultLogFileUsePlaintext);
    config.usePlainText = YES;
    Assert(config.usePlainText);
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelInfo;
    Assert(CBLDatabase.log.file.config.usePlainText);
    
    NSString* input = @"SOME TEST MESSAGE";
    CBLLogInfo(Database, @"%@", input);
    
    NSArray* files = [self getLogsInDirectory: config.directory
                                   properties: @[NSFileModificationDate]
                                 onlyInfoLogs: YES];
    NSArray* sorted = [files sortedArrayUsingComparator: ^NSComparisonResult(NSURL* url1,
                                                                             NSURL* url2) {
        NSError* err;
        NSDate *date1 = nil;
        [url1 getResourceValue: &date1
                        forKey: NSURLContentModificationDateKey
                         error: &err];
        
        NSDate* date2 = nil;
        [url2 getResourceValue: &date2
                        forKey: NSURLContentModificationDateKey
                         error: &err];
        return [date1 compare: date2];
    }];
    
    NSURL* last = [sorted lastObject];
    AssertNotNil(last);
    
    
    NSError* error;
    NSString* contents = [NSString stringWithContentsOfURL: last
                                                  encoding: NSASCIIStringEncoding
                                                     error: &error];
    Assert([contents rangeOfString: input].location != NSNotFound);
}

- (void) testFileLoggingLogFilename {
    CBLLogFileConfiguration* config = [self logFileConfig];
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelDebug;
    
    NSString* regex = @"cbl_(debug|verbose|info|warning|error)_\\d+\\.cbllog";
    NSPredicate* predicate = [NSPredicate predicateWithFormat: @"SELF MATCHES %@", regex];
    NSArray* files = [self getLogsInDirectory: config.directory properties: nil onlyInfoLogs: NO];
    for (NSURL* file in files) {
        Assert([predicate evaluateWithObject: file.lastPathComponent]);
    }
}

- (void) testEnableAndDisableCustomLogging {
    CBLLogInfo(Database, @"IGNORE");
    CustomLogger* customLogger = [[CustomLogger alloc] init];
    customLogger.level = kCBLLogLevelNone;
    CBLDatabase.log.custom = customLogger;
    CBLLogVerbose(Database, @"TEST VERBOSE");
    CBLLogInfo(Database, @"TEST INFO");
    CBLWarn(Database, @"TEST WARNING");
    CBLWarnError(Database, @"TEST ERROR");
    AssertEqual(customLogger.lines.count, 0);
    
    customLogger.level = kCBLLogLevelVerbose;
    CBLDatabase.log.custom = customLogger;
    CBLLogVerbose(Database, @"TEST VERBOSE");
    CBLLogInfo(Database, @"TEST INFO");
    CBLWarn(Database, @"TEST WARNING");
    CBLWarnError(Database, @"TEST ERROR");
    AssertEqual(customLogger.lines.count, 4);
}

- (void) testFileLoggingMaxSize {
    CBLLogFileConfiguration* config = [self logFileConfig];
    config.usePlainText = YES;
    AssertEqual(config.maxSize, kCBLDefaultLogFileMaxSize);
    AssertEqual(config.maxRotateCount, kCBLDefaultLogFileMaxRotateCount);
    config.maxSize = 1024;
    AssertEqual(config.maxSize, 1024);
    config.maxRotateCount = 2;
    AssertEqual(config.maxRotateCount, 2);
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelDebug;
    AssertEqual(CBLDatabase.log.file.config.maxSize, 1024);
    AssertEqual(CBLDatabase.log.file.config.maxRotateCount, 2);
    
    // this should create three files, as the 1KB + 1KB + extra ~400-500Bytes.
    [self writeOneKiloByteOfLog];
    [self writeOneKiloByteOfLog];
    
    NSUInteger totalFilesShouldBeInDirectory = (CBLDatabase.log.file.config.maxRotateCount + 1) * 5;
#if !DEBUG
    totalFilesShouldBeInDirectory = totalFilesShouldBeInDirectory - 1;
#endif
    NSArray* files = [self getLogsInDirectory: config.directory properties: nil onlyInfoLogs: NO];
    AssertEqual(files.count, totalFilesShouldBeInDirectory);
}

- (void) testFileLoggingDisableLogging {
    CBLLogFileConfiguration* config = [self logFileConfig];
    config.usePlainText = YES;
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelNone;
    
    NSString* inputString = [[NSUUID UUID] UUIDString];
    [self writeAllLogs: inputString];
    
    AssertFalse([self isKeywordPresentInAnyLog: inputString path: config.directory]);
}

- (void) testFileLoggingReEnableLogging {
    CBLLogFileConfiguration* config = [self logFileConfig];
    config.usePlainText = YES;
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelNone;
    
    NSString* inputString = [[NSUUID UUID] UUIDString];
    [self writeAllLogs: inputString];
    
    AssertFalse([self isKeywordPresentInAnyLog: inputString path: config.directory]);
    
    CBLDatabase.log.file.level = kCBLLogLevelVerbose;
    [self writeAllLogs: inputString];
    
    NSArray* files = [self getLogsInDirectory: config.directory properties: nil onlyInfoLogs: NO];
    NSError* error;
    for (NSURL* url in files) {
        if ([url.lastPathComponent hasPrefix: @"cbl_debug_"]) {
            continue;
        }
        NSString* contents = [NSString stringWithContentsOfURL: url
                                                      encoding: NSASCIIStringEncoding
                                                         error: &error];
        AssertNil(error);
        Assert([contents rangeOfString: inputString].location != NSNotFound);
    }
}

- (void) testFileLoggingHeader {
    CBLLogFileConfiguration* config = [self logFileConfig];
    config.usePlainText = YES;
    CBLDatabase.log.file.config = config;
    CBLDatabase.log.file.level = kCBLLogLevelVerbose;
    
    [self writeOneKiloByteOfLog];
    NSArray* files = [self getLogsInDirectory: config.directory properties: nil onlyInfoLogs: NO];
    NSError* error;
    for (NSURL* url in files) {
        NSString* contents = [NSString stringWithContentsOfURL: url
                                                      encoding: NSASCIIStringEncoding
                                                         error: &error];
        NSAssert(!error, @"Error reading file: %@", [error localizedDescription]);
        NSArray<NSString *> *lines = [contents componentsSeparatedByString:@"\n"];
        
        // Check if the log file contains at least two lines
        NSAssert(lines.count >= 2, @"log contents should have at least two lines: information and header section");
        NSString *secondLine = lines[1];

        NSAssert([secondLine rangeOfString:@"CouchbaseLite/"].location != NSNotFound, @"Second line should contain 'CouchbaseLite/'");
        NSAssert([secondLine rangeOfString:@"Build/"].location != NSNotFound, @"Second line should contain 'Build/'");
        NSAssert([secondLine rangeOfString:@"Commit/"].location != NSNotFound, @"Second line should contain 'Commit/'");
    }
}

- (void) testNonASCII {
    CustomLogger* customLogger = [[CustomLogger alloc] init];
    customLogger.level = kCBLLogLevelVerbose;
    CBLDatabase.log.custom = customLogger;
    
    NSString* hebrew = @"מזג האוויר נחמד היום"; // The weather is nice today.
    CBLMutableDocument* document = [self createDocument: @"doc1"];
    [document setString: hebrew forKey: @"hebrew"];
    NSError* error;
    [self.db saveDocument: document error: &error];
    AssertNil(error);
    
    CBLQuery* q = [CBLQueryBuilder select: @[[CBLQuerySelectResult all]]
                                     from: [CBLQueryDataSource database: self.db]];
    AssertNotNil(q);
    NSEnumerator* rs = [q execute:&error];
    AssertNil(error);
    AssertEqual([[rs allObjects] count], 1u);
    NSString* expectedHebrew = [NSString stringWithFormat: @"[{\"hebrew\":\"%@\"}]", hebrew];
    BOOL found = NO;
    for (NSString* line in customLogger.lines) {
        if ([line containsString: expectedHebrew]) {
            found = YES;
        }
    }
    Assert(found);
}

- (void) testPercentEscape {
    CustomLogger* customLogger = [[CustomLogger alloc] init];
    customLogger.level = kCBLLogLevelInfo;
    CBLDatabase.log.custom = customLogger;
    
    CBLLogInfo(Database, @"Hello %%s there");
    
    BOOL found = NO;
    for (NSString* line in customLogger.lines) {
        if ([line containsString:  @"Hello %s there"]) {
            found = YES;
        }
    }
    Assert(found);
}

- (void) testUseBothApi {
    CustomLogger* customLogger = [[CustomLogger alloc] init];
    customLogger.level = kCBLLogLevelVerbose;
    CBLDatabase.log.custom = customLogger;
    [self expectException: @"NSInternalInconsistencyException" in: ^{
        CBLLogSinks.console = [[CBLConsoleLogSink alloc] initWithLevel: kCBLLogLevelVerbose];
    }];
}

#pragma clang diagnostic pop

@end

@implementation FileLoggerBackup

@synthesize config=_config, level=_level;

@end

@implementation CustomLogger {
    NSMutableArray* _lines;
}

@synthesize level=_level;

- (instancetype) init {
    self = [super init];
    if (self) {
        _level = kCBLLogLevelNone;
        _lines = [NSMutableArray new];
    }
    return self;
}

- (NSArray*) lines {
    return _lines;
}

- (void) reset {
    [_lines removeAllObjects];
}

- (BOOL) containsString: (NSString *)string {
    for (NSString* line in _lines) {
        if ([line containsString: string]) {
            return YES;
        }
    }
    return NO;
}

- (void)logWithLevel: (CBLLogLevel)level domain: (CBLLogDomain)domain message: (NSString*)message {
    [_lines addObject: message];
}

@end
