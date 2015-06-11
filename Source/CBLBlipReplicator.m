//
//  CBLBlipReplicator.m
//  Couchbase Lite
//
//  Created by Jens Alfke on 5/1/15.
//  Copyright (c) 2015 Couchbase. All rights reserved.
//

#import "CBLBlipReplicator.h"
#import "CBLSyncConnection.h"
#import "CBLAuthorizer.h"
#import "BLIPPocketSocketConnection.h"
#import "BLIPHTTPLogic.h"
#import "CollectionUtils.h"
#import "Logging.h"
#import "MYErrorUtils.h"
#import <CouchbaseLite/CouchbaseLitePrivate.h>
#import <CouchbaseLite/CBLReachability.h>
#import <CouchbaseLite/CBLMisc.h>
#import <CouchbaseLite/CBLCookieStorage.h>
#import <netdb.h>


#define kMinRetryInterval 4.0           // Initial retry interval (secs); doubles every attempt
#define kMaxRetryInterval (5 * 60.0)    // Max retry interval

// Minimum retry interval to use while the server's unreachable and we're tracking its reachability.
// The assumption is we'll be notified as soon as it comes online, so the retry is only needed as a
// fail-safe case the SystemConfiguration Reachability API screws up.
#define kMinRetryIntervalWhileTrackingReachability kMaxRetryInterval


#define kReplicatorConnecting kCBLReplicatorActive


@interface CBLBlipReplicator ()
@property CBLSyncConnection* sync;
@property (readwrite) CBL_ReplicatorStatus status;
@property (readwrite) NSProgress* progress;
@end


@implementation CBLBlipReplicator
{
    dispatch_queue_t _syncQueue, _dbQueue;
    BOOL _started;
    int _retryCount;
    BLIPPocketSocketConnection* _conn;
    CBLReachability* _reachability;
    BOOL _reachable;
    BOOL _suspended;
    CBLSyncConnection* _sync;
}

@synthesize db=_db, settings=_settings, error=_error, sessionID=_sessionID;
@synthesize serverCert=_serverCert, cookieStorage = _cookieStorage;
@synthesize sync=_sync, status=_status, progress=_progress;
@synthesize remoteCheckpointDocID=_remoteCheckpointDocID;


+ (BOOL) needsRunLoop {
    return NO;
}


- (id<CBL_Replicator>) initWithDB: (CBLDatabase*)db
                         settings: (CBL_ReplicatorSettings*)settings
{
    self = [super init];
    if (self) {
        _db = db;
        _settings = settings;
        _dbQueue = _db.manager.dispatchQueue;

        NSString* name = $sprintf(@"Replicator %@ <%@>",
                                  (settings.isPush ?@"to" :@"from"), settings.remote);
        _syncQueue = dispatch_queue_create(name.UTF8String, DISPATCH_QUEUE_SERIAL);

        static int sLastSessionID = 0;
        _sessionID = [$sprintf(@"repl%03d", ++sLastSessionID) copy];
        _progress = [NSProgress progressWithTotalUnitCount: -1]; // indeterminate
        _remoteCheckpointDocID = [_settings remoteCheckpointDocIDForLocalUUID: _db.privateUUID];
        _cookieStorage = [[CBLCookieStorage alloc] initWithDB: db
                                                   storageKey: _remoteCheckpointDocID];
    }
    return self;
}

- (void) dealloc {
    [self forgetSync];
}


- (NSUInteger) changesProcessed     {return (NSUInteger)self.progress.completedUnitCount;}
- (NSUInteger) changesTotal         {return (NSUInteger)self.progress.totalUnitCount;}


+ (NSSet*) keyPathsForValuesAffectingProgress {
    return [NSSet setWithObjects:@"sync.pushProgress", @"sync.pullProgress", nil];
}

- (NSArray*) nestedProgress {
    return _settings.isPush ? _sync.nestedPushProgress : _sync.nestedPullProgress;
}

+ (NSSet*) keyPathsForValuesAffectingNestedProgress {
    return [NSSet setWithObjects: @"sync.nestedPushProgress", @"sync.nestedPullProgress", nil];
}


- (void) start {
    if (_started)
        return;
    _started = YES;
    self.status = kReplicatorConnecting;
    [self connect];
}


