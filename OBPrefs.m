#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import "../Shared.h"
#include <notify.h>
#include <ifaddrs.h>
#include <arpa/inet.h>
#include <sys/stat.h>
#include <string.h>
#include <math.h>

static NSString *wifiIP(void) {
    struct ifaddrs *list = NULL; NSString *ip = nil;
    if (!getifaddrs(&list)) {
        for (struct ifaddrs *p = list; p; p = p->ifa_next) {
            if (!p->ifa_addr || p->ifa_addr->sa_family != AF_INET || strcmp(p->ifa_name, "en0")) continue;
            char value[INET_ADDRSTRLEN];
            if (inet_ntop(AF_INET, &((struct sockaddr_in *)p->ifa_addr)->sin_addr, value, sizeof(value)))
                ip = [NSString stringWithUTF8String:value];
        }
        freeifaddrs(list);
    }
    return ip;
}
@interface OBPrefs : PSListController
@end
@implementation OBPrefs
- (NSArray *)specifiers {
    if (!_specifiers) _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}
- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isKindOfClass:NSString.class]) return nil;
    CFPreferencesAppSynchronize(OB_DOMAIN);
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, OB_DOMAIN));
    return value ?: [specifier propertyForKey:@"default"];
}
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (![key isEqualToString:@"PCIP"] || ![value isKindOfClass:NSString.class]) return;
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)trimmed, OB_DOMAIN);
    CFPreferencesAppSynchronize(OB_DOMAIN);
}
- (void)message:(NSString *)text {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"OBS 摄像头"
        message:text preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (BOOL)command:(BOOL)enabled {
    [self.view endEditing:YES];
    CFPreferencesAppSynchronize(OB_DOMAIN);
    NSString *ip = wifiIP();
    NSString *peer = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("PCIP"), OB_DOMAIN));
    struct in_addr addr;
    if (enabled && (!ip || ![peer isKindOfClass:NSString.class] ||
        inet_pton(AF_INET, peer.UTF8String, &addr) != 1)) {
        [self message:@"请连接 Wi-Fi，并填写 OBS 电脑的局域网 IPv4 地址。"]; return NO;
    }
    CFPreferencesSetAppValue(CFSTR("Enabled"), enabled ? kCFBooleanTrue : kCFBooleanFalse, OB_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("BindIP"), (__bridge CFStringRef)(ip ?: @""), OB_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("RequestID"), (__bridge CFStringRef)NSUUID.UUID.UUIDString, OB_DOMAIN);
    CFPreferencesSetAppValue(CFSTR("RequestDate"), (__bridge CFDateRef)[NSDate date], OB_DOMAIN);
    if (!CFPreferencesAppSynchronize(OB_DOMAIN)) { [self message:@"无法保存设置"]; return NO; }
    chmod(OB_CONFIG.fileSystemRepresentation, 0644);
    notify_post(OB_NOTIFY);
    return YES;
}
- (void)startLive {
    if ([self command:YES]) [self message:[NSString stringWithFormat:
        @"已发送启动请求（不是启动成功证明）。\n先查看状态，确认系统接口已挂接。\nOBS 地址：tcp://%@:%d\n该操作会影响系统摄像头采集链路；断流时支持的画面格式输出黑屏。", wifiIP(), OB_PORT]];
}
- (void)stopLive { if ([self command:NO]) [self message:@"已发送停止请求，请查看状态确认已恢复。"]; }
- (void)copyURL {
    NSString *ip = wifiIP();
    if (!ip) { [self message:@"未找到 Wi-Fi IPv4 地址"]; return; }
    UIPasteboard.generalPasteboard.string = [NSString stringWithFormat:@"tcp://%@:%d", ip, OB_PORT];
    [self message:@"手机 TCP 地址已复制"]; 
}
- (void)showStatus {
    NSDictionary *status = [NSDictionary dictionaryWithContentsOfFile:OB_STATUS];
    NSDate *date = status[@"Date"];
    if (![date isKindOfClass:NSDate.class] || fabs(date.timeIntervalSinceNow) > 8) {
        [self message:@"媒体服务未响应。检查插件是否注入 mediaserverd、状态文件访问权限，或查看系统日志。安装后需要重启用户空间使系统服务重新加载插件。"]; return;
    }
    NSString *text = status[@"Text"];
    [self message:[text isKindOfClass:NSString.class] ? text : @"状态数据格式错误"];
}
@end
