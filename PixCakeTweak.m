//
//  PixCakeTweak.m
//  像素蛋糕 (com.xiangtian.pixcake) 运行时补丁
//
//  作用：
//   1) 拦截发往 *.pixcakeai.com 的 API 响应，把「消费/导出」相关的业务错误码
//      (14 / 69 等) 改成 0，并在缺少导出凭据时补上伪造的 exportUUID / processId，
//      让客户端认为服务端已经放行；
//   2) 把用户信息里的额度字段 (left_count / total_count / is_vip ...) 抬到很大；
//   3) 可选：把类名里带 Watermark 的浮层隐藏（截图去水印用，默认关闭）。
//
//  编译：见 .github/workflows/build.yml（macos runner + iphoneos SDK）
//  注入：TrollFools / 任何 dylib 注入器
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>

static NSString *const kPXMark = @"PixCakeTweakHandled";
static NSString *const kPXLogPath = @"/tmp/pixcake_tweak.log";

#pragma mark - log

static void PXLog(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    NSLog(@"[PixCakeTweak] %@", msg);

    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("pixcake.tweak.log", DISPATCH_QUEUE_SERIAL);
    });
    dispatch_async(q, ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSDictionary *attrs = [fm attributesOfItemAtPath:kPXLogPath error:NULL];
        if (attrs && [attrs fileSize] > 512 * 1024) {
            [fm removeItemAtPath:kPXLogPath error:NULL];
        }
        NSString *line = [msg stringByAppendingString:@"\n"];
        NSData *d = [line dataUsingEncoding:NSUTF8StringEncoding];
        if (![fm fileExistsAtPath:kPXLogPath]) {
            [d writeToFile:kPXLogPath atomically:YES];
        } else {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:kPXLogPath];
            [fh seekToEndOfFile];
            [fh writeData:d];
            [fh closeFile];
        }
    });
}

#pragma mark - URLProtocol hook

@interface PXHookProtocol : NSURLProtocol
@end

