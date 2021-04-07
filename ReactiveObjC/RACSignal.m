//
//  RACSignal.m
//  ReactiveObjC
//
//  Created by Josh Abernathy on 3/15/12.
//  Copyright (c) 2012 GitHub, Inc. All rights reserved.
//

#import "RACSignal.h"
#import "RACCompoundDisposable.h"
#import "RACDisposable.h"
#import "RACDynamicSignal.h"
#import "RACEmptySignal.h"
#import "RACErrorSignal.h"
#import "RACMulticastConnection.h"
#import "RACNeverSignal.h"
#import "NSObject+RACDescription.h"
#import "RACReplaySubject.h"
#import "RACReturnSignal.h"
#import "RACScheduler.h"
#import "RACSerialDisposable.h"
#import "RACSignal+Operations.h"
#import "RACSubject.h"
#import "RACSubscriber+Private.h"
#import "RACTuple.h"
#import <stdatomic.h>

#if DEBUG

#import "RACSourceSymbolExtractor.h"

@interface RACSignal ()

@property (readonly, nonatomic) NSArray<NSString *> *initializationCallStackSymbols;

@property (readonly, nonatomic) NSLock *initializationSourceSymbolLock;

@property (nonatomic) BOOL didExtractInitializationSourceSymbol;

@end

#endif

@implementation RACSignal

#ifdef DEBUG

@synthesize initializationSourceSymbol = _initializationSourceSymbol;

- (instancetype)init {
  if (self = [super init]) {
    // Lightweight.
    _initializationCallStackSymbols = NSThread.callStackSymbols;

    _initializationSourceSymbolLock = [[NSLock alloc] init];

    self.didExtractInitializationSourceSymbol = NO;
  }

  return self;
}

- (NSString *)initializationSourceSymbol {
  [self.initializationSourceSymbolLock lock];
  if (!self.didExtractInitializationSourceSymbol) {
    // Heavy - done lazily (triggered by debugging) and only once per signal instance.
    _initializationSourceSymbol = RACExtractSourceSymbol(self.initializationCallStackSymbols);

    self.didExtractInitializationSourceSymbol = YES;
  }
  [self.initializationSourceSymbolLock unlock];

  return _initializationSourceSymbol;
}

#endif

#pragma mark Lifecycle

+ (RACSignal *)createSignal:(RACDisposable * (^)(id<RACSubscriber> subscriber))didSubscribe {
  return [RACDynamicSignal createSignal:didSubscribe];
}

+ (RACSignal *)error:(NSError *)error {
  return [RACErrorSignal error:error];
}

+ (RACSignal *)never {
  return [RACNeverSignal never];
}

+ (RACSignal *)startEagerlyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
  NSCParameterAssert(scheduler != nil);
  NSCParameterAssert(block != NULL);

  RACSignal *signal = [self startLazilyWithScheduler:scheduler block:block];
  // Subscribe to force the lazy signal to call its block.
  [[signal publish] connect];
  return [signal setNameWithFormat:@"+startEagerlyWithScheduler: %@ block:", scheduler];
}

+ (RACSignal *)startLazilyWithScheduler:(RACScheduler *)scheduler block:(void (^)(id<RACSubscriber> subscriber))block {
  NSCParameterAssert(scheduler != nil);
  NSCParameterAssert(block != NULL);

  RACMulticastConnection *connection = [[RACSignal
    createSignal:^ id (id<RACSubscriber> subscriber) {
      block(subscriber);
      return nil;
    }]
    multicast:[RACReplaySubject subject]];
  
  return [[[RACSignal
    createSignal:^ id (id<RACSubscriber> subscriber) {
      [connection.signal subscribe:subscriber];
      [connection connect];
      return nil;
    }]
    subscribeOn:scheduler]
    setNameWithFormat:@"+startLazilyWithScheduler: %@ block:", scheduler];
}

#pragma mark NSObject

- (NSString *)description {
  return [NSString stringWithFormat:@"<%@: %p> name: %@", self.class, self, self.name];
}

@end

@implementation RACSignal (RACStream)

+ (RACSignal *)empty {
  return [RACEmptySignal empty];
}

+ (RACSignal *)return:(id)value {
  return [RACReturnSignal return:value];
}

