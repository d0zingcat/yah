#import "RimeSession.h"
@import Rime;

@implementation YahRimeSession {
    RimeSessionId _session;
}

- (instancetype)initWithBundle:(NSBundle *)bundle {
    self = [super init];
    if (!self) return nil;
    static dispatch_once_t once;
    static BOOL ready;
    RimeApi_stdbool *api = rime_get_api_stdbool();
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSURL *directory = [[fm URLsForDirectory:NSApplicationSupportDirectory inDomains:NSUserDomainMask].firstObject URLByAppendingPathComponent:@"Yah/Rime"];
        NSURL *data = [bundle URLForResource:@"RimeData" withExtension:nil];
        if (!data || ![fm createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
        RIME_STRUCT(RimeTraits, traits);
        traits.shared_data_dir = data.fileSystemRepresentation;
        traits.user_data_dir = directory.fileSystemRepresentation;
        traits.app_name = "rime.yah";
        api->setup(&traits);
        api->initialize(&traits);
        if (api->start_maintenance(False)) api->join_maintenance_thread();
        ready = YES;
    });
    if (!ready) return nil;
    _session = api->create_session();
    if (!_session || !api->select_schema(_session, "yah")) return nil;
    return self;
}

- (void)dealloc {
    if (_session) rime_get_api_stdbool()->destroy_session(_session);
}

- (NSString *)input {
    const char *text = rime_get_api_stdbool()->get_input(_session);
    return text ? @(text) : @"";
}

- (NSArray<NSString *> *)choices {
    RimeApi_stdbool *api = rime_get_api_stdbool();
    RIME_STRUCT(RimeContext_stdbool, context);
    if (!api->get_context(_session, &context)) return @[];
    NSMutableArray *words = [NSMutableArray array];
    for (int i = 0; i < context.menu.num_candidates; i++) {
        [words addObject:@(context.menu.candidates[i].text)];
    }
    api->free_context(&context);
    return words;
}

- (void)processKey:(int)key {
    rime_get_api_stdbool()->process_key(_session, key, 0);
}

- (BOOL)canPageBackward:(BOOL)backward {
    RimeApi_stdbool *api = rime_get_api_stdbool();
    RIME_STRUCT(RimeContext_stdbool, context);
    if (!api->get_context(_session, &context)) return NO;
    BOOL available = context.menu.num_candidates > 0 &&
        (backward ? context.menu.page_no > 0 : !context.menu.is_last_page);
    api->free_context(&context);
    return available;
}

- (void)pageBackward:(BOOL)backward {
    rime_get_api_stdbool()->change_page(_session, backward);
}

- (void)reset {
    rime_get_api_stdbool()->clear_composition(_session);
}

- (NSString *)choose:(NSUInteger)index {
    RimeApi_stdbool *api = rime_get_api_stdbool();
    if (!api->select_candidate_on_current_page(_session, index)) return nil;
    RIME_STRUCT(RimeCommit, commit);
    if (!api->get_commit(_session, &commit)) return nil;
    NSString *word = @(commit.text);
    api->free_commit(&commit);
    return word;
}
@end