@implementation PXHookProtocol {
    NSURLSessionDataTask *_task;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if (!request.URL) return NO;
    if ([NSURLProtocol propertyForKey:kPXMark inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (!([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"])) return NO;
    NSString *host = request.URL.host.lowercaseString;
    if (!host.length) return NO;
    return [host containsString:@"pixcake"];
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
    return request;
}

- (void)startLoading {
    NSMutableURLRequest *req = [self.request mutableCopy];
    [NSURLProtocol setProperty:@YES forKey:kPXMark inRequest:req];

    NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration defaultSessionConfiguration];
    NSURLSession *session = [NSURLSession sessionWithConfiguration:cfg];

    __weak typeof(self) weakSelf = self;
    _task = [session dataTaskWithRequest:req
                      completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error) {
            [self.client URLProtocol:self didFailWithError:error];
            return;
        }
        if (response) {
            [self.client URLProtocol:self
                  didReceiveResponse:response
                  cacheStoragePolicy:NSURLCacheStorageNotAllowed];
        }
        NSData *out = [PXHookProtocol rewriteData:data request:req];
        if (out.length) {
            [self.client URLProtocol:self didLoadData:out];
        }
        [self.client URLProtocolDidFinishLoading:self];
    }];
    [_task resume];
}

- (void)stopLoading {
    [_task cancel];
    _task = nil;
}

#pragma mark - response rewriting

+ (NSData *)rewriteData:(NSData *)data request:(NSURLRequest *)request {
    if (data.length < 2) return data;
    id obj = [NSJSONSerialization JSONObjectWithData:data
                                             options:NSJSONReadingMutableContainers
                                               error:NULL];
    if (![obj isKindOfClass:[NSMutableDictionary class]]) return data;

    NSMutableDictionary *root = (NSMutableDictionary *)obj;

    NSString *path = request.URL.path.lowercaseString ?: @"";
    NSString *query = request.URL.query.lowercaseString ?: @"";
    BOOL exportCtx = [path containsString:@"export"]
                  || [path containsString:@"consume"]
                  || [path containsString:@"process"]
                  || [query containsString:@"export"]
                  || [query containsString:@"consume"];

    id origCode = root[@"code"];
    BOOL changed = [self scrubDict:root exportCtx:exportCtx depth:0];
    if (!changed) return data;

    if (exportCtx) {
        PXLog(@"rewrite %@ -> ok (orig code=%@)", request.URL.path, origCode ?: @"-");
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:root options:0 error:NULL];
    return out ?: data;
}

+ (BOOL)scrubDict:(NSMutableDictionary *)dict exportCtx:(BOOL)exportCtx depth:(NSInteger)depth {
    if (depth > 8) return NO;
    BOOL changed = NO;

    // 1) 业务错误码：导出/消费上下文里一律清零
    if (exportCtx) {
        NSArray *codeKeys = @[@"code", @"errno", @"errCode", @"ret", @"resultCode", @"status"];
        for (NSString *k in codeKeys) {
            id v = dict[k];
            if ([v isKindOfClass:[NSNumber class]]) {
                long long n = [v longLongValue];
                if (n != 0) {
                    dict[k] = @0;
                    changed = YES;
                }
            }
        }
        if (changed) {
            for (NSString *k in @[@"msg", @"message", @"errmsg", @"errMsg", @"error"]) {
                id v = dict[k];
                if ([v isKindOfClass:[NSString class]] && [v length]) {
                    dict[k] = @"";
                }
            }
        }

        // 2) 导出凭据：缺了就补一个伪造值，避免客户端因为 nil 直接判定失败
        NSArray *uuidKeys = @[@"exportUUID", @"exportId", @"exportProcessID", @"processId", @"processID", @"uuid"];
        BOOL hasUUID = NO;
        for (NSString *k in uuidKeys) {
            id v = dict[k];
            if ([v isKindOfClass:[NSString class]] && [v length]) { hasUUID = YES; break; }
        }
        if (!hasUUID) {
            NSString *fake = [[NSUUID UUID] UUIDString];
            dict[@"exportUUID"] = fake;
            dict[@"exportId"] = fake;
            dict[@"processId"] = fake;
            dict[@"exportProcessID"] = fake;
            changed = YES;
        }

        // 3) 消费计数/额度：给足
        NSDictionary *fill2 = @{
            @"left_count": @999999, @"total_count": @999999,
            @"leftCount": @999999, @"totalCount": @999999,
            @"remain": @999999, @"remainCount": @999999,
            @"surplus": @999999, @"balance": @999999,
            @"left_count_str": @"999999", @"total_count_str": @"999999",
            @"is_vip": @1, @"isVip": @1, @"vipLevel": @99, @"vip_level": @99,
            @"consumeCount": @1, @"consume_count": @1
        };
        for (NSString *k in fill2) {
            if (dict[k] != nil) {
                id cur = dict[k];
                BOOL diff = YES;
                if ([cur isKindOfClass:[NSNumber class]] && [fill2[k] isKindOfClass:[NSNumber class]]) {
                    diff = ([cur longLongValue] != [fill2[k] longLongValue]);
                } else if ([cur isKindOfClass:[NSString class]] && [fill2[k] isKindOfClass:[NSString class]]) {
                    diff = ![cur isEqualToString:fill2[k]];
                }
                if (diff) { dict[k] = fill2[k]; changed = YES; }
            }
        }
    }

    // 4) 递归处理嵌套
    for (id key in [dict allKeys]) {
        id v = dict[key];
        if ([v isKindOfClass:[NSMutableDictionary class]]) {
            if ([self scrubDict:v exportCtx:exportCtx depth:depth + 1]) changed = YES;
        } else if ([v isKindOfClass:[NSMutableArray class]]) {
            for (id item in v) {
                if ([item isKindOfClass:[NSMutableDictionary class]]) {
                    if ([self scrubDict:item exportCtx:exportCtx depth:depth + 1]) changed = YES;
                }
            }
        }
    }
    return changed;
}

@end

#pragma mark - optional: hide watermark overlays

static BOOL gHideWatermark = NO;

static void PXScanForWatermark(UIView *view, NSInteger depth) {
    if (!view || depth > 40) return;
    NSString *cn = NSStringFromClass([view class]);
    NSString *lower = cn.lowercaseString;
    BOOL looksLikeWatermark = [lower containsString:@"watermark"];
    if (looksLikeWatermark && ![view isKindOfClass:[UIControl class]]) {
        // 只处理「盖在画布上的展示层」，设置面板里的 cell 不动
        BOOL isCell = [lower containsString:@"cell"] || [lower containsString:@"viewcontroller"];
        if (!isCell && view.alpha > 0.01) {
            view.alpha = 0.0;
            PXLog(@"hide watermark view: %@", cn);
        }
    }
    for (UIView *sub in view.subviews) {
        PXScanForWatermark(sub, depth + 1);
    }
}

static void PXInstallWatermarkSweeper(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer *t) {
                if (!gHideWatermark) return;
                for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                    if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                    for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                        PXScanForWatermark(w, 0);
                    }
                }
            }];
        });
    });
}

#pragma mark - entry

__attribute__((constructor))
static void PixCakeTweakInit(void) {
    @autoreleasepool {
        PXLog(@"loaded (v1). watermark-hide=%@", gHideWatermark ? @"on" : @"off");
        [NSURLProtocol registerClass:[PXHookProtocol class]];

        // 想试「截图去水印」就把下面这行打开（改成 YES）
        // gHideWatermark = YES;
        PXInstallWatermarkSweeper();
    }
}
