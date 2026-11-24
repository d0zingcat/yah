#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface YahRimeSession : NSObject
@property(nonatomic, readonly) NSString *input;
@property(nonatomic, readonly) NSArray<NSString *> *choices;
- (nullable instancetype)initWithBundle:(NSBundle *)bundle;
- (void)processKey:(int)key;
- (BOOL)canPageBackward:(BOOL)backward;
- (void)pageBackward:(BOOL)backward;
- (void)reset;
- (nullable NSString *)choose:(NSUInteger)index;
@end
NS_ASSUME_NONNULL_END
