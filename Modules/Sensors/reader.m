//
//  reader.m
//  Sensors
//
//  Created by Serhiy Mytrovtsiy on 06/05/2021.
//  Using Swift 5.0.
//  Running on macOS 10.15.
//
//  Copyright © 2021 Serhiy Mytrovtsiy. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "bridge.h"

@interface AppleSiliconSensorSource : NSObject

@property(nonatomic, assign) IOHIDEventSystemClientRef system;
@property(nonatomic, assign) CFArrayRef services;
@property(nonatomic, strong) NSArray *names;

- (instancetype)initWithPage:(int32_t)page usage:(int32_t)usage;

@end

@implementation AppleSiliconSensorSource

- (instancetype)initWithPage:(int32_t)page usage:(int32_t)usage {
    self = [super init];
    if (self == nil) {
        return nil;
    }

    NSDictionary *matching = @{
        @"PrimaryUsagePage": @(page),
        @"PrimaryUsage": @(usage)
    };

    _system = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_system == nil) {
        return nil;
    }

    IOHIDEventSystemClientSetMatching(_system, (__bridge CFDictionaryRef)matching);
    _services = IOHIDEventSystemClientCopyServices(_system);
    if (_services == nil) {
        CFRelease(_system);
        _system = nil;
        return nil;
    }

    NSMutableArray *names = [NSMutableArray arrayWithCapacity:CFArrayGetCount(_services)];
    for (CFIndex i = 0; i < CFArrayGetCount(_services); i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(_services, i);
        NSString *name = CFBridgingRelease(IOHIDServiceClientCopyProperty(service, CFSTR("Product")));
        [names addObject:name ?: NSNull.null];
    }
    _names = [names copy];

    return self;
}

- (void)dealloc {
    if (_services != nil) {
        CFRelease(_services);
    }
    if (_system != nil) {
        CFRelease(_system);
    }
}

@end

static NSMutableDictionary<NSString *, AppleSiliconSensorSource *> *AppleSiliconSensorSources(void) {
    static NSMutableDictionary<NSString *, AppleSiliconSensorSource *> *sources;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sources = [NSMutableDictionary dictionary];
    });
    return sources;
}

NSDictionary*AppleSiliconSensors(int32_t page, int32_t usage, int32_t type) {
    NSMutableDictionary<NSString *, AppleSiliconSensorSource *> *sources = AppleSiliconSensorSources();
    @synchronized (sources) {
        NSString *key = [NSString stringWithFormat:@"%d:%d", page, usage];
        AppleSiliconSensorSource *source = sources[key];
        if (source == nil) {
            source = [[AppleSiliconSensorSource alloc] initWithPage:page usage:usage];
            if (source == nil) {
                return nil;
            }
            sources[key] = source;
        }

        NSMutableDictionary *values = [NSMutableDictionary dictionary];
        for (CFIndex i = 0; i < CFArrayGetCount(source.services); i++) {
            IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(source.services, i);
            id cachedName = source.names[i];
            NSString *name = cachedName == NSNull.null ? nil : cachedName;

            IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, type, 0, 0);
            if (event == nil) {
                continue;
            }

            if (name != nil) {
                double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(type));
                values[name] = @(value);
            }

            CFRelease(event);
        }

        return values;
    }
}
