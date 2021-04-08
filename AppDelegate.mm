//
//  AppDelegate.m
//  ObjcPlayground
//
//  Created by Ofir Gluzman on 08/04/2021.
//

#import "AppDelegate.h"

@interface Measurements : NSObject

- (instancetype)initWithCallStackDuration:(NSTimeInterval)callStackDuration
                perSymbolElementDurations:(NSArray<NSNumber *> *)perSymbolElementDurations;

+ (instancetype)make;

@property (readonly, nonatomic) NSTimeInterval callStackDuration;

@property (readonly, nonatomic) NSArray<NSNumber *> *perSymbolElementDurations;

@end

@implementation Measurements

+ (instancetype)make {
  auto beforeCallStack = CACurrentMediaTime();
  auto callStackSymbols = NSThread.callStackSymbols;
  auto afterCallStack = CACurrentMediaTime();
  auto callStackDuration = afterCallStack - beforeCallStack;

  auto perSymbolElementDurations = [NSMutableArray<NSNumber *>
                                    arrayWithCapacity:callStackSymbols.count];
  for (NSUInteger i = 0; i < callStackSymbols.count; ++i) {
    auto before = CACurrentMediaTime();

    // Actual evaluation
    auto __unused _ = callStackSymbols[i];
    auto after = CACurrentMediaTime();

    [perSymbolElementDurations addObject:@(after - before)];
  }

  return [[Measurements alloc] initWithCallStackDuration:callStackDuration
                               perSymbolElementDurations:perSymbolElementDurations];
}

- (instancetype)initWithCallStackDuration:(NSTimeInterval)callStackDuration
                perSymbolElementDurations:(NSArray<NSNumber *> *)perSymbolElementDurations {
  if (self = [super init]) {
    _callStackDuration = callStackDuration;
    _perSymbolElementDurations = perSymbolElementDurations;
  }

  return self;
}

@end

@interface AppDelegate ()

@end

@implementation AppDelegate

- (Measurements *)method_A_WithCounter:(NSUInteger)counter {
  if (counter == 0) {
    return [Measurements make];
  } else {
    return [self method_B_WithCounter:counter - 1];
  }
}

- (Measurements *)method_B_WithCounter:(NSUInteger)counter {
  if (counter == 0) {
    return [Measurements make];
  } else {
    return [self method_A_WithCounter:counter - 1];
  }
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
  NSUInteger stackDepth = 5;
  NSUInteger iterations = 100;

  NSTimeInterval callStackDurationSum = 0;

  auto perSymbolElementDurationsSums = [NSMutableArray<NSNumber *> array];

  for (NSUInteger i = 0; i < iterations; ++i) {
    auto measurements = [self method_A_WithCounter:stackDepth];
    callStackDurationSum += measurements.callStackDuration;

    for (NSUInteger j = 0; j < measurements.perSymbolElementDurations.count; ++j) {
      if (perSymbolElementDurationsSums.count <= j) {
        [perSymbolElementDurationsSums addObject:measurements.perSymbolElementDurations[j]];
      } else {
        // Objective C 😢
        perSymbolElementDurationsSums[j] =
            @(perSymbolElementDurationsSums[j].doubleValue +
              measurements.perSymbolElementDurations[j].doubleValue);
      }
    }
  }

  auto averageCallStackDuration = callStackDurationSum / iterations;

  auto averagePerSymbolElementDurations = [NSMutableArray<NSNumber *> array];
  for (NSUInteger i = 0; i < perSymbolElementDurationsSums.count; ++i) {
    averagePerSymbolElementDurations[i] =
        @(perSymbolElementDurationsSums[i].doubleValue / iterations);
  }

  NSLog(@"averageCallStackDuration: %g", averageCallStackDuration);
  NSLog(@"averagePerSymbolElementDurations: %@", averagePerSymbolElementDurations.description);

  return YES;
}


#pragma mark - UISceneSession lifecycle


- (UISceneConfiguration *)application:(UIApplication *)application configurationForConnectingSceneSession:(UISceneSession *)connectingSceneSession options:(UISceneConnectionOptions *)options {
  // Called when a new scene session is being created.
  // Use this method to select a configuration to create the new scene with.
  return [[UISceneConfiguration alloc] initWithName:@"Default Configuration" sessionRole:connectingSceneSession.role];
}


- (void)application:(UIApplication *)application didDiscardSceneSessions:(NSSet<UISceneSession *> *)sceneSessions {
  // Called when the user discards a scene session.
  // If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
  // Use this method to release any resources that were specific to the discarded scenes, as they will not return.
}


@end