- (void) stop {
    if (_started) {
        dispatch_async(_syncQueue, ^{
            [_sync close];
        });
    }
}


- (BOOL) suspended {
    return _suspended;
}

- (void) setSuspended: (BOOL)suspended {
    _suspended = suspended;
    if (_suspended)
        [self disconnect];
    else
        [self connect];
}


/** Called by CBLDatabase to notify active replicators that it's about to close. */
- (void) databaseClosing {
    // TODO
}


- (NSSet*) pendingDocIDs {
    CBLQueryEnumerator* e = _sync.pendingDocuments;
    if (!e)
        return nil;
    NSMutableSet* docIDs = [NSMutableSet new];
    for (CBLQueryRow* row in e) {
        [docIDs addObject: row.documentID];
    }
    return docIDs;
}


#if DEBUG
@synthesize savingCheckpoint=_savingCheckpoint, active=_active, lastSequence=_lastSequence;
#endif


#pragma mark - INTERNALS:


- (void) connect {
    LogTo(Sync, @"Connecting to %@ ...", _settings.remote.host);
    [self gotError: nil];

    NSURL* url = [_settings.remote URLByAppendingPathComponent: @"_blipsync"];
    NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL: url];
    request.timeoutInterval = _settings.requestTimeout;
    [request setValue: [BLIPHTTPLogic userAgent] forHTTPHeaderField: @"User-Agent"];
    [_settings.requestHeaders enumerateKeysAndObjectsUsingBlock:^(id key, id value, BOOL *stop) {
        [request setValue: value forHTTPHeaderField: key];
    }];
    [self.cookieStorage addCookieHeaderToRequest: request];

    id<CBLAuthorizer> auth = _settings.authorizer;
    if ([auth isKindOfClass: [CBLBasicAuthorizer class]]) {
        _conn.credential = ((CBLBasicAuthorizer*)auth).credential;
    } else {
        [request setValue: [auth authorizeURLRequest: request forRealm: nil]
                 forHTTPHeaderField: @"Authorization"];
    }

    _conn = [[BLIPPocketSocketConnection alloc] initWithURLRequest: request];

    CBLSyncConnection* sync = [[CBLSyncConnection alloc] initWithDatabase: _db
                                                               connection: _conn
                                                                    queue: _syncQueue];
    sync.remoteCheckpointDocID = _remoteCheckpointDocID;
    BOOL isPush = _settings.isPush;
    if (isPush)
        [sync setPushFilter: _settings.filterBlock params: _settings.filterParameters];
    [sync push: isPush pull: !isPush continuously: _settings.continuous];

    NSError* error;
    if (![_conn connect: &error]) {
        Warn(@"Couldn't connect: %@", error);
        _conn = nil;
        [self gotError: error];
    }

#if DEBUG
    _active = sync.active;
    _savingCheckpoint = sync.savingCheckpoint;
    _lastSequence = sync.lastSequence;
#endif

    [sync addObserver: self forKeyPath: @"state" options: 0 context: (void*)1];
    self.sync = sync;
    self.progress = isPush ? sync.pushProgress : sync.pullProgress;
    [_progress addObserver: self forKeyPath: @"fractionCompleted" options: 0 context: (void*)2];
    self.status = kReplicatorConnecting;
}


- (void) disconnect {
    [_sync close];
    [_reachability stop];
    _reachability = nil;
}


- (void) retry {
    [self forgetSync];

    NSTimeInterval retryDelay = MIN(kMinRetryInterval * exp2(_retryCount++), kMaxRetryInterval);

    if (!_reachability && CBLIsOfflineError(_error)) {
        // Network seems to be offline, so start a reachability monitor so I can retry ASAP:
        _reachability = [[CBLReachability alloc] initWithHostName: _settings.remote.host];
        __weak CBLBlipReplicator* weakSelf = self;
        _reachability.onChange = ^{
            [weakSelf reachabilityChanged];
        };
        _reachable = _reachability.reachable;
        LogTo(Sync, @"Starting reachability monitor... initial _reachable=%d", _reachable);
        [_reachability startOnQueue: _syncQueue];

        retryDelay = MAX(retryDelay, kMinRetryIntervalWhileTrackingReachability);
    }

    LogTo(Sync, @"Retrying connection in %g sec ...", retryDelay);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelay * NSEC_PER_SEC)), _syncQueue, ^{
        if (_started && !_sync)
            [self connect];
    });
}


