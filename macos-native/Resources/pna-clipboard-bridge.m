#import <Cocoa/Cocoa.h>

// Read a UTF-8 handoff from stdin, write it through the native AppKit
// pasteboard API, and verify the same bytes through the same pasteboard
// connection. Keeping write and read in one process avoids the GUI-launched
// pbcopy/pbpaste session race seen on macOS.
int main(void) {
    @autoreleasepool {
        NSData *payload = [[NSFileHandle fileHandleWithStandardInput] readDataToEndOfFile];
        NSString *value = [[NSString alloc] initWithData:payload encoding:NSUTF8StringEncoding];
        if (value == nil) return 65;

        NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
        [pasteboard clearContents];
        if (![pasteboard setString:value forType:NSPasteboardTypeString]) return 70;

        NSString *readbackValue = [pasteboard stringForType:NSPasteboardTypeString];
        NSData *readback = [readbackValue dataUsingEncoding:NSUTF8StringEncoding];
        if (readback == nil || ![readback isEqualToData:payload]) return 71;
        return 0;
    }
}
