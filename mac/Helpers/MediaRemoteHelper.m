// MediaRemote reader/commander hosted by /usr/bin/perl.
//
// macOS 15.4+ only serves now-playing info to Apple-signed processes, so Isola runs
//   /usr/bin/perl mediaremote.pl <this dylib> isola_mediaremote
// and talks to it over pipes: JSON lines out (one per change), commands in
// ("cmd <MRCommand>", "seek <seconds>", "rate <x>", "like <0|1>"). EOF on stdin ends the helper.
#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <math.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*InfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*PlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*PIDFn)(dispatch_queue_t, void (^)(int));
typedef void (*CommandsFn)(dispatch_queue_t, void (^)(CFArrayRef));
typedef unsigned (*CommandFn)(id);
typedef Boolean (*EnabledFn)(id);
typedef CFTypeRef (*OptionFn)(id, CFStringRef);
typedef Boolean (*SendFn)(unsigned int, CFDictionaryRef);
typedef void (*ElapsedFn)(double);
typedef CFTypeRef (*RequestFn)(long, long);
typedef void (*QueueFn)(id, id, dispatch_queue_t, void (^)(id, NSError *));
typedef CFArrayRef (*ItemsFn)(id);

// Private classes met on the playback-queue path (MRPlaybackQueueRequest, MRContentItem,
// MRContentItemMetadata, MRContentItemMetadataAudioFormat), as their runtime declares them.
@protocol IsolaQueueRequest
- (void)setIncludeMetadata:(BOOL)include;
@end
@protocol IsolaAudioFormat
- (BOOL)hasTier;
- (long long)tier;
- (BOOL)hasRenderingMode;
- (long long)renderingMode;
@end
@protocol IsolaMetadata
- (id<IsolaAudioFormat>)activeFormat;
@end
@protocol IsolaContentItem
- (NSString *)identifier;
- (id<IsolaMetadata>)metadata;
@end

// MRMediaRemoteCopyCommandDescription: 19 ChangePlaybackRateCommand, 21 LikeTrack.
static const unsigned ChangePlaybackRate = 19, LikeTrack = 21;

static void *mr;
static NSString *lastArtworkID = @"", *lastTrack = @"";
static NSData *lastLine;
static NSString *formatItem = @"";
static NSDictionary *format = @{};

static void emit(void);

// Strings and finite numbers only: NSJSONSerialization throws on NaN/Inf, which would kill the helper.
static BOOL usable(id v) {
    return [v isKindOfClass:NSString.class] || ([v isKindOfClass:NSNumber.class] && isfinite([v doubleValue]));
}

static void output(NSDictionary *o) {
    if (![NSJSONSerialization isValidJSONObject:o]) return;
    NSData *json = [NSJSONSerialization dataWithJSONObject:o options:NSJSONWritingSortedKeys error:nil];
    // Each change arrives as a burst of notifications: only the first identical line goes out.
    if (!json || [json isEqualToData:lastLine]) return;
    lastLine = json;
    fwrite(json.bytes, 1, json.length, stdout);
    fputc('\n', stdout);
    fflush(stdout);
}

// Lossless / Dolby Atmos live in the now-playing item's metadata (activeFormat), not in the
// info dictionary. Tier 2 Lossless, 3 HighResolutionLossless, 4 Spatial; rendering 5 DolbyAtmos.
static void requestFormat(NSString *item) {
    RequestFn create = (RequestFn)dlsym(mr, "MRPlaybackQueueRequestCreate");
    QueueFn ask = (QueueFn)dlsym(mr, "MRMediaRemoteRequestNowPlayingPlaybackQueueForPlayer");
    ItemsFn items = (ItemsFn)dlsym(mr, "MRPlaybackQueueCopyContentItems");
    if (!create || !ask || !items || !item.length) return;
    id<IsolaQueueRequest> request = CFBridgingRelease(create(0, 1));
    [request setIncludeMetadata:YES];
    ask(request, nil, dispatch_get_main_queue(), ^(id queue, NSError *error) {
        NSArray *list = queue ? CFBridgingRelease(items(queue)) : nil;
        id<IsolaContentItem> current = list.firstObject;
        if (![current.identifier isEqual:formatItem]) return;
        id<IsolaAudioFormat> f = current.metadata.activeFormat;
        NSMutableDictionary *found = [NSMutableDictionary dictionary];
        if (f.hasTier) found[@"tier"] = @(f.tier);
        if (f.hasRenderingMode) found[@"rendering"] = @(f.renderingMode);
        if ([found isEqual:format]) return;
        format = found;
        emit();
    });
}

