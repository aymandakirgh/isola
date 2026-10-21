// MediaRemote reader/commander hosted by /usr/bin/perl.
//
// macOS 15.4+ only serves now-playing info to Apple-signed processes, so Isola runs
//   /usr/bin/perl mediaremote.pl <this dylib> isola_mediaremote
// and talks to it over pipes: JSON lines out (one per change), commands in
// ("cmd <MRCommand>", "seek <seconds>", "rate <x>"). EOF on stdin ends the helper.
#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*RegisterFn)(dispatch_queue_t);
typedef void (*InfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef void (*PlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef void (*PIDFn)(dispatch_queue_t, void (^)(int));
typedef Boolean (*SendFn)(unsigned int, CFDictionaryRef);
typedef void (*ElapsedFn)(double);

static void *mr;
static NSString *lastArtworkID = @"";

static void emit(void) {
    InfoFn info = (InfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    PlayingFn playing = (PlayingFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    PIDFn pid = (PIDFn)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    if (!info || !playing || !pid) return;
    info(dispatch_get_main_queue(), ^(CFDictionaryRef raw) {
        NSDictionary *d = (__bridge NSDictionary *)raw;
        playing(dispatch_get_main_queue(), ^(Boolean isPlaying) {
            pid(dispatch_get_main_queue(), ^(int processID) {
                NSMutableDictionary *o = [NSMutableDictionary dictionary];
                NSString *p = @"kMRMediaRemoteNowPlayingInfo";
                NSDictionary *keys = @{@"Title": @"title", @"Artist": @"artist", @"Album": @"album", @"Duration": @"duration",
                                       @"ElapsedTime": @"elapsed", @"PlaybackRate": @"rate", @"ShuffleMode": @"shuffle",
                                       @"RepeatMode": @"repeat", @"IsExplicitTrack": @"explicit"};
                for (NSString *k in keys) {
                    id v = d[[p stringByAppendingString:k]];
                    if ([v isKindOfClass:NSString.class] || [v isKindOfClass:NSNumber.class]) o[keys[k]] = v;
                }
                NSDate *ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
                o[@"timestamp"] = @([ts isKindOfClass:NSDate.class] ? ts.timeIntervalSince1970 : NSDate.date.timeIntervalSince1970);
                o[@"playing"] = @(isPlaying);
                o[@"pid"] = @(processID);
                NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
                if ([art isKindOfClass:NSData.class]) {
                    NSString *aid = d[@"kMRMediaRemoteNowPlayingInfoArtworkIdentifier"];
                    if (![aid isKindOfClass:NSString.class]) aid = [NSString stringWithFormat:@"%@|%@|%lu", o[@"title"], o[@"album"], (unsigned long)art.length];
                    o[@"artworkID"] = aid;
                    if (![aid isEqualToString:lastArtworkID]) { o[@"artwork"] = [art base64EncodedStringWithOptions:0]; lastArtworkID = aid; }
                } else {
                    lastArtworkID = @"";
                }
                NSData *json = [NSJSONSerialization dataWithJSONObject:o options:0 error:nil];
                if (!json) return;
                fwrite(json.bytes, 1, json.length, stdout);
                fputc('\n', stdout);
                fflush(stdout);
            });
        });
    });
}

static void handle(NSString *line) {
    NSArray *parts = [line componentsSeparatedByString:@" "];
    if (parts.count < 2) return;
    NSString *verb = parts[0];
    double value = [parts[1] doubleValue];
    SendFn send = (SendFn)dlsym(mr, "MRMediaRemoteSendCommand");
    if ([verb isEqualToString:@"cmd"] && send) {
        send((unsigned int)value, NULL);
    } else if ([verb isEqualToString:@"seek"]) {
        ElapsedFn set = (ElapsedFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        if (set) set(value);
    } else if ([verb isEqualToString:@"rate"] && send) {
        send(19, (__bridge CFDictionaryRef) @{@"kMRMediaRemoteOptionPlaybackRate": @(value)});
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
    // Elapsed time drifts without notifications; a slow heartbeat keeps it honest.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