- (void) reachabilityChanged {
    BOOL wasReachable = _reachable;
    _reachable = !_suspended && [_settings isHostReachable: _reachability];
    if (!wasReachable && _reachable) {
        if (_started && !_sync) {
            LogTo(Sync, @"Host %@ is now reachable; retrying...", _settings.remote.host);
            [self connect];
        }
    }
}


- (void) forgetSync {
    if (_sync) {
        [_sync removeObserver: self forKeyPath: @"state"];
        [_progress removeObserver: self forKeyPath: @"fractionCompleted"];
        self.sync = nil;
    }
    _conn = nil;
}


#pragma mark - NOTIFICATION:


- (void) gotError: (NSError*)error {
    if ($equal(error.domain, @"HTTP")) {
        error = [NSError errorWithDomain: CBLHTTPErrorDomain
                                    code: error.code
                                userInfo: error.userInfo];
    }
    if (!$equal(error, _error)) {
        LogTo(Sync, @"Connection got error %@ [%@ %ld]",
              error.localizedDescription, error.domain, (long)error.code);
        self.error = error;
    }
}


// Called on the _syncQueue
- (void) syncStateChanged {
    CBL_ReplicatorStatus newStatus;
    NSError* newError = nil;

    switch (_sync.state) {
        case kSyncStopped: {
            newError = _sync.error;
            if (_suspended) {
                newStatus = kCBLReplicatorOffline;
            } else if (CBLMayBeTransientError(_error) || CBLIsOfflineError(_error)) {
                [self retry];
                newStatus = kCBLReplicatorOffline;
            } else {
                newStatus = kCBLReplicatorStopped;
            }
            break;
        }
        case kSyncConnecting:
            newStatus = kReplicatorConnecting;
            break;
        case kSyncActive:
            newStatus = kCBLReplicatorActive;
            break;
        case kSyncIdle:
            newStatus = kCBLReplicatorIdle;
            if (!_settings.continuous) {
                LogTo(Sync, @"%@: SyncHandler went idle; closing connection...", self);
                newStatus = kCBLReplicatorStopped;
                [_sync close];
            }
            break;
    }

    if (newStatus >= kCBLReplicatorIdle)
        _retryCount = 0; // reset retry interval back to minimum

#if DEBUG
    BOOL newActive = _sync.active;
    BOOL newSavingCheckpoint = _sync.savingCheckpoint;
    id newLastSequence = _sync.lastSequence;
#endif

    // Now switch back to the db thread to update my public state:
    [_db doAsync:^{
        static const char* kStateNames[] = {"Stopped", "Offline", "Idle", "Active"};
        LogTo(Sync, @"Replicator.status = kReplicator%s", kStateNames[newStatus]);
#if DEBUG
        LogTo(Sync, @"          .active=%d, .savingCheckpoint=%d, .lastSequence=%@",
              newActive, newSavingCheckpoint, newLastSequence);
        _active = newActive;
        _savingCheckpoint = newSavingCheckpoint;
        _lastSequence = newLastSequence;
#endif
        [self gotError: newError];
        if (newStatus != _status) {
            self.status = newStatus; // Triggers KVO!
            [[NSNotificationCenter defaultCenter]
                 postNotificationName: CBL_ReplicatorProgressChangedNotification object: self];
        }
    }];
}


- (void) syncProgressChanged {
#if DEBUG
    BOOL newActive = _sync.active;
    BOOL newSavingCheckpoint = _sync.savingCheckpoint;
    id newLastSequence = _sync.lastSequence;
#endif
    // Needs to be posted on the database's official thread/queue.
    [_db doAsync:^{
#if DEBUG
        _active = newActive;
        _savingCheckpoint = newSavingCheckpoint;
        _lastSequence = newLastSequence;
#endif
        [[NSNotificationCenter defaultCenter]
                     postNotificationName: CBL_ReplicatorProgressChangedNotification object: self];
    }];
}


- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                        change:(NSDictionary *)change context:(void *)context
{
    if (context == (void*)1 && object == _sync) {
        [self syncStateChanged];
    } else if (context == (void*)2 && object == _progress) {
        [self syncProgressChanged];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}


@end
