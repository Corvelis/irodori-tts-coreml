#pragma once
#import <Foundation/Foundation.h>
#include <cstddef>
#include <cstdint>

// Preserve the short-utterance path. At 25 latent frames/s, this is a
// predicted utterance of at least ten seconds, before silence trimming.
// Chat normally sends one sentence; multi-sentence inputs are not covered by
// the long-sentence sampling validation and keep the original schedule.
inline bool IrodoriUseLongSentenceSampling(NSString *source, int64_t frames) {
  if (frames < 250) return false;
  NSString *body = [source stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (body.length == 0) return false;
  NSCharacterSet *stops = [NSCharacterSet characterSetWithCharactersInString:@"。！？!?"];
  if ([stops characterIsMember:[body characterAtIndex:body.length - 1]]) {
    body = [body substringToIndex:body.length - 1];
  }
  NSCharacterSet *boundaries = [NSCharacterSet characterSetWithCharactersInString:
    @"。！？!?\n\r"];
  if ([body rangeOfCharacterFromSet:boundaries].location != NSNotFound) return false;
  for (NSUInteger i = 0; i < body.length; ++i) {
    const unichar c = [body characterAtIndex:i];
    if (c >= 0x3040 && c <= 0x30FF) return true;
  }
  return false;
}

// Like upstream strip_outer_brackets: an enclosing pair is formatting, while
// quoted words inside a sentence remain part of its linguistic context.
inline NSString *IrodoriTextWithoutOuterBrackets(NSString *source) {
  NSString *text = [source stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  bool changed = false;
  while (text.length >= 2) {
    const unichar first = [text characterAtIndex:0];
    unichar close = 0;
    switch (first) {
      case 0x300C: close = 0x300D; break; // 「」
      case 0x300E: close = 0x300F; break; // 『』
      case 0xFF08: close = 0xFF09; break; // （）
      case 0x3010: close = 0x3011; break; // 【】
      case '(': close = ')'; break;
      default: return changed ? text : source;
    }
    if ([text characterAtIndex:text.length - 1] != close) break;
    NSInteger depth = 0;
    bool enclosing = true;
    for (NSUInteger i = 0; i < text.length; ++i) {
      const unichar c = [text characterAtIndex:i];
      if (c == first) ++depth;
      if (c == close) --depth;
      if (depth == 0 && i + 1 < text.length) { enclosing = false; break; }
    }
    if (!enclosing || depth != 0) break;
    NSString *inner = [[text substringWithRange:NSMakeRange(1, text.length - 2)]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (inner.length == 0) break;
    text = inner;
    changed = true;
  }
  return changed ? text : source;
}

// On short Japanese utterances a terminal full stop can cause MF to allocate
// excess speech and drift away from the text. Only remove this non-spoken
// terminator from one short sentence; keep questions, emphasis, internal
// punctuation and longer contexts intact. Token count includes the BOS token.
inline NSString *IrodoriTextForConditioning(NSString *source,
                                          size_t originalTokenCount) {
  if (originalTokenCount <= 1 || originalTokenCount > 8) return source;
  NSString *trimmed = [source stringByTrimmingCharactersInSet:
    NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (![trimmed hasSuffix:@"。"] || trimmed.length < 2) return source;
  NSString *body = [trimmed substringToIndex:trimmed.length - 1];
  NSCharacterSet *boundaries = [NSCharacterSet characterSetWithCharactersInString:
    @"。！？!?\n\r"];
  if ([body rangeOfCharacterFromSet:boundaries].location != NSNotFound) return source;
  bool japanese = false;
  for (NSUInteger i = 0; i < body.length; ++i) {
    const unichar c = [body characterAtIndex:i];
    if ((c >= 0x3040 && c <= 0x30FF) || (c >= 0x3400 && c <= 0x9FFF)) {
      japanese = true;
      break;
    }
  }
  return japanese ? body : source;
}