- (RACSignal *)bind:(RACSignalBindBlock (^)(void))block {
  NSCParameterAssert(block != NULL);

  /*
   * -bind: should:
   * 
   * 1. Subscribe to the original signal of values.
   * 2. Any time the original signal sends a value, transform it using the binding block.
   * 3. If the binding block returns a signal, subscribe to it, and pass all of its values through to the subscriber as they're received.
   * 4. If the binding block asks the bind to terminate, complete the _original_ signal.
   * 5. When _all_ signals complete, send completed to the subscriber.
   * 
   * If any signal sends an error at any point, send that to the subscriber.
   */

  return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
    RACSignalBindBlock bindingBlock = block();

    __block atomic_int signalCount = 1;   // indicates self

    RACCompoundDisposable *compoundDisposable = [RACCompoundDisposable compoundDisposable];

    void (^completeSignal)(RACDisposable *) = ^(RACDisposable *finishedDisposable) {
      if (atomic_fetch_sub(&signalCount, 1) - 1 == 0) {
        [subscriber sendCompleted];
        [compoundDisposable dispose];
      } else {
        [compoundDisposable removeDisposable:finishedDisposable];
      }
    };

    void (^addSignal)(RACSignal *) = ^(RACSignal *signal) {
      atomic_fetch_add(&signalCount, 1);

      RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
      [compoundDisposable addDisposable:selfDisposable];

      RACDisposable *disposable = [signal subscribeNext:^(id x) {
        [subscriber sendNext:x];
      } error:^(NSError *error) {
        [compoundDisposable dispose];
        [subscriber sendError:error];
      } completed:^{
        @autoreleasepool {
          completeSignal(selfDisposable);
        }
      }];

      selfDisposable.disposable = disposable;
    };

    @autoreleasepool {
      RACSerialDisposable *selfDisposable = [[RACSerialDisposable alloc] init];
      [compoundDisposable addDisposable:selfDisposable];

      RACDisposable *bindingDisposable = [self subscribeNext:^(id x) {
        // Manually check disposal to handle synchronous errors.
        if (compoundDisposable.disposed) return;

        BOOL stop = NO;
        id signal = bindingBlock(x, &stop);

        @autoreleasepool {
          if (signal != nil) addSignal(signal);
          if (signal == nil || stop) {
            [selfDisposable dispose];
            completeSignal(selfDisposable);
          }
        }
      } error:^(NSError *error) {
        [compoundDisposable dispose];
        [subscriber sendError:error];
      } completed:^{
        @autoreleasepool {
          completeSignal(selfDisposable);
        }
      }];

      selfDisposable.disposable = bindingDisposable;
    }

    return compoundDisposable;
  }] setNameWithFormat:@"[%@] -bind:", self.name];
}

- (RACSignal *)concat:(RACSignal *)signal {
  return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
    RACCompoundDisposable *compoundDisposable = [[RACCompoundDisposable alloc] init];

    RACDisposable *sourceDisposable = [self subscribeNext:^(id x) {
      [subscriber sendNext:x];
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      RACDisposable *concattedDisposable = [signal subscribe:subscriber];
      [compoundDisposable addDisposable:concattedDisposable];
    }];

    [compoundDisposable addDisposable:sourceDisposable];
    return compoundDisposable;
  }] setNameWithFormat:@"[%@] -concat: %@", self.name, signal];
}

