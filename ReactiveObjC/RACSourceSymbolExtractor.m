// Copyright (c) 2021 Lightricks. All rights reserved.
// Created by Ofir Gluzman.

#if DEBUG

#import "RACSourceSymbolExtractor.h"

NS_ASSUME_NONNULL_BEGIN

NSString *RACExtractSourceSymbol(NSArray<NSString *> *callStackSymbols) {
  static NSString * const kPattern = @"[0-9]+[\\s]+([\\S]+)[ ]+0x[0-9,a-f]+ (.*?) \\+ ([0-9]+)";
  static NSString * const kRACLibraryName = @"ReactiveObjC";

  NSError *error;
  NSRegularExpression * _Nullable regex = [NSRegularExpression
                                           regularExpressionWithPattern:kPattern
                                           options:0 error:&error];
  NSCAssert(regex != nil, @"Failed to create regex: %@", error);

  for (NSUInteger i = 0; i < callStackSymbols.count; ++i) {
    NSArray<NSTextCheckingResult *> *matches = [regex
                                                matchesInString:callStackSymbols[i] options:0
                                                range:NSMakeRange(0, callStackSymbols[i].length)];
    NSCAssert(matches.count == 1, @"Number of matches (%lu) is expected to be exactly 1",
              (unsigned long)matches.count);
    NSCAssert(matches[0].numberOfRanges == 4, @"Number of ranges (%lu) is expected to be exactly 4",
              (unsigned long)matches[0].numberOfRanges);

    NSString *libraryName = [callStackSymbols[i] substringWithRange:[matches[0] rangeAtIndex:1]];

    if (![libraryName isEqual:kRACLibraryName]) {
      NSString *methodSymbol = [callStackSymbols[i] substringWithRange:[matches[0] rangeAtIndex:2]];
      return methodSymbol;
    }
  }

  NSCAssert(NO, @"Reached the end of the call stack (%@) without finding a source",
            callStackSymbols);
  return @"";
}


NS_ASSUME_NONNULL_END

#endif