static NSDictionary *build(NSDictionary *d, Boolean isPlaying, int processID, NSArray *commands) {
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    NSString *p = @"kMRMediaRemoteNowPlayingInfo";
    NSDictionary *keys = @{@"Title": @"title", @"Artist": @"artist", @"Album": @"album", @"Duration": @"duration",
                           @"ElapsedTime": @"elapsed", @"PlaybackRate": @"rate", @"ShuffleMode": @"shuffle",
                           @"RepeatMode": @"repeat", @"IsExplicitTrack": @"explicit", @"IsInTransition": @"transition",
                           @"IsLiked": @"liked"};
    for (NSString *k in keys) {
        id v = d[[p stringByAppendingString:k]];
        if (usable(v)) o[keys[k]] = v;
    }
    // No timestamp means "now" on Isola's side; sending the clock here would defeat deduplication.
    NSDate *ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    if ([ts isKindOfClass:NSDate.class] && isfinite(ts.timeIntervalSince1970)) o[@"timestamp"] = @(ts.timeIntervalSince1970);
    o[@"playing"] = @(isPlaying);
    o[@"pid"] = @(processID);
    // Liking is a command; its "active" flag is the liked state (MPFeedbackCommand.isActive).
    CommandFn command = (CommandFn)dlsym(mr, "MRMediaRemoteCommandInfoGetCommand");
    EnabledFn enabled = (EnabledFn)dlsym(mr, "MRMediaRemoteCommandInfoGetEnabled");
    OptionFn option = (OptionFn)dlsym(mr, "MRMediaRemoteCommandInfoCopyValueForKey");
    for (id c in commands) {
        if (!command || !enabled || !option || command(c) != LikeTrack || !enabled(c)) continue;
        o[@"canLike"] = @YES;
        id active = CFBridgingRelease(option(c, CFSTR("kMRMediaRemoteCommandInfoIsActiveKey")));
        if (!o[@"liked"] && [active isKindOfClass:NSNumber.class]) o[@"liked"] = active;
    }
    NSString *track = [NSString stringWithFormat:@"%@|%@|%@", o[@"title"], o[@"artist"], o[@"album"]];
    BOOL sameTrack = [track isEqualToString:lastTrack];
    lastTrack = track;
    NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    if ([art isKindOfClass:NSData.class]) {
        NSString *aid = d[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
        if (![aid isKindOfClass:NSString.class]) aid = [NSString stringWithFormat:@"%@|%@|%lu", o[@"title"], o[@"album"], (unsigned long)art.length];
        o[@"artworkID"] = aid;
        if (![aid isEqualToString:lastArtworkID]) { o[@"artwork"] = [art base64EncodedStringWithOptions:0]; lastArtworkID = aid; }
    } else if (sameTrack && lastArtworkID.length) {
        // Players republish the metadata on pause/play and add the art a moment later: keep the one Isola has.
        o[@"artworkID"] = lastArtworkID;
    } else {
        lastArtworkID = @"";
    }
    // The item identifier changes on every republish; the format only resets with the track.
    NSString *item = d[@"kMRMediaRemoteNowPlayingInfoContentItemIdentifier"];
    if (![item isKindOfClass:NSString.class]) item = @"";
    if (!sameTrack) format = @{};
    if (![item isEqualToString:formatItem]) { formatItem = item; requestFormat(item); }
    [o addEntriesFromDictionary:format];
    return o;
}

static void emit(void) {
    InfoFn info = (InfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    PlayingFn playing = (PlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    PIDFn pid = (PIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    CommandsFn supported = (CommandsFn)dlsym(mr, "MRMediaRemoteGetSupportedCommands");
    if (!info || !playing || !pid || !supported) return;
    info(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *d = (__bridge NSDictionary *)raw;
        playing(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            pid(dispatch_get_main_queue(), ^(int processID) {
                supported(dispatch_get_main_queue(), ^(CFArrayRef commands) {
                    output(build(d, isPlaying, processID, (__bridge NSArray *)commands));
                });
            });
        });
    });
}

static void handle(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    NSString *verb = parts[0];
    double value = [parts[1] doubleValue];
    if (!isfinite(value)) return;
    SendFn send = (SendFn)dlsym(mr, "MRMediaRemoteSendCommand");
    if ([verb isEqualToString:@"cmd"] && send) {
        send((unsigned int)value, NULL);
    } else if ([verb isEqualToString:@"seek"]) {
        ElapsedFn set = (ElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        if (set) set(value);
    } else if ([verb isEqualToString:@"rate"] && send) {
        send(ChangePlaybackRate, (__bridge CFDictionaryRef) @{@"kMRMediaRemoteOptionPlaybackRate": @(value)});
    } else if ([verb isEqualToString:@"like"] && send) {
        // "like 0" takes the like back (MPFeedbackCommandEvent.isNegative).
        send(LikeTrack, value ? NULL : (__bridge CFDictionaryRef) @{@"kMRMediaRemoteOptionIsNegative": @YES});
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
}

void isola_mediaremote(void *perl, void *cv) {
    mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    if (!mr) { fprintf(stderr, "MediaRemote unavailable\n"); exit(1); }
    ((RegisterFn)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications"))(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil usingBlock:^(NSNotification *n) { emit(); }];
    }
    // Commands arrive on stdin; EOF means Isola quit.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        char buf[256];
        while (fgets(buf, sizeof buf, stdin)) {
            NSString *line = [[NSString stringWithUTF8String:buf] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            dispatch_async(dispatch_get_main_queue(), ^{ handle(line); });
        }
        exit(0);
    });
    // Elapsed time and the like/format state drift without notifications; a slow heartbeat keeps them honest.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); requestFormat(formatItem); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
