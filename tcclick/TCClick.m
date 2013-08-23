//
//  TCClick.m
//  TCClick
//
//  Created by YongQing Gu on 7/31/12.
//  Copyright (c) 2012 TrueColor. All rights reserved.
//

#import "TCClick.h"
#import "zlib.h"
#import <sqlite3.h>
#import <UIKit/UIApplication.h>
#import <execinfo.h>
#import <CommonCrypto/CommonDigest.h>


@interface TCClickDevice : NSObject
// 获取设备相关信息并生成一个 json 字符串
+ (NSString*) getDeviceJsonMetrics:(TCClick*)tcclick;
+ (NSString*) getUDID;
+ (bool) isJailbroken;
@end


TCClick* _sharedInstance;

@interface TCClick (Private)

+ (TCClick*) sharedInstance;
+ (NSString*) dbFilePath;
+ (NSString*) md5:(NSString*) origin;
- (void) initDb;
- (void) insertActivityStartAt:(NSInteger)start_at endAt:(NSInteger)end_at;
- (void) uploadMonitoringData;
- (void) insertException:(NSException*) exception;
- (void) insertExceptionString:(NSString*)exceptionDescription md5:(NSString*)md5;
- (void) installHandler;
- (void) unInstallHandler;
- (void) event:(NSString *)name param:(NSString *)param value:(NSString*)value;
@end


static void tcclickUncaughtExceptionHandler(NSException *exception) {
  [[TCClick sharedInstance] insertException:exception];
}

static void tcclickSignalHandler(int signal){
  void* callstack[128];
  int frames = backtrace(callstack, 128);
  char **strs = backtrace_symbols(callstack, frames);
  
  NSMutableString* callback = [NSMutableString string];
  for (int i=0; i < frames; i++){
    [callback appendFormat:@"%s\n", strs[i]];
  }
  free(strs);
  
  NSString* description = nil;
  switch (signal) {
    case SIGABRT:
      description = [NSString stringWithFormat:@"Signal SIGABRT was raised!\n%@", callback];
      break;
    case SIGILL:
      description = [NSString stringWithFormat:@"Signal SIGILL was raised!\n%@", callback];
      break;
    case SIGSEGV:
      description = [NSString stringWithFormat:@"Signal SIGSEGV was raised!\n%@", callback];
      break;
    case SIGFPE:
      description = [NSString stringWithFormat:@"Signal SIGFPE was raised!\n%@", callback];
      break;
    case SIGBUS:
      description = [NSString stringWithFormat:@"Signal SIGBUS was raised!\n%@", callback];
      break;
    case SIGPIPE:
      description = [NSString stringWithFormat:@"Signal SIGPIPE was raised!\n%@", callback];
      break;
  }
  
  [[TCClick sharedInstance] insertExceptionString:description md5:[TCClick md5:callback]];
  [[TCClick sharedInstance] unInstallHandler];
  kill(getpid(), signal);
}

@implementation TCClick
@synthesize channel, uploadUrl;

