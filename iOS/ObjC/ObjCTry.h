#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// AVFoundation reports invalid settings by raising NSExceptions, which Swift
/// cannot catch and which terminate the app. Every camera mutation goes
/// through this so a rejected value becomes an error message instead.
@interface ObjCTry : NSObject
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
