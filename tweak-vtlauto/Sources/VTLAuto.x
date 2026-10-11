// VTL as its OWN source in the mod's Lyrics Sources list, next to BiniLyrics instead of replacing it,
// with the mod's own word-timed TTML pipeline - a separate dylib that needs none of the real dylib's
// source and none of its (stripped) C symbols.
//
// Found by reading the official spotifyglass.dylib (ObjC metadata + disassembly), not guessed:
//  * The sources are SGLyricsProvider objects (key, name, detail, needsName, ask). The list lives in a
//    static NSArray built once by SGLyricsAllProviders() - an `@[...]` of 6 providers, i.e. one call
//    to +[NSArray arrayWithObjects:count:] - stored at image offset 0x3b3f78 (dispatch_once token at
//    0x3b3f80). Everything reads that one array: SGLyricsProviderFor(key) (the fetch walk) and the
//    Lyrics Sources page (which builds one SGOrderItem per provider in it).
//  * So adding a 7th provider to that array adds a real, independent row AND a real source in the
//    chain, and BiniLyrics' own provider object is never touched.
//
// Two ways in, because the array may be built before or after this dylib loads:
//  1. Hook +[NSArray arrayWithObjects:count:]. The check is a pointer compare of every element's class
//     against SGLyricsProvider, so any other array costs a few compares and is left alone.
//  2. If the array already exists, rewrite the static slot (verified first - must be a heap NSArray of
//     SGLyricsProvider objects containing "binilyrics", or nothing is written).
//
// VTL's ask reuses the mod's own BiniLyrics ask for the heavy part: BiniLyrics already turns Apple-
// style TTML into word-timed karaoke lines (it searches lyrics-api.binimum.org, then downloads the
// lyricsUrl in the answer and runs the mod's TTML reader on it). VTL asks the REAL BiniLyrics ask with
// a marked query ("vtl:<id>"); a small NSURLProtocol answers that one search request with a result
// pointing at api.vexqyq.com/lyrics/<id>. A track VTL has nothing for answers nil, so the walk moves
// on to the next source - the real BiniLyrics included - untouched.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>

static NSString *const kVTLBase = @"https://api.vexqyq.com/lyrics/";
static NSString *const kBiniHost = @"lyrics-api.binimum.org";
static NSString *const kMarker = @"vtl:";
static NSString *const kVTLKey = @"vtl";

// Where each known spotifyglass.dylib build keeps its provider array, relative to the image, keyed by
// the image's LC_UUID so a build this was not checked against is never written to (that fallback just
// stands down; the +arrayWithObjects:count: hook below needs no offsets and covers it). Each offset is
// the address the build's SGLyricsAllProviders() stores its array to, read off its disassembly.
static const struct { const char *uuid; uintptr_t slot; } kKnownLists[] = {
    { "adfbf83aec1a3186948d7ff4318bb6ba", 0x3b3f78 },   // official kit v0.50.0
    { "d4c75c03b90b329d83b960d768cc43aa", 0x532ed0 },   // 0.51.0-beta.1
};

typedef void (^VTLDone)(id result);
typedef void (^VTLAsk)(id query, VTLDone done);

@interface SGLyricsProvider : NSObject
@property (nonatomic, copy) NSString *key;
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *detail;
@property (nonatomic) BOOL needsName;
@property (nonatomic, copy) id ask;
@end

static Class gProviderClass;      // SGLyricsProvider
static BOOL gInjected;

static void showBadge(int attemptsLeft, NSString *text);

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

#pragma mark - the VTL provider

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

// BiniLyrics' answer, relabelled: it is VTL's lyrics, and the credit line should say so rather than
// crediting BiniLyrics or linking to it.
static void stampResult(id result) {
    @try { [result setValue:kVTLKey forKey:@"provider"]; } @catch (NSException *e) {}
    for (NSString *field in @[@"credit", @"pageCredit"]) {
        @try {
            id credit = [result valueForKey:field];
            if (!credit) continue;
            [credit setValue:@"VTL" forKey:@"text"];
            [credit setValue:@[] forKey:@"links"];
            [credit setValue:@[] forKey:@"linkTitles"];
        } @catch (NSException *e) {}
    }
}

static VTLAsk makeVTLAsk(VTLAsk biniAsk) {
    return ^(id query, VTLDone done) {
        NSString *trackID = nil;
        @try { trackID = [query valueForKey:@"trackID"]; } @catch (NSException *e) {}
        if (!biniAsk || ![trackID isKindOfClass:NSString.class] || !trackID.length) { done(nil); return; }
        checkVTL(trackID, ^(BOOL has) {
            if (!has) { done(nil); return; }
            biniAsk(markedQuery(query, trackID), ^(id result) {
                if (result) stampResult(result);
                done(result);
            });
        });
    };
}

// Built once and kept: the arrays that hold it only borrow it (the buffers they are made from are
// unretained), so something has to own it, and the same object serving every list built is simpler
// than one per list.
static SGLyricsProvider *gVTLProvider;

