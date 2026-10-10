// VTL as a real row in the mod's own Lyrics Sources list, with the mod's own word-timed TTML
// pipeline - built as a separate dylib that needs none of the real dylib's source or symbols.
//
// How it works, using only things the real dylib already has at runtime:
//  1. The mod's providers are SGLyricsProvider objects (key, name, detail, ask). This hooks that
//     class's getters - a class only the mod defines and never hooks itself, so nothing collides.
//     The "binilyrics" slot is shown as "VTL" in Lyrics Sources, and its ask block is wrapped.
//  2. BiniLyrics already knows how to turn Apple-style TTML into word-timed karaoke lines (it
//     searches lyrics-api.binimum.org, then downloads the TTML from the lyricsUrl in the answer and
//     runs the mod's own TTML reader on it). The wrapper checks whether VTL has the track (by
//     Spotify id, api.vexqyq.com/lyrics/<id>); if so it asks the ORIGINAL BiniLyrics ask with a
//     marked query ("vtl:<id>"), and a small NSURLProtocol answers that one search request with a
//     result pointing at VTL's TTML. Everything else goes to the real BiniLyrics untouched.
//  3. NSURLProtocol registration is a public additive API (no swizzling) and only claims
//     lyrics-api.binimum.org requests whose track starts with "vtl:".
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kVTLBase = @"https://api.vexqyq.com/lyrics/";
static NSString *const kBiniHost = @"lyrics-api.binimum.org";
static NSString *const kMarker = @"vtl:";

typedef void (^VTLDone)(id result);
typedef void (^VTLAsk)(id query, VTLDone done);

#pragma mark - the NSURLProtocol that answers BiniLyrics' search for VTL tracks

static NSString *queryParam(NSURL *url, NSString *name) {
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    for (NSURLQueryItem *item in c.queryItems) {
        if ([item.name isEqualToString:name]) return item.value;
    }
    return nil;
}

@interface VTLProxyProtocol : NSURLProtocol
@end

@implementation VTLProxyProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    NSURL *url = request.URL;
    if (![url.host isEqualToString:kBiniHost]) return NO;
    return [queryParam(url, @"track") hasPrefix:kMarker];
}
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    NSURL *url = self.request.URL;
    NSString *trackID = [queryParam(url, @"track") substringFromIndex:kMarker.length];
    NSInteger duration = [queryParam(url, @"duration") integerValue];
    NSDictionary *body = @{@"results": @[@{
        @"lyricsUrl": [kVTLBase stringByAppendingString:trackID],
        @"duration": @(duration),
        @"timing_type": @"word",
    }]};
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:url statusCode:200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type": @"application/json"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

#pragma mark - does VTL have this track

static NSMutableDictionary<NSString *, NSNumber *> *sg_has;   // track id -> YES/NO, main queue only

static void checkVTL(NSString *trackID, void (^answer)(BOOL has)) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSNumber *known = sg_has[trackID];
        if (known) { answer(known.boolValue); return; }
        NSURL *url = [NSURL URLWithString:[kVTLBase stringByAppendingString:trackID]];
        [[NSURLSession.sharedSession dataTaskWithURL:url completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 0;
            BOOL has = !error && status == 200 && data.length > 0;
            dispatch_async(dispatch_get_main_queue(), ^{
                // A miss is kept too (one request per track per run); a failed request is not.
                if (has || status == 404) sg_has[trackID] = @(has);
                answer(has);
            });
        }] resume];
    });
}

#pragma mark - the SGLyricsProvider hook

@interface SGLyricsProvider : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic, copy) id ask;
@end

static BOOL isBini(id provider) {
    return [provider respondsToSelector:@selector(key)] && [[provider valueForKey:@"key"] isEqual:@"binilyrics"];
}

// A copy of the walk's query with the track marked for the protocol; the walk's own query is left
// alone since later sources read its title and artist.
static id markedQuery(id query, NSString *trackID) {
    id copy = [[[query class] alloc] init];
    for (NSString *key in @[@"trackID", @"title", @"artist", @"album", @"seconds"]) {
        @try { [copy setValue:[query valueForKey:key] forKey:key]; } @catch (NSException *e) {}
    }
    @try {
        [copy setValue:[kMarker stringByAppendingString:trackID] forKey:@"title"];
        [copy setValue:@"vtl" forKey:@"artist"];
    } @catch (NSException *e) {}
    return copy;
}

static VTLAsk wrap(VTLAsk original) {
    if (!original) return original;
    return ^(id query, VTLDone done) {
        NSString *trackID = nil;
        @try { trackID = [query valueForKey:@"trackID"]; } @catch (NSException *e) {}
        if (![trackID isKindOfClass:NSString.class] || !trackID.length) { original(query, done); return; }
        checkVTL(trackID, ^(BOOL has) {
            original(has ? markedQuery(query, trackID) : query, done);
        });
    };
}

%hook SGLyricsProvider
- (NSString *)name { return isBini(self) ? @"VTL" : %orig; }
- (NSString *)detail { return isBini(self) ? @"Your uploads, word timed, then BiniLyrics" : %orig; }
- (id)ask { return isBini(self) ? (id)wrap((VTLAsk)%orig) : %orig; }
%end

#pragma mark - load badge (diagnostic)

static UIWindow *keyWindow(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.isKeyWindow) return w;
        }
    }
    return nil;
}

static void showBadge(int attemptsLeft, NSString *text) {
    UIWindow *win = keyWindow();
    if (!win) {
        if (attemptsLeft > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ showBadge(attemptsLeft - 1, text); });
        return;
    }
    UILabel *badge = [UILabel new];
    badge.text = text;
    badge.textColor = UIColor.blackColor;
    badge.backgroundColor = [UIColor colorWithRed:0.35 green:1.0 blue:0.43 alpha:1];
    badge.font = [UIFont boldSystemFontOfSize:11];
    badge.textAlignment = NSTextAlignmentCenter;
    badge.layer.cornerRadius = 8;
    badge.clipsToBounds = YES;
    badge.translatesAutoresizingMaskIntoConstraints = NO;
    [win addSubview:badge];
    [NSLayoutConstraint activateConstraints:@[
        [badge.topAnchor constraintEqualToAnchor:win.safeAreaLayoutGuide.topAnchor constant:6],
        [badge.centerXAnchor constraintEqualToAnchor:win.centerXAnchor],
        [badge.widthAnchor constraintEqualToConstant:170],
        [badge.heightAnchor constraintEqualToConstant:22],
    ]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{ badge.alpha = 0; } completion:^(BOOL done) { [badge removeFromSuperview]; }];
    });
}

%ctor {
    sg_has = [NSMutableDictionary dictionary];
    [NSURLProtocol registerClass:VTLProxyProtocol.class];
    // The hook is only worth installing when the mod's provider class is there to hook.
    BOOL hooked = objc_getClass("SGLyricsProvider") != nil;
    if (hooked) { %init; }
    NSString *text = hooked ? @"VTL lyrics source active" : @"VTL: provider class not found";
    dispatch_async(dispatch_get_main_queue(), ^{ showBadge(15, text); });
}