- (id) init{
  self = [super init];
  if(self){
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(onWillApplicationResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(onWillApplicationEnterBackground)
                                                 name:UIApplicationDidEnterBackgroundNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(onDidApplicationBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self 
                                             selector:@selector(onWillApplicationEnterForeground)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    [self installHandler];
    [self initDb];
  }
  return self;
}

- (void) installHandler{
  NSSetUncaughtExceptionHandler(&tcclickUncaughtExceptionHandler);
  signal(SIGABRT, tcclickSignalHandler);
  signal(SIGILL, tcclickSignalHandler);
  signal(SIGSEGV, tcclickSignalHandler);
  signal(SIGFPE, tcclickSignalHandler);
  signal(SIGBUS, tcclickSignalHandler);
  signal(SIGPIPE, tcclickSignalHandler);
}

- (void) unInstallHandler{
	NSSetUncaughtExceptionHandler(NULL);
	signal(SIGABRT, SIG_DFL);
	signal(SIGILL, SIG_DFL);
	signal(SIGSEGV, SIG_DFL);
	signal(SIGFPE, SIG_DFL);
	signal(SIGBUS, SIG_DFL);
	signal(SIGPIPE, SIG_DFL);
}

- (void) initDb{
  sqlite3 *database;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "create table if not exists activities(\
    id integer not null primary key autoincrement,\
    start_at integer unsigned not null,\
    end_at integer unsigned not null\
    )";
    sqlite3_exec(database, sql, NULL, NULL, NULL);
    sql = "create table if not exists exceptions(\
    id integer not null primary key autoincrement,\
    md5 char(32) unique,\
    exception text,\
    created_at integer unsigned not null\
    )";
    sqlite3_exec(database, sql, NULL, NULL, NULL);
    sql = "create table if not exists events(\
    id integer not null primary key autoincrement,\
    name varchar(255),\
    param varchar(255),\
    value varchar(255),\
    version varchar(255),\
    created_at integer unsigned not null\
    )";
    sqlite3_exec(database, sql, NULL, NULL, NULL);
    sqlite3_close(database);
  }
}

+ (NSString*) md5:(NSString*) origin{
  const char* callStackSymbolsStr = [origin UTF8String];
  unsigned char result[16];
  CC_MD5( callStackSymbolsStr, strlen(callStackSymbolsStr), result ); // This is the md5 call
  return [NSString stringWithFormat:
          @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
          result[0], result[1], result[2], result[3], 
          result[4], result[5], result[6], result[7],
          result[8], result[9], result[10], result[11],
          result[12], result[13], result[14], result[15]
          ];
}

- (void) insertException:(NSException*) exception{
  NSString* md5 = [self.class md5:[[exception callStackSymbols] description]];
  NSString* exceptionDescription = [NSString stringWithFormat:@"%@: %@\n%@", 
                                    exception.name, exception.reason, [exception callStackSymbols]];
  [self insertExceptionString:exceptionDescription md5:md5];
}

- (void) insertExceptionString:(NSString*)exceptionDescription md5:(NSString*)md5{
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "insert into exceptions(md5, exception, created_at) values (:md5, :exception, :created_at)";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      int index;
      index = sqlite3_bind_parameter_index(stmt, ":exception");
      const char *cStr = [exceptionDescription UTF8String];
      sqlite3_bind_text(stmt, index, cStr, strlen(cStr), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":md5");
      const char* md5Str = [md5 UTF8String];
      sqlite3_bind_text(stmt, index, md5Str, strlen(md5Str), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":created_at");
      sqlite3_bind_int(stmt, index, (int)[[NSDate date] timeIntervalSince1970]);
      
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

- (void) insertActivityStartAt:(NSInteger)start_at endAt:(NSInteger)end_at{
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "insert into activities(start_at, end_at) values (:start_at, :end_at)";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      int index = sqlite3_bind_parameter_index(stmt, ":start_at");
      sqlite3_bind_int(stmt, index, start_at);
      index = sqlite3_bind_parameter_index(stmt, ":end_at");
      sqlite3_bind_int(stmt, index, end_at);
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

- (void) deleteActivitiesWithIdEqualOrLower:(NSInteger)id{
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "delete from activities where id<=:id";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      int index = sqlite3_bind_parameter_index(stmt, ":id");
      sqlite3_bind_int(stmt, index, id);
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

- (void) deleteExceptions{
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "delete from exceptions";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

- (void) deleteEventsWithIdEqualOrLower:(NSInteger)id{
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "delete from events where id<=:id";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      int index = sqlite3_bind_parameter_index(stmt, ":id");
      sqlite3_bind_int(stmt, index, id);
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

+ (TCClick*) sharedInstance{
  if (!_sharedInstance){
    _sharedInstance = [[TCClick alloc] init];
  }
  return _sharedInstance;
}

+ (NSString*) udid{
  return [TCClickDevice getUDID];
}

+ (bool) isDeviceJailbroken{
  return [TCClickDevice isJailbroken];
}

+ (void) start:(NSString*) uploadUrl channel:(NSString*) channel{
  [self sharedInstance].channel = channel;
  [self sharedInstance].uploadUrl = uploadUrl;
}

+ (NSString*) dbFilePath{
  static NSString* filePath = nil;
  if(!filePath){
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
		NSString* documentsDirectory = [paths objectAtIndex:0];
    filePath = [[documentsDirectory stringByAppendingPathComponent:@".tcclick.db"] retain];
  }
  return filePath;
}


+ (void)event:(NSString *)name{
  [self event:name value:name];
}

+ (void)event:(NSString *)name value:(NSString*)value{
  [self event:name param:name value:value];
}

+ (void)event:(NSString *)name param:(NSString *)param value:(NSString*)value{
  [[self sharedInstance] event:name param:param value:value];
}

- (void) event:(NSString *)name param:(NSString *)param value:(NSString*)value{
  if (!param || [param isEqualToString:@""]) param = name;
  if (!value) value = @"";
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "insert into events(name, param, value, version, created_at) values (:name, :param, :value, :version, :created_at)";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      int index;
      index = sqlite3_bind_parameter_index(stmt, ":name");
      const char *cStr = [name UTF8String];
      sqlite3_bind_text(stmt, index, cStr, strlen(cStr), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":param");
      const char* param5Str = [param UTF8String];
      sqlite3_bind_text(stmt, index, param5Str, strlen(param5Str), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":value");
      const char* value5Str = [value UTF8String];
      sqlite3_bind_text(stmt, index, value5Str, strlen(value5Str), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":version");
      NSString* app_version = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
      const char* version5Str = [app_version UTF8String];
      sqlite3_bind_text(stmt, index, version5Str, strlen(version5Str), SQLITE_TRANSIENT);
      
      index = sqlite3_bind_parameter_index(stmt, ":created_at");
      sqlite3_bind_int(stmt, index, (int)[[NSDate date] timeIntervalSince1970]);
      
      sqlite3_step(stmt);
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
}

#pragma mark - application notification listener


NSTimeInterval activity_start_at = 0;
- (void) onWillApplicationResignActive{
  if(activity_start_at){
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [self insertActivityStartAt:activity_start_at endAt:now];
    activity_start_at = 0;
  }
  
//  NSLog(@"onWillApplicationResignActive is called");
}

- (void) onWillApplicationEnterBackground{
  if(activity_start_at){
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    [self insertActivityStartAt:activity_start_at endAt:now];
    activity_start_at = 0;
  }
  
//  NSLog(@"onWillApplicationEnterBackground is called");
}

- (void) onDidApplicationBecomeActive{
  activity_start_at = [[NSDate date] timeIntervalSince1970];
  [NSThread detachNewThreadSelector:@selector(uploadMonitoringData) toTarget:self withObject:nil];
//  NSLog(@"onDidApplicationBecomeActive is called");
}

- (void) onWillApplicationEnterForeground{
  activity_start_at = [[NSDate date] timeIntervalSince1970];
//  NSLog(@"onWillApplicationEnterForeground is called");
}


#pragma mark - upload data

- (NSData*) compress:(NSData*) data{
  if ([data length] == 0) return data;
  NSMutableData *compressedData = [NSMutableData dataWithLength:[data length]];
  z_stream strm;
  strm.next_in = (Bytef *)[data bytes];
  strm.avail_in = [data length];
  strm.total_out = 0;
  strm.zalloc = Z_NULL;
  strm.zfree = Z_NULL;
  strm.opaque = Z_NULL;
  if (deflateInit(&strm, 5) == Z_OK){
    strm.avail_out = [data length];
    strm.next_out = (Bytef *)[compressedData bytes];
    deflate(&strm, Z_FINISH);
    [compressedData setLength:strm.total_out];
//    NSLog(@"strm.total_out=%lu", strm.total_out);
  }
  deflateEnd(&strm);
//  NSLog(@"compressed data length: %d, origin length: %d", compressedData.length, data.length);
  return [NSData dataWithData:compressedData];
}

- (void) uploadMonitoringData{
  NSAutoreleasePool* pool = [[NSAutoreleasePool alloc] init];
  
  NSMutableString* buffer = [[NSMutableString alloc] initWithCapacity:1024];
  [buffer appendString:@"{"];
  [buffer appendFormat:@"\"timestamp\":%.0f", [[NSDate date] timeIntervalSince1970]];
  [buffer appendFormat:@", \"device\":%@", [TCClickDevice getDeviceJsonMetrics:self]];
  
  [buffer appendString:@", \"data\":{"];
  
  // activities
  NSInteger max_activity_id = 0;
  [buffer appendString:@"\"activities\":["];
  sqlite3 *database;
  sqlite3_stmt *stmt;
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "select id, start_at, end_at from activities order by id";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      while (sqlite3_step(stmt)==SQLITE_ROW) {
        if(max_activity_id){ // 不是第一行
          [buffer appendString:@", {"];
        }else{
          [buffer appendString:@"{"];
        }
        max_activity_id = sqlite3_column_int(stmt, 0);
        [buffer appendFormat:@"\"start_at\":%d", sqlite3_column_int(stmt, 1)];
        [buffer appendFormat:@", \"end_at\":%d", sqlite3_column_int(stmt, 2)];
        [buffer appendString:@"}"];
      }
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
  [buffer appendString:@"]"];
  
  
  // 构建捕捉到的异常json串
  NSInteger max_exception_id = 0;
  [buffer appendString:@",\"exceptions\":["];
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "select id, exception, created_at, md5 from exceptions order by id";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      while (sqlite3_step(stmt)==SQLITE_ROW) {
        if(max_exception_id){ // 不是第一行
          [buffer appendString:@", {"];
        }else{
          [buffer appendString:@"{"];
        }
        max_exception_id = sqlite3_column_int(stmt, 0);
        NSString* exception = [self stringForJsonEncoded:[NSString stringWithFormat:@"%s", sqlite3_column_text(stmt, 1)]];
        [buffer appendFormat:@"\"exception\":\"%@\"", exception];
        [buffer appendFormat:@",\"created_at\":%d", sqlite3_column_int(stmt, 2)];
        [buffer appendFormat:@",\"md5\":\"%s\"", sqlite3_column_text(stmt, 3)];
        [buffer appendString:@"}"];
      }
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
  [buffer appendString:@"]"];
  
  
  // 构建客户端自定义事件的json串
  NSInteger max_event_id = 0;
  [buffer appendString:@",\"events\":["];
  if (sqlite3_open([[self.class dbFilePath] UTF8String], &database)==SQLITE_OK) {
    const char* sql = "select id, name, param, value, version, created_at from events order by id";
    if(sqlite3_prepare(database, sql, strlen(sql), &stmt, NULL) == SQLITE_OK){
      while (sqlite3_step(stmt)==SQLITE_ROW) {
        if(max_event_id){ // 不是第一行
          [buffer appendString:@", {"];
        }else{
          [buffer appendString:@"{"];
        }
        max_event_id = sqlite3_column_int(stmt, 0);
        NSString* name = [self stringForJsonEncoded:[NSString stringWithCString:(const char*)sqlite3_column_text(stmt, 1)
                                                                       encoding:NSUTF8StringEncoding]];
        NSString* param = [self stringForJsonEncoded:[NSString stringWithCString:(const char*)sqlite3_column_text(stmt, 2)
                                                                       encoding:NSUTF8StringEncoding]];
        NSString* value = [self stringForJsonEncoded:[NSString stringWithCString:(const char*)sqlite3_column_text(stmt, 3)
                                                                        encoding:NSUTF8StringEncoding]];
        NSString* version = [self stringForJsonEncoded:[NSString stringWithCString:(const char*)sqlite3_column_text(stmt, 4)
                                                                        encoding:NSUTF8StringEncoding]];
        [buffer appendFormat:@"\"name\":\"%@\"", name];
        [buffer appendFormat:@",\"param\":\"%@\"", param];
        [buffer appendFormat:@",\"value\":\"%@\"", value];
        [buffer appendFormat:@",\"version\":\"%@\"", version];
        [buffer appendFormat:@",\"created_at\":%d", sqlite3_column_int(stmt, 5)];
        [buffer appendString:@"}"];
      }
      sqlite3_finalize(stmt);
    }
    sqlite3_close(database);
  }
  [buffer appendString:@"]"];
  
  
  [buffer appendString:@"}"];
  [buffer appendString:@"}"];
  
//  NSLog(@"%@", [TCClickDevice getDeviceJsonMetrics:self]);
//  NSLog(@"%@", buffer);
//  NSLog(@"uploading data to: %@", self.uploadUrl);
  
  NSData* compressedData = [self compress:[buffer dataUsingEncoding:NSUTF8StringEncoding]];
  NSMutableURLRequest* request = [[NSMutableURLRequest alloc] initWithURL: [NSURL URLWithString:self.uploadUrl]];
  [request setHTTPMethod: @"POST"];
  [request setHTTPBody:compressedData];
  NSError* error = nil;
  NSHTTPURLResponse* response = nil;
  [NSURLConnection sendSynchronousRequest: request returningResponse: &response error: &error];
  
  if (!error && response.statusCode==200){
    if(max_activity_id){
      // 删除掉之前存下来的activities
      [self deleteActivitiesWithIdEqualOrLower:max_activity_id];
    }
    if(max_event_id){
      // 删除之前存下来的那些客户端事件
      [self deleteEventsWithIdEqualOrLower:max_event_id];
    }
    [self deleteExceptions];
  }
    
  [request release];
  [buffer release];
  [pool release];
}


- (NSString*) stringForJsonEncoded:(NSString*) originString{
  NSMutableString* encoded = [NSMutableString stringWithString:originString];
  [encoded replaceOccurrencesOfString:@"\\" withString:@"\\\\" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\"" withString:@"\\\"" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"/" withString:@"\\/" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\b" withString:@"\\b" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\f" withString:@"\\f" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\n" withString:@"\\n" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\r" withString:@"\\r" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  [encoded replaceOccurrencesOfString:@"\t" withString:@"\\t" options:NSCaseInsensitiveSearch range:NSMakeRange(0, encoded.length)];
  return encoded;
}

@end


#import <CommonCrypto/CommonDigest.h>
#import <UIKit/UIPasteboard.h>
#import <UIKit/UIKit.h>
#import <sys/utsname.h>
#import <CoreTelephony/CTTelephonyNetworkInfo.h>
#import <CoreTelephony/CTCarrier.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <netinet6/in6.h>
#import <arpa/inet.h>
#import <ifaddrs.h>
#import <netdb.h>
#import <Foundation/Foundation.h>
#import <SystemConfiguration/SystemConfiguration.h>
#import <netinet/in.h>

static NSString * const kTCClickUdidKey = @"TCCLICK_UDID";
static NSString * const kTCClickUdidPastboardKey = @"TCCLICK_UDID_PASTBOARD";
@implementation TCClickDevice

+ (NSString*) generateFreshOpenUDID {
  // 先按照 identifierForVendor 的方式去取 UDID，如果不成功再生成一个随机的 UUID
  UIDevice* device = [UIDevice currentDevice];
  if ([device respondsToSelector:@selector(identifierForVendor)]){
    NSString* uniqueIdentifier = [[device performSelector:@selector(identifierForVendor)] UUIDString];
    if (uniqueIdentifier && [uniqueIdentifier isKindOfClass:NSString.class]){
      return [TCClick md5:uniqueIdentifier];
    }
  }
  
  NSString* udid = nil;
  CFUUIDRef uuid = CFUUIDCreate(kCFAllocatorDefault);
  CFStringRef cfstring = CFUUIDCreateString(kCFAllocatorDefault, uuid);
  const char *cStr = CFStringGetCStringPtr(cfstring,CFStringGetFastestEncoding(cfstring));
  unsigned char result[16];
  CC_MD5( cStr, strlen(cStr), result);
  CFRelease(uuid);

  udid = [NSString stringWithFormat:
          @"%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x",
          result[0], result[1], result[2], result[3], 
          result[4], result[5], result[6], result[7],
          result[8], result[9], result[10], result[11],
          result[12], result[13], result[14], result[15]
          ];
  return udid;
}

+ (NSString*) readUDIDFromPastboard{
  UIPasteboard* pastboard = [UIPasteboard pasteboardWithName:kTCClickUdidPastboardKey create:NO];
  if(pastboard && pastboard.string){
    return pastboard.string;
  }
  return nil;
}

+ (void) writeUDIDToPastboard:(NSString*)udid{
  UIPasteboard* pastboard = [UIPasteboard pasteboardWithName:kTCClickUdidPastboardKey create:YES];
  pastboard.string = udid;
}

// 用户在第一次使用应用时将生成一个随机的udid，生成udid之后，将在NSUserDefaults和UIPasteboard系统存储两份数据
// UIPasteboard系统中存储的数据可以在其他应用中得到共享
+ (NSString*) getUDID{
  static NSString* udid = nil;
  if(!udid){
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    udid = (NSString *) [defaults objectForKey:kTCClickUdidKey];
    if(udid == nil){
      udid = [self readUDIDFromPastboard];
      if(!udid){
        udid = [self generateFreshOpenUDID];
        [self writeUDIDToPastboard:udid];
      }
      [defaults setObject:udid forKey:kTCClickUdidKey];
    }else{
      [self writeUDIDToPastboard:udid];
    }
    udid = [udid retain];
  }
  return udid;
}

+ (NSString*) getModel{
  struct utsname u;
  uname(&u);
  return [NSString stringWithCString: u.machine encoding: NSUTF8StringEncoding];
}

+ (NSString*) getCarrier{
  CTTelephonyNetworkInfo *info = [[CTTelephonyNetworkInfo alloc] init];
  NSString* carrier = [info.subscriberCellularProvider carrierName];
  [info release];
  return carrier ? carrier : @"";
}

+ (NSString*) getResolution{
  CGSize size = [UIScreen instancesRespondToSelector:@selector(currentMode)] ? 
  [[UIScreen mainScreen] currentMode].size : [UIScreen mainScreen].bounds.size;
  return [NSString stringWithFormat:@"%.0fx%.0f", size.width, size.height];
}

+ (NSString*) getNetwork{
  struct sockaddr_in zeroAddress;
	bzero(&zeroAddress, sizeof(zeroAddress));
	zeroAddress.sin_len = sizeof(zeroAddress);
	zeroAddress.sin_family = AF_INET;
  zeroAddress.sin_addr.s_addr = htonl(IN_LINKLOCALNETNUM);
  SCNetworkReachabilityRef ref = SCNetworkReachabilityCreateWithAddress(kCFAllocatorDefault, 
                                                                        (const struct sockaddr*)&zeroAddress);
  SCNetworkReachabilityFlags flags = 0;
  SCNetworkReachabilityGetFlags(ref, &flags);
  CFRelease(ref);
  
  if (flags & kSCNetworkReachabilityFlagsTransientConnection) return @"wifi";
  if (flags & kSCNetworkReachabilityFlagsConnectionRequired) return @"wifi";
  if (flags & kSCNetworkReachabilityFlagsIsDirect) return @"wifi";
  if (flags & kSCNetworkReachabilityFlagsIsWWAN) return @"cellnetwork";
  return @"unknow";
}

+ (bool) isJailbroken{
  static bool isChecked = NO;
  static bool isJailbroken = NO;
  if(!isChecked){
    if ([[NSFileManager defaultManager] fileExistsAtPath:@"/Applications/Cydia.app"]) {
      isJailbroken = YES;
    }else if([[NSFileManager defaultManager] fileExistsAtPath:@"/private/var/lib/apt"]){
      isJailbroken = YES;
    }
  }
  return isJailbroken;
}

+ (NSString*) getDeviceJsonMetrics:(TCClick*)tcclick{
  NSMutableString* buffer = [[NSMutableString alloc] initWithCapacity:1024];
  
  [buffer appendString:@"{"];
  [buffer appendFormat:@"\"udid\":\"%@\"", [self getUDID]];
  [buffer appendFormat:@", \"channel\":\"%@\"", tcclick.channel];
  [buffer appendFormat:@", \"model\":\"%@\"", [self getModel]];
  [buffer appendString:@", \"brand\":\"Apple\""];
  [buffer appendFormat:@", \"os_version\":\"%@\"", [[UIDevice currentDevice] systemVersion]];
  [buffer appendFormat:@", \"app_version\":\"%@\"", [[[NSBundle mainBundle] infoDictionary] 
                                                     objectForKey:@"CFBundleShortVersionString"]];
  [buffer appendFormat:@", \"carrier\":\"%@\"", [self getCarrier]];
  [buffer appendFormat:@", \"resolution\":\"%@\"", [self getResolution]];
  [buffer appendFormat:@", \"locale\":\"%@\"", [[NSLocale currentLocale] objectForKey: NSLocaleCountryCode]];
  [buffer appendFormat:@", \"network\":\"%@\"", [self getNetwork]];
  [buffer appendFormat:@", \"jailbroken\":\"%@\"", [self isJailbroken]?@"true":@"false"];
  [buffer appendString:@"}"];
  
  return [buffer autorelease];
}

@end