static SGLyricsProvider *makeVTLProvider(id bini) {
    @synchronized (kVTLKey) {
        if (gVTLProvider) return gVTLProvider;
        VTLAsk biniAsk = nil;
        @try { biniAsk = (VTLAsk)[bini valueForKey:@"ask"]; } @catch (NSException *e) {}
        if (!biniAsk) return nil;
        SGLyricsProvider *p = [gProviderClass new];
        p.key = kVTLKey;
        p.name = @"VTL";
        p.detail = @"Your uploads, word timed";
        p.needsName = NO;                 // matches by Spotify's own track id, like Musixmatch
        p.ask = (id)makeVTLAsk(biniAsk);
        gVTLProvider = p;
        return p;
    }
}

// If `objects` is the mod's provider list (every element an SGLyricsProvider, one of them BiniLyrics,
// none of them VTL yet), the same list with VTL added in front. nil for anything else.
static BOOL withVTL(const id __unsafe_unretained *objects, NSUInteger cnt, id __unsafe_unretained *out) {
    if (!gProviderClass || cnt < 2 || cnt > 24) return NO;
    id bini = nil;
    for (NSUInteger i = 0; i < cnt; i++) {
        if (!objects[i] || object_getClass(objects[i]) != gProviderClass) return NO;
    }
    for (NSUInteger i = 0; i < cnt; i++) {
        NSString *key = ((SGLyricsProvider *)objects[i]).key;
        if ([key isEqual:kVTLKey]) return NO;
        if ([key isEqual:@"binilyrics"]) bini = objects[i];
    }
    if (!bini) return NO;
    SGLyricsProvider *vtl = makeVTLProvider(bini);
    if (!vtl) return NO;
    out[0] = vtl;
    for (NSUInteger i = 0; i < cnt; i++) out[i + 1] = objects[i];
    return YES;
}

#pragma mark - way 1: the array is built after we load

%hook NSArray
+ (instancetype)arrayWithObjects:(const id __unsafe_unretained *)objects count:(NSUInteger)cnt {
    // First element's class is one pointer compare; everything else exits here.
    if (cnt >= 2 && cnt <= 24 && objects && objects[0] && object_getClass(objects[0]) == gProviderClass) {
        id __unsafe_unretained buf[25];
        if (withVTL(objects, cnt, buf)) {
            gInjected = YES;
            dispatch_async(dispatch_get_main_queue(), ^{ showBadge(15, @"VTL source added"); });
            return %orig(buf, cnt + 1);
        }
    }
    return %orig;
}
%end

#pragma mark - way 2: the array was already built before we loaded

// The image's LC_UUID as 32 lowercase hex digits, "" when it has none.
static NSString *imageUUID(const struct mach_header *header) {
    const struct mach_header_64 *h = (const struct mach_header_64 *)header;
    if (h->magic != MH_MAGIC_64) return @"";
    const uint8_t *p = (const uint8_t *)(h + 1);
    for (uint32_t i = 0; i < h->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)p;
        if (lc->cmd == LC_UUID) {
            const struct uuid_command *u = (const struct uuid_command *)lc;
            NSMutableString *hex = [NSMutableString stringWithCapacity:32];
            for (int b = 0; b < 16; b++) [hex appendFormat:@"%02x", u->uuid[b]];
            return hex;
        }
        p += lc->cmdsize;
    }
    return @"";
}

static void patchExistingList(void) {
    if (gInjected || !gProviderClass) return;
    const struct mach_header *header = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "/spotifyglass.dylib")) { header = _dyld_get_image_header(i); break; }
    }
    if (!header) return;
    NSString *uuid = imageUUID(header);
    uintptr_t slotOffset = 0;
    for (size_t k = 0; k < sizeof(kKnownLists) / sizeof(kKnownLists[0]); k++) {
        if ([uuid isEqualToString:@(kKnownLists[k].uuid)]) { slotOffset = kKnownLists[k].slot; break; }
    }
    if (!slotOffset) return;                                      // a build not checked: the hook alone covers it
    void **slot = (void **)((uintptr_t)header + slotOffset);
    void *current = *slot;
    if (!current || malloc_size(current) == 0) return;            // not a heap object: wrong offset, stand down
    id list = (__bridge id)current;
    if (![list isKindOfClass:NSArray.class]) return;
    NSUInteger n = [list count];
    if (n < 2 || n > 24) return;
    id __unsafe_unretained objs[24];
    [list getObjects:objs range:NSMakeRange(0, n)];
    id __unsafe_unretained buf[25];
    if (!withVTL(objs, n, buf)) return;
    NSArray *patched = [NSArray arrayWithObjects:buf count:n + 1];
    *slot = (void *)CFBridgingRetain(patched);                    // the old array is deliberately leaked
    gInjected = YES;
    dispatch_async(dispatch_get_main_queue(), ^{ showBadge(15, @"VTL source added"); });
}

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
    gProviderClass = objc_getClass("SGLyricsProvider");
    if (!gProviderClass) {
        dispatch_async(dispatch_get_main_queue(), ^{ showBadge(15, @"VTL: provider class not found"); });
        return;
    }
    %init;
    // The list may already exist (built before this dylib loaded); patch it now, and again shortly
    // after launch in case it was built during startup. Way 1 covers a list built later than that.
    patchExistingList();
    for (NSNumber *delay in @[@2, @6, @15]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.intValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ patchExistingList(); });
    }
    if (!gInjected) {
        dispatch_async(dispatch_get_main_queue(), ^{ showBadge(15, @"VTL source armed"); });
    }
}
