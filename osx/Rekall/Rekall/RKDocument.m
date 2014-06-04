//
//  RKDocument.m
//  Rekall
//
//  Created by Adam Sindelar on 5/8/14.
//  Copyright (c) 2014 Rekall. All rights reserved.
//

#import "RKDocument.h"
#import "RKSessionWrapper.h"

@interface RKDocument ()

@property (retain) RKSessionWrapper *rekall;
@property (retain) NSURL *rekallURL;

@property (copy) NSURL *deferredLoadURL;
@property (copy, nonatomic) void (^webViewLoadCallback)(WebView *);

- (void)loadWebconsole:(id)sender;
- (void)reportError:(NSError *)error;

- (void)loadPageWhenReady:(NSURL *)url callback:(void (^)(WebView *))callback;
- (void)injectJavascriptResource:(NSString *)resource;
- (NSString *)injectJavascript:(NSString *)js;
- (NSString *)callJavascriptFunction:(NSString *)function args:(NSArray *)args onReady:(BOOL)onReady;

@end


@interface RKDocument (WebFrameLoadDelegate)

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame;
- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame;
- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame;

@end


@implementation RKDocument (WebFrameLoadDelegate)

- (void)webView:(WebView *)sender didFinishLoadForFrame:(WebFrame *)frame {
    NSLog(@"WebView done loading!");
    if (self.webViewLoadCallback) {
        self.webViewLoadCallback(sender);
    }
    
    [self.spinner removeFromSuperview];
}

- (void)webView:(WebView *)sender didFailProvisionalLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    NSLog(@"WebView provisional load error: %@", error);
}

- (void)webView:(WebView *)sender didFailLoadWithError:(NSError *)error forFrame:(WebFrame *)frame {
    NSLog(@"WebView load error: %@", error);
}

@end


@implementation RKDocument

- (void)loadPageWhenReady:(NSURL *)url callback:(void (^)(WebView *))callback {
    self.webViewLoadCallback = callback;
    if(!self.webView) {
        // WebView isn't initialized yet. Save the URL for deferred action.
        self.deferredLoadURL = url;
        return;
    }
    
    [self.webView performSelectorOnMainThread:@selector(setMainFrameURL:)
                                   withObject:[url absoluteString]
                                waitUntilDone:NO];
}

- (void)injectJavascriptResource:(NSString *)resource {
    NSString *path = [[NSBundle mainBundle] pathForResource:resource ofType:@"js"];
    NSString *js = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSLog(@"Injecting JS from %@.js. Output: %@",
          resource,
          [self injectJavascript:js]);
}

- (NSString *)injectJavascript:(NSString *)js {
    return [self.webView stringByEvaluatingJavaScriptFromString:js];
}

- (NSString *)callJavascriptFunction:(NSString *)function args:(NSArray *)args onReady:(BOOL)onReady {
    NSMutableString *js = [[NSMutableString alloc] init];
    
    if (onReady) {
        [js appendString:@"$(function() {"];
    }
    
    [js appendString:@"var _args = [];"];
    
    for (NSString *arg in args) {
        [js appendString:
         [NSString stringWithFormat:
          @"_args.push(decodeURIComponent('%@'));",
          [arg stringByAddingPercentEscapesUsingEncoding:NSUTF8StringEncoding]]];
    }
    
    [js appendString:[NSString stringWithFormat: @"%@.apply(this, _args);", function]];
    
    if (onReady) {
        [js appendString:@"});"];
    }
    
    NSString *result = [self injectJavascript:js];
    NSLog(@"Generated safe function call: %@\noutput:%@", js, result);
    
    return result;
}

- (void)reportError:(NSError *)error {
    NSLog(@"Reporting error %@", error);
    
    NSString *errorPath = [[NSBundle mainBundle] pathForResource:@"error" ofType:@"html"];
    NSURL *errorURL = [NSURL fileURLWithPath:errorPath];
    
    NSString *errorTitle = [error.userInfo objectForKey:RKErrorTitle];
    NSString *errorDescription = [error.userInfo objectForKey:RKErrorDescription];
    
    if (!errorTitle) {
        errorTitle = error ? [error localizedDescription] : @"unknown error";
    }
    
    if (!errorDescription) {
        errorDescription = error ? [error localizedFailureReason] : @"unknown error";
    }
    
    __weak id weakSelf = self;
    [self loadPageWhenReady:errorURL
                   callback:^(WebView *sender) {
                       // Inject jQuery
                       [weakSelf injectJavascriptResource:@"jquery.min"];
                       [weakSelf injectJavascriptResource:@"error"];
                       [weakSelf callJavascriptFunction:@"showError"
                                                   args:@[errorTitle, errorDescription]
                                                onReady:YES];
                   }];

    [self.rekall stopRekallWebconsoleSession];
}

- (void)windowControllerDidLoadNib:(NSWindowController *)windowController {
    [super windowControllerDidLoadNib:windowController];
    [self.spinner startAnimation:self];
    self.webView.frameLoadDelegate = self;
    
    // If there's a deferred load request we can handle it now that the nib is initialized.
    if(self.deferredLoadURL) {
        [self.webView setMainFrameURL:[self.deferredLoadURL absoluteString]];
        self.deferredLoadURL = nil;
    }
}

- (void)loadWebconsole:(id)sender {
    self.rekallURL = [NSURL URLWithString:[NSString stringWithFormat:@"http://127.0.0.1:%d", (int)self.rekall.port]];
    NSLog(@"Connecting to the Rekall webconsole at %@", self.rekallURL);
    [self loadPageWhenReady:self.rekallURL callback:nil];
}

- (NSString *)windowNibName {
    return @"RKDocument";
}

+ (BOOL)autosavesInPlace {
    return YES;
}

- (void)close {
    NSLog(@"Terminating rekall instance at %@ because window closed.", self.rekallURL);
    [self.rekall stopRekallWebconsoleSession];
}

- (NSData *)dataOfType:(NSString *)typeName error:(NSError *__autoreleasing *)outError {
    NSLog(@"Not yet implemented.");
    return nil;
}

- (BOOL)readFromURL:(NSURL *)url ofType:(NSString *)typeName error:(NSError *__autoreleasing *)outError {
    self.rekall = [[RKSessionWrapper alloc] init];
    __weak id weakSelf = self;
    
    self.rekall.onLaunchCallback = ^(void) {
        // I get called when the webconsole is done launching.
        [weakSelf loadWebconsole:nil];
    };
    
    self.rekall.onErrorCallback = ^(NSError *error) {
        [weakSelf reportError:error];
    };
    
    if ([typeName isEqualToString:@"com.google.rekall-session"]) {
        // Restore saved session.
        NSLog(@"Not yet implemented.");
        return NO;
    }
    
    // Any other file format we get passed we try to treat as a memory image.
    // Memory images are obviously read only, so dissociate the document with the filetype and url.
    self.fileType = @"com.google.rekall-session";
    self.fileURL = nil;

    return [self.rekall startWebconsoleWithImage:url error:outError];
}

@end
