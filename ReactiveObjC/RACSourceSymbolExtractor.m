// Copyright (c) 2021 Lightricks. All rights reserved.
// Created by Ofir Gluzman.

#if DEBUG

#import "RACSourceSymbolExtractor.h"

#include <dlfcn.h>

NS_ASSUME_NONNULL_BEGIN

NSString *RACExtractSourceSymbol(void **addresses, NSUInteger addressesCount) {
  static NSString * const kRACLibraryName = @"ReactiveObjC";

  Dl_info info;
  for (NSUInteger i = 0; i < addressesCount; ++i) {
    dladdr(addresses[i], &info);
    NSString *frameworkPath = [NSString stringWithUTF8String:info.dli_fname];
    if (![[frameworkPath pathComponents].lastObject isEqual:kRACLibraryName]) {
      return [NSString stringWithUTF8String:info.dli_sname];
    }
  }

  return nil;
}


NS_ASSUME_NONNULL_END

#endif