+ (instancetype)zip:(id<NSFastEnumeration>)signals {
  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

    NSMutableArray<RACSignal *> *signalsArray = [NSMutableArray array];
    for (RACSignal *signal in signals) {
      [signalsArray addObject:signal];
    }

    NSUInteger signalsCount = signalsArray.count;
    if (!signalsCount) {
      [subscriber sendCompleted];
      return nil;
    }

    // BOOL value indicates if the signal at index has completed.
    __block NSMutableArray *completed = [NSMutableArray arrayWithCapacity:signalsCount];
    // Array of arrays of values sent.
    __block NSMutableArray *values = [NSMutableArray arrayWithCapacity:signalsCount];
    for (NSUInteger i = 0; i < signalsCount; ++i) {
      [completed addObject:@NO];
      [values addObject:[NSMutableArray array]];
    }

    void (^sendCompletedIfNecessary)(void) = ^{
      for (NSUInteger i = 0; i < signalsCount; ++i) {
        if (![values[i] count] && [completed[i] boolValue]) {
          [subscriber sendCompleted];
          return;
        }
      }
    };

    for (NSUInteger i = 0; i < signalsArray.count; ++i) {
      RACDisposable *innerDisposable = [signalsArray[i] subscribeNext:^(id x) {
        @synchronized (values) {
          [values[i] addObject:x ?: RACTupleNil.tupleNil];

          for (NSArray *sentValues in values) {
            if (!sentValues.count) {
              return;
            }
          }

          NSMutableArray *valuesToSend = [NSMutableArray arrayWithCapacity:signalsCount];
          for (NSMutableArray *sentValues in values) {
            [valuesToSend addObject:sentValues.firstObject];
            [sentValues removeObjectAtIndex:0];
          }

          RACTuple *tuple = [RACTuple tupleWithObjectsFromArray:valuesToSend];

          [subscriber sendNext:tuple];
          sendCompletedIfNecessary();
        }
      } error:^(NSError *error) {
        [subscriber sendError:error];
      } completed:^{
        @synchronized (values) {
          completed[i] = @YES;
          sendCompletedIfNecessary();
        }
      }];
      
      [disposable addDisposable:innerDisposable];
    }

    return disposable;
  }] setNameWithFormat:@"+zip: %@", signals];
}

