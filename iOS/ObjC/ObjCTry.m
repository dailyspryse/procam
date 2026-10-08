#import "ObjCTry.h"

@implementation ObjCTry
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return e.reason ?: e.name;
    }
}
@end
