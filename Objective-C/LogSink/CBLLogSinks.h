//
//  CBLLogSinks.h
//  CouchbaseLite
//
//  Copyright (c) 2025 Couchbase, Inc All rights reserved.
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

#import <Foundation/Foundation.h>

@class CBLConsoleLogSink;
@class CBLCustomLogSink;
@class CBLFileLogSink;

NS_ASSUME_NONNULL_BEGIN

/** A static container for managing the three log sinks used by Couchbase Lite. */
@interface CBLLogSinks : NSObject

/** The console log sink, enabled by default with a warning level. */
@property (class, nonatomic, nullable) CBLConsoleLogSink* console;

/** The file log sink, disabled by default. */
@property (class, nonatomic, nullable) CBLFileLogSink* file;

/** The custom log sink, disabled by default. */
@property (class, nonatomic, nullable) CBLCustomLogSink* custom;

- (instancetype) init NS_UNAVAILABLE;

@end

NS_ASSUME_NONNULL_END