- (RACSignal *)zipWith:(RACSignal *)signal {
  NSCParameterAssert(signal != nil);

  return [[RACSignal createSignal:^(id<RACSubscriber> subscriber) {
    __block BOOL selfCompleted = NO;
    NSMutableArray *selfValues = [NSMutableArray array];

    __block BOOL otherCompleted = NO;
    NSMutableArray *otherValues = [NSMutableArray array];

    void (^sendCompletedIfNecessary)(void) = ^{
      @synchronized (selfValues) {
        BOOL selfEmpty = (selfCompleted && selfValues.count == 0);
        BOOL otherEmpty = (otherCompleted && otherValues.count == 0);
        if (selfEmpty || otherEmpty) [subscriber sendCompleted];
      }
    };

    void (^sendNext)(void) = ^{
      @synchronized (selfValues) {
        if (selfValues.count == 0) return;
        if (otherValues.count == 0) return;

        RACTuple *tuple = RACTuplePack(selfValues[0], otherValues[0]);
        [selfValues removeObjectAtIndex:0];
        [otherValues removeObjectAtIndex:0];

        [subscriber sendNext:tuple];
        sendCompletedIfNecessary();
      }
    };

    RACDisposable *selfDisposable = [self subscribeNext:^(id x) {
      @synchronized (selfValues) {
        [selfValues addObject:x ?: RACTupleNil.tupleNil];
        sendNext();
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      @synchronized (selfValues) {
        selfCompleted = YES;
        sendCompletedIfNecessary();
      }
    }];

    RACDisposable *otherDisposable = [signal subscribeNext:^(id x) {
      @synchronized (selfValues) {
        [otherValues addObject:x ?: RACTupleNil.tupleNil];
        sendNext();
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      @synchronized (selfValues) {
        otherCompleted = YES;
        sendCompletedIfNecessary();
      }
    }];

    return [RACDisposable disposableWithBlock:^{
      [selfDisposable dispose];
      [otherDisposable dispose];
    }];
  }] setNameWithFormat:@"[%@] -zipWith: %@", self.name, signal];
}

- (instancetype)map:(id (^)(id value))block {
  NSCParameterAssert(block != nil);

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    return [self subscribeNext:^(id x) {
      [subscriber sendNext:block(x)];
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -map:", self.name];
}

- (instancetype)filter:(BOOL (^)(id))block {
  NSCParameterAssert(block != nil);

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    return [self subscribeNext:^(id x) {
      if (block(x)) {
        [subscriber sendNext:x];
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -filter:", self.name];
}

- (instancetype)flattenMap:(RACSignal *(^)(id))block {
  return [RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    __block atomic_int subscriptionCount = 1;

    RACCompoundDisposable *disposable = [RACCompoundDisposable compoundDisposable];

    RACDisposable *outerDisposable = [self subscribeNext:^(id x) {
      if (disposable.disposed) {
        return;
      }

      RACSignal *signal = block(x);
      if (!signal) {
        return;
      }
      NSCAssert([signal isKindOfClass:RACSignal.class], @"Expected a RACSignal, got %@", signal);

      atomic_fetch_add(&subscriptionCount, 1);

      RACDisposable *innerDisposable = [signal subscribeNext:^(id x) {
        [subscriber sendNext:x];
      } error:^(NSError *error) {
        [subscriber sendError:error];
        [disposable dispose];
      } completed:^{
        if (atomic_fetch_sub(&subscriptionCount, 1) - 1 == 0) {
          [subscriber sendCompleted];
        }
      }];

      [disposable addDisposable:innerDisposable];
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      if (atomic_fetch_sub(&subscriptionCount, 1) - 1 == 0) {
        [subscriber sendCompleted];
      }
    }];

    [disposable addDisposable:outerDisposable];
    return disposable;
  }];
}

- (instancetype)skip:(NSUInteger)skipCount {
  if (!skipCount) {
    return self;
  }

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    __block NSUInteger skipped = 0;

    return [self subscribeNext:^(id x) {
      if (skipped >= skipCount) {
        [subscriber sendNext:x];
        return;
      }
      ++skipped;
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -skip: %lu", self.name, (unsigned long)skipCount];
}

- (instancetype)take:(NSUInteger)count {
  if (!count) {
    return [RACSignal empty];
  }

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    __block NSUInteger taken = 0;

    return [self subscribeNext:^(id x) {
      // Avoid sending more than `count` values for recursive signals.
      if (taken >= count) {
        return;
      }

      ++taken;
      [subscriber sendNext:x];

      if (taken >= count) {
        [subscriber sendCompleted];
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -take: %lu", self.name, (unsigned long)count];
}

- (instancetype)distinctUntilChanged {
  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    __block id lastValue = nil;
    __block BOOL initial = YES;

    return [self subscribeNext:^(id x) {
      BOOL isEqual = lastValue == x || [x isEqual:lastValue];
      if (!initial && isEqual) {
        return;
      }

      initial = NO;
      lastValue = x;
      [subscriber sendNext:x];
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -distinctUntilChanged", self.name];
}

- (instancetype)scanWithStart:(id)startingValue reduceWithIndex:(id (^)(id, id, NSUInteger))reduceBlock {
  NSCParameterAssert(reduceBlock != nil);

  return [[RACSignal defer:^RACSignal *{
    __block id running = startingValue;
    __block NSUInteger idx = 0;

    return [self map:^id(id value) {
      running = reduceBlock(running, value, idx);
      ++idx;
      return running;
    }];
  }] setNameWithFormat:@"[%@] -scanWithStart: %@ reduceWithIndex:", self.name,
          RACDescription(startingValue)];
}

- (instancetype)combinePreviousWithStart:(id)start reduce:(id (^)(id previous, id next))reduceBlock {
  NSCParameterAssert(reduceBlock != NULL);

  return [[RACSignal createSignal:^RACDisposable * _Nullable(id<RACSubscriber> subscriber) {
    __block id _Nullable previous = start;

    return [self subscribeNext:^(id _Nullable current) {
      id _Nullable reducedValue = reduceBlock(previous, current);
      previous = current;
      [subscriber sendNext:reducedValue];
    } error:^(NSError * _Nullable error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -combinePreviousWithStart: %@ reduce:", self.name, RACDescription(start)];
}

- (instancetype)takeUntilBlock:(BOOL (^)(id x))predicate {
  NSCParameterAssert(predicate != nil);

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    return [self subscribeNext:^(id x) {
      if (predicate(x)) {
        [subscriber sendCompleted];
      } else {
        [subscriber sendNext:x];
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -takeUntilBlock:", self.name];
}

- (instancetype)skipUntilBlock:(BOOL (^)(id x))predicate {
  NSCParameterAssert(predicate != nil);

  return [[RACSignal createSignal:^RACDisposable *(id<RACSubscriber> subscriber) {
    __block BOOL skipping = YES;

    return [self subscribeNext:^(id x) {
      if (skipping) {
        skipping &= !predicate(x);
      }

      if (!skipping) {
        [subscriber sendNext:x];
      }
    } error:^(NSError *error) {
      [subscriber sendError:error];
    } completed:^{
      [subscriber sendCompleted];
    }];
  }] setNameWithFormat:@"[%@] -skipUntilBlock:", self.name];
}

@end

@implementation RACSignal (Subscription)

- (nullable RACDisposable *)subscribe:(id<RACSubscriber>)subscriber {
  NSCAssert(NO, @"This method must be overridden by subclasses");
  return nil;
}

- (nullable RACDisposable *)subscribeNext:(void (^)(id x))nextBlock {
  NSCParameterAssert(nextBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:NULL];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeNext:(void (^)(id x))nextBlock completed:(void (^)(void))completedBlock {
  NSCParameterAssert(nextBlock != NULL);
  NSCParameterAssert(completedBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:NULL completed:completedBlock];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock completed:(void (^)(void))completedBlock {
  NSCParameterAssert(nextBlock != NULL);
  NSCParameterAssert(errorBlock != NULL);
  NSCParameterAssert(completedBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:completedBlock];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeError:(void (^)(NSError *error))errorBlock {
  NSCParameterAssert(errorBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:NULL];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeCompleted:(void (^)(void))completedBlock {
  NSCParameterAssert(completedBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:NULL completed:completedBlock];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeNext:(void (^)(id x))nextBlock error:(void (^)(NSError *error))errorBlock {
  NSCParameterAssert(nextBlock != NULL);
  NSCParameterAssert(errorBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:nextBlock error:errorBlock completed:NULL];
  return [self subscribe:o];
}

- (nullable RACDisposable *)subscribeError:(void (^)(NSError *))errorBlock completed:(void (^)(void))completedBlock {
  NSCParameterAssert(completedBlock != NULL);
  NSCParameterAssert(errorBlock != NULL);
  
  RACSubscriber *o = [RACSubscriber subscriberWithNext:NULL error:errorBlock completed:completedBlock];
  return [self subscribe:o];
}

@end

@implementation RACSignal (Debugging)

- (RACSignal *)logAll {
  return [[[self logNext] logError] logCompleted];
}

- (RACSignal *)logNext {
  return [[self doNext:^(id x) {
    NSLog(@"%@ next: %@", self, x);
  }] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logError {
  return [[self doError:^(NSError *error) {
    NSLog(@"%@ error: %@", self, error);
  }] setNameWithFormat:@"%@", self.name];
}

- (RACSignal *)logCompleted {
  return [[self doCompleted:^{
    NSLog(@"%@ completed", self);
  }] setNameWithFormat:@"%@", self.name];
}

@end

@implementation RACSignal (Testing)

static const NSTimeInterval RACSignalAsynchronousWaitTimeout = 10;

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error {
  return [self asynchronousFirstOrDefault:defaultValue success:success error:error timeout:RACSignalAsynchronousWaitTimeout];
}

- (id)asynchronousFirstOrDefault:(id)defaultValue success:(BOOL *)success error:(NSError **)error timeout:(NSTimeInterval)timeout {
  NSCAssert([NSThread isMainThread], @"%s should only be used from the main thread", __func__);

  __block id result = defaultValue;
  __block BOOL done = NO;

  // Ensures that we don't pass values across thread boundaries by reference.
  __block NSError *localError;
  __block BOOL localSuccess = YES;

  [[[[self
    take:1]
    timeout:timeout onScheduler:[RACScheduler scheduler]]
    deliverOn:RACScheduler.mainThreadScheduler]
    subscribeNext:^(id x) {
      result = x;
      done = YES;
    } error:^(NSError *e) {
      if (!done) {
        localSuccess = NO;
        localError = e;
        done = YES;
      }
    } completed:^{
      done = YES;
    }];
  
  do {
    [NSRunLoop.mainRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
  } while (!done);

  if (success != NULL) *success = localSuccess;
  if (error != NULL) *error = localError;

  return result;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error timeout:(NSTimeInterval)timeout {
  BOOL success = NO;
  [[self ignoreValues] asynchronousFirstOrDefault:nil success:&success error:error timeout:timeout];
  return success;
}

- (BOOL)asynchronouslyWaitUntilCompleted:(NSError **)error {
  return [self asynchronouslyWaitUntilCompleted:error timeout:RACSignalAsynchronousWaitTimeout];
}

@end
